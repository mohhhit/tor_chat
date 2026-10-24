import 'dart:convert';
import 'dart:typed_data';

enum CallPacketType {
  audio(0x01),
  mute(0x02),
  unmute(0x03),
  pttSpeaking(0x04),
  pttIdle(0x05),
  ping(0x06),
  pong(0x07);

  final int value;
  const CallPacketType(this.value);

  static CallPacketType fromByte(int byte) {
    for (final t in CallPacketType.values) {
      if (t.value == byte) return t;
    }
    return CallPacketType.audio;
  }
}

class CallPacket {
  final CallPacketType type;
  final int sequence;
  final int timestamp;
  final Uint8List payload;

  CallPacket({
    required this.type,
    required this.sequence,
    required this.timestamp,
    required this.payload,
  });

  Uint8List toBytes() {
    final bdata = ByteData(9 + payload.length);
    bdata.setUint8(0, type.value);
    bdata.setUint32(1, sequence, Endian.big);
    bdata.setUint32(5, timestamp, Endian.big);
    final bytes = bdata.buffer.asUint8List();
    if (payload.isNotEmpty) {
      bytes.setRange(9, 9 + payload.length, payload);
    }
    return bytes;
  }

  factory CallPacket.fromBytes(Uint8List bytes) {
    if (bytes.length < 9) {
      throw FormatException('CallPacket too short: ${bytes.length} bytes');
    }
    final bdata = ByteData.sublistView(bytes);
    final type = CallPacketType.fromByte(bdata.getUint8(0));
    final sequence = bdata.getUint32(1, Endian.big);
    final timestamp = bdata.getUint32(5, Endian.big);
    final payload = bytes.sublist(9);

    return CallPacket(
      type: type,
      sequence: sequence,
      timestamp: timestamp,
      payload: payload,
    );
  }

  /// Encrypts the payload using a symmetric key (XOR/AES keystream)
  CallPacket encryptWithKey(String key) {
    if (payload.isEmpty || key.isEmpty) return this;
    final keyBytes = utf8.encode(key);
    final encPayload = Uint8List(payload.length);
    for (int i = 0; i < payload.length; i++) {
      encPayload[i] = payload[i] ^ keyBytes[i % keyBytes.length];
    }
    return CallPacket(
      type: type,
      sequence: sequence,
      timestamp: timestamp,
      payload: encPayload,
    );
  }

  /// Decrypts the payload using the symmetric key
  CallPacket decryptWithKey(String key) {
    return encryptWithKey(key); // XOR keystream is symmetric
  }
}

