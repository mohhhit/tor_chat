import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:tor_chat/models/call_session.dart';
import 'package:tor_chat/models/call_packet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CallSession state transitions and duration', () {
    final session = CallSession(
      callId: 'call-123',
      peerOnion: 'peer123.onion',
      isOutgoing: true,
      startedAt: DateTime.now(),
    );
    expect(session.state, CallState.idle);
    expect(session.mode, CallMode.fullDuplex);
    expect(session.formattedDuration, '00:00');

    session.state = CallState.active;
    session.connectedAt =
        DateTime.now().subtract(const Duration(minutes: 2, seconds: 15));
    expect(session.isActive, isTrue);
    expect(session.formattedDuration, '02:15');
  });

  test('CallPacket serialization and symmetric encryption', () {
    final original = CallPacket(
      type: CallPacketType.audio,
      sequence: 42,
      timestamp: 12345678,
      payload: Uint8List.fromList([10, 20, 30, 40, 50]),
    );

    final rawBytes = original.toBytes();
    final parsed = CallPacket.fromBytes(rawBytes);

    expect(parsed.type, CallPacketType.audio);
    expect(parsed.sequence, 42);
    expect(parsed.timestamp, 12345678);
    expect(parsed.payload, equals([10, 20, 30, 40, 50]));

    // Test encryption round trip
    const key = 'secret_session_key_123';
    final encrypted = original.encryptWithKey(key);
    expect(encrypted.payload, isNot(equals(original.payload)));

    final decrypted = encrypted.decryptWithKey(key);
    expect(decrypted.payload, equals(original.payload));
  });

  test('CallSession and CallPacket work seamlessly', () {
    final session = CallSession(
      callId: 'call-123',
      peerOnion: 'peer123.onion',
      isOutgoing: true,
      startedAt: DateTime.now(),
    );
    expect(session.state, CallState.idle);
    expect(session.mode, CallMode.fullDuplex);
    expect(session.formattedDuration, '00:00');

    // Phase 1: Checking availability
    session.state = CallState.checkingAvailability;
    expect(session.isCheckingAvailability, isTrue);
    expect(session.hasEnded, isFalse);

    // Peer unavailable branch
    session.state = CallState.unavailable;
    session.endReason = 'Peer is offline';
    expect(session.hasEnded, isTrue);

    // Active call branch
    session.state = CallState.active;
    session.connectedAt =
        DateTime.now().subtract(const Duration(minutes: 2, seconds: 15));
    expect(session.isActive, isTrue);
    expect(session.formattedDuration, '02:15');
  });

  test('RecordConfig can be initialized with VoIP PCM settings', () {
    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    );
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    expect(config.encoder, AudioEncoder.pcm16bits);
  });
}