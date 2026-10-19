package com.onionchat.tor_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class NotificationDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val chatOnion = intent.getStringExtra("chat_onion")
        if (!chatOnion.isNullOrEmpty()) {
            NotificationHelper.clearHistory(chatOnion)
        }
    }
}

