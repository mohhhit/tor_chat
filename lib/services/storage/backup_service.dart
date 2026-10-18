import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import '../../models/contact.dart';
import '../../models/identity.dart';
import '../../models/message.dart';
import 'database_helper.dart';

class BackupResult {
  final bool success;
  final String message;
  final UserIdentity? identity;
  final int restoredContacts;
  final int restoredMessages;

  BackupResult({
    required this.success,
    required this.message,
    this.identity,
    this.restoredContacts = 0,
    this.restoredMessages = 0,
  });
}

class BackupService {
  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Creates a backup JSON containing identity, all contacts, and chat history.
  /// If [password] is provided, encrypts the JSON using AES-256.
  Future<String> exportBackup({String? password}) async {
    final identity = await _db.getIdentity();
    if (identity == null) {
      throw Exception('No active identity found to export.');
    }

    final contacts = await _db.getAllContacts();
    final messages = await _db.getAllMessages();

    final payload = {
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'identity': identity.toJson(),
      'contacts': contacts.map((c) => c.toMap()).toList(),
      'messages': messages.map((m) => m.toMap()).toList(),
    };

    final rawJson = jsonEncode(payload);

    if (password != null && password.trim().isNotEmpty) {
      return _encryptData(rawJson, password.trim());
    }

    return rawJson;
  }

  /// Exports only identity key data in a portable JSON format
  Future<String> exportKeysOnly() async {
    final identity = await _db.getIdentity();
    if (identity == null) {
      throw Exception('No identity found to export.');
    }
    return jsonEncode({
      'type': 'onion_chat_key',
      'onionAddress': identity.onionAddress,
      'privateKey': identity.privateKey,
      'nickname': identity.nickname,
      'exported_at': DateTime.now().toIso8601String(),
    });
  }

  /// Restores identity and/or chats from an exported backup string or file content
  Future<BackupResult> importBackup(String backupContent, {String? password}) async {
    try {
      String jsonStr = backupContent.trim();

      // Check if encrypted
      if (password != null && password.trim().isNotEmpty) {
        try {
          jsonStr = _decryptData(jsonStr, password.trim());
        } catch (e) {
          return BackupResult(
            success: false,
            message: 'Failed to decrypt backup. Incorrect password or corrupted data.',
          );
        }
      }

      final Map<String, dynamic> data = jsonDecode(jsonStr);

      // Check if it's a key-only export or full backup
      if (data.containsKey('privateKey') && !data.containsKey('contacts')) {
        // Key-only import
        final identity = UserIdentity.fromJson(data);
        await _db.saveIdentity(identity);
        return BackupResult(
          success: true,
          message: 'Identity key successfully imported! Onion address: ${identity.onionAddress}',
          identity: identity,
        );
      }

      if (data['version'] == 1 && data.containsKey('identity')) {
        // Full backup import
        final identity = UserIdentity.fromJson(data['identity']);
        await _db.saveIdentity(identity);

        int contactCount = 0;
        if (data['contacts'] != null) {
          final contactsList = (data['contacts'] as List);
          for (final item in contactsList) {
            final contact = Contact.fromMap(item as Map<String, dynamic>);
            await _db.saveContact(contact);
            contactCount++;
          }
        }

        int messageCount = 0;
        if (data['messages'] != null) {
          final messagesList = (data['messages'] as List);
          for (final item in messagesList) {
            final msg = ChatMessage.fromMap(item as Map<String, dynamic>);
            await _db.insertMessage(msg);
            messageCount++;
          }
        }

        return BackupResult(
          success: true,
          message: 'Backup restored successfully! Restored identity, $contactCount contacts, and $messageCount messages.',
          identity: identity,
          restoredContacts: contactCount,
          restoredMessages: messageCount,
        );
      }

      return BackupResult(
        success: false,
        message: 'Invalid backup format or unsupported version.',
      );
    } catch (e) {
      return BackupResult(
        success: false,
        message: 'Error importing backup: $e',
      );
    }
  }

  /// Directly import raw private key string (e.g. "ED25519-V3:...") and derive onion address or set identity
  Future<UserIdentity> importRawPrivateKey({
    required String privateKey,
    required String onionAddress,
    String nickname = 'Restored User',
  }) async {
    final identity = UserIdentity(
      onionAddress: onionAddress.trim(),
      privateKey: privateKey.trim(),
      nickname: nickname.trim(),
    );
    await _db.saveIdentity(identity);
    return identity;
  }

  // --- Encryption Helpers ---

  String _encryptData(String plainText, String password) {
    // Derive 32-byte key using SHA-256
    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV.fromSecureRandom(16);

    final encrypted = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc)).encrypt(plainText, iv: iv);

    // Pack IV + ciphertext into base64
    final payload = {
      'encrypted': true,
      'iv': iv.base64,
      'data': encrypted.base64,
    };
    return jsonEncode(payload);
  }

  String _decryptData(String cipherPayload, String password) {
    final Map<String, dynamic> parsed = jsonDecode(cipherPayload);
    if (parsed['encrypted'] != true || parsed['iv'] == null || parsed['data'] == null) {
      throw Exception('Data is not in encrypted backup format');
    }

    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV.fromBase64(parsed['iv'] as String);

    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final decrypted = encrypter.decrypt64(parsed['data'] as String, iv: iv);
    return decrypted;
  }
}
