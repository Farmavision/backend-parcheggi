package com.parkadvisor.parkadvisor_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.max
import kotlin.math.sqrt

class FixedWifiMonitorService : Service(), SensorEventListener {

    companion object {
        const val PREFS_NAME = "parknow_native_store"
        const val CHANNEL_FG = "parknow_fg_service_v1"
        const val CHANNEL_ALERT = "parknow_urgent_alarm_v4"
        const val FG_NOTIF_ID = 4101
        const val PROMPT_NOTIF_ID = 4102
        const val IN_CAR_PROMPT_NOTIF_ID = 4103
        const val RELEASED_NOTIF_ID = 4104
        const val WIFI_PROMPT_NOTIF_ID = 9042

        const val ACTION_START = "com.parkadvisor.ACTION_START"
        const val ACTION_CONFIRM_RELEASE = "com.parkadvisor.ACTION_CONFIRM_RELEASE"
        const val ACTION_DENY_RELEASE = "com.parkadvisor.ACTION_DENY_RELEASE"
        const val ACTION_CONFIRM_IN_CAR = "com.parkadvisor.ACTION_CONFIRM_IN_CAR"
        const val ACTION_DENY_IN_CAR = "com.parkadvisor.ACTION_DENY_IN_CAR"
        const val ACTION_GEOFENCE_TRANSITION = "com.parkadvisor.ACTION_GEOFENCE_TRANSITION"
        const val ACTION_SAVE_WIFI_HOME = "com.parkadvisor.ACTION_SAVE_WIFI_HOME"
        const val ACTION_SAVE_WIFI_WORK = "com.parkadvisor.ACTION_SAVE_WIFI_WORK"
        const val ACTION_IGNORE_WIFI = "com.parkadvisor.ACTION_IGNORE_WIFI"

        const val GEOFENCE_REQ_ID = "parknow_active_stall_geofence"

        const val STATE_AT_HOME = "atHome"
        const val STATE_AT_WORK = "atWork"
        const val STATE_STILL = "still"
        const val STATE_MOVING = "moving"
        const val STATE_IN_CAR = "inCar"

        @Volatile var instance: FixedWifiMonitorService? = null
        @Volatile var uiStateListener: ((HashMap<String, Any?>) -> Unit)? = null

        fun buildFallbackSnapshot(ctx: Context): HashMap<String, Any?> {
            val p = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val hasParked = p.contains("parked_lat") && p.contains("parked_lon")
            return hashMapOf(
                "userActivityState" to (p.getString("user_state", STATE_STILL) ?: STATE_STILL),
                "gpsActive" to false,
                "gpsRemainingSec" to 0,
                "gpsCycle" to 0,
                "speedKmh" to 0.0,
                "sessionSteps" to p.getInt("session_steps", 0),
                "carBtConnected" to false,
                "promptInCar" to p.getBoolean("prompt_in_car", false),
                "promptRelease" to p.getBoolean("prompt_release", false),
                "hasParked" to hasParked,
                "parkedLat" to if (hasParked) p.getString("parked_lat", null)?.toDoubleOrNull() else null,
                "parkedLon" to if (hasParked) p.getString("parked_lon", null)?.toDoubleOrNull() else null,
                "homeWifiSsid" to (p.getString("home_wifi_ssid", "") ?: ""),
                "workWifiSsid" to (p.getString("work_wifi_ssid", "") ?: ""),
                "connectedWifiSsid" to (p.getString("ui_wifi_ssid", "") ?: ""),
                "onFixedWifi" to false,
                "anchoredSteps" to 0,
                "nPassi" to p.getInt("n_passi", 50).coerceIn(5, 500),
                "t0PassiSec" to p.getInt("t0_passi_sec", 30).coerceIn(5, 300)
            )
        }
    }

    private data class NativeGpsSample(
        val timestampMs: Long,
        val lat: Double,
        val lon: Double,
        val speedKmh: Float,
        val accuracy: Float
    )

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var prefs: SharedPreferences
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var geofencingClient: GeofencingClient
    private var sensorManager: SensorManager? = null
    private var stepCounterSensor: Sensor? = null
    private var stepDetectorSensor: Sensor? = null
    private var accelerometerSensor: Sensor? = null

    private var stepCounterRegistered = false
    private var stepDetectorRegistered = false
    private var accelListenerRegistered = false

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private var userActivityState: String = STATE_STILL
    private var anchoredStationaryState: String? = null
    private var activeWifiIsFixed: Boolean = false
    private var lastNotifiedTitleState: String = ""
    private var lastNotifiedGpsMode: Boolean? = null
    private var currentConnectedWifiSsid: String? = null
    @Volatile private var lastCallbackWifiSsid: String? = null
    @Volatile private var pendingUnknownWifiSsid: String? = null
    private var lastPromptedWifiSsid: String? = null
    private var promptShownForCurrentSession = false
    private var armedForDeparturePrompt = true

    private var hasStepHardware = false
    private var lastStepCounterHardwareVal: Int? = null
    private var lastStepCounterEventMs = 0L
    private var lastStepTimestampMs = 0L
    private var sessionSteps = 0
    private var recentWindowSteps = 0
    private var boutStepsSinceStationary = 0
    private var anchoredStepCount = 0
    private var isWalking = false

    private var gravX = 0f
    private var gravY = 0f
    private var gravZ = 0f
    private var gravInitialized = false
    private var inertialWakeupHits = 0
    private var lastInertialHitMs = 0L

    private var gpsHighAccuracyActive = false
    private var gpsWindowRemainingSec = 0
    private var noStepGpsCycleCount = 0
    private var gpsRestingAfterAnalysis = false
    private var carPromptShownInCurrentBout = false
    private var currentSpeedKmh = 0f
    private val gpsWindowSamples = mutableListOf<NativeGpsSample>()

    private var isCarBtConnected = false
    private var passedThroughStall = false
    private var lastGeofenceCoords: Pair<Double, Double>? = null
    private var lastGeofenceRadiusMeters: Float = -1f
    private var activeRingtone: android.media.Ringtone? = null

    private var gpsWindowTickRunnable: Runnable? = null
    private var stepStoppedRunnable: Runnable? = null
    private var anchoredStepResetRunnable: Runnable? = null
    private var geofenceWatchdogRunnable: Runnable? = null
    private var homeRearmRunnable: Runnable? = null

