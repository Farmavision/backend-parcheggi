package com.parkadvisor.parkadvisor_app

import android.Manifest
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
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
    private var stateReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            (getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        startBgServiceIfPermitted()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parknow/bg_service")
        bgChannel = channel

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
                    result.success(true)
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

        if (stateReceiver == null) {
            stateReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action == FixedWifiMonitorService.ACTION_STATE_UPDATED) {
                        bgChannel?.invokeMethod("onNativeStateUpdated", null)
                    }
                }
            }
            ContextCompat.registerReceiver(
                this,
                stateReceiver,
                IntentFilter(FixedWifiMonitorService.ACTION_STATE_UPDATED),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
        }
    }

    override fun onDestroy() {
        try {
            stateReceiver?.let { unregisterReceiver(it) }
            stateReceiver = null
        } catch (_: Exception) {}
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
