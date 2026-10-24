import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

class CallAudioService {
  static const MethodChannel _nativeChannel = MethodChannel('com.onionchat.tor_chat/native');

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _ringtonePlayer = AudioPlayer();
  final AudioPlayer _voicePlayer = AudioPlayer();

  bool _isRecording = false;
  bool _isMuted = false;
  bool _isSpeakerphone = false;
  InputDevice? _selectedInputDevice;

  bool get isRecording => _isRecording;
  bool get isMuted => _isMuted;
  bool get isSpeakerphone => _isSpeakerphone;
  InputDevice? get selectedInputDevice => _selectedInputDevice;

  void setMuted(bool muted) {
    _isMuted = muted;
  }

  Future<void> setSpeakerphone(bool enabled) async {
    _isSpeakerphone = enabled;
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('setSpeakerphone', {'enabled': enabled});
      } catch (e) {
        debugPrint('Error setting native speakerphone: $e');
      }
    }
  }

  Future<List<InputDevice>> getInputDevices() async {
    try {
      return await _recorder.listInputDevices();
    } catch (e) {
      debugPrint('Error listing input devices: $e');
      return [];
    }
  }

  Future<void> setInputDevice(InputDevice? device) async {
    _selectedInputDevice = device;
  }

  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return true; // Desktop platforms usually don't throw permission prompts
    }
  }

  /// Initializes hardware voice stream (AudioTrack on Android with Earpiece/Speakerphone routing)
  Future<void> initVoiceStream() async {
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('initVoiceStream', {
          'sampleRate': 16000,
          'speakerphone': _isSpeakerphone,
        });
      } catch (e) {
        debugPrint('Error initializing native Android voice stream: $e');
      }
    }
  }

  /// Stops hardware voice stream
  Future<void> stopVoiceStream() async {
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('stopVoiceStream');
      } catch (e) {
        debugPrint('Error stopping native Android voice stream: $e');
      }
    }
    try {
      await _voicePlayer.stop();
    } catch (_) {}
  }

  /// Starts streaming raw microphone input (16kHz, mono, PCM 16-bit)
  Future<Stream<Uint8List>> startMicrophoneStream() async {
    if (_isRecording) {
      await stopMicrophoneStream();
    }

    final hasPerm = await hasPermission();
    if (!hasPerm) {
      throw Exception('Microphone permission denied');
    }

    final config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      device: _selectedInputDevice,
      echoCancel: true,
      autoGain: true,
      noiseSuppress: true,
    );

    final stream = await _recorder.startStream(config);
    _isRecording = true;

    // Filter silent/zero chunks if muted
    return stream.map((chunk) {
      if (_isMuted) {
        return Uint8List(chunk.length);
      }
      return chunk;
    });
  }

  /// Stops streaming microphone input
  Future<void> stopMicrophoneStream() async {
    if (!_isRecording) return;
    try {
      await _recorder.stop();
    } catch (_) {}
    _isRecording = false;
  }

  /// Plays a received raw audio chunk (PCM/WAV)
  Future<void> playAudioChunk(Uint8List rawPcmBytes) async {
    try {
      if (rawPcmBytes.isEmpty) return;

      if (Platform.isAndroid) {
        // Direct zero-latency hardware AudioTrack on Android
        await _nativeChannel.invokeMethod('writeVoiceChunk', {'bytes': rawPcmBytes});
      } else {
        // Wrap raw 16kHz 16-bit mono PCM into standard WAV header for immediate playback on Desktop
        final wavBytes = _wrapPcmInWav(rawPcmBytes, sampleRate: 16000, channels: 1);
        await _voicePlayer.play(BytesSource(wavBytes));
      }
    } catch (e) {
      debugPrint('Error playing voice chunk: $e');
    }
  }

  /// Starts playing outgoing ringback tone (beep... beep...)
  Future<void> startOutgoingRingtone() async {
    try {
      await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
      final wav = _generateToneWav(frequency: 440, durationSeconds: 1.5, silenceSeconds: 2.0);
      await _ringtonePlayer.play(BytesSource(wav));
    } catch (e) {
      debugPrint('Outgoing ringtone error: $e');
    }
  }

  /// Starts playing incoming call ringtone
  Future<void> startIncomingRingtone() async {
    try {
      await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
      final wav = _generateDualToneWav(f1: 520, f2: 660, durationSeconds: 1.2, silenceSeconds: 1.5);
      await _ringtonePlayer.play(BytesSource(wav));
    } catch (e) {
      debugPrint('Incoming ringtone error: $e');
    }
  }

  /// Stops all ringing sounds
  Future<void> stopRingtones() async {
    try {
      await _ringtonePlayer.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stopMicrophoneStream();
    await stopVoiceStream();
    await stopRingtones();
    await _ringtonePlayer.dispose();
    await _voicePlayer.dispose();
    await _recorder.dispose();
  }

  /// Generates a simple synthetic sine wave WAV in memory (for ringback)
  static Uint8List _generateToneWav({
    required double frequency,
    required double durationSeconds,
    required double silenceSeconds,
    int sampleRate = 8000,
  }) {
    final toneSamples = (durationSeconds * sampleRate).toInt();
    final silenceSamples = (silenceSeconds * sampleRate).toInt();
    final totalSamples = toneSamples + silenceSamples;
    final pcm = Int16List(totalSamples);

    for (int i = 0; i < toneSamples; i++) {
      final t = i / sampleRate;
      final val = (sin(2 * pi * frequency * t) * 8000).toInt();
      pcm[i] = val;
    }
    // silenceSamples are 0 by default

    final byteData = pcm.buffer.asUint8List();
    return _wrapPcmInWav(byteData, sampleRate: sampleRate, channels: 1);
  }

  /// Generates dual-tone chime WAV in memory (for incoming ringtone)
  static Uint8List _generateDualToneWav({
    required double f1,
    required double f2,
    required double durationSeconds,
    required double silenceSeconds,
    int sampleRate = 8000,
  }) {
    final toneSamples = (durationSeconds * sampleRate).toInt();
    final silenceSamples = (silenceSeconds * sampleRate).toInt();
    final totalSamples = toneSamples + silenceSamples;
    final pcm = Int16List(totalSamples);

    for (int i = 0; i < toneSamples; i++) {
      final t = i / sampleRate;
      final v1 = sin(2 * pi * f1 * t);
      final v2 = sin(2 * pi * f2 * t);
      final val = ((v1 + v2) * 5000).toInt();
      pcm[i] = val;
    }

    final byteData = pcm.buffer.asUint8List();
    return _wrapPcmInWav(byteData, sampleRate: sampleRate, channels: 1);
  }

  /// Wraps raw 16-bit PCM bytes with a standard 44-byte RIFF/WAV header
  static Uint8List _wrapPcmInWav(
    Uint8List pcmBytes, {
    required int sampleRate,
    required int channels,
  }) {
    const headerSize = 44;
    final totalDataLen = pcmBytes.length;
    final totalAudioLen = totalDataLen + headerSize - 8;
    final byteRate = sampleRate * channels * 2;

    final header = ByteData(headerSize);
    // RIFF chunk
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, totalAudioLen, Endian.little);
    header.setUint8(8, 0x57);  // 'W'
    header.setUint8(9, 0x41);  // 'A'
    header.setUint8(10, 0x56); // 'V'
    header.setUint8(11, 0x45); // 'E'

    // fmt subchunk
    header.setUint8(12, 0x66); // 'f'
    header.setUint8(13, 0x6D); // 'm'
    header.setUint8(14, 0x74); // 't'
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little); // SubChunk1Size (16 for PCM)
    header.setUint16(20, 1, Endian.little);  // AudioFormat (1 = PCM)
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, channels * 2, Endian.little); // BlockAlign
    header.setUint16(34, 16, Endian.little); // BitsPerSample (16)

    // data subchunk
    header.setUint8(36, 0x64); // 'd'
    header.setUint8(37, 0x61); // 'a'
    header.setUint8(38, 0x74); // 't'
    header.setUint8(39, 0x61); // 'a'
    header.setUint32(40, totalDataLen, Endian.little);

    final wav = Uint8List(headerSize + totalDataLen);
    wav.setRange(0, headerSize, header.buffer.asUint8List());
    wav.setRange(headerSize, headerSize + totalDataLen, pcmBytes);
    return wav;
  }
}