    private val fusedLocationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            val loc = result.lastLocation ?: return
            handleFusedLocation(loc)
        }
    }

    private val internalReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_CONFIRM_RELEASE -> handleUserConfirmRelease()
                ACTION_DENY_RELEASE -> handleUserDenyRelease()
                ACTION_CONFIRM_IN_CAR -> handleUserConfirmInCarFromNotif()
                ACTION_DENY_IN_CAR -> handleUserDenyInCarFromNotif()
                ACTION_GEOFENCE_TRANSITION -> handleGeofenceEnterEvent(intent)
                ACTION_SAVE_WIFI_HOME -> handleSaveWifiAction(intent.getStringExtra("wifi_ssid"), isHome = true)
                ACTION_SAVE_WIFI_WORK -> handleSaveWifiAction(intent.getStringExtra("wifi_ssid"), isHome = false)
                ACTION_IGNORE_WIFI -> handleIgnoreWifiAction(intent.getStringExtra("wifi_ssid"))
            }
        }
    }

    private val systemReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == WifiManager.WIFI_STATE_CHANGED_ACTION) {
                val wifiState = intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, WifiManager.WIFI_STATE_UNKNOWN)
                if (wifiState == WifiManager.WIFI_STATE_DISABLED || wifiState == WifiManager.WIFI_STATE_DISABLING) {
                    activeWifiIsFixed = false
                    lastCallbackWifiSsid = null
                    currentConnectedWifiSsid = null
                    pendingUnknownWifiSsid = null
                    prefs.edit().remove("ui_wifi_ssid").apply()
                    gpsRestingAfterAnalysis = false
                    evaluateNoFixedWifiAlgorithm()
                } else if (wifiState == WifiManager.WIFI_STATE_ENABLED) {
                    handler.postDelayed({ evaluateConnectedWifiState() }, 1500L)
                }
                return
            }

            val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            val targetMac = prefs.getString("car_bt_mac", null)?.uppercase()
            if (targetMac.isNullOrEmpty() || dev?.address?.uppercase() != targetMac) return

            when (intent?.action) {
                BluetoothDevice.ACTION_ACL_CONNECTED -> {
                    isCarBtConnected = true
                    onCarBluetoothConnected()
                }
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                    isCarBtConnected = false
                    onCarBluetoothDisconnected()
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        migrateLegacyPrefsIfNeeded()
        userActivityState = prefs.getString("user_state", STATE_STILL) ?: STATE_STILL
        anchoredStationaryState = prefs.getString("anchored_place_state", null)
        if (anchoredStationaryState == null && (userActivityState == STATE_AT_HOME || userActivityState == STATE_AT_WORK)) {
            anchoredStationaryState = userActivityState
        }

        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        geofencingClient = LocationServices.getGeofencingClient(this)

        createNotificationChannels()
        startForegroundCompat()

        checkInitialBluetoothConnection()
        registerStepSensors()
        registerReceivers()
        registerWifiNetworkCallback()
        startGeofenceSyncWatchdog()

        evaluateConnectedWifiState()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        registerStepSensors()
        if (networkCallback == null) {
            registerWifiNetworkCallback()
        }
        syncNativeGeofenceWithActiveParking()
        evaluateConnectedWifiState()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (instance === this) instance = null
        stopNoStepGpsWindow()
        updateDynamicAccelerometerRegistration(shouldListen = false)
        stepStoppedRunnable?.let { handler.removeCallbacks(it) }
        anchoredStepResetRunnable?.let { handler.removeCallbacks(it) }
        geofenceWatchdogRunnable?.let { handler.removeCallbacks(it) }
        homeRearmRunnable?.let { handler.removeCallbacks(it) }
        try {
            sensorManager?.unregisterListener(this)
            unregisterReceiver(internalReceiver)
            unregisterReceiver(systemReceiver)
            networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
            geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID))
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun migrateLegacyPrefsIfNeeded() {
        try {
            val legacy = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val ed = prefs.edit()
            if (!prefs.contains("home_wifi_ssid")) {
                legacy.getString("flutter.home_wifi_ssid", null)?.takeIf { it.isNotBlank() }?.let {
                    ed.putString("home_wifi_ssid", it.replace("\"", "").trim())
                }
            }
            if (!prefs.contains("work_wifi_ssid")) {
                legacy.getString("flutter.work_wifi_ssid", null)?.takeIf { it.isNotBlank() }?.let {
                    ed.putString("work_wifi_ssid", it.replace("\"", "").trim())
                }
            }
            if (!prefs.contains("car_bt_mac")) {
                legacy.getString("flutter.car_bt_mac", null)?.takeIf { it.isNotBlank() }?.let {
                    ed.putString("car_bt_mac", it.trim().uppercase())
                }
            }
            ed.apply()
        } catch (_: Exception) {}
    }

    fun buildSnapshotMap(): HashMap<String, Any?> {
        val coords = getParkedLatLon()
        return hashMapOf(
            "userActivityState" to userActivityState,
            "gpsActive" to gpsHighAccuracyActive,
            "gpsRemainingSec" to gpsWindowRemainingSec,
            "gpsCycle" to noStepGpsCycleCount,
            "speedKmh" to currentSpeedKmh.toDouble(),
            "sessionSteps" to sessionSteps,
            "carBtConnected" to isCarBtConnected,
            "promptInCar" to prefs.getBoolean("prompt_in_car", false),
            "promptRelease" to prefs.getBoolean("prompt_release", false),
            "hasParked" to (coords != null),
            "parkedLat" to coords?.first,
            "parkedLon" to coords?.second,
            "homeWifiSsid" to (prefs.getString("home_wifi_ssid", "") ?: ""),
            "workWifiSsid" to (prefs.getString("work_wifi_ssid", "") ?: ""),
            "connectedWifiSsid" to (currentConnectedWifiSsid ?: ""),
            "onFixedWifi" to isOnFixedWifi(),
            "anchoredSteps" to anchoredStepCount,
            "nPassi" to getNPassi(),
            "t0PassiSec" to getT0PassiSec()
        )
    }

    fun refreshAndGetSnapshot(): HashMap<String, Any?> {
        registerStepSensors()
        evaluateConnectedWifiState()
        return buildSnapshotMap()
    }

    fun onFlutterConfigSynced(args: Map<String, Any?>): HashMap<String, Any?> {
        val ed = prefs.edit()
        (args["homeWifiSsid"] as? String)?.trim()?.let {
            val clean = it.replace("\"", "")
            if (clean.isNotEmpty()) {
                ed.putString("home_wifi_ssid", clean)
                if (prefs.getString("work_wifi_ssid", "").equals(clean, ignoreCase = true) &&
                    (args["workWifiSsid"] as? String)?.trim()?.replace("\"", "")?.equals(clean, ignoreCase = true) != true) {
                    ed.remove("work_wifi_ssid")
                }
            }
        }
        if (args["clearHomeWifi"] == true) {
            ed.remove("home_wifi_ssid")
            if (anchoredStationaryState == STATE_AT_HOME) anchoredStationaryState = null
        }

        (args["workWifiSsid"] as? String)?.trim()?.let {
            val clean = it.replace("\"", "")
            if (clean.isNotEmpty()) ed.putString("work_wifi_ssid", clean)
        }
        if (args["clearWorkWifi"] == true) {
            ed.remove("work_wifi_ssid")
            if (anchoredStationaryState == STATE_AT_WORK) anchoredStationaryState = null
        }

        if (args.containsKey("uiDetectedWifiSsid")) {
            val uiSsid = (args["uiDetectedWifiSsid"] as? String)?.replace("\"", "")?.trim()
            if (!uiSsid.isNullOrEmpty() && uiSsid != "<unknown ssid>") {
                lastCallbackWifiSsid = uiSsid
                ed.putString("ui_wifi_ssid", uiSsid)
            } else if (uiSsid != null && uiSsid.isEmpty() && !isWifiTransportConnected()) {
                lastCallbackWifiSsid = null
                ed.remove("ui_wifi_ssid")
            }
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
        (args["nPassi"] as? Number)?.let {
            ed.putInt("n_passi", it.toInt().coerceIn(5, 500))
        }
        (args["t0PassiSec"] as? Number)?.let {
            ed.putInt("t0_passi_sec", it.toInt().coerceIn(5, 300))
        }

        if (args.containsKey("parkedLat") && args.containsKey("parkedLon")) {
            val lat = (args["parkedLat"] as? Number)?.toDouble()
            val lon = (args["parkedLon"] as? Number)?.toDouble()
            if (lat != null && lon != null) {
                val hadBefore = hasActiveParking()
                val isSim = args["isSimulation"] == true
                ed.putString("parked_lat", lat.toString())
                ed.putString("parked_lon", lon.toString())
                if (!hadBefore || isSim) {
                    promptShownForCurrentSession = false
                    passedThroughStall = false
                    armedForDeparturePrompt = true
                    ed.putBoolean("prompt_release", false)
                    if (isSim) {
                        isWalking = false
                        boutStepsSinceStationary = 0
                        recentWindowSteps = 0
                        resetAnchoredStepsCounter()
                        if (!isOnFixedWifi() && userActivityState == STATE_MOVING) {
                            userActivityState = anchoredStationaryState ?: STATE_STILL
                        }
                    }
                }
            } else {
                ed.remove("parked_lat")
                ed.remove("parked_lon")
                ed.putBoolean("prompt_release", false)
                promptShownForCurrentSession = false
                passedThroughStall = false
                cancelPromptNotification()
            }
        }

        if (args["clearPromptInCar"] == true) {
            ed.putBoolean("prompt_in_car", false)
            cancelInCarPromptNotification()
        }
        if (args["clearPromptRelease"] == true) {
            ed.putBoolean("prompt_release", false)
        }
        if (args["dismissReleaseNotif"] == true) {
            ed.putBoolean("prompt_release", false)
            cancelPromptNotification()
        }

        val forced = (args["forceUserState"] as? String)?.trim()
        ed.apply()

        registerStepSensors()
        syncNativeGeofenceWithActiveParking()

        if (forced == STATE_IN_CAR) {
            anchoredStationaryState = null
            gpsRestingAfterAnalysis = true
            stopNoStepGpsWindow()
            updateDynamicAccelerometerRegistration(shouldListen = false)
            userActivityState = STATE_IN_CAR
            persistAndBroadcastState(forceNotification = true)
        } else if (forced == STATE_AT_HOME || forced == STATE_AT_WORK) {
            anchoredStationaryState = forced
            evaluateConnectedWifiState()
        } else {
            evaluateConnectedWifiState()
        }
        return buildSnapshotMap()
    }

    private fun getTGpsNoStepSec(): Int = prefs.getInt("tgps_senzapasso_sec", 30).coerceIn(10, 180)
    private fun getGeofenceRadiusMeters(): Float = prefs.getInt("geofence_radius_m", 100).coerceIn(20, 2000).toFloat()
    private fun getNPassi(): Int = prefs.getInt("n_passi", 50).coerceIn(5, 500)
    private fun getT0PassiSec(): Int = prefs.getInt("t0_passi_sec", 30).coerceIn(5, 300)

    private fun isAnchoredWithoutFixedWifi(): Boolean {
        return !isOnFixedWifi() && anchoredStationaryState != null &&
            (userActivityState == STATE_AT_HOME || userActivityState == STATE_AT_WORK)
    }

    private fun resetAnchoredStepsCounter() {
        anchoredStepResetRunnable?.let { handler.removeCallbacks(it) }
        anchoredStepResetRunnable = null
        anchoredStepCount = 0
    }

    private fun hasActiveParking(): Boolean {
        return prefs.contains("parked_lat") && prefs.contains("parked_lon")
    }

    private fun getParkedLatLon(): Pair<Double, Double>? {
        val lat = prefs.getString("parked_lat", null)?.toDoubleOrNull() ?: return null
        val lon = prefs.getString("parked_lon", null)?.toDoubleOrNull() ?: return null
        if (lat == 0.0 && lon == 0.0) return null
        return Pair(lat, lon)
    }

    private fun checkInitialBluetoothConnection() {
        val targetMac = prefs.getString("car_bt_mac", null)?.uppercase() ?: return
        if (targetMac.isEmpty()) return
        try {
            val hasBtPerm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            } else {
                true
            }
            if (!hasBtPerm) return
            val bm = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return
            val gattConnected = bm.getConnectedDevices(BluetoothProfile.GATT).any { it.address?.uppercase() == targetMac }
            if (gattConnected) {
                isCarBtConnected = true
                return
            }
            val adapter: BluetoothAdapter? = bm.adapter
            val bonded = adapter?.bondedDevices?.firstOrNull { it.address?.uppercase() == targetMac }
            if (bonded != null) {
                val m = bonded.javaClass.getMethod("isConnected")
                if (m.invoke(bonded) == true) {
                    isCarBtConnected = true
                }
            }
        } catch (_: Exception) {}
    }

    private fun registerStepSensors() {
        try {
            if (sensorManager == null) {
                sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            }
            val hasActivityPerm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED
            } else {
                true
            }
            if (!hasActivityPerm) return

            if (stepCounterSensor == null) {
                stepCounterSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
            }
            if (stepCounterSensor != null && !stepCounterRegistered) {
                val ok = sensorManager?.registerListener(this, stepCounterSensor, SensorManager.SENSOR_DELAY_FASTEST) ?: false
                if (ok) {
                    stepCounterRegistered = true
                    hasStepHardware = true
                }
            }

            if (stepDetectorSensor == null) {
                stepDetectorSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
            }
            if (stepDetectorSensor != null && !stepDetectorRegistered) {
                val ok = sensorManager?.registerListener(this, stepDetectorSensor, SensorManager.SENSOR_DELAY_FASTEST) ?: false
                if (ok) {
                    stepDetectorRegistered = true
                    hasStepHardware = true
                }
            }
        } catch (_: Exception) {}
    }

    private fun updateDynamicAccelerometerRegistration(shouldListen: Boolean) {
        try {
            if (sensorManager == null) {
                sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            }
            if (shouldListen && !accelListenerRegistered) {
                if (accelerometerSensor == null) {
                    accelerometerSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
                }
                if (accelerometerSensor != null) {
                    gravInitialized = false
                    inertialWakeupHits = 0
                    accelListenerRegistered = sensorManager?.registerListener(
                        this,
                        accelerometerSensor,
                        SensorManager.SENSOR_DELAY_NORMAL
                    ) ?: false
                }
            } else if (!shouldListen && accelListenerRegistered) {
                accelerometerSensor?.let { sensorManager?.unregisterListener(this, it) }
                accelListenerRegistered = false
                gravInitialized = false
                inertialWakeupHits = 0
            }
        } catch (_: Exception) {}
    }

    override fun onSensorChanged(event: SensorEvent?) {
        when (event?.sensor?.type) {
            Sensor.TYPE_STEP_COUNTER -> {
                val rawTotal = event.values[0].toInt()
                val prev = lastStepCounterHardwareVal
                lastStepCounterHardwareVal = rawTotal
                lastStepCounterEventMs = System.currentTimeMillis()
                if (prev != null) {
                    val delta = (rawTotal - prev).coerceIn(0, 25)
                    if (delta > 0) {
                        onHardwareStepsDetected(delta)
                    }
                }
            }
            Sensor.TYPE_STEP_DETECTOR -> {
                val now = System.currentTimeMillis()
                if (stepCounterSensor == null || (now - lastStepCounterEventMs) > 2500L) {
                    onHardwareStepsDetected(1)
                }
            }
            Sensor.TYPE_ACCELEROMETER -> {
                handleAccelerometerSample(event.values[0], event.values[1], event.values[2])
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun scheduleWalkStopTimeout() {
        stepStoppedRunnable?.let { handler.removeCallbacks(it) }
        stepStoppedRunnable = Runnable {
            val wasWalkingBeforeStop = isWalking
            isWalking = false
            recentWindowSteps = 0
            boutStepsSinceStationary = 0
            if (wasWalkingBeforeStop && !isOnFixedWifi() && userActivityState != STATE_IN_CAR) {
                gpsRestingAfterAnalysis = false
                evaluateNoFixedWifiAlgorithm()
            }
        }
        handler.postDelayed(stepStoppedRunnable!!, 6_000L)
    }

    private fun onHardwareStepsDetected(stepDelta: Int) {
        val now = System.currentTimeMillis()
        sessionSteps += stepDelta

        if (isOnFixedWifi()) {
            resetAnchoredStepsCounter()
            lastStepTimestampMs = now
            persistAndBroadcastState(forceNotification = false)
            return
        }

        if (isCarBtConnected) {
            resetAnchoredStepsCounter()
            lastStepTimestampMs = now
            persistAndBroadcastState(forceNotification = false)
            return
        }

        // Soglia Npassi + reset T0passi (su eventi passo) solo se ancorato a Casa/Lavoro senza Wi-Fi
        if (isAnchoredWithoutFixedWifi()) {
            lastStepTimestampMs = now
            anchoredStepCount += stepDelta
            boutStepsSinceStationary += stepDelta

            anchoredStepResetRunnable?.let { handler.removeCallbacks(it) }
            val threshold = getNPassi()
            if (anchoredStepCount >= threshold) {
                anchoredStepResetRunnable = null
                anchoredStepCount = 0
                anchoredStationaryState = null
                recentWindowSteps = threshold
                isWalking = true
                scheduleWalkStopTimeout()
                evaluateNoFixedWifiAlgorithm()
            } else {
                anchoredStepResetRunnable = Runnable {
                    anchoredStepResetRunnable = null
                    anchoredStepCount = 0
                    boutStepsSinceStationary = 0
                    recentWindowSteps = 0
                    persistAndBroadcastState(forceNotification = false)
                }
                handler.postDelayed(anchoredStepResetRunnable!!, getT0PassiSec() * 1000L)
                persistAndBroadcastState(forceNotification = false)
            }
            return
        }

        boutStepsSinceStationary += stepDelta
        if (now - lastStepTimestampMs > 5_000L) {
            recentWindowSteps = stepDelta
        } else {
            recentWindowSteps += stepDelta
        }
        lastStepTimestampMs = now
        scheduleWalkStopTimeout()

        if (userActivityState == STATE_IN_CAR) {
            if (recentWindowSteps >= 6) {
                isWalking = true
                gpsRestingAfterAnalysis = false
                evaluateNoFixedWifiAlgorithm()
            } else {
                persistAndBroadcastState(forceNotification = false)
            }
            return
        }

        if (recentWindowSteps >= 3) {
            isWalking = true
            evaluateNoFixedWifiAlgorithm()
        } else {
            persistAndBroadcastState(forceNotification = false)
        }
    }

    private fun handleAccelerometerSample(ax: Float, ay: Float, az: Float) {
        if (isOnFixedWifi() || isWalking || gpsHighAccuracyActive || userActivityState == STATE_IN_CAR || !gpsRestingAfterAnalysis) {
            return
        }
        if (isAnchoredWithoutFixedWifi() && (System.currentTimeMillis() - lastStepTimestampMs) < 3_000L) {
            return
        }
        if (!gravInitialized) {
            gravX = ax
            gravY = ay
            gravZ = az
            gravInitialized = true
            return
        }
        gravX = 0.9f * gravX + 0.1f * ax
        gravY = 0.9f * gravY + 0.1f * ay
        gravZ = 0.9f * gravZ + 0.1f * az
        val lx = ax - gravX
        val ly = ay - gravY
        val lz = az - gravZ
        val linearAcc = sqrt(lx * lx + ly * ly + lz * lz)

        if (linearAcc > 1.35f) {
            val now = System.currentTimeMillis()
            if (now - lastInertialHitMs > 3_000L) {
                inertialWakeupHits = 1
            } else {
                inertialWakeupHits++
            }
            lastInertialHitMs = now
            if (inertialWakeupHits >= 2) {
                inertialWakeupHits = 0
                gpsRestingAfterAnalysis = false
                updateDynamicAccelerometerRegistration(shouldListen = false)
                startNoStepGpsWindow(cycleIndex = 0)
            }
        }
    }

    private fun isWifiTransportConnected(): Boolean {
        return try {
            val cm = connectivityManager ?: (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
            val net = cm?.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(net) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        } catch (_: Exception) {
            false
        }
    }

    private fun detectActiveWifiSsid(): String? {
        if (!isWifiTransportConnected()) {
            lastCallbackWifiSsid = null
            return null
        }

        try {
            val cm = connectivityManager ?: (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
            val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
            if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val wifiInfo = caps.transportInfo as? WifiInfo
                val s = wifiInfo?.ssid?.replace("\"", "")?.trim()
                if (!s.isNullOrEmpty() && s != "<unknown ssid>") {
                    lastCallbackWifiSsid = s
                    return s
                }
            }
        } catch (_: Exception) {}

        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            val s = wm?.connectionInfo?.ssid?.replace("\"", "")?.trim()
            if (!s.isNullOrEmpty() && s != "<unknown ssid>") {
                lastCallbackWifiSsid = s
                return s
            }
        } catch (_: Exception) {}

        val cached = lastCallbackWifiSsid?.replace("\"", "")?.trim()
        if (!cached.isNullOrEmpty() && cached != "<unknown ssid>") return cached

        val uiSsid = prefs.getString("ui_wifi_ssid", null)?.replace("\"", "")?.trim()
        if (!uiSsid.isNullOrEmpty() && uiSsid != "<unknown ssid>") return uiSsid

        return null
    }

    private fun isHomeWifi(ssid: String?): Boolean {
        if (ssid.isNullOrBlank()) return false
        val home = prefs.getString("home_wifi_ssid", "")?.replace("\"", "")?.trim() ?: ""
        return home.isNotEmpty() && home.equals(ssid, ignoreCase = true)
    }

    private fun isWorkWifi(ssid: String?): Boolean {
        if (ssid.isNullOrBlank()) return false
        val work = prefs.getString("work_wifi_ssid", "")?.replace("\"", "")?.trim() ?: ""
        return work.isNotEmpty() && work.equals(ssid, ignoreCase = true)
    }

    private fun isOnFixedWifi(): Boolean {
        if (!isWifiTransportConnected()) {
            activeWifiIsFixed = false
            currentConnectedWifiSsid = null
            return false
        }
        val s = detectActiveWifiSsid()
        currentConnectedWifiSsid = s
        if (!s.isNullOrEmpty()) {
            activeWifiIsFixed = isHomeWifi(s) || isWorkWifi(s)
            return activeWifiIsFixed
        }
        return activeWifiIsFixed
    }

    private fun isIgnoredWifiSsid(ssid: String): Boolean {
        val set = prefs.getStringSet("ignored_wifis", emptySet()) ?: emptySet()
        return set.any { it.equals(ssid, ignoreCase = true) }
    }

    private fun evaluateConnectedWifiState() {
        val wifiConnected = isWifiTransportConnected()
        val ssid = if (wifiConnected) detectActiveWifiSsid() else null
        currentConnectedWifiSsid = ssid

        if (isHomeWifi(ssid) || isWorkWifi(ssid)) {
            val targetState = if (isHomeWifi(ssid)) STATE_AT_HOME else STATE_AT_WORK
            activeWifiIsFixed = true
            anchoredStationaryState = targetState
            pendingUnknownWifiSsid = null
            noStepGpsCycleCount = 0
            gpsRestingAfterAnalysis = false
            carPromptShownInCurrentBout = false
            resetAnchoredStepsCounter()
            boutStepsSinceStationary = 0
            recentWindowSteps = 0
            currentSpeedKmh = 0f
            stopNoStepGpsWindow()
            updateDynamicAccelerometerRegistration(shouldListen = false)
            cancelReleasePromptNotification()

            if (promptShownForCurrentSession && homeRearmRunnable == null) {
                homeRearmRunnable = Runnable {
                    homeRearmRunnable = null
                    if (isOnFixedWifi()) {
                        promptShownForCurrentSession = false
                    }
                }
                handler.postDelayed(homeRearmRunnable!!, 30_000L)
            }

            transitionUserState(targetState)
            return
        }

        if (ssid == null && wifiConnected && activeWifiIsFixed) {
            persistAndBroadcastState(forceNotification = false)
            return
        }
        activeWifiIsFixed = false

        homeRearmRunnable?.let {
            handler.removeCallbacks(it)
            homeRearmRunnable = null
        }

        if (!ssid.isNullOrEmpty() && !isIgnoredWifiSsid(ssid) && !ssid.equals(lastPromptedWifiSsid, ignoreCase = true)) {
            pendingUnknownWifiSsid = ssid
            lastPromptedWifiSsid = ssid
            showUnknownWifiPromptNotification(ssid)
        } else if (ssid == null) {
            pendingUnknownWifiSsid = null
        }

        evaluateNoFixedWifiAlgorithm()
    }

    private fun evaluateNoFixedWifiAlgorithm() {
        if (isOnFixedWifi()) return

        if (isCarBtConnected) {
            resetAnchoredStepsCounter()
            anchoredStationaryState = null
            stopNoStepGpsWindow()
            updateDynamicAccelerometerRegistration(shouldListen = false)
            transitionUserState(STATE_IN_CAR)
            return
        }

        if (isWalking) {
            anchoredStationaryState = null
            noStepGpsCycleCount = 0
            gpsRestingAfterAnalysis = false
            stopNoStepGpsWindow()
            updateDynamicAccelerometerRegistration(shouldListen = false)
            transitionUserState(STATE_MOVING)
            return
        }

        if (userActivityState == STATE_IN_CAR) {
            stopNoStepGpsWindow()
            updateDynamicAccelerometerRegistration(shouldListen = false)
            persistAndBroadcastState(forceNotification = false)
            return
        }

        val stationaryTarget = anchoredStationaryState ?: STATE_STILL
        if (userActivityState != stationaryTarget) {
            transitionUserState(stationaryTarget)
        }

        if (!gpsHighAccuracyActive && !gpsRestingAfterAnalysis) {
            updateDynamicAccelerometerRegistration(shouldListen = false)
            startNoStepGpsWindow(cycleIndex = 0)
        } else {
            updateDynamicAccelerometerRegistration(shouldListen = gpsRestingAfterAnalysis)
            persistAndBroadcastState(forceNotification = false)
        }
    }

    private fun transitionUserState(newState: String) {
        val changed = (userActivityState != newState)
        userActivityState = newState

        if (newState == STATE_AT_HOME || newState == STATE_AT_WORK || newState == STATE_STILL) {
            armedForDeparturePrompt = true
        }

        val inMotion = (newState == STATE_MOVING || newState == STATE_IN_CAR)
        if (inMotion && armedForDeparturePrompt && !isOnFixedWifi() && hasActiveParking() && !promptShownForCurrentSession) {
            val enoughMovement = (newState == STATE_IN_CAR) || !hasStepHardware || (boutStepsSinceStationary >= 3) || !isWalking
            if (enoughMovement) {
                armedForDeparturePrompt = false
                if (newState == STATE_IN_CAR && isCarBtConnected) {
                    completeAutomaticVehicleDeparture()
                } else {
                    triggerReleaseConfirmationPrompt()
                }
            }
        }

        persistAndBroadcastState(forceNotification = changed)
    }

    private fun startNoStepGpsWindow(cycleIndex: Int) {
        if (isOnFixedWifi() || isWalking || userActivityState == STATE_IN_CAR) return
        val hasFine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) {
            transitionUserState(STATE_STILL)
            return
        }

        stopNoStepGpsWindow()
        gpsHighAccuracyActive = true
        noStepGpsCycleCount = cycleIndex
        gpsWindowRemainingSec = getTGpsNoStepSec()
        gpsWindowSamples.clear()
        currentSpeedKmh = 0f

        try {
            val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
                .setMinUpdateIntervalMillis(500L)
                .build()
            fusedLocationClient.requestLocationUpdates(req, fusedLocationCallback, Looper.getMainLooper())
        } catch (_: SecurityException) {} catch (_: Exception) {}

        gpsWindowTickRunnable = object : Runnable {
            override fun run() {
                if (isOnFixedWifi() || isWalking || userActivityState == STATE_IN_CAR) {
                    stopNoStepGpsWindow()
                    evaluateConnectedWifiState()
                    return
                }
                gpsWindowRemainingSec--
                if (gpsWindowRemainingSec <= 0) {
                    evaluateNoStepGpsWindowResult()
                } else {
                    persistAndBroadcastState(forceNotification = false)
                    handler.postDelayed(this, 1000L)
                }
            }
        }
        persistAndBroadcastState(forceNotification = true)
        handler.postDelayed(gpsWindowTickRunnable!!, 1000L)
    }

    private fun evaluateNoStepGpsWindowResult() {
        var vMedia = 0f
        var vIst = currentSpeedKmh

        if (gpsWindowSamples.size >= 2) {
            val first = gpsWindowSamples.first()
            val last = gpsWindowSamples.last()
            val elapsedSec = max(1L, (last.timestampMs - first.timestampMs) / 1000L)
            val distArr = FloatArray(1)
            Location.distanceBetween(first.lat, first.lon, last.lat, last.lon, distArr)
            val netMeters = distArr[0]
            val netAvgKmh = (netMeters / elapsedSec) * 3.6f
            val dopplerAvgKmh = gpsWindowSamples.map { it.speedKmh }.average().toFloat()
            val minReliableDisp = max(25f, first.accuracy + last.accuracy)
            vMedia = if (netMeters > minReliableDisp) max(netAvgKmh, dopplerAvgKmh) else dopplerAvgKmh

            val tail = gpsWindowSamples.takeLast(2)
            vIst = tail.map { it.speedKmh }.average().toFloat()
        } else if (gpsWindowSamples.size == 1) {
            vMedia = gpsWindowSamples.first().speedKmh
            vIst = gpsWindowSamples.first().speedKmh
        }

        currentSpeedKmh = vIst

        if (vMedia <= 1.0f) {
            val stationaryTarget = anchoredStationaryState ?: STATE_STILL
            stopNoStepGpsWindow()
            noStepGpsCycleCount = 0
            gpsRestingAfterAnalysis = true
            carPromptShownInCurrentBout = false
            boutStepsSinceStationary = 0
            updateDynamicAccelerometerRegistration(shouldListen = true)
            transitionUserState(stationaryTarget)
            return
        }

        resetAnchoredStepsCounter()
        anchoredStationaryState = null

        if (vIst <= 10.0f) {
            transitionUserState(STATE_MOVING)
            if (noStepGpsCycleCount == 0) {
                startNoStepGpsWindow(cycleIndex = 1)
            } else {
                stopNoStepGpsWindow()
                noStepGpsCycleCount = 0
                gpsRestingAfterAnalysis = true
                updateDynamicAccelerometerRegistration(shouldListen = true)
                persistAndBroadcastState(forceNotification = true)
            }
            return
        }

        stopNoStepGpsWindow()
        noStepGpsCycleCount = 0
        gpsRestingAfterAnalysis = true

        if (isCarBtConnected) {
            updateDynamicAccelerometerRegistration(shouldListen = false)
            transitionUserState(STATE_IN_CAR)
            if (hasActiveParking()) {
                completeAutomaticVehicleDeparture()
            }
        } else {
            updateDynamicAccelerometerRegistration(shouldListen = true)
            transitionUserState(STATE_MOVING)
            if (!carPromptShownInCurrentBout) {
                carPromptShownInCurrentBout = true
                prefs.edit().putBoolean("prompt_in_car", true).apply()
                showAreYouInCarNotification()
                persistAndBroadcastState(forceNotification = true)
            }
        }
    }

    private fun stopNoStepGpsWindow() {
        gpsWindowTickRunnable?.let { handler.removeCallbacks(it) }
        gpsWindowTickRunnable = null
        val wasActive = gpsHighAccuracyActive
        gpsHighAccuracyActive = false
        gpsWindowRemainingSec = 0
        try {
            fusedLocationClient.removeLocationUpdates(fusedLocationCallback)
        } catch (_: Exception) {}
        if (wasActive) {
            lastNotifiedGpsMode = null
        }
    }

    private fun handleFusedLocation(loc: Location) {
        val instKmh = if (loc.hasSpeed()) max(0f, loc.speed * 3.6f) else 0f
        currentSpeedKmh = instKmh

        if (gpsHighAccuracyActive) {
            if (loc.accuracy <= 35f || gpsWindowSamples.isEmpty()) {
                gpsWindowSamples.add(
                    NativeGpsSample(System.currentTimeMillis(), loc.latitude, loc.longitude, instKmh, loc.accuracy)
                )
            }
            persistAndBroadcastState(forceNotification = false)
        }

        val coords = getParkedLatLon()
        if (coords != null) {
            val results = FloatArray(1)
            Location.distanceBetween(loc.latitude, loc.longitude, coords.first, coords.second, results)
            val distMeters = results[0]
            if (distMeters <= 30f) passedThroughStall = true
            if (passedThroughStall && isCarBtConnected && distMeters > 15f) {
                completeAutomaticVehicleDeparture()
            }
        }
    }

    private fun onCarBluetoothConnected() {
        if (isOnFixedWifi()) return
        anchoredStationaryState = null
        gpsRestingAfterAnalysis = true
        stopNoStepGpsWindow()
        updateDynamicAccelerometerRegistration(shouldListen = false)
        transitionUserState(STATE_IN_CAR)
        if (hasActiveParking()) {
            completeAutomaticVehicleDeparture()
        }
    }

    private fun onCarBluetoothDisconnected() {
        gpsRestingAfterAnalysis = false
        carPromptShownInCurrentBout = false
        boutStepsSinceStationary = 0
        recentWindowSteps = 0
        if (userActivityState == STATE_IN_CAR) {
            userActivityState = STATE_STILL
        }
        evaluateConnectedWifiState()
    }

    private fun handleGeofenceEnterEvent(intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent)
        if (event != null && event.hasError()) return
        if (!hasActiveParking() || isOnFixedWifi()) return

        if (userActivityState == STATE_MOVING && !promptShownForCurrentSession) {
            triggerReleaseConfirmationPrompt()
        }
    }

    private fun triggerReleaseConfirmationPrompt() {
        if (isOnFixedWifi()) return
        promptShownForCurrentSession = true
        prefs.edit().putBoolean("prompt_release", true).apply()
        showReleasePromptNotification()
        persistAndBroadcastState(forceNotification = true)
    }

    private fun handleUserConfirmRelease() {
        prefs.edit().putBoolean("prompt_release", false).apply()
        cancelPromptNotification()
        triggerServerRelease(2)
        resetSessionFlagsAndClearParking()
        persistAndBroadcastState(forceNotification = true)
    }

    private fun handleUserDenyRelease() {
        prefs.edit().putBoolean("prompt_release", false).apply()
        cancelPromptNotification()
        passedThroughStall = false
        persistAndBroadcastState(forceNotification = false)
    }

    private fun handleUserConfirmInCarFromNotif() {
        cancelInCarPromptNotification()
        anchoredStationaryState = null
        prefs.edit().putBoolean("prompt_in_car", false).apply()
        gpsRestingAfterAnalysis = true
        stopNoStepGpsWindow()
        updateDynamicAccelerometerRegistration(shouldListen = false)
        userActivityState = STATE_IN_CAR
        persistAndBroadcastState(forceNotification = true)
        if (hasActiveParking()) {
            showReleasePromptNotification()
        }
    }

    private fun handleUserDenyInCarFromNotif() {
        cancelInCarPromptNotification()
        prefs.edit().putBoolean("prompt_in_car", false).apply()
        persistAndBroadcastState(forceNotification = false)
    }

    private fun completeAutomaticVehicleDeparture() {
        cancelPromptNotification()
        cancelInCarPromptNotification()
        triggerServerRelease(0)
        showDepartureReleasedNotification()
        resetSessionFlagsAndClearParking()
        persistAndBroadcastState(forceNotification = true)
    }

    private fun resetSessionFlagsAndClearParking() {
        prefs.edit()
            .remove("parked_lat")
            .remove("parked_lon")
            .putBoolean("prompt_in_car", false)
            .putBoolean("prompt_release", false)
            .apply()
        promptShownForCurrentSession = false
        passedThroughStall = false
        try { geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID)) } catch (_: Exception) {}
    }

    private fun persistAndBroadcastState(forceNotification: Boolean) {
        try {
            val ed = prefs.edit()
                .putString("user_state", userActivityState)
                .putInt("session_steps", sessionSteps)
            if (anchoredStationaryState != null) {
                ed.putString("anchored_place_state", anchoredStationaryState)
            } else {
                ed.remove("anchored_place_state")
            }
            ed.apply()

            if (forceNotification || lastNotifiedTitleState != userActivityState || lastNotifiedGpsMode != gpsHighAccuracyActive) {
                lastNotifiedTitleState = userActivityState
                lastNotifiedGpsMode = gpsHighAccuracyActive
                updateForegroundStatusNotification()
            }

            val snap = buildSnapshotMap()
            uiStateListener?.invoke(snap)
        } catch (_: Exception) {}
    }

    private fun userStateItalianLabel(): String {
        return when (userActivityState) {
            STATE_AT_HOME -> "A casa"
            STATE_AT_WORK -> "Al lavoro"
            STATE_STILL -> "Attualmente fermo"
            STATE_MOVING -> "In Movimento"
            STATE_IN_CAR -> "In Auto"
            else -> "Attualmente fermo"
        }
    }

    private fun updateForegroundStatusNotification() {
        try {
            val openPi = PendingIntent.getActivity(this, 10, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val wifiNote = if ((userActivityState == STATE_AT_HOME || userActivityState == STATE_AT_WORK) && !isOnFixedWifi()) " • Wi-Fi assente" else ""
            val gpsText = (if (gpsHighAccuracyActive) "GPS alta precisione attivo" else "GPS in risparmio") + wifiNote
            val notif = NotificationCompat.Builder(this, CHANNEL_FG)
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("Stato utente: ${userStateItalianLabel()}")
                .setContentText(gpsText)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(openPi)
                .build()
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(FG_NOTIF_ID, notif)
        } catch (_: Exception) {}
    }

    private fun handleSaveWifiAction(ssid: String?, isHome: Boolean) {
        val clean = ssid?.replace("\"", "")?.trim()?.takeIf { it.isNotEmpty() } ?: return
        val key = if (isHome) "home_wifi_ssid" else "work_wifi_ssid"
        val otherKey = if (isHome) "work_wifi_ssid" else "home_wifi_ssid"
        val targetState = if (isHome) STATE_AT_HOME else STATE_AT_WORK
        resetAnchoredStepsCounter()
        activeWifiIsFixed = true
        anchoredStationaryState = targetState
        lastCallbackWifiSsid = clean
        currentConnectedWifiSsid = clean
        pendingUnknownWifiSsid = null
        noStepGpsCycleCount = 0
        gpsRestingAfterAnalysis = false
        carPromptShownInCurrentBout = false
        boutStepsSinceStationary = 0
        stopNoStepGpsWindow()
        updateDynamicAccelerometerRegistration(shouldListen = false)
        cancelReleasePromptNotification()
        val ed = prefs.edit()
            .putString(key, clean)
            .putString("ui_wifi_ssid", clean)
            .putString("user_state", targetState)
            .putString("anchored_place_state", targetState)
        if (prefs.getString(otherKey, "").equals(clean, ignoreCase = true)) {
            ed.remove(otherKey)
        }
        ed.apply()
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(WIFI_PROMPT_NOTIF_ID)
        } catch (_: Exception) {}
        transitionUserState(targetState)
    }

    private fun handleIgnoreWifiAction(ssid: String?) {
        val clean = ssid?.replace("\"", "")?.trim()?.takeIf { it.isNotEmpty() } ?: return
        val current = (prefs.getStringSet("ignored_wifis", emptySet()) ?: emptySet()).toMutableSet()
        current.add(clean)
        prefs.edit().putStringSet("ignored_wifis", current).apply()
        pendingUnknownWifiSsid = null
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(WIFI_PROMPT_NOTIF_ID)
        } catch (_: Exception) {}
    }

    private fun showUnknownWifiPromptNotification(ssid: String) {
        try {
            val homePi = PendingIntent.getBroadcast(
                this, 31,
                Intent(ACTION_SAVE_WIFI_HOME).setPackage(packageName).putExtra("wifi_ssid", ssid),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val workPi = PendingIntent.getBroadcast(
                this, 32,
                Intent(ACTION_SAVE_WIFI_WORK).setPackage(packageName).putExtra("wifi_ssid", ssid),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val ignorePi = PendingIntent.getBroadcast(
                this, 33,
                Intent(ACTION_IGNORE_WIFI).setPackage(packageName).putExtra("wifi_ssid", ssid),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val notif = NotificationCompat.Builder(this, CHANNEL_ALERT)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Nuova rete Wi-Fi: $ssid")
                .setContentText("È Casa o Lavoro?")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .addAction(0, "Casa", homePi)
                .addAction(0, "Lavoro", workPi)
                .addAction(0, "Ignora", ignorePi)
                .build()
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(WIFI_PROMPT_NOTIF_ID, notif)
        } catch (_: Exception) {}
    }

    private fun showAreYouInCarNotification() {
        try {
            val openPi = PendingIntent.getActivity(this, 40, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val yesPi = PendingIntent.getBroadcast(
                this, 41,
                Intent(ACTION_CONFIRM_IN_CAR).setPackage(packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val noPi = PendingIntent.getBroadcast(
                this, 42,
                Intent(ACTION_DENY_IN_CAR).setPackage(packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val notif = NotificationCompat.Builder(this, CHANNEL_ALERT)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Sei in auto?")
                .setContentText("Rilevata velocità > 10 km/h senza Bluetooth auto collegato.")
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setContentIntent(openPi)
                .addAction(0, "Sì, sono in auto", yesPi)
                .addAction(0, "No", noPi)
                .build()
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(IN_CAR_PROMPT_NOTIF_ID, notif)
        } catch (_: Exception) {}
    }

    private fun cancelInCarPromptNotification() {
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(IN_CAR_PROMPT_NOTIF_ID)
        } catch (_: Exception) {}
    }

    private fun registerWifiNetworkCallback() {
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        val handleCaps: (NetworkCapabilities) -> Unit = { caps ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val wifiInfo = caps.transportInfo as? WifiInfo
                val raw = wifiInfo?.ssid?.replace("\"", "")?.trim()
                if (!raw.isNullOrEmpty() && raw != "<unknown ssid>") {
                    lastCallbackWifiSsid = raw
                }
            }
            handler.post { evaluateConnectedWifiState() }
        }

        val handleLost: () -> Unit = {
            activeWifiIsFixed = false
            lastCallbackWifiSsid = null
            handler.post {
                currentConnectedWifiSsid = null
                pendingUnknownWifiSsid = null
                prefs.edit().remove("ui_wifi_ssid").apply()
                gpsRestingAfterAnalysis = false
                evaluateNoFixedWifiAlgorithm()
            }
        }

        networkCallback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
                override fun onAvailable(network: Network) {
                    handler.post {
                        evaluateConnectedWifiState()
                        handler.postDelayed({ evaluateConnectedWifiState() }, 1200L)
                    }
                }
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = handleCaps(caps)
                override fun onLost(network: Network) = handleLost()
            }
        } else {
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    handler.post {
                        evaluateConnectedWifiState()
                        handler.postDelayed({ evaluateConnectedWifiState() }, 1200L)
                    }
                }
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = handleCaps(caps)
                override fun onLost(network: Network) = handleLost()
            }
        }
        try {
            connectivityManager?.registerNetworkCallback(req, networkCallback!!)
        } catch (_: Exception) {
            networkCallback = null
        }
    }

    private fun startGeofenceSyncWatchdog() {
        geofenceWatchdogRunnable = object : Runnable {
            override fun run() {
                registerStepSensors()
                syncNativeGeofenceWithActiveParking()
                evaluateConnectedWifiState()
                handler.postDelayed(this, 30_000L)
            }
        }
        handler.post(geofenceWatchdogRunnable!!)
    }

    private fun syncNativeGeofenceWithActiveParking() {
        val coords = getParkedLatLon()
        if (coords == null) {
            promptShownForCurrentSession = false
            lastGeofenceCoords = null
            lastGeofenceRadiusMeters = -1f
            try { geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID)) } catch (_: Exception) {}
            return
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return
        }

        val radiusMeters = getGeofenceRadiusMeters()
        if (lastGeofenceCoords == coords && lastGeofenceRadiusMeters == radiusMeters) return
        try { geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID)) } catch (_: Exception) {}
        lastGeofenceCoords = coords
        lastGeofenceRadiusMeters = radiusMeters

        val geofence = Geofence.Builder()
            .setRequestId(GEOFENCE_REQ_ID)
            .setCircularRegion(coords.first, coords.second, radiusMeters)
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER)
            .build()

        val geoReq = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofence(geofence)
            .build()

        val pi = PendingIntent.getBroadcast(
            this,
            5101,
            Intent(ACTION_GEOFENCE_TRANSITION).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )

        try {
            geofencingClient.addGeofences(geoReq, pi)
        } catch (_: Exception) {}
    }

    private fun triggerServerRelease(minutes: Int) {
        Thread {
            try {
                val url = URL("https://parknow-api.onrender.com/api/parking/leaving")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.doOutput = true
                val body = JSONObject().apply {
                    put("userId", "USER-001")
                    put("estimatedMinutes", minutes)
                }.toString()
                conn.outputStream.use { it.write(body.toByteArray()) }
                conn.responseCode
            } catch (_: Exception) {}
        }.start()
    }

    private fun registerReceivers() {
        val internalFilter = IntentFilter().apply {
            addAction(ACTION_CONFIRM_RELEASE)
            addAction(ACTION_DENY_RELEASE)
            addAction(ACTION_CONFIRM_IN_CAR)
            addAction(ACTION_DENY_IN_CAR)
            addAction(ACTION_GEOFENCE_TRANSITION)
            addAction(ACTION_SAVE_WIFI_HOME)
            addAction(ACTION_SAVE_WIFI_WORK)
            addAction(ACTION_IGNORE_WIFI)
        }
        ContextCompat.registerReceiver(this, internalReceiver, internalFilter, ContextCompat.RECEIVER_EXPORTED)

        val sysFilter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
        }
        ContextCompat.registerReceiver(this, systemReceiver, sysFilter, ContextCompat.RECEIVER_EXPORTED)
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val fgChannel = NotificationChannel(CHANNEL_FG, "Monitoraggio Stato Utente", NotificationManager.IMPORTANCE_LOW)
            nm.createNotificationChannel(fgChannel)

            val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val audioAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val alertChannel = NotificationChannel(CHANNEL_ALERT, "Avvisi Urgenti Rilascio Parcheggio", NotificationManager.IMPORTANCE_HIGH).apply {
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 700, 250, 700, 250, 900)
                setSound(alarmUri, audioAttrs)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(alertChannel)
        }
    }

    private fun startForegroundCompat() {
        val openPi = PendingIntent.getActivity(this, 10, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notif = NotificationCompat.Builder(this, CHANNEL_FG)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("Stato utente: ${userStateItalianLabel()}")
            .setContentText("GPS in risparmio")
            .setOngoing(true)
            .setContentIntent(openPi)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try { startForeground(FG_NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION) } catch (_: Throwable) { try { startForeground(FG_NOTIF_ID, notif) } catch (_: Throwable) {} }
        } else {
            startForeground(FG_NOTIF_ID, notif)
        }
    }

    private fun wakeUpScreenAndSoundAlarm() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            @Suppress("DEPRECATION")
            val wl = pm.newWakeLock(android.os.PowerManager.FULL_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP or android.os.PowerManager.ON_AFTER_RELEASE, "parkadvisor:UrgentWakeLock")
            wl.acquire(15_000L)
        } catch (_: Exception) {}
        try {
            stopAlarmRingtone()
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val rt = RingtoneManager.getRingtone(applicationContext, uri)
            rt?.audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) rt?.isLooping = true
            rt?.play()
            activeRingtone = rt
            handler.postDelayed({ stopAlarmRingtone() }, 12_000L)
        } catch (_: Exception) {}
    }

    private fun stopAlarmRingtone() {
        try { activeRingtone?.stop(); activeRingtone = null } catch (_: Exception) {}
    }

    private fun showReleasePromptNotification() {
        val openPi = PendingIntent.getActivity(this, 20, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val confirmPi = PendingIntent.getBroadcast(
            this, 21,
            Intent(ACTION_CONFIRM_RELEASE).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val denyPi = PendingIntent.getBroadcast(
            this, 22,
            Intent(ACTION_DENY_RELEASE).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif = NotificationCompat.Builder(this, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("Stai lasciando il parcheggio?")
            .setContentText("Rilevato stato In Movimento. Conferma per segnalare lo stallo in rilascio.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setVibrate(longArrayOf(0, 700, 250, 700, 250, 900))
            .setAutoCancel(true)
            .setFullScreenIntent(openPi, true)
            .setContentIntent(openPi)
            .addAction(android.R.drawable.ic_menu_send, "Conferma Rilascio", confirmPi)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Rifiuta / Non parto", denyPi)
            .build()

        wakeUpScreenAndSoundAlarm()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(PROMPT_NOTIF_ID, notif)
    }

    private fun cancelReleasePromptNotification() {
        cancelPromptNotification()
    }

    private fun cancelPromptNotification() {
        stopAlarmRingtone()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(PROMPT_NOTIF_ID)
    }

    private fun showDepartureReleasedNotification() {
        val openPi = PendingIntent.getActivity(this, 25, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notif = NotificationCompat.Builder(this, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Ripartenza in auto rilevata")
            .setContentText("Segnaposto P attivato: parcheggio liberato sulla mappa.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setContentIntent(openPi)
            .build()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(RELEASED_NOTIF_ID, notif)
    }
}
