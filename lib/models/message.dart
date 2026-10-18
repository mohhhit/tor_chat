enum MessageStatus {
  sending,
  delivered,
  failed,
  read;

  String get name => toString().split('.').last;

  static MessageStatus fromString(String value) {
    return MessageStatus.values.firstWhere(
      (e) => e.name.toLowerCase() == value.toLowerCase(),
      orElse: () => MessageStatus.sending,
    );
  }
}

class ChatMessage {
  final String id;
  final String chatOnion;
  final String senderOnion;
  final String recipientOnion;
  final String content;
  final DateTime timestamp;
  final bool isOutgoing;
  final MessageStatus status;

  ChatMessage({
    required this.id,
    required this.chatOnion,
    required this.senderOnion,
    required this.recipientOnion,
    required this.content,
    required this.timestamp,
    required this.isOutgoing,
    this.status = MessageStatus.sending,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'chat_onion': chatOnion,
        'sender_onion': senderOnion,
        'recipient_onion': recipientOnion,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'is_outgoing': isOutgoing ? 1 : 0,
        'status': status.name,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] as String,
      chatOnion: map['chat_onion'] as String,
      senderOnion: map['sender_onion'] as String,
      recipientOnion: map['recipient_onion'] as String,
      content: map['content'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
      isOutgoing: (map['is_outgoing'] as int) == 1,
      status: MessageStatus.fromString(map['status'] as String? ?? 'sending'),
    );
  }

  Map<String, dynamic> toNetworkPayload() => {
        'id': id,
        'sender': senderOnion,
        'recipient': recipientOnion,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
      };

  ChatMessage copyWith({
    String? id,
    String? chatOnion,
    String? senderOnion,
    String? recipientOnion,
    String? content,
    DateTime? timestamp,
    bool? isOutgoing,
    MessageStatus? status,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      chatOnion: chatOnion ?? this.chatOnion,
      senderOnion: senderOnion ?? this.senderOnion,
      recipientOnion: recipientOnion ?? this.recipientOnion,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      status: status ?? this.status,
    );
  }
}
