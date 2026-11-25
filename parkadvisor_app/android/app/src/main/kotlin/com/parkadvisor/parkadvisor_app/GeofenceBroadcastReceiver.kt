package com.parkadvisor.parkadvisor_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class GeofenceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val svc = FixedWifiMonitorService.instance
        if (svc != null) {
            svc.onExternalGeofenceIntent(intent)
        } else {
            val fwd = Intent(FixedWifiMonitorService.ACTION_GEOFENCE_TRANSITION)
                .setPackage(context.packageName)
            intent.extras?.let { fwd.putExtras(it) }
            context.sendBroadcast(fwd)
        }
    }
}
