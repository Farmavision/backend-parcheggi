package com.parkadvisor.parkadvisor_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.parknow.app/classic_bt"
    private var methodChannel: MethodChannel? = null

    private val btReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            val mac = device?.address ?: return
            val name = try {
                device.name ?: "Dispositivo Bluetooth"
            } catch (_: SecurityException) {
                "Dispositivo Bluetooth"
            }

            val payload = HashMap<String, String>()
            payload["mac"] = mac
            payload["name"] = name

            if (action == BluetoothDevice.ACTION_ACL_CONNECTED) {
                methodChannel?.invokeMethod("onBtConnected", payload)
            } else if (action == BluetoothDevice.ACTION_ACL_DISCONNECTED) {
                methodChannel?.invokeMethod("onBtDisconnected", payload)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getBondedDevices") {
                try {
                    val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                    val adapter: BluetoothAdapter? = btManager.adapter
                    val list = ArrayList<Any>()
                    adapter?.bondedDevices?.forEach { dev ->
                        val item = HashMap<String, String>()
                        item["name"] = dev.name ?: "Dispositivo BT"
                        item["mac"] = dev.address
                        list.add(item)
                    }
                    result.success(list)
                } catch (e: SecurityException) {
                    result.error("PERM_ERROR", "Permesso Bluetooth mancante", null)
                }
            } else {
                result.notImplemented()
            }
        }

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(btReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(btReceiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(btReceiver)
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
