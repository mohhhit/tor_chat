class UserIdentity {
  final String onionAddress;
  final String privateKey; // ED25519-V3:...
  final String nickname;
  final DateTime createdAt;

  UserIdentity({
    required this.onionAddress,
    required this.privateKey,
    required this.nickname,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'onionAddress': onionAddress,
        'privateKey': privateKey,
        'nickname': nickname,
        'createdAt': createdAt.toIso8601String(),
      };

  factory UserIdentity.fromJson(Map<String, dynamic> json) {
    return UserIdentity(
      onionAddress: json['onionAddress'] as String,
      privateKey: json['privateKey'] as String,
      nickname: json['nickname'] as String? ?? 'Anonymous',
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  UserIdentity copyWith({
    String? onionAddress,
    String? privateKey,
    String? nickname,
    DateTime? createdAt,
  }) {
    return UserIdentity(
      onionAddress: onionAddress ?? this.onionAddress,
      privateKey: privateKey ?? this.privateKey,
      nickname: nickname ?? this.nickname,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

