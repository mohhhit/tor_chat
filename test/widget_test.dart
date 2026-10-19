import 'package:flutter_test/flutter_test.dart';
import 'package:tor_chat/models/contact.dart';
import 'package:tor_chat/models/identity.dart';
import 'package:tor_chat/models/message.dart';
import 'package:tor_chat/providers/chat_provider.dart';

void main() {
  group('Models & Cryptographic Key Serialization Tests', () {
    test('UserIdentity serialization and deserialization preserves ED25519-V3 keys', () {
      final identity = UserIdentity(
        onionAddress: 'expy5z3p6y224o4cq6q56bvh4nug7lcmh7x3a776p2a2l7aevz26k3yd.onion',
        privateKey: 'ED25519-V3:dGhpcyBpcyBhIHRlc3QgcHJpdmF0ZSBrZXkgYmxvYiBmb3Igb25pb24=',
        nickname: 'Alice',
      );

      final json = identity.toJson();
      expect(json['onionAddress'], identity.onionAddress);
      expect(json['privateKey'], identity.privateKey);
      expect(json['nickname'], 'Alice');

      final restored = UserIdentity.fromJson(json);
      expect(restored.onionAddress, identity.onionAddress);
      expect(restored.privateKey, identity.privateKey);
      expect(restored.nickname, identity.nickname);
    });

    test('Contact serialization and updates', () {
      final contact = Contact(
        onionAddress: 'targetpeeronionaddress1234567890abcdefghijklmnopqrstuv.onion',
        nickname: 'Bob',
        lastMessage: 'Hello over Tor!',
        unreadCount: 3,
      );

      final map = contact.toMap();
      expect(map['onion_address'], contact.onionAddress);
      expect(map['nickname'], 'Bob');
      expect(map['unread_count'], 3);

      final restored = Contact.fromMap(map);
      expect(restored.onionAddress, contact.onionAddress);
      expect(restored.nickname, 'Bob');
      expect(restored.lastMessage, 'Hello over Tor!');
      expect(restored.unreadCount, 3);
    });

    test('ChatMessage network payload and status transition', () {
      final msg = ChatMessage(
        id: 'msg-uuid-1234',
        chatOnion: 'target.onion',
        senderOnion: 'sender.onion',
        recipientOnion: 'target.onion',
        content: 'Secret P2P Message',
        timestamp: DateTime(2026, 10, 18, 12, 0, 0),
        isOutgoing: true,
        status: MessageStatus.sending,
      );

      final payload = msg.toNetworkPayload();
      expect(payload['id'], 'msg-uuid-1234');
      expect(payload['content'], 'Secret P2P Message');
      expect(payload['sender'], 'sender.onion');
      expect(payload['recipient'], 'target.onion');

      final delivered = msg.copyWith(status: MessageStatus.delivered);
      expect(delivered.status, MessageStatus.delivered);
    });

    test('ChatMessage image serialization and mediaPath preservation', () {
      final imgMsg = ChatMessage(
        id: 'img-uuid-5678',
        chatOnion: 'target.onion',
        senderOnion: 'sender.onion',
        recipientOnion: 'target.onion',
        content: 'Check this out!',
        timestamp: DateTime(2026, 10, 18, 12, 5, 0),
        isOutgoing: true,
        status: MessageStatus.sending,
        mediaPath: '/path/to/media/photo.jpg',
        messageType: MessageType.image,
      );

      final map = imgMsg.toMap();
      expect(map['media_path'], '/path/to/media/photo.jpg');
      expect(map['message_type'], 'image');

      final restored = ChatMessage.fromMap(map);
      expect(restored.mediaPath, '/path/to/media/photo.jpg');
      expect(restored.messageType, MessageType.image);
      expect(restored.content, 'Check this out!');

      final payload = imgMsg.toNetworkPayload();
      expect(payload['type'], 'image');
    });

    test('ChatMessage deletion status and payload serialization', () {
      final msg = ChatMessage(
        id: 'msg-del-9999',
        chatOnion: 'target.onion',
        senderOnion: 'sender.onion',
        recipientOnion: 'target.onion',
        content: 'Sensitive message to delete',
        timestamp: DateTime(2026, 10, 18, 12, 10, 0),
        isOutgoing: true,
        status: MessageStatus.delivered,
        isDeleted: false,
      );

      final deletedMsg = msg.copyWith(
        isDeleted: true,
        content: '',
      );

      final map = deletedMsg.toMap();
      expect(map['is_deleted'], 1);
      expect(map['content'], '');

      final restored = ChatMessage.fromMap(map);
      expect(restored.isDeleted, isTrue);
      expect(restored.content, '');

      final payload = deletedMsg.toNetworkPayload();
      expect(payload['is_deleted'], 1);
    });

    test('ChatScrollState preserves offset and latest message timestamp', () {
      final now = DateTime.now();
      const scrollState = ChatScrollState(
        offset: 450.5,
        lastMessageTimestamp: null,
      );
      expect(scrollState.offset, 450.5);
      expect(scrollState.lastMessageTimestamp, isNull);

      final withTime = ChatScrollState(
        offset: 320.0,
        lastMessageTimestamp: now,
      );
      expect(withTime.offset, 320.0);
      expect(withTime.lastMessageTimestamp, now);
    });
  });
}
