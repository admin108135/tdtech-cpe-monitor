package com.tdtech.tdtech_cpe_monitor

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.CellIdentityLte
import android.telephony.CellIdentityNr
import android.telephony.CellInfo
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellSignalStrengthLte
import android.telephony.CellSignalStrengthNr
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private val channelName = "com.tdtech.cpe/cellinfo"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCellInfo" -> result.success(readCellInfo())
                    "hasPermission" -> result.success(hasPhonePermission())
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPhonePermission(): Boolean {
        return checkSelfPermission(Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun readCellInfo(): String {
        if (!hasPhonePermission()) {
            return JSONObject().put("status", "need_permission").toString()
        }
        return try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            val list: List<CellInfo> =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    tm.allCellInfo ?: emptyList()
                else emptyList()
            val arr = JSONArray()
            for (info in list) {
                val obj = JSONObject()
                obj.put("registered", info.isRegistered)
                when (info) {
                    is CellInfoNr -> {
                        obj.put("type", "NR")
                        val id = info.cellIdentity as CellIdentityNr
                        val sig = info.cellSignalStrength as CellSignalStrengthNr
                        obj.put("pci", id.pci)
                        obj.put("arfcn", id.nrarfcn)
                        obj.put("mcc", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) (id.mccString ?: "") else "")
                        obj.put("mnc", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) (id.mncString ?: "") else "")
                        obj.put("cid", id.nci.toString())
                        obj.put("tac", id.tac.toString())
                        putNrSignal(obj, sig)
                    }
                    is CellInfoLte -> {
                        obj.put("type", "LTE")
                        val id = info.cellIdentity as CellIdentityLte
                        val sig = info.cellSignalStrength as CellSignalStrengthLte
                        obj.put("pci", id.pci)
                        obj.put("arfcn", id.earfcn)
                        obj.put("mcc", intToStr(id.mcc))
                        obj.put("mnc", intToStr(id.mnc))
                        obj.put("cid", id.ci.toString())
                        obj.put("tac", id.tac.toString())
                        putLteSignal(obj, sig)
                    }
                    else -> obj.put("type", "OTHER")
                }
                arr.put(obj)
            }
            JSONObject().put("status", "ok").put("cells", arr).toString()
        } catch (e: SecurityException) {
            JSONObject().put("status", "security")
                .put("message", e.message ?: "Not allowed").toString()
        } catch (e: Exception) {
            JSONObject().put("status", "error")
                .put("message", e.message ?: "unknown").toString()
        }
    }

    private fun intToStr(intVal: Int): String {
        return if (intVal != Integer.MAX_VALUE) intVal.toString() else ""
    }

    private fun validDbm(v: Int?): Double? {
        if (v == null) return null
        if (v <= -1400 || v == Integer.MAX_VALUE) return null
        return v.toDouble()
    }

    private fun putNrSignal(obj: JSONObject, sig: CellSignalStrengthNr) {
        obj.put("rsrp", validDbm(sig.csiRsrp) ?: validDbm(sig.ssRsrp))
        obj.put("rsrq", validDbm(sig.csiRsrq) ?: validDbm(sig.ssRsrq))
        obj.put("sinr", validDbm(sig.csiSinr) ?: validDbm(sig.ssSinr))
        obj.put("rssi", null)
    }

    private fun putLteSignal(obj: JSONObject, sig: CellSignalStrengthLte) {
        obj.put("rsrp", validDbm(sig.rsrp))
        obj.put("rsrq", validDbm(sig.rsrq))
        obj.put("sinr", validDbm(sig.rssnr))
        obj.put("rssi", validDbm(sig.rssi))
    }
}
