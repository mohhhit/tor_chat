package com.onionchat.tor_chat

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.PowerManager
import android.util.Log

object VoiceStreamManager {
    private const val TAG = "VoiceStreamManager"
    private var audioTrack: AudioTrack? = null
    private var isSpeakerphone: Boolean = false
    private var proximityWakeLock: PowerManager.WakeLock? = null

    private fun updateProximityLock(context: Context, needProximity: Boolean) {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        if (needProximity) {
            val field = PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK
            val isSupported = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                powerManager.isWakeLockLevelSupported(field)
            } else true

            if (isSupported && proximityWakeLock == null) {
                try {
                    proximityWakeLock = powerManager.newWakeLock(field, "TorChat::ProximityScreenOff").apply {
                        setReferenceCounted(false)
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Cannot create proximity wake lock: ${e.message}")
                }
            }
            try {
                if (proximityWakeLock?.isHeld == false) {
                    proximityWakeLock?.acquire()
                    Log.d(TAG, "Proximity screen-off wake lock acquired (earpiece active)")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error acquiring proximity lock: ${e.message}")
            }
        } else {
            try {
                if (proximityWakeLock?.isHeld == true) {
                    proximityWakeLock?.release()
                    Log.d(TAG, "Proximity screen-off wake lock released")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error releasing proximity lock: ${e.message}")
            } finally {
                proximityWakeLock = null
            }
        }
    }

    @Synchronized
    fun initStream(context: Context, sampleRate: Int = 16000, speakerphoneOn: Boolean = false) {
        stopStream(context)
        isSpeakerphone = speakerphoneOn

        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioManager?.let { am ->
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            am.isSpeakerphoneOn = speakerphoneOn
        }

        // Engage proximity sensor to turn off screen when at ear in Earpiece mode
        updateProximityLock(context, !speakerphoneOn)

        val channelConfig = AudioFormat.CHANNEL_OUT_MONO
        val audioEncoding = AudioFormat.ENCODING_PCM_16BIT
        val minBufferSize = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioEncoding)
        val bufferSize = maxOf(minBufferSize * 2, 4096)

        try {
            audioTrack = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(audioEncoding)
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelConfig)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                AudioTrack(
                    AudioManager.STREAM_VOICE_CALL,
                    sampleRate,
                    channelConfig,
                    audioEncoding,
                    bufferSize,
                    AudioTrack.MODE_STREAM
                )
            }

            audioTrack?.play()
            Log.d(TAG, "AudioTrack initialized and playing (Speakerphone: $speakerphoneOn, SampleRate: $sampleRate)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize AudioTrack: ${e.message}", e)
        }
    }

    @Synchronized
    fun writeChunk(pcmBytes: ByteArray?) {
        if (pcmBytes == null || pcmBytes.isEmpty()) return
        val track = audioTrack ?: return
        try {
            if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    track.write(pcmBytes, 0, pcmBytes.size, AudioTrack.WRITE_NON_BLOCKING)
                } else {
                    track.write(pcmBytes, 0, pcmBytes.size)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error writing PCM chunk: ${e.message}")
        }
    }

    @Synchronized
    fun setSpeakerphone(context: Context, enabled: Boolean) {
        isSpeakerphone = enabled
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioManager?.let { am ->
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            am.isSpeakerphoneOn = enabled
            Log.d(TAG, "Speakerphone set to: $enabled")
        }
        // When speakerphone is ON, screen should stay on; when OFF (earpiece), proximity sensor turns screen off at ear
        updateProximityLock(context, !enabled)
    }

    @Synchronized
    fun stopStream(context: Context) {
        updateProximityLock(context, false)

        try {
            audioTrack?.let { track ->
                if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    track.stop()
                }
                track.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping AudioTrack: ${e.message}")
        } finally {
            audioTrack = null
        }

        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioManager?.let { am ->
            am.isSpeakerphoneOn = false
            am.mode = AudioManager.MODE_NORMAL
            Log.d(TAG, "AudioManager reset to MODE_NORMAL")
        }
    }
}
