package com.onionchat.tor_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodChannel

class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        val callId = intent.getStringExtra("call_id") ?: ""
        val chatOnion = intent.getStringExtra("chat_onion") ?: ""

        // Dismiss notification and stop ringtone
        NotificationHelper.dismissCallNotification(context)

        if (action == NotificationHelper.ACTION_ACCEPT_CALL) {
            // Launch main activity into call
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                putExtra("incoming_call", true)
                putExtra("call_id", callId)
                putExtra("chat_onion", chatOnion)
            }
            if (launchIntent != null) {
                context.startActivity(launchIntent)
            }

            try {
                val engine = TorEngineHolder.getOrCreateEngine(context)
                MethodChannel(engine.dartExecutor.binaryMessenger, MainActivity.CHANNEL).invokeMethod(
                    "onAcceptCall",
                    mapOf("callId" to callId, "chatOnion" to chatOnion)
                )
            } catch (_: Exception) {}
        } else if (action == NotificationHelper.ACTION_DECLINE_CALL) {
            try {
                val engine = TorEngineHolder.getOrCreateEngine(context)
                MethodChannel(engine.dartExecutor.binaryMessenger, MainActivity.CHANNEL).invokeMethod(
                    "onDeclineCall",
                    mapOf("callId" to callId, "chatOnion" to chatOnion)
                )
            } catch (_: Exception) {}
        }
    }
}

