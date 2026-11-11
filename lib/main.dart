import 'dart:async';
import 'dart:io' as io;
import 'package:flutter/material.dart';
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

    final rawMcs = _findTag(root, ['nrmcsup', 'mcs']);
    final rawTxPower = _findTag(root, ['nrtxpower', 'transpower', 'ppusch']);

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
      timestamp: DateTime.now(),
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
    });
    await _refreshToken();
    _startPolling();
  }

  Future<void> _refreshToken() async {
    try {
      final uri = Uri.parse('$_baseUrl/api/webserver/SesTokInfo');
      final headers = <String, String>{
        'Referer': '$_baseUrl/html/index.html',
      };
      if (_sessionCookie.isNotEmpty) headers['Cookie'] = _sessionCookie;

      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final doc = XmlDocument.parse(response.body);
        final ses =
            doc.rootElement.findElements('SesInfo').firstOrNull?.innerText;
        final tok =
            doc.rootElement.findElements('TokInfo').firstOrNull?.innerText;
        if (ses != null && _sessionCookie.isEmpty) {
          _sessionCookie = ses;
        }
        if (tok != null) {
          _requestToken = tok;
        }
      }
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
      final headers = <String, String>{
        'Referer': '$_baseUrl/html/index.html',
      };
      if (_sessionCookie.isNotEmpty) headers['Cookie'] = _sessionCookie;
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
            _statusMessage = '需登录授权 (错误码: $code)，请点击右上角钥匙图标登录';
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
    if (response.headers.containsKey('__requestverificationtoken')) {
      final rawTok = response.headers['__requestverificationtoken']!;
      _requestToken = rawTok
          .split('#')
          .firstWhere((e) => e.isNotEmpty, orElse: () => rawTok);
    }
    if (response.headers.containsKey('set-cookie')) {
      final rawCookie = response.headers['set-cookie']!;
      final sessionMatch = RegExp(r'SessionID=[^;]+').firstMatch(rawCookie);
      if (sessionMatch != null) {
        _sessionCookie = sessionMatch.group(0)!;
      }
    }
  }

  Future<String> _postHilinkXml(String apiPath, String xmlBody) async {
    await _refreshToken();
    try {
      final cleanPath = apiPath.startsWith('http')
          ? Uri.parse(apiPath).path
          : (apiPath.startsWith('/') ? apiPath : '/$apiPath');
      final uri = Uri.parse('$_baseUrl$cleanPath');
      final headers = <String, String>{
        'Content-Type': 'application/xml; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': '$_baseUrl/html/index.html',
      };
      if (_sessionCookie.isNotEmpty) headers['Cookie'] = _sessionCookie;
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
  String _capturedLog =
      '提示：请先登录后台。下方网页浏览信号/小区/锁小区等页面时，此处会自动记录 GET 响应与 POST 请求的接口和报文，可用于核对邻区字段。';

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

  Future<void> _extractCookieAndClose() async {
    try {
      final cookies = await _cookieManager.getCookies(
        url: WebUri('${widget.baseUrl}/html/index.html'),
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
            width: double.infinity,
            color: const Color(0xFF263238),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SelectableText(
              _capturedLog,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.cyanAccent,
                fontFamily: 'monospace',
              ),
              maxLines: 10,
            ),
          ),
          Expanded(
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
                        setState(() {
                          _capturedLog = '[$method] $apiUrl\n报文: $payload';
                        });
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
