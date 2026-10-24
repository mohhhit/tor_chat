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

    fun applyLockscreenFlags(enable: Boolean) {
        runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(enable)
                setTurnScreenOn(enable)
            } else {
                if (enable) {
                    @Suppress("DEPRECATION")
                    window.addFlags(
                        android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        android.view.WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                    )
                } else {
                    @Suppress("DEPRECATION")
                    window.clearFlags(
                        android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        android.view.WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                    )
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        currentActivity = this
        createMessageNotificationChannel(applicationContext)
        NotificationHelper.createCallNotificationChannel(applicationContext)

        if (intent?.getBooleanExtra("incoming_call", false) == true) {
            applyLockscreenFlags(true)
        }

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

        // When activity is created: if chat_onion was given (from notification), open chat;
        // otherwise (e.g. fresh launch or reopened from launcher/recents), reset to inbox
        val chatOnion = intent?.getStringExtra("chat_onion")
        val currentEngine = TorEngineHolder.getOrCreateEngine(this)
        if (chatOnion != null) {
            intent?.removeExtra("chat_onion")
            MethodChannel(currentEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onSelectChat", chatOnion)
        } else {
            MethodChannel(currentEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onResetToInbox", null)
        }
    }

    override fun onDestroy() {
        if (currentActivity == this) {
            currentActivity = null
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra("incoming_call", false)) {
            applyLockscreenFlags(true)
        }
        val chatOnion = intent.getStringExtra("chat_onion")
        val currentEngine = TorEngineHolder.getOrCreateEngine(this)
        if (chatOnion != null) {
            intent.removeExtra("chat_onion")
            MethodChannel(currentEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onSelectChat", chatOnion)
        } else if (intent.action == Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_LAUNCHER)) {
            MethodChannel(currentEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onResetToInbox", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Ensure channel handler is ready
        setupNativeChannel(flutterEngine, applicationContext)

        // Forward initial chat onion if present, otherwise reset to inbox
        val initialChat = intent?.getStringExtra("chat_onion")
        if (initialChat != null) {
            intent?.removeExtra("chat_onion")
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onSelectChat", initialChat)
        } else {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onResetToInbox", null)
        }
    }

    companion object {
        const val CHANNEL = "com.onionchat.tor_chat/native"
        const val MSG_CHANNEL_ID = NotificationHelper.MSG_CHANNEL_ID
        private var currentActivity: MainActivity? = null

        fun turnScreenOnAndShowOnLockscreen() {
            currentActivity?.applyLockscreenFlags(true)
        }

        fun resetLockscreenFlags() {
            currentActivity?.applyLockscreenFlags(false)
        }

        fun createMessageNotificationChannel(context: Context) {
            NotificationHelper.createNotificationChannel(context)
        }

        fun setupNativeChannel(flutterEngine: FlutterEngine, context: Context) {
            val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            channel.setMethodCallHandler { call, result ->
                val appContext = context.applicationContext
                when (call.method) {
                    "moveToBackground" -> {
                        try {
                            val moved = currentActivity?.moveTaskToBack(true) ?: false
                            if (!moved) {
                                val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                                    addCategory(Intent.CATEGORY_HOME)
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                appContext.startActivity(homeIntent)
                            }
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
                            if (!chatOnion.isNullOrEmpty()) {
                                NotificationHelper.showNotification(appContext, chatOnion, sender, content)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("NOTIFICATION_ERROR", e.message, null)
                        }
                    }
                    "dismissNotification" -> {
                        try {
                            val chatOnion = call.argument<String>("chatOnion")
                            if (!chatOnion.isNullOrEmpty()) {
                                NotificationHelper.dismissNotification(appContext, chatOnion)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("DISMISS_ERROR", e.message, null)
                        }
                    }
                    "showIncomingCallNotification" -> {
                        try {
                            val callerOnion = call.argument<String>("callerOnion") ?: ""
                            val callerNickname = call.argument<String>("callerNickname") ?: "Peer"
                            val callId = call.argument<String>("callId") ?: ""
                            NotificationHelper.showCallNotification(appContext, callerOnion, callerNickname, callId)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("CALL_NOTIF_ERROR", e.message, null)
                        }
                    }
                    "dismissCallNotification" -> {
                        try {
                            NotificationHelper.dismissCallNotification(appContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("DISMISS_CALL_ERROR", e.message, null)
                        }
                    }
                    "playDefaultRingtone" -> {
                        try {
                            NotificationHelper.playDefaultRingtone(appContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("RINGTONE_ERROR", e.message, null)
                        }
                    }
                    "stopDefaultRingtone" -> {
                        try {
                            NotificationHelper.stopDefaultRingtone()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("RINGTONE_STOP_ERROR", e.message, null)
                        }
                    }
                    "initVoiceStream" -> {
                        try {
                            val sampleRate = call.argument<Int>("sampleRate") ?: 16000
                            val speakerphone = call.argument<Boolean>("speakerphone") ?: false
                            VoiceStreamManager.initStream(appContext, sampleRate, speakerphone)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("VOICE_INIT_ERROR", e.message, null)
                        }
                    }
                    "writeVoiceChunk" -> {
                        try {
                            val bytes = call.argument<ByteArray>("bytes")
                            VoiceStreamManager.writeChunk(bytes)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("VOICE_WRITE_ERROR", e.message, null)
                        }
                    }
                    "setSpeakerphone" -> {
                        try {
                            val enabled = call.argument<Boolean>("enabled") ?: false
                            VoiceStreamManager.setSpeakerphone(appContext, enabled)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SPEAKER_ERROR", e.message, null)
                        }
                    }
                    "stopVoiceStream" -> {
                        try {
                            VoiceStreamManager.stopStream(appContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("VOICE_STOP_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
