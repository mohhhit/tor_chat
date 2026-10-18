package com.onionchat.tor_chat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return TorEngineHolder.getOrCreateEngine(context)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createMessageNotificationChannel(applicationContext)

        // Start Tor background service immediately to protect the process
        try {
            val serviceIntent = Intent(this, TorBackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (_: Exception) {}

        // Request notification permission on Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }
    }

    override fun onBackPressed() {
        moveTaskToBack(true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val chatOnion = intent.getStringExtra("chat_onion")
        if (chatOnion != null) {
            intent.removeExtra("chat_onion")
            val currentEngine = TorEngineHolder.getOrCreateEngine(this)
            MethodChannel(currentEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onSelectChat", chatOnion)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Ensure channel handler is ready
        setupNativeChannel(flutterEngine, applicationContext)

        // Forward any initial chat onion from launcher intent
        intent?.getStringExtra("chat_onion")?.let { initialChat ->
            intent?.removeExtra("chat_onion")
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onSelectChat", initialChat)
        }
    }

    companion object {
        const val CHANNEL = "com.onionchat.tor_chat/native"
        const val MSG_CHANNEL_ID = "tor_chat_incoming_messages"

        fun createMessageNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    MSG_CHANNEL_ID,
                    "TorChat Messages",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notifies you when peer messages arrive"
                    enableVibration(true)
                }
                val manager = context.getSystemService(NotificationManager::class.java)
                manager?.createNotificationChannel(channel)
            }
        }

        fun setupNativeChannel(flutterEngine: FlutterEngine, context: Context) {
            val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            channel.setMethodCallHandler { call, result ->
                val appContext = context.applicationContext
                when (call.method) {
                    "moveToBackground" -> {
                        try {
                            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                                addCategory(Intent.CATEGORY_HOME)
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            appContext.startActivity(homeIntent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MOVE_ERROR", e.message, null)
                        }
                    }
                    "getNativeTorPath" -> {
                        try {
                            val libDir = appContext.applicationInfo.nativeLibraryDir
                            val torFile = File(libDir, "libtor.so")
                            if (torFile.exists() && torFile.canExecute()) {
                                result.success(torFile.absolutePath)
                            } else if (torFile.exists()) {
                                torFile.setExecutable(true, false)
                                result.success(torFile.absolutePath)
                            } else {
                                result.success(null)
                            }
                        } catch (e: Exception) {
                            result.error("TOR_PATH_ERROR", e.message, null)
                        }
                    }
                    "startBackgroundService" -> {
                        try {
                            val intent = Intent(appContext, TorBackgroundService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                appContext.startForegroundService(intent)
                            } else {
                                appContext.startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE_START_ERROR", e.message, null)
                        }
                    }
                    "stopBackgroundService" -> {
                        try {
                            val intent = Intent(appContext, TorBackgroundService::class.java)
                            appContext.stopService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE_STOP_ERROR", e.message, null)
                        }
                    }
                    "isBatteryOptimizationIgnored" -> {
                        try {
                            val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                            val isIgnored = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                powerManager?.isIgnoringBatteryOptimizations(appContext.packageName) == true
                            } else {
                                true
                            }
                            result.success(isIgnored)
                        } catch (e: Exception) {
                            result.error("BATTERY_CHECK_ERROR", e.message, null)
                        }
                    }
                    "requestIgnoreBatteryOptimization" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:${appContext.packageName}")
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                appContext.startActivity(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                appContext.startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("BATTERY_REQUEST_ERROR", e2.message, null)
                            }
                        }
                    }
                    "showIncomingNotification" -> {
                        try {
                            val sender = call.argument<String>("sender") ?: "Peer"
                            val content = call.argument<String>("content") ?: "New message"
                            val chatOnion = call.argument<String>("chatOnion")

                            val launchIntent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)?.apply {
                                action = Intent.ACTION_MAIN
                                addCategory(Intent.CATEGORY_LAUNCHER)
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                                if (chatOnion != null) {
                                    putExtra("chat_onion", chatOnion)
                                }
                            }

                            val pendingIntent = if (launchIntent != null) {
                                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                                } else {
                                    PendingIntent.FLAG_UPDATE_CURRENT
                                }
                                PendingIntent.getActivity(appContext, (System.currentTimeMillis() % 10000).toInt(), launchIntent, flags)
                            } else null

                            val iconRes = appContext.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_notify_chat

                            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                android.app.Notification.Builder(appContext, MSG_CHANNEL_ID)
                            } else {
                                @Suppress("DEPRECATION")
                                android.app.Notification.Builder(appContext)
                            }

                            builder.setContentTitle(sender)
                                .setContentText(content)
                                .setSmallIcon(iconRes)
                                .setAutoCancel(true)

                            if (pendingIntent != null) {
                                builder.setContentIntent(pendingIntent)
                            }

                            val notificationManager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                            notificationManager?.notify((System.currentTimeMillis() % 10000).toInt(), builder.build())
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("NOTIFICATION_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
