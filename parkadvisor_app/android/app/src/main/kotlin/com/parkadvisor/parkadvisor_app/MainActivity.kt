package com.parkadvisor.parkadvisor_app

import android.Manifest
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bgChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            (getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
        startBgServiceIfPermitted()
    }

    override fun onResume() {
        super.onResume()
        startBgServiceIfPermitted()
        pushForegroundWifiHintIfAvailable()
        val snap = FixedWifiMonitorService.instance?.refreshAndGetSnapshot()
            ?: FixedWifiMonitorService.buildFallbackSnapshot(this)
        bgChannel?.invokeMethod("onNativeStateUpdated", snap)
    }

    private fun readForegroundWifiSsid(): String? {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
            if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val wifiInfo = caps.transportInfo as? WifiInfo
                val s = wifiInfo?.ssid?.replace("\"", "")?.trim()
                if (!s.isNullOrEmpty() && s != "<unknown ssid>") return s
            }
        } catch (_: Exception) {}
        return try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            val s = wm?.connectionInfo?.ssid?.replace("\"", "")?.trim()
            if (!s.isNullOrEmpty() && s != "<unknown ssid>") s else null
        } catch (_: Exception) {
            null
        }
    }

    private fun pushForegroundWifiHintIfAvailable() {
        val fgSsid = readForegroundWifiSsid()
        if (!fgSsid.isNullOrEmpty()) {
            val p = getSharedPreferences(FixedWifiMonitorService.PREFS_NAME, Context.MODE_PRIVATE)
            p.edit().putString("ui_wifi_ssid", fgSsid).apply()
            FixedWifiMonitorService.instance?.onFlutterConfigSynced(mapOf("uiDetectedWifiSsid" to fgSsid))
        }
    }

    private fun persistFallbackConfig(args: Map<String, Any?>) {
        val p = getSharedPreferences(FixedWifiMonitorService.PREFS_NAME, Context.MODE_PRIVATE)
        val ed = p.edit()
        (args["homeWifiSsid"] as? String)?.trim()?.let {
            if (it.isNotEmpty()) ed.putString("home_wifi_ssid", it.replace("\"", ""))
        }
        if (args["clearHomeWifi"] == true) ed.remove("home_wifi_ssid")
        (args["workWifiSsid"] as? String)?.trim()?.let {
            if (it.isNotEmpty()) ed.putString("work_wifi_ssid", it.replace("\"", ""))
        }
        if (args["clearWorkWifi"] == true) ed.remove("work_wifi_ssid")
        if (args.containsKey("uiDetectedWifiSsid")) {
            val s = (args["uiDetectedWifiSsid"] as? String)?.replace("\"", "")?.trim()
            if (!s.isNullOrEmpty() && s != "<unknown ssid>") ed.putString("ui_wifi_ssid", s)
        }
        (args["carBtMac"] as? String)?.trim()?.let {
            if (it.isNotEmpty()) ed.putString("car_bt_mac", it.uppercase())
        }
        (args["tGpsNoStepSec"] as? Number)?.let {
            ed.putInt("tgps_senzapasso_sec", it.toInt().coerceIn(10, 180))
        }
        (args["geofenceRadiusM"] as? Number)?.let {
            ed.putInt("geofence_radius_m", it.toInt().coerceIn(20, 2000))
        }
        if (args.containsKey("parkedLat") && args.containsKey("parkedLon")) {
            val lat = (args["parkedLat"] as? Number)?.toDouble()
            val lon = (args["parkedLon"] as? Number)?.toDouble()
            if (lat != null && lon != null) {
                ed.putString("parked_lat", lat.toString())
                ed.putString("parked_lon", lon.toString())
            } else {
                ed.remove("parked_lat")
                ed.remove("parked_lon")
            }
        }
        if (args["clearPromptInCar"] == true) ed.putBoolean("prompt_in_car", false)
        (args["forceUserState"] as? String)?.trim()?.let {
            if (it.isNotEmpty()) ed.putString("user_state", it)
        }
        ed.apply()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parknow/bg_service")
        bgChannel = channel

        FixedWifiMonitorService.uiStateListener = { snap ->
            runOnUiThread {
                try {
                    bgChannel?.invokeMethod("onNativeStateUpdated", snap)
                } catch (_: Exception) {}
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestFullScreenIntentPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        if (!nm.canUseFullScreenIntent()) {
                            try {
                                startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName")))
                            } catch (_: Exception) {}
                            result.success(false)
                        } else {
                            result.success(true)
                        }
                    } else {
                        result.success(true)
                    }
                }
                "startMonitorService" -> {
                    startBgServiceIfPermitted()
                    pushForegroundWifiHintIfAvailable()
                    result.success(true)
                }
                "getNativeStateSnapshot" -> {
                    startBgServiceIfPermitted()
                    pushForegroundWifiHintIfAvailable()
                    val snap = FixedWifiMonitorService.instance?.refreshAndGetSnapshot()
                        ?: FixedWifiMonitorService.buildFallbackSnapshot(this)
                    result.success(snap)
                }
                "syncConfigToNative" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                    persistFallbackConfig(args)
                    startBgServiceIfPermitted()
                    val snap = FixedWifiMonitorService.instance?.onFlutterConfigSynced(args)
                        ?: FixedWifiMonitorService.buildFallbackSnapshot(this)
                    result.success(snap)
                }
                "confirmInCar" -> {
                    sendBroadcast(Intent(FixedWifiMonitorService.ACTION_CONFIRM_IN_CAR).setPackage(packageName))
                    result.success(true)
                }
                "denyInCar" -> {
                    sendBroadcast(Intent(FixedWifiMonitorService.ACTION_DENY_IN_CAR).setPackage(packageName))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        FixedWifiMonitorService.uiStateListener = null
        bgChannel = null
        super.onDestroy()
    }

    private fun startBgServiceIfPermitted() {
        val hasFine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) return
        try {
            val svcIntent = Intent(this, FixedWifiMonitorService::class.java).apply {
                action = FixedWifiMonitorService.ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try { startForegroundService(svcIntent) } catch (_: Throwable) {}
            } else {
                startService(svcIntent)
            }
        } catch (_: Exception) {}
    }
}
