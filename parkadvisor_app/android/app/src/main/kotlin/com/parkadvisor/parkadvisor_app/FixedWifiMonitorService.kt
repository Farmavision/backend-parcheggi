package com.parkadvisor.parkadvisor_app

import android.app.*
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.*
import android.net.wifi.WifiManager
import android.os.*
import androidx.core.app.NotificationCompat
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

class FixedWifiMonitorService : Service() {
    companion object {
        const val CHANNEL_MONITOR = "parknow_bg_monitor"
        const val CHANNEL_ALERT = "parknow_urgent_alert_v2"
        const val NOTIF_FOREGROUND_ID = 4101
        const val NOTIF_WIFI_EXIT_ID = 4102
        const val NOTIF_100M_ID = 4103

        const val ACTION_START = "ACTION_START_MONITOR"
        const val ACTION_WIFI_DISCONNECTED = "ACTION_WIFI_DISCONNECTED"
        const val ACTION_USER_CONFIRM_RELEASE = "ACTION_USER_CONFIRM_RELEASE"
        const val ACTION_USER_IGNORE_WALK = "ACTION_USER_IGNORE_WALK"
    }

    private val handler = Handler(Looper.getMainLooper())
    private var escalationRunnable: Runnable? = null
    private var gpsTimeoutRunnable: Runnable? = null
    private var gpsActive = false
    private var vehicularSamples = 0
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var locationListener: LocationListener? = null

    override fun onCreate() {
        super.onCreate()
        createChannels()
        registerWifiCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        when (action) {
            ACTION_START -> {
                safeStartForeground(NOTIF_FOREGROUND_ID, buildMonitorNotification("Monitoraggio Wi-Fi fisse e sosta attivo"))
            }
            ACTION_WIFI_DISCONNECTED -> {
                val disconnectedSsid = intent?.getStringExtra("ssid") ?: "Wi-Fi fissa"
                handleFixedWifiDisconnected(disconnectedSsid)
            }
            ACTION_USER_CONFIRM_RELEASE -> {
                cancelEscalation()
                stopGpsTracking()
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(NOTIF_WIFI_EXIT_ID)
                triggerServerRelease(4)
                safeStartForeground(NOTIF_FOREGROUND_ID, buildMonitorNotification("Rilascio stallo confermato (4 min)"))
            }
            ACTION_USER_IGNORE_WALK -> {
                cancelEscalation()
                stopGpsTracking()
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(NOTIF_WIFI_EXIT_ID)
                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                prefs.edit().putLong("flutter.walk_snooze_until", System.currentTimeMillis() + 30 * 60 * 1000L).apply()
                safeStartForeground(NOTIF_FOREGROUND_ID, buildMonitorNotification("Uscita a piedi: monitoraggio in pausa 30 min"))
            }
        }
        return START_STICKY
    }

