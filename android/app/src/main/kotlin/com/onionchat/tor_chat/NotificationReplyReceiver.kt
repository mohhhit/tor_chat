package com.onionchat.tor_chat

import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodChannel

class NotificationReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val remoteInput = RemoteInput.getResultsFromIntent(intent)
        val replyText = remoteInput?.getCharSequence(NotificationHelper.KEY_TEXT_REPLY)?.toString()?.trim()
        val chatOnion = intent.getStringExtra("chat_onion")
        val sender = intent.getStringExtra("sender") ?: "Peer"

        if (replyText.isNullOrEmpty() || chatOnion.isNullOrEmpty()) return

        // 1. Add reply to local notification conversation and update notification so Android shows "You: ..."
        NotificationHelper.addMessage(chatOnion, replyText, System.currentTimeMillis(), "You", isMe = true)
        NotificationHelper.showNotification(context, chatOnion, sender, replyText, isReply = true)

        // 2. Dispatch to Flutter engine to send over Tor
        try {
            val engine = TorEngineHolder.getOrCreateEngine(context)
            MethodChannel(engine.dartExecutor.binaryMessenger, MainActivity.CHANNEL).invokeMethod(
                "onNotificationReply",
                mapOf(
                    "chatOnion" to chatOnion,
                    "content" to replyText
                )
            )
        } catch (_: Exception) {}
    }
}

