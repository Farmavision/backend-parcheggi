package com.parkadvisor.parkadvisor_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothDevice
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

private fun readSafeDouble(prefs: android.content.SharedPreferences, key: String, def: Double): Double {
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

class FixedWifiMonitorService : Service(), LocationListener, SensorEventListener {

    companion object {
        const val CHANNEL_FG = "parknow_fg_service_v1"
        const val CHANNEL_ALERT = "parknow_urgent_alarm_v3"
        const val FG_NOTIF_ID = 4101
        const val PROMPT_NOTIF_ID = 4102
        const val RELEASED_NOTIF_ID = 4104

        const val ACTION_START = "com.parkadvisor.ACTION_START"
        const val ACTION_CONFIRM_RELEASE = "com.parkadvisor.ACTION_CONFIRM_RELEASE"
        const val ACTION_DENY_RELEASE = "com.parkadvisor.ACTION_DENY_RELEASE"
        const val ACTION_GEOFENCE_TRANSITION = "com.parkadvisor.ACTION_GEOFENCE_TRANSITION"
        const val GEOFENCE_REQ_ID = "parknow_active_stall_geofence"
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var prefs: SharedPreferences
    private lateinit var locationManager: LocationManager
    private lateinit var geofencingClient: GeofencingClient
    private var sensorManager: SensorManager? = null
    private var stepDetector: Sensor? = null

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private var wasOnFixedWifi = false
    private var promptShownForCurrentSession = false
    private var activeScenario = "NONE"
    private var gpsHighAccuracyActive = false
    private var inExitAnalysis = false
    private var passedThroughStall = false
    private var vehicularSamples = 0
    private var initialGpsDistanceMeters: Float? = null
    private var lastGeofenceCoords: Pair<Double, Double>? = null
    private var lastGeofenceRadiusMeters: Float = -1f

    private var hasStepSensor = false
    private var lastStepTimestampMs = 0L
    private var recentStepCount = 0
    private var isCarBtConnected = false
    private var activeRingtone: android.media.Ringtone? = null

    private var wifiDebounceRunnable: Runnable? = null
    private var gpsActivateDelayRunnable: Runnable? = null
    private var gpsMaxTimeoutRunnable: Runnable? = null
    private var gpsDeactivateRunnable: Runnable? = null
    private var geofenceWatchdogRunnable: Runnable? = null

    private val internalReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_CONFIRM_RELEASE -> handleUserConfirmRelease()
                ACTION_DENY_RELEASE -> handleUserDenyRelease()
                ACTION_GEOFENCE_TRANSITION -> handleGeofenceEnterEvent(intent)
                BluetoothDevice.ACTION_ACL_CONNECTED -> {
                    val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    val targetMac = prefs.getString("flutter.car_bt_mac", null)?.uppercase()
                    if (!targetMac.isNullOrEmpty() && dev?.address?.uppercase() == targetMac) {
                        isCarBtConnected = true
                        evaluateFastPathBluetooth()
                    }
                }
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                    isCarBtConnected = false
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

        registerStepSensor()
        registerInternalReceivers()
        registerWifiNetworkCallback()
        startGeofenceSyncWatchdog()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        syncNativeGeofenceWithActiveParking()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        cancelAllRunnables()
        stopHighAccuracyGpsImmediate()
        try {
            sensorManager?.unregisterListener(this)
            unregisterReceiver(internalReceiver)
            networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
            geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID))
        } catch (_: Exception) {}
    }

    private fun getXtRitNotSec(): Long = (safeGetInt("flutter.xt_rit_not_sec", 15)).coerceAtLeast(0).toLong()
    private fun getXtGpsAttivoSec(): Long = (safeGetInt("flutter.xt_gps_attivo_sec", 10)).coerceAtLeast(0).toLong()
    private fun getXtGpsMaxAttivoMin(): Long = (safeGetInt("flutter.xt_gps_max_attivo_min", 5)).coerceAtLeast(1).toLong()
    private fun getXtGpsDisattivoSec(): Long = (safeGetInt("flutter.xt_gps_disattivo_sec", 15)).coerceAtLeast(0).toLong()
    
    

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

    private fun getGeofenceRadiusMeters(): Float = (safeGetInt("flutter.geofence_radius_m", 100)).coerceIn(20, 2000).toFloat()

    private fun hasActiveParking(): Boolean {
        return prefs.contains("flutter.parked_lat") && prefs.contains("flutter.parked_lon")
    }

    private fun getParkedLatLon(): Pair<Double, Double>? {
        if (!hasActiveParking()) return null
        val lat = java.lang.readSafeDouble(prefs, "flutter.parked_lat", 0.0)
        val lon = java.lang.readSafeDouble(prefs, "flutter.parked_lon", 0.0)
        if (lat == 0.0 && lon == 0.0) return null
        return Pair(lat, lon)
    }

    private fun registerStepSensor() {
        try {
            sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            stepDetector = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
            if (stepDetector != null) {
                hasStepSensor = true
                sensorManager?.registerListener(this, stepDetector, SensorManager.SENSOR_DELAY_NORMAL)
            }
        } catch (_: Exception) {
            hasStepSensor = false
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type == Sensor.TYPE_STEP_DETECTOR) {
            val now = System.currentTimeMillis()
            if (now - lastStepTimestampMs > 180_000L) {
                recentStepCount = 0
            }
            lastStepTimestampMs = now
            recentStepCount++
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun hasRecentHumanWalking(): Boolean {
        if (!hasStepSensor) return true
        val elapsed = System.currentTimeMillis() - lastStepTimestampMs
        return elapsed <= 180_000L && recentStepCount >= 5
    }

    private fun isStepStoppedAfterWalking(): Boolean {
        if (!hasStepSensor) return true
        val elapsedSinceLastStep = System.currentTimeMillis() - lastStepTimestampMs
        return recentStepCount >= 3 && elapsedSinceLastStep >= 6_000L
    }

    private fun getConnectedFixedWifiSsid(): String? {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
            val info = wifiManager.connectionInfo ?: return null
            val rawSsid = info.ssid?.replace("\"", "") ?: return null
            if (rawSsid == "<unknown ssid>" || rawSsid.isEmpty()) return null

            val homeSsid = prefs.getString("flutter.home_wifi_ssid", "") ?: ""
            val workSsid = prefs.getString("flutter.work_wifi_ssid", "") ?: ""
            val fixedList = prefs.getString("flutter.fixed_wifi_ssids", "") ?: ""

            val registered = (listOf(homeSsid, workSsid) + fixedList.split(","))
                .map { it.trim() }
                .filter { it.isNotEmpty() }

            return if (registered.any { it.equals(rawSsid, ignoreCase = true) }) rawSsid else null
        } catch (_: Exception) {
            return null
        }
    }

    private fun registerWifiNetworkCallback() {
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        wasOnFixedWifi = getConnectedFixedWifiSsid() != null

        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handler.post {
                    if (getConnectedFixedWifiSsid() != null) {
                        wasOnFixedWifi = true
                        wifiDebounceRunnable?.let { handler.removeCallbacks(it) }
                    }
                }
            }

            override fun onLost(network: Network) {
                handler.post {
                    if (wasOnFixedWifi && hasActiveParking()) {
                        wasOnFixedWifi = false
                        scheduleScenarioAWifiDebounce()
                    }
                }
            }
        }
        try {
            connectivityManager?.registerNetworkCallback(req, networkCallback!!)
        } catch (_: Exception) {}
    }

    private fun scheduleScenarioAWifiDebounce() {
        wifiDebounceRunnable?.let { handler.removeCallbacks(it) }
        val delayMs = getXtRitNotSec() * 1000L
        wifiDebounceRunnable = Runnable {
            if (getConnectedFixedWifiSsid() == null && hasActiveParking() && !promptShownForCurrentSession) {
                activeScenario = "A"
                triggerReleaseConfirmationPrompt()
            }
        }
        handler.postDelayed(wifiDebounceRunnable!!, delayMs)
    }

    private fun startGeofenceSyncWatchdog() {
        geofenceWatchdogRunnable = object : Runnable {
            override fun run() {
                syncNativeGeofenceWithActiveParking()
                handler.postDelayed(this, 30_000L)
            }
        }
        handler.post(geofenceWatchdogRunnable!!)
    }

    private fun syncNativeGeofenceWithActiveParking() {
        val coords = getParkedLatLon()
        if (coords == null) {
            promptShownForCurrentSession = false
            activeScenario = "NONE"
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

    private fun handleGeofenceEnterEvent(intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent)
        if (event != null && event.hasError()) return
        if (!hasActiveParking()) return

        if (activeScenario == "A" && promptShownForCurrentSession) {
            inExitAnalysis = true
            if (!gpsHighAccuracyActive) {
                startHighAccuracyGpsTracking()
            }
            return
        }

        if (getConnectedFixedWifiSsid() == null && !promptShownForCurrentSession) {
            if (hasRecentHumanWalking()) {
                activeScenario = "B"
                triggerReleaseConfirmationPrompt()
            }
        }
    }

    private fun triggerReleaseConfirmationPrompt() {
        promptShownForCurrentSession = true
        showReleasePromptNotification()

        gpsActivateDelayRunnable?.let { handler.removeCallbacks(it) }
        val waitMs = getXtGpsAttivoSec() * 1000L
        gpsActivateDelayRunnable = Runnable {
            if (hasActiveParking()) {
                if (activeScenario == "B") {
                    inExitAnalysis = true
                }
                startHighAccuracyGpsTracking()
            }
        }
        handler.postDelayed(gpsActivateDelayRunnable!!, waitMs)
    }

    private fun handleUserConfirmRelease() {
        cancelAllRunnables()
        cancelPromptNotification()
        triggerServerRelease(2)
        resetSessionFlagsAndClearParking()
        stopHighAccuracyGpsImmediate()
    }

    private fun handleUserDenyRelease() {
        gpsActivateDelayRunnable?.let { handler.removeCallbacks(it) }
        gpsMaxTimeoutRunnable?.let { handler.removeCallbacks(it) }
        cancelPromptNotification()
        inExitAnalysis = false
        passedThroughStall = false
        vehicularSamples = 0

        if (gpsHighAccuracyActive) {
            scheduleGpsPowerSaveAfterXtDisattivo()
        }
    }

    private fun startHighAccuracyGpsTracking() {
        if (gpsHighAccuracyActive) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return
        }

        gpsDeactivateRunnable?.let { handler.removeCallbacks(it) }
        gpsHighAccuracyActive = true
        initialGpsDistanceMeters = null
        vehicularSamples = 0

        try {
            locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 2000L, 2f, this, Looper.getMainLooper())
            locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 3000L, 5f, this, Looper.getMainLooper())
        } catch (_: Exception) {}

        gpsMaxTimeoutRunnable?.let { handler.removeCallbacks(it) }
        val maxMs = getXtGpsMaxAttivoMin() * 60_000L
        gpsMaxTimeoutRunnable = Runnable {
            closeTrackingAndSchedulePowerSave()
        }
        handler.postDelayed(gpsMaxTimeoutRunnable!!, maxMs)
    }

    private fun closeTrackingAndSchedulePowerSave() {
        gpsMaxTimeoutRunnable?.let { handler.removeCallbacks(it) }
        inExitAnalysis = false
        passedThroughStall = false
        vehicularSamples = 0
        scheduleGpsPowerSaveAfterXtDisattivo()
    }

    private fun scheduleGpsPowerSaveAfterXtDisattivo() {
        gpsDeactivateRunnable?.let { handler.removeCallbacks(it) }
        val disattivoMs = getXtGpsDisattivoSec() * 1000L
        gpsDeactivateRunnable = Runnable {
            stopHighAccuracyGpsImmediate()
        }
        handler.postDelayed(gpsDeactivateRunnable!!, disattivoMs)
    }

    private fun stopHighAccuracyGpsImmediate() {
        gpsHighAccuracyActive = false
        try {
            locationManager.removeUpdates(this)
        } catch (_: Exception) {}
    }

    override fun onLocationChanged(loc: Location) {
        val coords = getParkedLatLon() ?: run {
            stopHighAccuracyGpsImmediate()
            return
        }

        val results = FloatArray(1)
        Location.distanceBetween(loc.latitude, loc.longitude, coords.first, coords.second, results)
        val distMeters = results[0]

        if (initialGpsDistanceMeters == null) {
            initialGpsDistanceMeters = distMeters
        }

        val geoRadius = getGeofenceRadiusMeters()
        if (distMeters <= geoRadius) {
            inExitAnalysis = true
        }

        val initDist = initialGpsDistanceMeters ?: distMeters
        if (!inExitAnalysis && distMeters > initDist + 50f && distMeters > geoRadius + 60f) {
            closeTrackingAndSchedulePowerSave()
            return
        }

        if (distMeters <= 30f) {
            passedThroughStall = true
        }

        if (inExitAnalysis) {
            if (passedThroughStall && isCarBtConnected && distMeters > 15f) {
                completeAutomaticVehicleDeparture()
                return
            }

            val speedKmh = if (loc.hasSpeed()) loc.speed * 3.6f else 0f
            if (passedThroughStall && isStepStoppedAfterWalking() && speedKmh >= 16f && distMeters > 40f) {
                vehicularSamples++
                if (vehicularSamples >= 2) {
                    completeAutomaticVehicleDeparture()
                    return
                }
            } else if (speedKmh < 10f) {
                vehicularSamples = 0
            }
        }
    }

    private fun evaluateFastPathBluetooth() {
        getParkedLatLon() ?: return
        if (passedThroughStall && isCarBtConnected) {
            if (!gpsHighAccuracyActive) {
                inExitAnalysis = true
                startHighAccuracyGpsTracking()
            }
        }
    }

    private fun completeAutomaticVehicleDeparture() {
        cancelAllRunnables()
        cancelPromptNotification()
        triggerServerRelease(0)
        showDepartureReleasedNotification()
        resetSessionFlagsAndClearParking()
        scheduleGpsPowerSaveAfterXtDisattivo()
    }

    private fun resetSessionFlagsAndClearParking() {
        prefs.edit().remove("flutter.parked_lat").remove("flutter.parked_lon").apply()
        promptShownForCurrentSession = false
        activeScenario = "NONE"
        inExitAnalysis = false
        passedThroughStall = false
        vehicularSamples = 0
        initialGpsDistanceMeters = null
        try { geofencingClient.removeGeofences(listOf(GEOFENCE_REQ_ID)) } catch (_: Exception) {}
    }

    private fun cancelAllRunnables() {
        wifiDebounceRunnable?.let { handler.removeCallbacks(it) }
        gpsActivateDelayRunnable?.let { handler.removeCallbacks(it) }
        gpsMaxTimeoutRunnable?.let { handler.removeCallbacks(it) }
        gpsDeactivateRunnable?.let { handler.removeCallbacks(it) }
    }

    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}

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

    private fun registerInternalReceivers() {
        val filter = IntentFilter().apply {
            addAction(ACTION_CONFIRM_RELEASE)
            addAction(ACTION_DENY_RELEASE)
            addAction(ACTION_GEOFENCE_TRANSITION)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        ContextCompat.registerReceiver(this, internalReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val fgChannel = NotificationChannel(CHANNEL_FG, "Monitoraggio Parcheggio Attivo", NotificationManager.IMPORTANCE_LOW)
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
            .setContentTitle("ParkAdvisor attivo in background")
            .setContentText("Rilevamento uscita parcheggio a basso consumo")
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
            .setContentText("Conferma per segnalare lo stallo in rilascio oppure rifiuta.")
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
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(PROMPT_NOTIF_ID, notif)
    }

    private fun cancelPromptNotification() {
        stopAlarmRingtone()
        prefs.edit().putBoolean("flutter.pending_lockscreen_alarm", false).apply()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(PROMPT_NOTIF_ID)
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
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(RELEASED_NOTIF_ID, notif)
    }
}
