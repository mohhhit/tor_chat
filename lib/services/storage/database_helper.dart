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
        status TEXT NOT NULL
      )
    ''');

    // Index for fast query on chat_onion & timestamp
    await db.execute('''
      CREATE INDEX idx_messages_chat_onion ON messages (chat_onion, timestamp)
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

  Future<void> updateMessageStatus(String id, MessageStatus status) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<ChatMessage>> getAllMessages() async {
    final db = await database;
    final maps = await db.query('messages', orderBy: 'timestamp ASC');
    return maps.map((m) => ChatMessage.fromMap(m)).toList();
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('identity');
    await db.delete('contacts');
    await db.delete('messages');
  }
}
