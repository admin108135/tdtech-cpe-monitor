import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class CPEHttpOverrides extends io.HttpOverrides {
  @override
  io.HttpClient createHttpClient(io.SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (io.X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  io.HttpOverrides.global = CPEHttpOverrides();
  runApp(const CPEMonitorApp());
}

class CPEMonitorApp extends StatelessWidget {
  const CPEMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鼎桥 INS2 信号监测与锁频',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF76FF03),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class SignalMetrics {
  final String pci;
  final String pciDecimal;
  final String cellId;
  final String plmn;
  final String band;
  final String bandNumberOnly;
  final String arfcn;
  final String dlArfcnOnly;
  final String dlBandwidth;
  final String ulMcs;
  final String txPower;
  final double nrRsrp;
  final double nrSinr;
  final double nrRsrq;
  final Map<String, String> raw;
  final DateTime timestamp;

  SignalMetrics({
    required this.pci,
    required this.pciDecimal,
    required this.cellId,
    required this.plmn,
    required this.band,
    required this.bandNumberOnly,
    required this.arfcn,
    required this.dlArfcnOnly,
    required this.dlBandwidth,
    required this.ulMcs,
    required this.txPower,
    required this.nrRsrp,
    required this.nrSinr,
    required this.nrRsrq,
    required this.raw,
    required this.timestamp,
  });

  static double _parseNumeric(String? raw, double fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    final match = RegExp(r'[-+]?\d+(\.\d+)?').firstMatch(raw);
    if (match != null) {
      return double.tryParse(match.group(0)!) ?? fallback;
    }
    return fallback;
  }

  static String _findTag(XmlElement root, List<String> candidates) {
    for (final tag in candidates) {
      final elements = root.findElements(tag);
      if (elements.isNotEmpty && elements.first.innerText.trim().isNotEmpty) {
        return elements.first.innerText.trim();
      }
    }
    return '--';
  }

  static String _raw(XmlElement root, String tag) {
    final elements = root.findElements(tag);
    if (elements.isEmpty) return '';
    return elements.first.innerText.trim();
  }

  static String _convertPciToDecimal(String rawPci) {
    if (rawPci == '--') return '';
    if (RegExp(r'^\d+$').hasMatch(rawPci)) return rawPci;
    final parsedHex = int.tryParse(rawPci, radix: 16);
    return parsedHex?.toString() ?? rawPci;
  }

  static String _extractDlArfcn(String rawArfcn) {
    final match = RegExp(r'DL:(\d+)').firstMatch(rawArfcn);
    if (match != null) return match.group(1)!;
    final numMatch = RegExp(r'\d+').firstMatch(rawArfcn);
    return numMatch?.group(0) ?? '';
  }

  static Map<String, String> _inferBandInfo(
      String rawBand, String rawFreq, String rawArfcn) {
    if (rawBand != '--' && rawBand != '0') {
      final clean = rawBand.replaceAll(RegExp(r'[^0-9]'), '');
      return {'label': 'n$clean', 'num': clean};
    }
    if (rawFreq.contains('3450000') ||
        rawFreq.contains('35') ||
        rawArfcn.contains('630000')) {
      return {'label': 'n78 (3.5GHz)', 'num': '78'};
    }
    if (rawFreq.contains('25') || rawFreq.contains('26')) {
      return {'label': 'n41 (2.6GHz)', 'num': '41'};
    }
    if (rawFreq.contains('700')) {
      return {'label': 'n28 (700MHz)', 'num': '28'};
    }
    if (rawFreq.contains('2100')) {
      return {'label': 'n1 (2.1GHz)', 'num': '1'};
    }
    return {'label': rawBand, 'num': '78'};
  }

  static String _formatOperator(String plmn) {
    switch (plmn) {
      case '46001':
      case '46006':
      case '46009':
        return '中国联通 ($plmn)';
      case '46000':
      case '46002':
      case '46004':
      case '46007':
        return '中国移动 ($plmn)';
      case '46003':
      case '46005':
      case '46011':
        return '中国电信 ($plmn)';
      case '46015':
        return '中国广电 ($plmn)';
      default:
        return plmn;
    }
  }

  factory SignalMetrics.fromXml(XmlDocument doc) {
    final root = doc.rootElement;
    final nrRsrpStr = _findTag(root, ['nrrsrp', '5g_rsrp', 'nr_rsrp']);
    final nrSinrStr = _findTag(root, ['nrsinr', '5g_sinr', 'nr_sinr']);
    final nrRsrqStr = _findTag(root, ['nrrsrq', '5g_rsrq', 'nr_rsrq']);
    final lteRsrpStr = _findTag(root, ['rsrp']);
    final lteSinrStr = _findTag(root, ['sinr']);

    final rawArfcn = _findTag(root, ['nrarfcn', 'earfcn']);
    final rawFreq = _findTag(root, ['nrdlfreq', 'nrulfreq', 'dlfrequency']);
    final rawBand = _findTag(root, ['nrband', 'band']);
    final bandInfo = _inferBandInfo(rawBand, rawFreq, rawArfcn);

    final rawPci = _findTag(root, ['nrpci', 'pci', 'sc']);
    final decPci = _convertPciToDecimal(rawPci);

    final rawMcs = _findTag(root, ['nrulmcs', 'nrmcsup', 'mcs']);
    final rawTxPower = _findTag(root, ['nrtxpower', 'transpower', 'ppusch']);

    const rawTags = [
      'pci', 'sc', 'cell_id', 'rsrq', 'rsrp', 'rssi', 'sinr', 'rscp',
      'ecio', 'mode', 'ulbandwidth', 'dlbandwidth', 'txpower', 'tdd',
      'ul_mcs', 'dl_mcs', 'earfcn', 'rrc_status', 'rac', 'lac', 'tac',
      'band', 'nei_cellid', 'plmn', 'ims', 'wdlfreq', 'lteulfreq',
      'ltedlfreq', 'transmode', 'enodeb_id', 'cqi0', 'cqi1', 'ulfrequency',
      'dlfrequency', 'nrulbandwidth', 'nrdlbandwidth', 'nrulmcs', 'nrdlmcs',
      'nrtxpower', 'nrearfcn', 'nrulfreq', 'nrdlfreq', 'nrsinr', 'nrrsrp',
      'nrrsrq', 'arfcn', 'bsic', 'rxlev',
    ];
    final raw = <String, String>{
      for (final t in rawTags) t: _raw(root, t),
    };

    return SignalMetrics(
      pci: decPci.isNotEmpty && decPci != rawPci ? '$rawPci ($decPci)' : rawPci,
      pciDecimal: decPci,
      cellId: _findTag(root, ['nrcellid', 'cell_id']),
      plmn: _formatOperator(_findTag(root, ['plmn'])),
      band: bandInfo['label']!,
      bandNumberOnly: bandInfo['num']!,
      arfcn: rawArfcn.replaceAll(' ', ' · '),
      dlArfcnOnly: _extractDlArfcn(rawArfcn),
      dlBandwidth: _findTag(root, ['nrdlbandwidth', 'dlbandwidth']),
      ulMcs: rawMcs.replaceAll('NRmcsUpCarrier1:', ''),
      txPower: rawTxPower,
      nrRsrp: nrRsrpStr != '--'
          ? _parseNumeric(nrRsrpStr, -140)
          : _parseNumeric(lteRsrpStr, -140),
      nrSinr: nrSinrStr != '--'
          ? _parseNumeric(nrSinrStr, -20)
          : _parseNumeric(lteSinrStr, -20),
      nrRsrq: _parseNumeric(nrRsrqStr, -20),
      raw: raw,
      timestamp: DateTime.now(),
    );
  }
}

class CellTower {
  final String type;
  final bool registered;
  final String pci;
  final String arfcn;
  final String band;
  final String plmn;
  final String cid;
  final String tac;
  final double? rsrp;
  final double? rsrq;
  final double? sinr;
  final double? rssi;

  CellTower({
    required this.type,
    required this.registered,
    required this.pci,
    required this.arfcn,
    required this.band,
    required this.plmn,
    required this.cid,
    required this.tac,
    required this.rsrp,
    required this.rsrq,
    required this.sinr,
    required this.rssi,
  });

  factory CellTower.fromMap(Map<dynamic, dynamic> m) {
    String s(String k) => (m[k] ?? '').toString();
    double? d(String k) {
      final v = m[k];
      return v is num ? v.toDouble() : null;
    }

    final mcc = s('mcc');
    final mnc = s('mnc');
    return CellTower(
      type: s('type'),
      registered: m['registered'] == true,
      pci: s('pci'),
      arfcn: s('arfcn'),
      band: s('band'),
      plmn: mcc.isEmpty ? '' : '$mcc-$mnc',
      cid: s('cid'),
      tac: s('tac'),
      rsrp: d('rsrp'),
      rsrq: d('rsrq'),
      sinr: d('sinr'),
      rssi: d('rssi'),
    );
  }
}

class CellScanScreen extends StatefulWidget {
  const CellScanScreen({super.key});

  @override
  State<CellScanScreen> createState() => _CellScanScreenState();
}

class _CellScanScreenState extends State<CellScanScreen> {
  static const MethodChannel _channel = MethodChannel('com.tdtech.cpe/cellinfo');
  bool _busy = false;
  bool _needPerm = false;
  bool _blocked = false;
  String _status = '正在读取手机基带小区信息...';
  final List<CellTower> _cells = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _blocked = false;
      _status = '正在读取手机基带...';
    });
    final phoneStatus = await Permission.phone.status;
    final locStatus = await Permission.locationWhenInUse.status;
    if (!phoneStatus.isGranted || !locStatus.isGranted) {
      final reqs = await [Permission.phone, Permission.locationWhenInUse].request();
      final phoneOk = reqs[Permission.phone]?.isGranted ?? false;
      final locOk = reqs[Permission.locationWhenInUse]?.isGranted ?? false;
      if (!phoneOk || !locOk) {
        setState(() {
          _busy = false;
          _needPerm = true;
          _status = '需要电话和位置权限才能读取小区信息';
        });
        return;
      }
    }
    try {
      final raw = await _channel.invokeMethod<String>('getCellInfo');
      if (raw == null) throw '空响应';
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      final st = doc['status'];
      if (st == 'need_permission') {
        setState(() {
          _busy = false;
          _needPerm = true;
          _status = '未获得电话权限';
        });
        return;
      }
      if (st == 'security') {
        setState(() {
          _busy = false;
          _blocked = true;
          _status = '系统限制：当前机型不允许第三方应用读取小区信息'
              '（${doc['message'] ?? 'Not allowed'}）';
        });
        return;
      }
      if (st == 'error') {
        setState(() {
          _busy = false;
          _status = '读取失败: ${doc['message'] ?? '未知'}';
        });
        return;
      }
      final list = (doc['cells'] as List? ?? []);
      _cells
        ..clear()
        ..addAll(list.map((e) => CellTower.fromMap(e as Map<dynamic, dynamic>)));
      _cells.sort((a, b) => (b.rsrp ?? -150).compareTo(a.rsrp ?? -150));
      setState(() {
        _busy = false;
        _needPerm = false;
        _status = '共 ${_cells.length} 个小区（服务小区 + 周边邻区）';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _status = '读取异常: $e';
      });
    }
  }

  Color _rsrpColor(double? v) {
    if (v == null) return Colors.grey;
    if (v >= -85) return Colors.greenAccent;
    if (v >= -100) return Colors.amberAccent;
    return Colors.redAccent;
  }

  Color _sinrColor(double? v) {
    if (v == null) return Colors.grey;
    if (v >= 15) return Colors.greenAccent;
    if (v >= 5) return Colors.amberAccent;
    return Colors.redAccent;
  }

  String _fmt(double? v, String unit) =>
      v == null ? '--' : '${v.toStringAsFixed(0)}$unit';

  Widget _buildCellCard(CellTower c, bool neighbor) {
    final title = neighbor ? '邻区' : '服务小区';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: neighbor ? Colors.white12 : Colors.cyanAccent.withOpacity(0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('${c.type} · $title',
                    style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ),
              const Spacer(),
              if (c.band.isNotEmpty)
                Text(c.band,
                    style: const TextStyle(fontSize: 12, color: Colors.amberAccent)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'PCI ${c.pci.isEmpty ? '--' : c.pci} · 频点 ${c.arfcn.isEmpty ? '--' : c.arfcn}'
            '${c.plmn.isEmpty ? '' : ' · PLMN ${c.plmn}'}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _signalItem('RSRP', _fmt(c.rsrp, ' dBm'), _rsrpColor(c.rsrp)),
              _signalItem('RSRQ', _fmt(c.rsrq, ' dB'), _rsrpColor(c.rsrq)),
              _signalItem('SINR', _fmt(c.sinr, ' dB'), _sinrColor(c.sinr)),
              _signalItem('RSSI', _fmt(c.rssi, ' dBm'), Colors.white70),
            ],
          ),
          if (c.cid.isNotEmpty && c.cid != '0')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Cell ID: ${c.cid}${c.tac.isEmpty ? '' : ' · TAC ${c.tac}'}',
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
            ),
        ],
      ),
    );
  }

  Widget _signalItem(String label, String value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final serving = _cells.where((c) => c.registered).toList();
    final neighbors = _cells.where((c) => !c.registered).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('手机基带小区扫描'),
        backgroundColor: const Color(0xFF1A1A1A),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新扫描',
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF252525),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '说明：以下为手机自身基带扫描到的小区，非 CPE 空口邻区；部分国产系统仅返回服务小区、不提供周边邻区。',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
          const SizedBox(height: 14),
          if (_needPerm || _blocked)
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新申请权限'),
                    onPressed: _busy ? null : _refresh,
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('去系统设置'),
                    onPressed: () => openAppSettings(),
                  ),
                ],
              ),
            ),
          if (!_needPerm && !_blocked && serving.isNotEmpty) ...[
            const Text('服务小区',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...serving.map((c) => _buildCellCard(c, false)),
          ],
          if (!_needPerm && !_blocked && neighbors.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text('周边邻区',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...neighbors.map((c) => _buildCellCard(c, true)),
          ],
          if (!_needPerm && !_blocked && !_busy && _cells.isEmpty)
            Container(
              margin: const EdgeInsets.only(top: 20),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '系统未返回任何小区信息。可能原因：未驻留蜂窝、信号过弱，或系统裁剪了基带信息（华为/荣耀机型较常见）。',
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
            ),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _gatewayIp = '192.168.1.1';
  bool _useHttps = true;
  String _sessionCookie = '';
  String _requestToken = '';
  bool _isPolling = false;
  String _statusMessage = '未连接，正在初始化会话...';
  SignalMetrics? _currentMetrics;
  final List<FlSpot> _rsrpHistory = [];
  final List<FlSpot> _sinrHistory = [];
  double _timeStep = 0;
  Timer? _pollingTimer;

  String get _baseUrl => '${_useHttps ? "https" : "http"}://$_gatewayIp';

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
  }

  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _gatewayIp = prefs.getString('gateway_ip') ?? '192.168.1.1';
      _useHttps = prefs.getBool('use_https') ?? true;
      _sessionCookie = prefs.getString('session_cookie') ?? '';
      _requestToken = prefs.getString('request_token') ?? '';
    });
    await _refreshToken();
    _startPolling();
  }

  Future<void> _persistSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_cookie', _sessionCookie);
    await prefs.setString('request_token', _requestToken);
  }

  void _mergeSessionCookie(String setCookie) {
    final sessionMatch = RegExp(r'SessionID=[^;]+').firstMatch(setCookie);
    if (sessionMatch == null) return;
    final newSession = sessionMatch.group(0)!;
    final parts = _sessionCookie
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    parts.removeWhere((p) => p.startsWith('SessionID='));
    parts.add(newSession);
    _sessionCookie = parts.join('; ');
  }

  static const String _cpeUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  Map<String, String> get _baseHeaders {
    final h = <String, String>{
      'Referer': '$_baseUrl/html/index.html',
      'User-Agent': _cpeUserAgent,
    };
    if (_sessionCookie.isNotEmpty) h['Cookie'] = _sessionCookie;
    return h;
  }

  Future<void> _refreshToken() async {
    try {
      // 1) 新款固件：/api/webserver/token -> <token>
      try {
        final r1 = await http
            .get(Uri.parse('$_baseUrl/api/webserver/token'),
                headers: _baseHeaders)
            .timeout(const Duration(seconds: 3));
        if (r1.statusCode == 200) {
          final d1 = XmlDocument.parse(r1.body);
          final t =
              d1.rootElement.findElements('token').firstOrNull?.innerText;
          if (t != null && t.isNotEmpty) _requestToken = t;
        }
      } catch (_) {}

      // 2) 老款固件：/api/webserver/SesTokInfo -> SesInfo / TokInfo
      try {
        final r2 = await http
            .get(Uri.parse('$_baseUrl/api/webserver/SesTokInfo'),
                headers: _baseHeaders)
            .timeout(const Duration(seconds: 3));
        if (r2.statusCode == 200) {
          final d2 = XmlDocument.parse(r2.body);
          final ses =
              d2.rootElement.findElements('SesInfo').firstOrNull?.innerText;
          final tok =
              d2.rootElement.findElements('TokInfo').firstOrNull?.innerText;
          if (ses != null && _sessionCookie.isEmpty) {
            _sessionCookie = ses;
          }
          if (tok != null && tok.isNotEmpty && _requestToken.isEmpty) {
            _requestToken = tok;
          }
        }
      } catch (_) {}

      await _persistSession();
    } catch (_) {}
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    setState(() {
      _isPolling = true;
      _statusMessage = '正在实时轮询 ($_baseUrl)...';
    });
    _fetchSignalOnce();
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _fetchSignalOnce();
    });
  }

  void _stopPolling() {
    _pollingTimer?.cancel();
    setState(() {
      _isPolling = false;
      _statusMessage = '监测已暂停';
    });
  }

  Future<void> _fetchSignalOnce() async {
    try {
      final uri = Uri.parse('$_baseUrl/api/device/signal');
      final headers = Map<String, String>.from(_baseHeaders);
      if (_requestToken.isNotEmpty) {
        headers['__RequestVerificationToken'] = _requestToken;
      }

      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 2));

      _updateHeadersFromResponse(response);

      if (response.statusCode == 200) {
        final doc = XmlDocument.parse(response.body);
        if (doc.rootElement.name.local == 'error') {
          final code =
              doc.rootElement.findElements('code').firstOrNull?.innerText ??
                  '未知';
          setState(() {
            _statusMessage =
                '需登录授权 (错误码: $code)，请点钥匙登录 [cookie:${_sessionCookie.length} token:${_requestToken.length}]';
          });
          return;
        }

        final metrics = SignalMetrics.fromXml(doc);
        setState(() {
          _currentMetrics = metrics;
          _statusMessage =
              '${metrics.plmn} · 在线 (${metrics.timestamp.toIso8601String().substring(11, 19)})';
          _timeStep += 1;
          _rsrpHistory.add(FlSpot(_timeStep, metrics.nrRsrp));
          _sinrHistory.add(FlSpot(_timeStep, metrics.nrSinr));
          if (_rsrpHistory.length > 40) _rsrpHistory.removeAt(0);
          if (_sinrHistory.length > 40) _sinrHistory.removeAt(0);
        });
      } else {
        setState(() {
          _statusMessage = 'HTTP 状态码异常: ${response.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = '连接超时，请确认已连接 CPE Wi-Fi ($_baseUrl)';
      });
    }
  }

  void _updateHeadersFromResponse(http.Response response) {
    bool changed = false;
    if (response.headers.containsKey('__requestverificationtoken')) {
      final rawTok = response.headers['__requestverificationtoken']!;
      _requestToken = rawTok
          .split('#')
          .firstWhere((e) => e.isNotEmpty, orElse: () => rawTok);
      changed = true;
    }
    if (response.headers.containsKey('set-cookie')) {
      _mergeSessionCookie(response.headers['set-cookie']!);
      changed = true;
    }
    if (changed) _persistSession();
  }

  Future<String> _postHilinkXml(String apiPath, String xmlBody) async {
    await _refreshToken();
    try {
      final cleanPath = apiPath.startsWith('http')
          ? Uri.parse(apiPath).path
          : (apiPath.startsWith('/') ? apiPath : '/$apiPath');
      final uri = Uri.parse('$_baseUrl$cleanPath');
      final headers = Map<String, String>.from(_baseHeaders);
      headers['Content-Type'] = 'application/xml; charset=UTF-8';
      headers['X-Requested-With'] = 'XMLHttpRequest';
      if (_requestToken.isNotEmpty) {
        headers['__RequestVerificationToken'] = _requestToken;
      }

      final response = await http
          .post(uri, headers: headers, body: xmlBody)
          .timeout(const Duration(seconds: 5));

      _updateHeadersFromResponse(response);

      if (response.body.contains('<response>OK</response>')) {
        return 'OK';
      } else if (response.body.contains('<code>')) {
        final doc = XmlDocument.parse(response.body);
        final errCode =
            doc.rootElement.findElements('code').firstOrNull?.innerText ?? '未知';
        return '错误码: $errCode (若为100003请在钥匙图标内开启开发者模式)';
      }
      return '响应: ${response.body}';
    } catch (e) {
      return '请求异常: $e';
    }
  }

  Future<void> _showLockControlSheet() async {
    final prefs = await SharedPreferences.getInstance();
    String capturedApi =
        prefs.getString('last_dev_api') ?? '/api/net/cell-lock';
    String capturedXml = prefs.getString('last_dev_xml') ?? '';

    String selectedBandMask = '20000000000000000000';
    String selectedNetMode = '08';
    final bandController =
        TextEditingController(text: _currentMetrics?.bandNumberOnly ?? '78');
    final arfcnController =
        TextEditingController(text: _currentMetrics?.dlArfcnOnly ?? '630000');
    final pciController =
        TextEditingController(text: _currentMetrics?.pciDecimal ?? '332');
    final customApiController = TextEditingController(text: capturedApi);
    final customXmlController = TextEditingController(text: capturedXml);

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '一、 5G 频段与网络模式锁定',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: selectedNetMode,
                  decoration: const InputDecoration(
                    labelText: '网络模式 (NetworkMode)',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: '08', child: Text('5G 优先 / SA模式 (08)')),
                    DropdownMenuItem(value: '00', child: Text('5G/4G 自动切换 (00)')),
                    DropdownMenuItem(value: '03', child: Text('仅 4G 模式 (03)')),
                  ],
                  onChanged: (v) => setSheetState(() => selectedNetMode = v!),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: selectedBandMask,
                  decoration: const InputDecoration(
                    labelText: '目标 5G NR 频段',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: '7FFFFFFFFFFFFFFF',
                      child: Text('全频段自动 (不锁频段)'),
                    ),
                    DropdownMenuItem(
                      value: '20000000000000000000',
                      child: Text('仅锁 n78 (联通/电信 3.5GHz)'),
                    ),
                    DropdownMenuItem(
                      value: '10000000000',
                      child: Text('仅锁 n41 (移动/广电 2.6GHz)'),
                    ),
                    DropdownMenuItem(
                      value: '8000000',
                      child: Text('仅锁 n28 (700MHz 广覆盖)'),
                    ),
                    DropdownMenuItem(
                      value: '1',
                      child: Text('仅锁 n1 (2.1GHz)'),
                    ),
                  ],
                  onChanged: (v) => setSheetState(() => selectedBandMask = v!),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.settings_input_antenna),
                    label: const Text('下发网络模式与频段指令'),
                    onPressed: () async {
                      final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<request>
  <NetworkMode>$selectedNetMode</NetworkMode>
  <NetworkBand>4680380</NetworkBand>
  <LTEBand>7E2880E00D5</LTEBand>
  <NRBand>$selectedBandMask</NRBand>
</request>''';
                      final res =
                          await _postHilinkXml('/api/net/net-mode', xml);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('锁频执行结果: $res')),
                        );
                      }
                    },
                  ),
                ),
                const Divider(height: 24),
                const Text(
                  '二、 5G 物理小区锁定 (锁 PCI / 频点)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: bandController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Band',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: arfcnController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '频点 ARFCN',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: pciController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '十进制PCI',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.lock),
                        label: const Text('锁定该 PCI'),
                        onPressed: () async {
                          final b = bandController.text.trim();
                          final a = arfcnController.text.trim();
                          final p = pciController.text.trim();
                          final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<request>
  <lock_type>1</lock_type>
  <rat>1</rat>
  <band>$b</band>
  <arfcn>$a</arfcn>
  <pci>$p</pci>
</request>''';
                          var res =
                              await _postHilinkXml('/api/net/cell-lock', xml);
                          if (res != 'OK') {
                            res = await _postHilinkXml(
                                '/api/net/nr-cell-lock', xml);
                          }
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('锁 PCI 结果: $res')),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.lock_open),
                        label: const Text('解除锁定'),
                        onPressed: () async {
                          const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<request>
  <lock_type>0</lock_type>
  <rat>1</rat>
  <band>0</band>
  <arfcn>0</arfcn>
  <pci>0</pci>
</request>''';
                          var res =
                              await _postHilinkXml('/api/net/cell-lock', xml);
                          if (res != 'OK') {
                            res = await _postHilinkXml(
                                '/api/net/nr-cell-lock', xml);
                          }
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('解锁结果: $res')),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
                if (capturedXml.isNotEmpty) ...[
                  const Divider(height: 24),
                  const Text(
                    '三、 已捕获的【开发者模式】原生指令重放',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.cyanAccent),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: customApiController,
                    decoration: const InputDecoration(
                      labelText: '捕获到的开发者 API 路径',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: customXmlController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '捕获到的 XML 报文 (可直接修改参数后发送)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.send),
                      label: const Text('直接重放该开发者模式指令'),
                      onPressed: () async {
                        final res = await _postHilinkXml(
                          customApiController.text.trim(),
                          customXmlController.text.trim(),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('开发者指令执行结果: $res')),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showIpSettingsDialog() async {
    final controller = TextEditingController(text: _gatewayIp);
    bool tempHttps = _useHttps;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置 CPE 网关参数'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '网关 IP 地址',
                  hintText: '192.168.1.1',
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 HTTPS 加密访问'),
                subtitle: const Text('自动忽略过期或自签名 SSL 证书'),
                value: tempHttps,
                onChanged: (val) => setDialogState(() => tempHttps = val),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newIp = controller.text.trim();
                if (newIp.isNotEmpty) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('gateway_ip', newIp);
                  await prefs.setBool('use_https', tempHttps);
                  setState(() {
                    _gatewayIp = newIp;
                    _useHttps = tempHttps;
                  });
                  await _refreshToken();
                  _startPolling();
                }
                if (context.mounted) Navigator.pop(ctx);
              },
              child: const Text('保存并重连'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openWebAuthPage() async {
    _stopPolling();
    final capturedCookie = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => WebAuthScreen(baseUrl: _baseUrl),
      ),
    );
    if (capturedCookie != null && capturedCookie.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session_cookie', capturedCookie);
      setState(() {
        _sessionCookie = capturedCookie;
      });
      await _refreshToken();
    }
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = _currentMetrics;
    return Scaffold(
      appBar: AppBar(
        title: const Text('鼎桥 INS2 信号与锁频'),
        backgroundColor: const Color(0xFF1A1A1A),
        actions: [
          IconButton(
            icon: const Icon(Icons.network_cell, color: Colors.cyanAccent),
            tooltip: '手机基带小区扫描',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CellScanScreen()),
            ),
          ),
          IconButton(
            icon:
                const Icon(Icons.lock_person_outlined, color: Colors.amberAccent),
            tooltip: '锁频段 / 锁PCI',
            onPressed: _showLockControlSheet,
          ),
          IconButton(
            icon: const Icon(Icons.vpn_key_outlined),
            tooltip: '网页登录与捕获接口',
            onPressed: _openWebAuthPage,
          ),
          IconButton(
            icon: const Icon(Icons.settings_ethernet),
            tooltip: '修改网关与协议',
            onPressed: _showIpSettingsDialog,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF252525),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  _isPolling ? Icons.radar : Icons.pause_circle_outline,
                  color: _isPolling ? Colors.greenAccent : Colors.amber,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.55,
            children: [
              _buildMetricCard(
                '5G RSRP (接收功率)',
                m != null ? '${m.nrRsrp.toStringAsFixed(0)} dBm' : '--',
                _evaluateRsrpColor(m?.nrRsrp),
              ),
              _buildMetricCard(
                '5G SINR (信干噪比)',
                m != null ? '${m.nrSinr.toStringAsFixed(0)} dB' : '--',
                _evaluateSinrColor(m?.nrSinr),
              ),
              _buildMetricCard(
                '5G RSRQ / 发射功率',
                m != null
                    ? '${m.nrRsrq.toStringAsFixed(1)}dB / ${m.txPower}'
                    : '--',
                Colors.cyanAccent,
              ),
              _buildMetricCard(
                'PCI / 驻留频段',
                m != null ? 'PCI:${m.pci} · ${m.band}' : '--',
                Colors.amberAccent,
              ),
              _buildMetricCard(
                '小区 CELL ID / 上行MCS',
                m != null ? '${m.cellId} (MCS:${m.ulMcs})' : '--',
                Colors.white70,
              ),
              _buildMetricCard(
                '频点 / 载波带宽',
                m != null ? '${m.dlArfcnOnly} / ${m.dlBandwidth}' : '--',
                Colors.white70,
              ),
            ],
          ),
          const SizedBox(height: 18),
          _buildChartSection(
            title: '5G RSRP 实时走势 (dBm) · 越高越好',
            spots: _rsrpHistory,
            minY: -130,
            maxY: -50,
            lineColor: const Color(0xFF00E5FF),
          ),
          const SizedBox(height: 16),
          _buildChartSection(
            title: '5G SINR 实时走势 (dB) · 越高越稳定',
            spots: _sinrHistory,
            minY: -10,
            maxY: 40,
            lineColor: const Color(0xFF76FF03),
          ),
          const SizedBox(height: 16),
          if (m != null) _buildDetailPanel(m),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isPolling ? _stopPolling : _startPolling,
        icon: Icon(_isPolling ? Icons.pause : Icons.play_arrow),
        label: Text(_isPolling ? '暂停轮询' : '开始轮询'),
      ),
    );
  }

  Color _evaluateRsrpColor(double? rsrp) {
    if (rsrp == null) return Colors.grey;
    if (rsrp >= -85) return Colors.greenAccent;
    if (rsrp >= -100) return Colors.amberAccent;
    return Colors.redAccent;
  }

  Color _evaluateSinrColor(double? sinr) {
    if (sinr == null) return Colors.grey;
    if (sinr >= 15) return Colors.greenAccent;
    if (sinr >= 5) return Colors.amberAccent;
    return Colors.redAccent;
  }

  Widget _buildMetricCard(String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _dv(Map<String, String> raw, String key) {
    final v = raw[key] ?? '';
    return v.isEmpty ? '--' : v;
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.white60)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _detailGroupTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(t,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.cyanAccent)),
    );
  }

  Widget _buildDetailPanel(SignalMetrics m) {
    final raw = m.raw;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('完整参数明细',
              style:
                  TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          _detailGroupTitle('小区标识'),
          _detailRow('PCI', m.pci),
          _detailRow('Cell ID', _dv(raw, 'cell_id')),
          _detailRow('TAC', _dv(raw, 'tac')),
          _detailRow('LAC', _dv(raw, 'lac')),
          _detailRow('PLMN', _dv(raw, 'plmn')),
          _detailRow('RRC 状态', _dv(raw, 'rrc_status')),
          _detailRow('驻留模式 mode', _dv(raw, 'mode')),
          _detailRow('IMS', _dv(raw, 'ims')),
          _detailRow('CQI0 / CQI1',
              '${_dv(raw, 'cqi0')} / ${_dv(raw, 'cqi1')}'),
          _detailGroupTitle('5G NR'),
          _detailRow('RSRP', _dv(raw, 'nrrsrp')),
          _detailRow('RSRQ', _dv(raw, 'nrrsrq')),
          _detailRow('SINR', _dv(raw, 'nrsinr')),
          _detailRow('下行带宽', _dv(raw, 'nrdlbandwidth')),
          _detailRow('上行带宽', _dv(raw, 'nrulbandwidth')),
          _detailRow('下行 MCS', _dv(raw, 'nrdlmcs')),
          _detailRow('上行 MCS', _dv(raw, 'nrulmcs')),
          _detailRow('发射功率', _dv(raw, 'nrtxpower')),
          _detailRow('ARFCN', _dv(raw, 'nrearfcn')),
          _detailRow('下行频点', _dv(raw, 'nrdlfreq')),
          _detailRow('上行频点', _dv(raw, 'nrulfreq')),
          _detailGroupTitle('LTE / 其他制式'),
          _detailRow('RSRP', _dv(raw, 'rsrp')),
          _detailRow('RSRQ', _dv(raw, 'rsrq')),
          _detailRow('SINR', _dv(raw, 'sinr')),
          _detailRow('RSSI', _dv(raw, 'rssi')),
          _detailRow('RSCP', _dv(raw, 'rscp')),
          _detailRow('ECIO', _dv(raw, 'ecio')),
          _detailRow('下行带宽', _dv(raw, 'dlbandwidth')),
          _detailRow('上行带宽', _dv(raw, 'ulbandwidth')),
          _detailRow('发射功率', _dv(raw, 'txpower')),
          _detailRow('TDD', _dv(raw, 'tdd')),
          _detailRow('下行 MCS', _dv(raw, 'dl_mcs')),
          _detailRow('上行 MCS', _dv(raw, 'ul_mcs')),
          _detailRow('EARFCN', _dv(raw, 'earfcn')),
          _detailRow('下行频点', _dv(raw, 'dlfrequency')),
          _detailRow('上行频点', _dv(raw, 'ulfrequency')),
          _detailRow('eNodeB ID', _dv(raw, 'enodeb_id')),
          _detailRow('传输模式', _dv(raw, 'transmode')),
          _detailRow('ARFCN', _dv(raw, 'arfcn')),
          _detailRow('BSIC', _dv(raw, 'bsic')),
          _detailRow('RXLEV', _dv(raw, 'rxlev')),
          _detailGroupTitle('邻区'),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8)),
            child: const Text(
              '⚠️ 当前设备 Web 接口不返回 CPE 基带邻区列表（nei_cellid 为空），无法获取周边邻区。',
              style: TextStyle(fontSize: 12, color: Colors.amberAccent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartSection({
    required String title,
    required List<FlSpot> spots,
    required double minY,
    required double maxY,
    required Color lineColor,
  }) {
    return Container(
      height: 210,
      padding: const EdgeInsets.fromLTRB(12, 14, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: spots.isEmpty
                ? const Center(
                    child: Text('等待数据采集中...',
                        style: TextStyle(color: Colors.white38)),
                  )
                : LineChart(
                    LineChartData(
                      minY: minY,
                      maxY: maxY,
                      gridData:
                          const FlGridData(show: true, drawVerticalLine: false),
                      titlesData: const FlTitlesData(
                        topTitles:
                            AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles:
                            AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles:
                            AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: false),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: lineColor,
                          barWidth: 2.5,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: lineColor.withOpacity(0.15),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class WebAuthScreen extends StatefulWidget {
  final String baseUrl;
  const WebAuthScreen({super.key, required this.baseUrl});

  @override
  State<WebAuthScreen> createState() => _WebAuthScreenState();
}

class _WebAuthScreenState extends State<WebAuthScreen> {
  final CookieManager _cookieManager = CookieManager.instance();
  List<Map<String, String>> _captures = [];

  static const String _xhrInterceptorScript = '''
    (function() {
      if (window._cpeHooked) return;
      window._cpeHooked = true;
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this._method = method;
        this._url = url;
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        var self = this;
        var method = (this._method || '').toUpperCase();
        var url = this._url || '';
        var report = function(payload) {
          if (window.flutter_inappwebview && url.indexOf('/api/') >= 0) {
            window.flutter_inappwebview.callHandler('onApiCaptured', method, url, payload == null ? '' : String(payload));
          }
        };
        if (method === 'POST') {
          if (body) report(body);
        } else {
          this.addEventListener('load', function() {
            var resp = '';
            try { resp = self.responseText || ''; } catch (e) {}
            report(resp);
          });
        }
        return origSend.apply(this, arguments);
      };
    })();
  ''';

  @override
  void initState() {
    super.initState();
    _loadCaptures();
  }

  Future<void> _loadCaptures() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('dev_captures');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _captures =
            list.map((e) => Map<String, String>.from(e as Map)).toList();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveCaptures() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dev_captures', jsonEncode(_captures));
  }

  void _addCapture(String method, String url, String payload) {
    final key = '$method $url $payload';
    final dup = _captures.any(
        (c) => '${c['method']} ${c['url']} ${c['payload']}' == key);
    if (!dup) {
      _captures.insert(0, {
        'method': method,
        'url': url,
        'payload': payload,
        'time': DateTime.now().toIso8601String().substring(11, 19),
      });
      if (_captures.length > 50) _captures.removeLast();
      _saveCaptures();
    }
    if (mounted) setState(() {});
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
    }
  }

  String _encodeAll() {
    return _captures
        .map((c) =>
            '[${c['time']}] ${c['method']} ${c['url']}\n报文: ${c['payload']}')
        .join('\n\n---\n\n');
  }

  Future<void> _clearCaptures() async {
    _captures.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('dev_captures');
    setState(() {});
  }

  Future<void> _extractCookieAndClose() async {
    try {
      final cookies = await _cookieManager.getCookies(
        url: WebUri('${widget.baseUrl}/'),
      );
      final cookiePairs = cookies.map((c) => '${c.name}=${c.value}').toList();
      final fullCookieHeader = cookiePairs.join('; ');

      if (mounted) {
        Navigator.pop(context, fullCookieHeader);
      }
    } catch (_) {
      if (mounted) {
        Navigator.pop(context, '');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录与开发者接口捕获'),
        actions: [
          TextButton.icon(
            onPressed: _extractCookieAndClose,
            icon: const Icon(Icons.check_circle, color: Colors.greenAccent),
            label: const Text('完成并返回',
                style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: const Color(0xFF263238),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Text('已捕获 ${_captures.length} 条',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.cyanAccent)),
                const Spacer(),
                TextButton.icon(
                  onPressed:
                      _captures.isEmpty ? null : () => _copyText(_encodeAll()),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制全部', style: TextStyle(fontSize: 12)),
                ),
                TextButton.icon(
                  onPressed: _captures.isEmpty ? null : _clearCaptures,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: _captures.isEmpty
                ? const Center(
                    child: Text(
                      '暂无记录。在下方网页浏览信号/小区/锁小区页面后，\n此处会逐条记录 GET 响应与 POST 请求。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: _captures.length,
                    itemBuilder: (ctx, i) {
                      final c = _captures[i];
                      return Card(
                        color: const Color(0xFF1E1E1E),
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.white12,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(c['method'] ?? '',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.amberAccent)),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(c['url'] ?? '',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace')),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 16),
                                    onPressed: () => _copyText(
                                        '[${c['method']}] ${c['url']}\n报文: ${c['payload']}'),
                                  ),
                                ],
                              ),
                              Text(c['time'] ?? '',
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white38)),
                              const SizedBox(height: 6),
                              SelectableText(
                                c['payload'] ?? '',
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white70,
                                    fontFamily: 'monospace'),
                                maxLines: 6,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Expanded(
            flex: 5,
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('${widget.baseUrl}/html/index.html'),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                useShouldOverrideUrlLoading: false,
              ),
              onReceivedServerTrustAuthRequest: (controller, challenge) async {
                return ServerTrustAuthResponse(
                  action: ServerTrustAuthResponseAction.PROCEED,
                );
              },
              onWebViewCreated: (controller) {
                controller.addJavaScriptHandler(
                  handlerName: 'onApiCaptured',
                  callback: (args) async {
                    if (args.length >= 3) {
                      final method = args[0].toString();
                      final apiUrl = args[1].toString();
                      final payload = args[2].toString();
                      if (!apiUrl.contains('login')) {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('last_dev_api', apiUrl);
                        await prefs.setString('last_dev_method', method);
                        await prefs.setString('last_dev_xml', payload);
                        _addCapture(method, apiUrl, payload);
                      }
                    }
                  },
                );
              },
              onLoadStop: (controller, url) async {
                await controller.evaluateJavascript(
                    source: _xhrInterceptorScript);
              },
            ),
          ),
        ],
      ),
    );
  }
}
