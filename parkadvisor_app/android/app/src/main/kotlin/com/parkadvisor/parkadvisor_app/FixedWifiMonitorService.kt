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
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.max
import kotlin.math.sqrt

private fun readSafeDouble(prefs: SharedPreferences, key: String, def: Double): Double {
    return try {
        val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"
        when (val v = prefs.all[key]) {
            is Double -> v
            is Float -> v.toDouble()
            is String -> {
                val clean = if (v.startsWith(prefix)) v.removePrefix(prefix) else v
                clean.toDoubleOrNull() ?: def
            }
            is Long -> {
                if (kotlin.math.abs(v) > 1_000_000_000L) java.lang.Double.longBitsToDouble(v)
                else v.toDouble()
            }
            is Number -> v.toDouble()
            else -> def
        }
    } catch (_: Throwable) {
        def
    }
}

private data class NativeGpsSample(
    val timestampMs: Long,
    val lat: Double,
    val lon: Double,
    val speedKmh: Float,
    val accuracy: Float
)

class FixedWifiMonitorService : Service(), LocationListener, SensorEventListener {

    companion object {
        const val CHANNEL_FG = "parknow_fg_service_v1"
        const val CHANNEL_ALERT = "parknow_urgent_alarm_v3"
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
        const val ACTION_STATE_UPDATED = "com.parkadvisor.ACTION_STATE_UPDATED"

        const val GEOFENCE_REQ_ID = "parknow_active_stall_geofence"

        const val STATE_AT_HOME = "atHome"
        const val STATE_AT_WORK = "atWork"
        const val STATE_STILL = "still"
        const val STATE_MOVING = "moving"
        const val STATE_IN_CAR = "inCar"
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var prefs: SharedPreferences
    private lateinit var locationManager: LocationManager
    private lateinit var geofencingClient: GeofencingClient
    private var sensorManager: SensorManager? = null
    private var stepDetector: Sensor? = null
    private var accelerometer: Sensor? = null

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var prefsChangeListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    // Stato macchina utente 24/7
    private var userActivityState: String = STATE_STILL
    private var currentConnectedWifiSsid: String? = null
    @Volatile private var pendingUnknownWifiSsid: String? = null
    private var lastPromptedWifiSsid: String? = null
    private var promptShownForCurrentSession = false

    // Sensori passo e inerziali
    private var hasStepSensor = false
    private var lastStepTimestampMs = 0L
    private var sessionSteps = 0
    private var boutStepsSinceStationary = 0
    private var isWalking = false

    private var gravX = 0f
    private var gravY = 0f
    private var gravZ = 0f
    private var gravInitialized = false
    private var inertialWakeupHits = 0
    private var lastInertialHitMs = 0L

    // Finestra GPS Tgps_senzapasso (default 30s)
    private var gpsHighAccuracyActive = false
    private var gpsWindowRemainingSec = 0
    private var noStepGpsCycleCount = 0 // 0 = analisi 30s, 1 = conferma 30s
    private var gpsRestingAfterAnalysis = false
    private var carPromptShownInCurrentBout = false
    private var currentSpeedKmh = 0f
    private val gpsWindowSamples = mutableListOf<NativeGpsSample>()

    // Bluetooth e geofence
    private var isCarBtConnected = false
    private var passedThroughStall = false
    private var lastGeofenceCoords: Pair<Double, Double>? = null
    private var lastGeofenceRadiusMeters: Float = -1f
    private var activeRingtone: android.media.Ringtone? = null

    // Timers / Runnables
    private var gpsWindowTickRunnable: Runnable? = null
    private var stepStoppedRunnable: Runnable? = null
    private var geofenceWatchdogRunnable: Runnable? = null

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

    private val systemBtReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            val targetMac = prefs.getString("flutter.car_bt_mac", null)?.uppercase()
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
        prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        geofencingClient = LocationServices.getGeofencingClient(this)

        createNotificationChannels()
        startForegroundCompat()

        registerSensors()
        registerReceivers()
        registerWifiNetworkCallback()
        startGeofenceSyncWatchdog()

        evaluateConnectedWifiState()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        registerSensors()
        syncNativeGeofenceWithActiveParking()
        evaluateConnectedWifiState()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        stopNoStepGpsWindow()
        stepStoppedRunnable?.let { handler.removeCallbacks(it) }
        geofenceWatchdogRunnable?.let { handler.removeCallbacks(it) }
        try {
            sensorManager?.unregisterListener(this)
            unregisterReceiver(internalReceiver)
            unregisterReceiver(systemBtReceiver)
            networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
            prefsChangeListener?.let { prefs.unregisterOnSharedPreferenceChangeListener(it) }
            geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID))
        } catch (_: Exception) {}
    }

    private fun safeGetInt(key: String, def: Int): Int {
        return try {
            when (val v = prefs.all[key]) {
                is Int -> v
                is Long -> v.toInt()
                is Number -> v.toInt()
                is String -> v.toIntOrNull() ?: def
                else -> def
            }
        } catch (_: Throwable) {
            def
        }
    }

    private fun getTGpsNoStepSec(): Int = safeGetInt("flutter.tgps_senzapasso_sec", 30).coerceIn(10, 180)
    private fun getGeofenceRadiusMeters(): Float = safeGetInt("flutter.geofence_radius_m", 100).coerceIn(20, 2000).toFloat()

    private fun hasActiveParking(): Boolean {
        return prefs.contains("flutter.parked_lat") && prefs.contains("flutter.parked_lon")
    }

    private fun getParkedLatLon(): Pair<Double, Double>? {
        if (!hasActiveParking()) return null
        val lat = readSafeDouble(prefs, "flutter.parked_lat", 0.0)
        val lon = readSafeDouble(prefs, "flutter.parked_lon", 0.0)
        if (lat == 0.0 && lon == 0.0) return null
        return Pair(lat, lon)
    }

    private fun registerSensors() {
        try {
            if (sensorManager == null) {
                sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            }
            if (stepDetector == null) {
                stepDetector = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
                if (stepDetector != null) {
                    hasStepSensor = true
                    sensorManager?.registerListener(this, stepDetector, SensorManager.SENSOR_DELAY_NORMAL)
                }
            }
            if (accelerometer == null) {
                accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
                if (accelerometer != null) {
                    sensorManager?.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_NORMAL)
                }
            }
        } catch (_: Exception) {}
    }

    override fun onSensorChanged(event: SensorEvent?) {
        when (event?.sensor?.type) {
            Sensor.TYPE_STEP_DETECTOR -> handleStepDetected()
            Sensor.TYPE_ACCELEROMETER -> handleAccelerometerSample(event.values[0], event.values[1], event.values[2])
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun handleStepDetected() {
        val now = System.currentTimeMillis()
        lastStepTimestampMs = now
        sessionSteps++
        boutStepsSinceStationary++
        isWalking = true

        stepStoppedRunnable?.let { handler.removeCallbacks(it) }
        stepStoppedRunnable = Runnable {
            isWalking = false
            if (!isOnFixedWifi()) {
                gpsRestingAfterAnalysis = false
                evaluateNoFixedWifiAlgorithm()
            }
        }
        handler.postDelayed(stepStoppedRunnable!!, 6_000L)

        if (!isOnFixedWifi()) {
            evaluateNoFixedWifiAlgorithm()
        } else {
            persistAndBroadcastState()
        }
    }

    private fun handleAccelerometerSample(ax: Float, ay: Float, az: Float) {
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

        // Risveglio affidabile dallo stato "Attualmente fermo" (o riposo post-ciclo)
        if (!isOnFixedWifi() && !isWalking && !gpsHighAccuracyActive && gpsRestingAfterAnalysis) {
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
                    startNoStepGpsWindow(cycleIndex = 0)
                }
            }
        }
    }

    private fun detectActiveWifiSsid(): String? {
        try {
            val cm = connectivityManager ?: (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
            if (cm != null) {
                val net = cm.activeNetwork
                val caps = cm.getNetworkCapabilities(net)
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val wifiInfo = caps.transportInfo as? WifiInfo
                        val s = wifiInfo?.ssid?.replace("\"", "")?.trim()
                        if (!s.isNullOrEmpty() && s != "<unknown ssid>") return s
                    }
                }
            }
        } catch (_: Exception) {}

        return try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
            @Suppress("DEPRECATION")
            val s = wm.connectionInfo?.ssid?.replace("\"", "")?.trim()
            if (!s.isNullOrEmpty() && s != "<unknown ssid>") s else null
        } catch (_: Exception) {
            null
        }
    }

    private fun isHomeWifi(ssid: String?): Boolean {
        if (ssid.isNullOrBlank()) return false
        val home = prefs.getString("flutter.home_wifi_ssid", "")?.replace("\"", "")?.trim() ?: ""
        return home.isNotEmpty() && home.equals(ssid, ignoreCase = true)
    }

    private fun isWorkWifi(ssid: String?): Boolean {
        if (ssid.isNullOrBlank()) return false
        val work = prefs.getString("flutter.work_wifi_ssid", "")?.replace("\"", "")?.trim() ?: ""
        return work.isNotEmpty() && work.equals(ssid, ignoreCase = true)
    }

    private fun isOnFixedWifi(): Boolean {
        val s = currentConnectedWifiSsid ?: detectActiveWifiSsid()
        return isHomeWifi(s) || isWorkWifi(s)
    }

    private fun isIgnoredWifiSsid(ssid: String): Boolean {
        return try {
            val nativeIgnored = prefs.getStringSet("native_ignored_wifis", emptySet()) ?: emptySet()
            if (nativeIgnored.any { it.equals(ssid, ignoreCase = true) }) return true
            val rawFlutterList = prefs.getString("flutter.ignored_wifis", "") ?: ""
            rawFlutterList.contains(ssid, ignoreCase = true)
        } catch (_: Exception) {
            false
        }
    }

    private fun evaluateConnectedWifiState() {
        val ssid = detectActiveWifiSsid()
        currentConnectedWifiSsid = ssid

        if (isHomeWifi(ssid) || isWorkWifi(ssid)) {
            val targetState = if (isWorkWifi(ssid)) STATE_AT_WORK else STATE_AT_HOME
            pendingUnknownWifiSsid = null
            noStepGpsCycleCount = 0
            gpsRestingAfterAnalysis = false
            carPromptShownInCurrentBout = false
            boutStepsSinceStationary = 0
            stopNoStepGpsWindow()
            cancelReleasePromptNotification()
            transitionUserState(targetState)
            return
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

        // Punto 3: Non connesso a Wi-Fi fissa + presenza di passo -> "In Movimento" senza analisi GPS accurata
        if (isWalking) {
            noStepGpsCycleCount = 0
            gpsRestingAfterAnalysis = false
            stopNoStepGpsWindow()
            transitionUserState(STATE_MOVING)
            return
        }

        // Se confermato In Auto con BT collegato, resta "In Auto" con GPS in risparmio
        if (userActivityState == STATE_IN_CAR && isCarBtConnected) {
            stopNoStepGpsWindow()
            persistAndBroadcastState()
            return
        }

        // Punto 2: Non connesso a Wi-Fi fissa + mancanza di passo -> finestra GPS Tgps_senzapasso (30s)
        if (!gpsHighAccuracyActive && !gpsRestingAfterAnalysis) {
            startNoStepGpsWindow(cycleIndex = 0)
        } else {
            persistAndBroadcastState()
        }
    }

    private fun transitionUserState(newState: String) {
        val previous = userActivityState
        userActivityState = newState

        // Collegamento diretto della prima richiesta di rilascio all'ingresso in "In Movimento" (o "In Auto")
        val wasStationary = (previous == STATE_AT_HOME || previous == STATE_AT_WORK || previous == STATE_STILL)
        val enteredMotion = (newState == STATE_MOVING || newState == STATE_IN_CAR)

        if (wasStationary && enteredMotion) {
            val enoughMovement = (newState == STATE_IN_CAR) || !hasStepSensor || (boutStepsSinceStationary >= 3) || !isWalking
            if (enoughMovement && hasActiveParking() && !promptShownForCurrentSession && !isOnFixedWifi()) {
                if (newState == STATE_IN_CAR && isCarBtConnected) {
                    completeAutomaticVehicleDeparture()
                } else {
                    triggerReleaseConfirmationPrompt()
                }
            }
        }

        persistAndBroadcastState()
    }

    private fun startNoStepGpsWindow(cycleIndex: Int) {
        if (isOnFixedWifi() || isWalking) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return
        }

        stopNoStepGpsWindow()
        gpsHighAccuracyActive = true
        noStepGpsCycleCount = cycleIndex
        gpsWindowRemainingSec = getTGpsNoStepSec()
        gpsWindowSamples.clear()
        currentSpeedKmh = 0f

        try {
            locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, this, Looper.getMainLooper())
            locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 2000L, 0f, this, Looper.getMainLooper())
        } catch (_: Exception) {}

        gpsWindowTickRunnable = object : Runnable {
            override fun run() {
                if (isOnFixedWifi() || isWalking) {
                    stopNoStepGpsWindow()
                    evaluateConnectedWifiState()
                    return
                }
                gpsWindowRemainingSec--
                if (gpsWindowRemainingSec <= 0) {
                    evaluateNoStepGpsWindowResult()
                } else {
                    persistAndBroadcastState()
                    handler.postDelayed(this, 1000L)
                }
            }
        }
        persistAndBroadcastState()
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
            vMedia = if (netMeters > 8f) max(netAvgKmh, dopplerAvgKmh) else dopplerAvgKmh

            val tail = gpsWindowSamples.takeLast(2)
            vIst = tail.map { it.speedKmh }.average().toFloat()
        } else if (gpsWindowSamples.size == 1) {
            vMedia = gpsWindowSamples.first().speedKmh
            vIst = gpsWindowSamples.first().speedKmh
        }

        currentSpeedKmh = vIst

        // Ramo 2a: vMedia <= 1 km/h -> "Attualmente fermo", poi GPS in risparmio
        if (vMedia <= 1.0f) {
            stopNoStepGpsWindow()
            noStepGpsCycleCount = 0
            gpsRestingAfterAnalysis = true
            carPromptShownInCurrentBout = false
            boutStepsSinceStationary = 0
            transitionUserState(STATE_STILL)
            return
        }

        // Ramo 2b: vMedia > 1 km/h e vIst <= 10 km/h -> "In Movimento", secondo ciclo 30s poi riposo
        if (vIst <= 10.0f) {
            transitionUserState(STATE_MOVING)
            if (noStepGpsCycleCount == 0) {
                startNoStepGpsWindow(cycleIndex = 1)
            } else {
                stopNoStepGpsWindow()
                noStepGpsCycleCount = 0
                gpsRestingAfterAnalysis = true
                persistAndBroadcastState()
            }
            return
        }

        // Ramo 2c: vMedia > 1 km/h e vIst > 10 km/h -> controllo connessione Bluetooth auto
        stopNoStepGpsWindow()
        noStepGpsCycleCount = 0
        gpsRestingAfterAnalysis = true

        if (isCarBtConnected) {
            transitionUserState(STATE_IN_CAR)
            if (hasActiveParking()) {
                completeAutomaticVehicleDeparture()
            }
        } else {
            transitionUserState(STATE_MOVING)
            if (!carPromptShownInCurrentBout) {
                carPromptShownInCurrentBout = true
                prefs.edit().putBoolean("flutter.native_prompt_in_car", true).apply()
                showAreYouInCarNotification()
                persistAndBroadcastState()
            }
        }
    }

    private fun stopNoStepGpsWindow() {
        gpsWindowTickRunnable?.let { handler.removeCallbacks(it) }
        gpsWindowTickRunnable = null
        gpsHighAccuracyActive = false
        gpsWindowRemainingSec = 0
        try {
            locationManager.removeUpdates(this)
        } catch (_: Exception) {}
    }

    override fun onLocationChanged(loc: Location) {
        val instKmh = if (loc.hasSpeed()) max(0f, loc.speed * 3.6f) else 0f
        currentSpeedKmh = instKmh

        if (gpsHighAccuracyActive) {
            if (loc.accuracy <= 25f || gpsWindowSamples.isEmpty()) {
                gpsWindowSamples.add(
                    NativeGpsSample(System.currentTimeMillis(), loc.latitude, loc.longitude, instKmh, loc.accuracy)
                )
            }
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

    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}

    private fun onCarBluetoothConnected() {
        if (isOnFixedWifi()) return
        gpsRestingAfterAnalysis = true
        stopNoStepGpsWindow()
        transitionUserState(STATE_IN_CAR)
        if (hasActiveParking()) {
            completeAutomaticVehicleDeparture()
        }
    }

    private fun onCarBluetoothDisconnected() {
        gpsRestingAfterAnalysis = false
        carPromptShownInCurrentBout = false
        boutStepsSinceStationary = 0
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
        if (isOnFixedWifi() || pendingUnknownWifiSsid != null) return
        promptShownForCurrentSession = true
        showReleasePromptNotification()
    }

    private fun handleUserConfirmRelease() {
        cancelPromptNotification()
        triggerServerRelease(2)
        resetSessionFlagsAndClearParking()
        persistAndBroadcastState()
    }

    private fun handleUserDenyRelease() {
        cancelPromptNotification()
        passedThroughStall = false
        persistAndBroadcastState()
    }

    private fun handleUserConfirmInCarFromNotif() {
        cancelInCarPromptNotification()
        prefs.edit().putBoolean("flutter.native_prompt_in_car", false).apply()
        gpsRestingAfterAnalysis = true
        stopNoStepGpsWindow()
        userActivityState = STATE_IN_CAR
        persistAndBroadcastState()
        if (hasActiveParking()) {
            showReleasePromptNotification()
        }
    }

    private fun handleUserDenyInCarFromNotif() {
        cancelInCarPromptNotification()
        prefs.edit().putBoolean("flutter.native_prompt_in_car", false).apply()
        persistAndBroadcastState()
    }

    private fun completeAutomaticVehicleDeparture() {
        cancelPromptNotification()
        cancelInCarPromptNotification()
        triggerServerRelease(0)
        showDepartureReleasedNotification()
        resetSessionFlagsAndClearParking()
        persistAndBroadcastState()
    }

    private fun resetSessionFlagsAndClearParking() {
        prefs.edit()
            .remove("flutter.parked_lat")
            .remove("flutter.parked_lon")
            .putBoolean("flutter.native_prompt_in_car", false)
            .apply()
        promptShownForCurrentSession = false
        passedThroughStall = false
        try { geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID)) } catch (_: Exception) {}
    }

    private fun persistAndBroadcastState() {
        try {
            prefs.edit()
                .putString("flutter.native_user_state", userActivityState)
                .putBoolean("flutter.native_gps_active", gpsHighAccuracyActive)
                .putInt("flutter.native_gps_remaining_sec", gpsWindowRemainingSec)
                .putInt("flutter.native_gps_cycle", noStepGpsCycleCount)
                .putFloat("flutter.native_speed_kmh", currentSpeedKmh)
                .putInt("flutter.native_session_steps", sessionSteps)
                .putBoolean("flutter.native_car_bt_connected", isCarBtConnected)
                .apply()

            updateForegroundStatusNotification()

            sendBroadcast(Intent(ACTION_STATE_UPDATED).setPackage(packageName))
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
            val gpsText = if (gpsHighAccuracyActive) "GPS alta precisione (${gpsWindowRemainingSec}s)" else "GPS in risparmio"
            val notif = NotificationCompat.Builder(this, CHANNEL_FG)
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("Stato utente: ${userStateItalianLabel()}")
                .setContentText(gpsText)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(openPi)
                .build()
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(FG_NOTIF_ID, notif)
        } catch (_: Exception) {}
    }

    private fun handleSaveWifiAction(ssid: String?, isHome: Boolean) {
        val clean = ssid?.trim()?.takeIf { it.isNotEmpty() } ?: return
        val key = if (isHome) "flutter.home_wifi_ssid" else "flutter.work_wifi_ssid"
        prefs.edit().putString(key, clean).apply()
        pendingUnknownWifiSsid = null
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(WIFI_PROMPT_NOTIF_ID)
        } catch (_: Exception) {}
        evaluateConnectedWifiState()
    }

    private fun handleIgnoreWifiAction(ssid: String?) {
        val clean = ssid?.trim()?.takeIf { it.isNotEmpty() } ?: return
        val current = (prefs.getStringSet("native_ignored_wifis", emptySet()) ?: emptySet()).toMutableSet()
        current.add(clean)
        prefs.edit().putStringSet("native_ignored_wifis", current).apply()
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
        if (prefsChangeListener == null) {
            prefsChangeListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                handler.post {
                    when (key) {
                        "flutter.parked_lat" -> {
                            if (prefs.contains("flutter.parked_lat")) {
                                promptShownForCurrentSession = false
                                passedThroughStall = false
                                boutStepsSinceStationary = 0
                            } else {
                                cancelPromptNotification()
                                cancelInCarPromptNotification()
                                promptShownForCurrentSession = false
                                passedThroughStall = false
                            }
                            persistAndBroadcastState()
                        }
                        "flutter.home_wifi_ssid", "flutter.work_wifi_ssid" -> evaluateConnectedWifiState()
                        "flutter.native_user_state" -> {
                            val synced = prefs.getString("flutter.native_user_state", null)
                            if (synced != null && synced != userActivityState) {
                                userActivityState = synced
                                if (userActivityState == STATE_IN_CAR) {
                                    gpsRestingAfterAnalysis = true
                                    stopNoStepGpsWindow()
                                }
                                updateForegroundStatusNotification()
                            }
                        }
                    }
                }
            }
            prefs.registerOnSharedPreferenceChangeListener(prefsChangeListener)
        }

        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handler.post {
                    evaluateConnectedWifiState()
                    handler.postDelayed({ evaluateConnectedWifiState() }, 1200L)
                }
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                handler.post { evaluateConnectedWifiState() }
            }

            override fun onLost(network: Network) {
                handler.post {
                    currentConnectedWifiSsid = null
                    pendingUnknownWifiSsid = null
                    gpsRestingAfterAnalysis = false
                    evaluateNoFixedWifiAlgorithm()
                }
            }
        }
        try {
            connectivityManager?.registerNetworkCallback(req, networkCallback!!)
        } catch (_: Exception) {}
    }

    private fun startGeofenceSyncWatchdog() {
        geofenceWatchdogRunnable = object : Runnable {
            override fun run() {
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
        ContextCompat.registerReceiver(this, internalReceiver, internalFilter, ContextCompat.RECEIVER_NOT_EXPORTED)

        val btFilter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        ContextCompat.registerReceiver(this, systemBtReceiver, btFilter, ContextCompat.RECEIVER_EXPORTED)
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
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
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
        prefs.edit().putBoolean("flutter.pending_lockscreen_alarm", true).apply()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(PROMPT_NOTIF_ID, notif)
    }

    private fun cancelReleasePromptNotification() {
        cancelPromptNotification()
    }

    private fun cancelPromptNotification() {
        stopAlarmRingtone()
        prefs.edit().putBoolean("flutter.pending_lockscreen_alarm", false).apply()
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
