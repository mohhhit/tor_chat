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

enum MessageType {
  text,
  image;

  String get name => toString().split('.').last;

  static MessageType fromString(String? value) {
    if (value == null) return MessageType.text;
    return MessageType.values.firstWhere(
      (e) => e.name.toLowerCase() == value.toLowerCase(),
      orElse: () => MessageType.text,
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
  final String? mediaPath;
  final MessageType messageType;
  final bool isDeleted;

  ChatMessage({
    required this.id,
    required this.chatOnion,
    required this.senderOnion,
    required this.recipientOnion,
    required this.content,
    required this.timestamp,
    required this.isOutgoing,
    this.status = MessageStatus.sending,
    this.mediaPath,
    this.messageType = MessageType.text,
    this.isDeleted = false,
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
        'media_path': mediaPath,
        'message_type': messageType.name,
        'is_deleted': isDeleted ? 1 : 0,
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
      mediaPath: map['media_path'] as String?,
      messageType: MessageType.fromString(map['message_type'] as String?),
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
    );
  }

  Map<String, dynamic> toNetworkPayload() => {
        'id': id,
        'sender': senderOnion,
        'recipient': recipientOnion,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'type': messageType.name,
        'is_deleted': isDeleted ? 1 : 0,
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
    String? mediaPath,
    MessageType? messageType,
    bool? isDeleted,
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
      mediaPath: mediaPath ?? this.mediaPath,
      messageType: messageType ?? this.messageType,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}