    private fun registerWifiCallback() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handler.postDelayed({ checkCurrentWifiAndStore() }, 1500)
            }

            override fun onLost(network: Network) {
                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val wasOnFixed = prefs.getBoolean("flutter.was_on_fixed_wifi", false)
                val lastSsid = prefs.getString("flutter.last_fixed_wifi_name", "Wi-Fi fissa") ?: "Wi-Fi fissa"
                if (wasOnFixed) {
                    prefs.edit().putBoolean("flutter.was_on_fixed_wifi", false).apply()
                    handler.post { handleFixedWifiDisconnected(lastSsid) }
                }
            }
        }
        try {
            cm.registerNetworkCallback(request, networkCallback!!)
        } catch (_: Exception) {}
    }

    private fun checkCurrentWifiAndStore() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val rawList = prefs.getString("flutter.home_wifi_ssid", "") ?: ""
            val fixedList = rawList.split(",").map { it.trim().lowercase() }.filter { it.isNotEmpty() }
            if (fixedList.isEmpty()) return

            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wm.connectionInfo
            val ssid = (info?.ssid ?: "").replace("\"", "").trim()
            if (ssid.isNotEmpty() && ssid != "<unknown ssid>" && fixedList.contains(ssid.lowercase())) {
                prefs.edit()
                    .putBoolean("flutter.was_on_fixed_wifi", true)
                    .putString("flutter.last_fixed_wifi_name", ssid)
                    .apply()
                cancelEscalation()
                stopGpsTracking()
                safeStartForeground(NOTIF_FOREGROUND_ID, buildMonitorNotification("Connesso a $ssid (GPS in stand-by)"))
            }
        } catch (_: Exception) {}
    }

    private fun handleFixedWifiDisconnected(ssidName: String) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val hasParkedCar = prefs.contains("flutter.parked_lat") && prefs.contains("flutter.parked_lon")
        if (!hasParkedCar) return

        val snoozeUntil = prefs.getLong("flutter.walk_snooze_until", 0L)
        if (System.currentTimeMillis() < snoozeUntil) return

        safeStartForeground(NOTIF_FOREGROUND_ID, buildMonitorNotification("Uscita da $ssidName rilevata: in attesa risposta..."))
        showWifiExitNotification(ssidName)

        val waitSec = prefs.getInt("flutter.wifi_exit_timeout_sec", 35).coerceIn(5, 300)
        cancelEscalation()
        escalationRunnable = Runnable {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTIF_WIFI_EXIT_ID)
            safeStartForeground(NOTIF_FOREGROUND_ID, buildMonitorNotification("Notifica ignorata (${waitSec}s): GPS avvicinamento attivo"))
            startGpsTracking()
        }
        handler.postDelayed(escalationRunnable!!, waitSec * 1000L)
    }

    private fun cancelEscalation() {
        escalationRunnable?.let { handler.removeCallbacks(it) }
        escalationRunnable = null
    }

    private fun startGpsTracking() {
        if (gpsActive) return
        val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        locationListener = object : LocationListener {
            override fun onLocationChanged(loc: Location) {
                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                if (!prefs.contains("flutter.parked_lat") || !prefs.contains("flutter.parked_lon")) {
                    stopGpsTracking()
                    return
                }
                val carLat = java.lang.Double.longBitsToDouble(prefs.getLong("flutter.parked_lat", 0L))
                val carLon = java.lang.Double.longBitsToDouble(prefs.getLong("flutter.parked_lon", 0L))
                if (carLat == 0.0 || carLon == 0.0) return

                val results = FloatArray(1)
                Location.distanceBetween(loc.latitude, loc.longitude, carLat, carLon, results)
                val distMeters = results[0]
                val speedKmh = if (loc.hasSpeed()) loc.speed * 3.6f else 0f

                if (speedKmh >= 10f && distMeters > 120f) {
                    vehicularSamples++
                    if (vehicularSamples >= 2) {
                        vehicularSamples = 0
                        prefs.edit().remove("flutter.parked_lat").remove("flutter.parked_lon").apply()
                        triggerServerRelease(0)
                        showDepartureReleasedNotification()
                        stopGpsTracking()
                        return
                    }
                } else if (speedKmh < 6f) {
                    vehicularSamples = 0
                }

                if (distMeters <= 100f) {
                    showApproaching100mNotification(distMeters.toInt())
                    val isBeta = prefs.getBoolean("flutter.is_beta_tester", false)
                    if (isBeta) {
                        triggerServerRelease(3)
                    }
                    stopGpsTracking()
                }
            }
        }
        try {
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 4000L, 5f, locationListener!!, Looper.getMainLooper())
            gpsActive = true
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val idleMin = prefs.getInt("flutter.gps_idle_timeout_min", 12).coerceIn(1, 120)
            gpsTimeoutRunnable?.let { handler.removeCallbacks(it) }
            gpsTimeoutRunnable = Runnable {
                stopGpsTracking()
                safeStartForeground(NOTIF_FOREGROUND_ID, buildMonitorNotification("GPS spento dopo ${idleMin}m senza avvicinamento"))
            }
            handler.postDelayed(gpsTimeoutRunnable!!, idleMin * 60 * 1000L)
        } catch (_: SecurityException) {}
    }

    private fun stopGpsTracking() {
        gpsTimeoutRunnable?.let { handler.removeCallbacks(it) }
        gpsTimeoutRunnable = null
        if (!gpsActive) return
        try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            locationListener?.let { lm.removeUpdates(it) }
        } catch (_: Exception) {}
        gpsActive = false
    }

    private fun showWifiExitNotification(ssidName: String) {
        val confirmIntent = Intent(this, FixedWifiMonitorService::class.java).apply { action = ACTION_USER_CONFIRM_RELEASE }
        val confirmPi = PendingIntent.getService(this, 11, confirmIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val ignoreIntent = Intent(this, FixedWifiMonitorService::class.java).apply { action = ACTION_USER_IGNORE_WALK }
        val ignorePi = PendingIntent.getService(this, 12, ignoreIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val openAppIntent = Intent(this, MainActivity::class.java)
        val openPi = PendingIntent.getActivity(this, 13, openAppIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val notif = NotificationCompat.Builder(this, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Uscita da $ssidName")
            .setContentText("Stai andando a riprendere l\u0027auto? (Se ignori, attivo il GPS)")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVibrate(longArrayOf(0, 500, 250, 500))
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setFullScreenIntent(openPi, true)
            .setContentIntent(openPi)
            .addAction(android.R.drawable.ic_menu_send, "Sì, libero tra poco", confirmPi)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Resto a piedi", ignorePi)
            .build()

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_WIFI_EXIT_ID, notif)
    }

    private fun showApproaching100mNotification(meters: Int) {
        val openAppIntent = Intent(this, MainActivity::class.java)
        val openPi = PendingIntent.getActivity(this, 20, openAppIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val notif = NotificationCompat.Builder(this, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("Sei a ${meters}m dalla tua auto!")
            .setContentText("Rilascio stallo avviato automaticamente (Silenzio-Assenso).")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVibrate(longArrayOf(0, 700, 300, 700, 300, 700))
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setFullScreenIntent(openPi, true)
            .setContentIntent(openPi)
            .build()

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_100M_ID, notif)
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
                conn.disconnect()
            } catch (_: Exception) {}
        }.start()
    }

    private fun buildMonitorNotification(text: String): Notification {
        val openPi = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_MONITOR)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("ParkNow! Attivo")
            .setContentText(text)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setFullScreenIntent(openPi, true)
            .setContentIntent(openPi)
            .build()
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val chMonitor = NotificationChannel(CHANNEL_MONITOR, "Monitoraggio Sosta Background", NotificationManager.IMPORTANCE_LOW)
            val chAlert = NotificationChannel(CHANNEL_ALERT, "Avvisi Rilascio Parcheggio", NotificationManager.IMPORTANCE_HIGH).apply {
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 250, 500)
            }
            nm.createNotificationChannel(chMonitor)
            nm.createNotificationChannel(chAlert)
        }
    }

    private fun safeStartForeground(id: Int, notif: Notification) {
        try {
            startForeground(id, notif)
        } catch (_: Exception) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        cancelEscalation()
        stopGpsTracking()
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            networkCallback?.let { cm.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showDepartureReleasedNotification() {
        val openPi = PendingIntent.getActivity(this, 25, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notif = NotificationCompat.Builder(this, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Ripartenza in auto rilevata")
            .setContentText("Parcheggio liberato automaticamente sulla mappa.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setContentIntent(openPi)
            .build()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(4104, notif)
    }

}
