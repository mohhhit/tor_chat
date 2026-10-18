import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../models/contact.dart';
import '../../models/identity.dart';
import '../../models/message.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('tor_chat_vault.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    // If desktop (Windows, Linux, macOS), use sqflite_common_ffi
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbFolder = await getApplicationDocumentsDirectory();
    final path = p.join(dbFolder.path, 'tor_chat', filePath);

    final dir = Directory(p.dirname(path));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS pending_receipts (
            message_id TEXT PRIMARY KEY,
            peer_onion TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS pending_deletes (
            message_id TEXT PRIMARY KEY,
            peer_onion TEXT NOT NULL
          )
        ''');
        try {
          await db.execute('ALTER TABLE messages ADD COLUMN media_path TEXT');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE messages ADD COLUMN message_type TEXT DEFAULT "text"');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE messages ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
        } catch (_) {}
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Identity table
    await db.execute('''
      CREATE TABLE identity (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        onion_address TEXT NOT NULL,
        private_key TEXT NOT NULL,
        nickname TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // Contacts table
    await db.execute('''
      CREATE TABLE contacts (
        onion_address TEXT PRIMARY KEY,
        nickname TEXT NOT NULL,
        added_at TEXT NOT NULL,
        last_seen TEXT,
        unread_count INTEGER NOT NULL DEFAULT 0,
        last_message TEXT,
        last_message_timestamp TEXT
      )
    ''');

    // Messages table
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_onion TEXT NOT NULL,
        sender_onion TEXT NOT NULL,
        recipient_onion TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        is_outgoing INTEGER NOT NULL,
        status TEXT NOT NULL,
        media_path TEXT,
        message_type TEXT NOT NULL DEFAULT 'text',
        is_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Index for fast query on chat_onion & timestamp
    await db.execute('''
      CREATE INDEX idx_messages_chat_onion ON messages (chat_onion, timestamp)
    ''');

    // Pending read receipts queue
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_receipts (
        message_id TEXT PRIMARY KEY,
        peer_onion TEXT NOT NULL
      )
    ''');

    // Pending deletes queue
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_deletes (
        message_id TEXT PRIMARY KEY,
        peer_onion TEXT NOT NULL
      )
    ''');
  }

  // --- Identity Operations ---

  Future<UserIdentity?> getIdentity() async {
    final db = await database;
    final maps = await db.query('identity', where: 'id = 1');
    if (maps.isNotEmpty) {
      final m = maps.first;
      return UserIdentity(
        onionAddress: m['onion_address'] as String,
        privateKey: m['private_key'] as String,
        nickname: m['nickname'] as String,
        createdAt: DateTime.parse(m['created_at'] as String),
      );
    }
    return null;
  }

  Future<void> saveIdentity(UserIdentity identity) async {
    final db = await database;
    await db.insert(
      'identity',
      {
        'id': 1,
        'onion_address': identity.onionAddress,
        'private_key': identity.privateKey,
        'nickname': identity.nickname,
        'created_at': identity.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteIdentity() async {
    final db = await database;
    await db.delete('identity', where: 'id = 1');
  }

  // --- Contact Operations ---

  Future<List<Contact>> getAllContacts() async {
    final db = await database;
    final maps = await db.query('contacts', orderBy: 'last_message_timestamp DESC, added_at DESC');
    return maps.map((m) => Contact.fromMap(m)).toList();
  }

  Future<Contact?> getContact(String onionAddress) async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'onion_address = ?',
      whereArgs: [onionAddress],
    );
    if (maps.isNotEmpty) {
      return Contact.fromMap(maps.first);
    }
    return null;
  }

  Future<void> saveContact(Contact contact) async {
    final db = await database;
    await db.insert(
      'contacts',
      contact.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateContactLastMessage({
    required String onionAddress,
    required String lastMessage,
    required DateTime timestamp,
  }) async {
    final db = await database;
    await db.update(
      'contacts',
      {
        'last_message': lastMessage,
        'last_message_timestamp': timestamp.toIso8601String(),
      },
      where: 'onion_address = ?',
      whereArgs: [onionAddress],
    );
  }

  Future<void> incrementUnread(String onionAddress) async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE contacts
      SET unread_count = unread_count + 1
      WHERE onion_address = ?
    ''', [onionAddress]);
  }

  Future<void> clearUnread(String onionAddress) async {
    final db = await database;
    await db.update(
      'contacts',
      {'unread_count': 0},
      where: 'onion_address = ?',
      whereArgs: [onionAddress],
    );
  }

  Future<void> deleteContact(String onionAddress) async {
    final db = await database;
    await db.delete(
      'contacts',
      where: 'onion_address = ?',
      whereArgs: [onionAddress],
    );
    await db.delete(
      'messages',
      where: 'chat_onion = ?',
      whereArgs: [onionAddress],
    );
    await db.delete(
      'pending_receipts',
      where: 'peer_onion = ?',
      whereArgs: [onionAddress],
    );
    await db.delete(
      'pending_deletes',
      where: 'peer_onion = ?',
      whereArgs: [onionAddress],
    );
  }

  // --- Message Operations ---

  Future<List<ChatMessage>> getMessagesForChat(String chatOnion) async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'chat_onion = ?',
      whereArgs: [chatOnion],
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => ChatMessage.fromMap(m)).toList();
  }

  Future<void> insertMessage(ChatMessage message) async {
    final db = await database;
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Updates message status forward-only (sending -> delivered -> read).
  /// Returns true if status was updated, false if demotion was blocked.
  Future<bool> updateMessageStatus(String id, MessageStatus newStatus) async {
    final db = await database;
    final existing = await db.query(
      'messages',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (existing.isNotEmpty) {
      final currentStatusStr = existing.first['status'] as String?;
      final currentStatus = MessageStatus.values.firstWhere(
        (e) => e.name == currentStatusStr,
        orElse: () => MessageStatus.sending,
      );

      // Status progression: sending -> delivered -> read. Never downgrade.
      if (currentStatus == MessageStatus.read && newStatus != MessageStatus.read) {
        return false;
      }
      if (currentStatus == MessageStatus.delivered && newStatus == MessageStatus.sending) {
        return false;
      }
    }
    await db.update(
      'messages',
      {'status': newStatus.name},
      where: 'id = ?',
      whereArgs: [id],
    );
    return true;
  }

  // --- Pending Receipts Operations ---

  Future<void> addPendingReadReceipts(String peerOnion, List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in messageIds) {
      batch.insert(
        'pending_receipts',
        {'message_id': id, 'peer_onion': peerOnion.trim()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Map<String, List<String>>> getPendingReadReceipts() async {
    final db = await database;
    final maps = await db.query('pending_receipts');
    final Map<String, List<String>> result = {};
    for (final row in maps) {
      final peer = row['peer_onion'] as String;
      final msgId = row['message_id'] as String;
      result.putIfAbsent(peer, () => []).add(msgId);
    }
    return result;
  }

  Future<void> removePendingReadReceipts(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in messageIds) {
      batch.delete(
        'pending_receipts',
        where: 'message_id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<ChatMessage>> getPendingOutgoingMessages() async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'is_outgoing = 1 AND status = ?',
      whereArgs: [MessageStatus.sending.name],
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => ChatMessage.fromMap(m)).toList();
  }

  Future<void> resetFailedMessagesToSending(String chatOnion) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': MessageStatus.sending.name},
      where: 'chat_onion = ? AND is_outgoing = 1 AND status = ?',
      whereArgs: [chatOnion, MessageStatus.failed.name],
    );
  }

  Future<void> markIncomingMessagesAsRead(String chatOnion) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': MessageStatus.read.name},
      where: 'chat_onion = ? AND is_outgoing = 0 AND status != ?',
      whereArgs: [chatOnion, MessageStatus.read.name],
    );
  }

  Future<List<String>> getUnreadIncomingMessageIds(String chatOnion) async {
    final db = await database;
    final maps = await db.query(
      'messages',
      columns: ['id'],
      where: 'chat_onion = ? AND is_outgoing = 0 AND status != ?',
      whereArgs: [chatOnion, MessageStatus.read.name],
    );
    return maps.map((m) => m['id'] as String).toList();
  }

  Future<List<ChatMessage>> getAllMessages() async {
    final db = await database;
    final maps = await db.query('messages', orderBy: 'timestamp ASC');
    return maps.map((m) => ChatMessage.fromMap(m)).toList();
  }

  // --- Message Deletion Operations (WhatsApp Style) ---

  Future<void> deleteMessageForMe(String id) async {
    final db = await database;
    final maps = await db.query('messages', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return;
    final msg = ChatMessage.fromMap(maps.first);

    // Delete local media file if present
    if (msg.mediaPath != null) {
      try {
        final f = File(msg.mediaPath!);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }

    // Delete message record
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
    await db.delete('pending_receipts', where: 'message_id = ?', whereArgs: [id]);
    await db.delete('pending_deletes', where: 'message_id = ?', whereArgs: [id]);

    // Recalculate contact's last message summary from remaining history
    await updateContactLastMessageFromHistory(msg.chatOnion);
  }

  Future<void> markMessageDeletedForEveryone(String id) async {
    final db = await database;
    final maps = await db.query('messages', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return;
    final msg = ChatMessage.fromMap(maps.first);

    // Delete local media file if present
    if (msg.mediaPath != null) {
      try {
        final f = File(msg.mediaPath!);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }

    // Mark as deleted, clear content and media_path
    await db.update(
      'messages',
      {
        'is_deleted': 1,
        'content': '',
        'media_path': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    // Recalculate contact's last message summary
    await updateContactLastMessageFromHistory(msg.chatOnion);
  }

  Future<void> updateContactLastMessageFromHistory(String chatOnion) async {
    final db = await database;
    final latest = await db.query(
      'messages',
      where: 'chat_onion = ?',
      whereArgs: [chatOnion],
      orderBy: 'timestamp DESC',
      limit: 1,
    );

    if (latest.isEmpty) {
      await db.update(
        'contacts',
        {
          'last_message': null,
          'last_message_timestamp': null,
        },
        where: 'onion_address = ?',
        whereArgs: [chatOnion],
      );
    } else {
      final lastMsg = ChatMessage.fromMap(latest.first);
      String summary;
      if (lastMsg.isDeleted) {
        summary = lastMsg.isOutgoing ? '🚫 You deleted this message' : '🚫 This message was deleted';
      } else if (lastMsg.messageType == MessageType.image) {
        summary = lastMsg.content.isNotEmpty ? '📷 ${lastMsg.content}' : '📷 Photo';
      } else {
        summary = lastMsg.content;
      }

      await db.update(
        'contacts',
        {
          'last_message': summary,
          'last_message_timestamp': lastMsg.timestamp.toIso8601String(),
        },
        where: 'onion_address = ?',
        whereArgs: [chatOnion],
      );
    }
  }

  // --- Pending Deletes Operations ---

  Future<void> addPendingDelete(String peerOnion, String messageId) async {
    final db = await database;
    await db.insert(
      'pending_deletes',
      {'message_id': messageId, 'peer_onion': peerOnion.trim()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, List<String>>> getPendingDeletes() async {
    final db = await database;
    final maps = await db.query('pending_deletes');
    final Map<String, List<String>> result = {};
    for (final row in maps) {
      final peer = row['peer_onion'] as String;
      final msgId = row['message_id'] as String;
      result.putIfAbsent(peer, () => []).add(msgId);
    }
    return result;
  }

  Future<void> removePendingDelete(String messageId) async {
    final db = await database;
    await db.delete(
      'pending_deletes',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('identity');
    await db.delete('contacts');
    await db.delete('messages');
    await db.delete('pending_receipts');
    await db.delete('pending_deletes');
  }
}
