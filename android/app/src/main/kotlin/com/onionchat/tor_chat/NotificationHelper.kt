package com.onionchat.tor_chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.concurrent.ConcurrentHashMap

data class NotificationMessage(
    val text: String,
    val timestamp: Long,
    val sender: String,
    val isMe: Boolean = false
)

object NotificationHelper {
    const val MSG_CHANNEL_ID = "tor_chat_incoming_messages"
    const val CALL_CHANNEL_ID = "tor_chat_incoming_calls"
    const val CALL_NOTIFICATION_ID = 999988
    const val KEY_TEXT_REPLY = "key_text_reply"
    const val ACTION_REPLY = "com.onionchat.tor_chat.ACTION_REPLY"
    const val ACTION_DISMISS = "com.onionchat.tor_chat.ACTION_DISMISS_NOTIFICATION"
    const val ACTION_ACCEPT_CALL = "com.onionchat.tor_chat.ACTION_ACCEPT_CALL"
    const val ACTION_DECLINE_CALL = "com.onionchat.tor_chat.ACTION_DECLINE_CALL"

    private var activeRingtone: android.media.Ringtone? = null

    fun playDefaultRingtone(context: Context) {
        try {
            stopDefaultRingtone()
            val uri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE)
            activeRingtone = android.media.RingtoneManager.getRingtone(context.applicationContext, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                activeRingtone?.isLooping = true
            }
            activeRingtone?.play()
        } catch (_: Exception) {}
    }

    fun stopDefaultRingtone() {
        try {
            activeRingtone?.stop()
            activeRingtone = null
        } catch (_: Exception) {}
    }

    private val conversationHistory = ConcurrentHashMap<String, MutableList<NotificationMessage>>()

    fun createCallNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val soundUri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE)
            val audioAttributes = android.media.AudioAttributes.Builder()
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .build()

            val channel = NotificationChannel(
                CALL_CHANNEL_ID,
                "TorChat Voice Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Incoming voice call alerts"
                setSound(soundUri, audioAttributes)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 1000, 1000, 1000, 1000)
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    fun createNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                MSG_CHANNEL_ID,
                "TorChat Messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifies you when peer messages arrive"
                enableVibration(true)
                setShowBadge(true)
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    fun addMessage(chatOnion: String, text: String, timestamp: Long, sender: String, isMe: Boolean = false) {
        val key = chatOnion.trim().lowercase()
        val list = conversationHistory.getOrPut(key) { mutableListOf() }
        synchronized(list) {
            list.add(NotificationMessage(text, timestamp, sender, isMe))
            while (list.size > 20) {
                list.removeAt(0)
            }
        }
    }

    fun clearHistory(chatOnion: String) {
        conversationHistory.remove(chatOnion.trim().lowercase())
    }

    fun getNotificationId(chatOnion: String): Int {
        return (chatOnion.trim().lowercase().hashCode() and 0x7FFFFFFF)
    }

    fun showNotification(
        context: Context,
        chatOnion: String,
        sender: String,
        content: String,
        isReply: Boolean = false
    ) {
        createNotificationChannel(context)
        val cleanOnion = chatOnion.trim().lowercase()
        val notificationId = getNotificationId(cleanOnion)

        if (!isReply) {
            addMessage(cleanOnion, content, System.currentTimeMillis(), sender, isMe = false)
        }

        // Tapping the notification opens this chat in the app
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            putExtra("chat_onion", cleanOnion)
        }
        val contentPendingIntent = if (launchIntent != null) {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            PendingIntent.getActivity(context, notificationId, launchIntent, flags)
        } else null

        // Swiping away the notification clears the in-memory conversation history for this chat
        val deleteIntent = Intent(context, NotificationDismissReceiver::class.java).apply {
            action = ACTION_DISMISS
            putExtra("chat_onion", cleanOnion)
        }
        val deletePendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId,
            deleteIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        // RemoteInput action for inline reply directly from notification
        val remoteInput = RemoteInput.Builder(KEY_TEXT_REPLY)
            .setLabel("Reply")
            .build()

        val replyIntent = Intent(context, NotificationReplyReceiver::class.java).apply {
            action = ACTION_REPLY
            putExtra("chat_onion", cleanOnion)
            putExtra("sender", sender)
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId,
            replyIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val replyAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Reply",
            replyPendingIntent
        )
        .addRemoteInput(remoteInput)
        .setAllowGeneratedReplies(true)
        .build()

        val iconRes = context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_notify_chat

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, MSG_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder.setSmallIcon(iconRes)
            .setAutoCancel(true)
            .setContentTitle(sender)
            .setDeleteIntent(deletePendingIntent)
            .addAction(replyAction)

        if (contentPendingIntent != null) {
            builder.setContentIntent(contentPendingIntent)
        }

        // Apply MessagingStyle conversation aggregation
        val list = conversationHistory[cleanOnion] ?: mutableListOf()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val userPerson = Person.Builder().setName("You").build()
            val senderPerson = Person.Builder().setName(sender).build()
            val messagingStyle = Notification.MessagingStyle(userPerson)
                .setConversationTitle(sender)
            messagingStyle.isGroupConversation = false
            synchronized(list) {
                for (msg in list) {
                    val person = if (msg.isMe) userPerson else senderPerson
                    messagingStyle.addMessage(
                        Notification.MessagingStyle.Message(msg.text, msg.timestamp, person)
                    )
                }
            }
            builder.setStyle(messagingStyle)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val messagingStyle = Notification.MessagingStyle("You")
                .setConversationTitle(sender)
            messagingStyle.isGroupConversation = false
            synchronized(list) {
                for (msg in list) {
                    messagingStyle.addMessage(
                        msg.text,
                        msg.timestamp,
                        if (msg.isMe) null else sender
                    )
                }
            }
            builder.setStyle(messagingStyle)
        } else {
            builder.setContentText(content)
        }

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        notificationManager?.notify(notificationId, builder.build())
    }

    fun dismissNotification(context: Context, chatOnion: String) {
        val cleanOnion = chatOnion.trim().lowercase()
        val notificationId = getNotificationId(cleanOnion)
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        notificationManager?.cancel(notificationId)
        clearHistory(cleanOnion)
    }

    fun showCallNotification(
        context: Context,
        callerOnion: String,
        callerNickname: String,
        callId: String
    ) {
        createCallNotificationChannel(context)

        val cleanOnion = callerOnion.trim().lowercase()

        // Tapping notification brings up the call screen
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            putExtra("chat_onion", cleanOnion)
            putExtra("incoming_call", true)
            putExtra("call_id", callId)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPendingIntent = if (launchIntent != null) {
            PendingIntent.getActivity(context, CALL_NOTIFICATION_ID, launchIntent, flags)
        } else null

        // Accept Action
        val acceptIntent = Intent(context, CallActionReceiver::class.java).apply {
            action = ACTION_ACCEPT_CALL
            putExtra("call_id", callId)
            putExtra("chat_onion", cleanOnion)
        }
        val acceptPendingIntent = PendingIntent.getBroadcast(
            context,
            1001,
            acceptIntent,
            flags
        )

        // Decline Action
        val declineIntent = Intent(context, CallActionReceiver::class.java).apply {
            action = ACTION_DECLINE_CALL
            putExtra("call_id", callId)
            putExtra("chat_onion", cleanOnion)
        }
        val declinePendingIntent = PendingIntent.getBroadcast(
            context,
            1002,
            declineIntent,
            flags
        )

        val soundUri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CALL_CHANNEL_ID)
        } else {
            Notification.Builder(context)
                .setPriority(Notification.PRIORITY_MAX)
                .setSound(soundUri)
        }

        builder.setContentTitle(callerNickname)
            .setContentText("Incoming Tor Voice Call")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentPendingIntent)
            .setFullScreenIntent(contentPendingIntent, true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_MAX)
            .setAutoCancel(true)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Decline",
                    declinePendingIntent
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_call,
                    "Accept",
                    acceptPendingIntent
                ).build()
            )

        // Wake up screen physically if device is sleeping / locked
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            val wakeLock = pm?.newWakeLock(
                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "torchat:incoming_call_wake"
            )
            wakeLock?.acquire(15000L)
        } catch (_: Exception) {}

        MainActivity.turnScreenOnAndShowOnLockscreen()

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        notificationManager?.notify(CALL_NOTIFICATION_ID, builder.build())
    }

    fun dismissCallNotification(context: Context) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        notificationManager?.cancel(CALL_NOTIFICATION_ID)
        stopDefaultRingtone()
        MainActivity.resetLockscreenFlags()
    }
}

