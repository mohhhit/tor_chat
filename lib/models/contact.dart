class Contact {
  final String onionAddress;
  final String nickname;
  final DateTime addedAt;
  final DateTime? lastSeen;
  final bool isOnline;
  final int unreadCount;
  final String? lastMessage;
  final DateTime? lastMessageTimestamp;

  Contact({
    required this.onionAddress,
    required this.nickname,
    DateTime? addedAt,
    this.lastSeen,
    this.isOnline = false,
    this.unreadCount = 0,
    this.lastMessage,
    this.lastMessageTimestamp,
  }) : addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'onion_address': onionAddress,
        'nickname': nickname,
        'added_at': addedAt.toIso8601String(),
        'last_seen': lastSeen?.toIso8601String(),
        'unread_count': unreadCount,
        'last_message': lastMessage,
        'last_message_timestamp': lastMessageTimestamp?.toIso8601String(),
      };

  factory Contact.fromMap(Map<String, dynamic> map) {
    return Contact(
      onionAddress: map['onion_address'] as String,
      nickname: map['nickname'] as String? ?? 'Contact',
      addedAt: map['added_at'] != null
          ? DateTime.tryParse(map['added_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastSeen: map['last_seen'] != null
          ? DateTime.tryParse(map['last_seen'] as String)
          : null,
      unreadCount: (map['unread_count'] as num?)?.toInt() ?? 0,
      lastMessage: map['last_message'] as String?,
      lastMessageTimestamp: map['last_message_timestamp'] != null
          ? DateTime.tryParse(map['last_message_timestamp'] as String)
          : null,
    );
  }

  Contact copyWith({
    String? onionAddress,
    String? nickname,
    DateTime? addedAt,
    DateTime? lastSeen,
    bool? isOnline,
    int? unreadCount,
    String? lastMessage,
    DateTime? lastMessageTimestamp,
  }) {
    return Contact(
      onionAddress: onionAddress ?? this.onionAddress,
      nickname: nickname ?? this.nickname,
      addedAt: addedAt ?? this.addedAt,
      lastSeen: lastSeen ?? this.lastSeen,
      isOnline: isOnline ?? this.isOnline,
      unreadCount: unreadCount ?? this.unreadCount,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTimestamp:
          lastMessageTimestamp ?? this.lastMessageTimestamp,
    );
  }
}
