package com.onionchat.tor_chat

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

object TorEngineHolder {
    const val ENGINE_ID = "tor_chat_engine"
    @Volatile
    private var engine: FlutterEngine? = null

    @Synchronized
    fun getOrCreateEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        var currentEngine = cache.get(ENGINE_ID) ?: engine
        if (currentEngine == null) {
            val appContext = context.applicationContext
            currentEngine = FlutterEngine(appContext)

            // Register all Flutter plugins (sqflite, path_provider, etc.)
            try {
                GeneratedPluginRegistrant.registerWith(currentEngine)
            } catch (_: Exception) {}

            // Setup native platform channel handlers
            MainActivity.setupNativeChannel(currentEngine, appContext)

            // Execute the default Dart entrypoint (main())
            currentEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )

            cache.put(ENGINE_ID, currentEngine)
            engine = currentEngine
        }
        return currentEngine
    }

    fun getEngine(): FlutterEngine? = engine ?: FlutterEngineCache.getInstance().get(ENGINE_ID)
}

