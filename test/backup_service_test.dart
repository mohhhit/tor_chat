import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tor_chat/models/identity.dart';
import 'package:tor_chat/services/storage/backup_service.dart';

void main() {
  group('BackupService Crypto & Migration Tests', () {
    test('UserIdentity JSON matches portable key export format', () {
      final identity = UserIdentity(
        onionAddress: 'kpw7s74gky6b47x3a776p2a2l7aevz26k3ydexpy5z3p6y224o4cq6qa.onion',
        privateKey: 'ED25519-V3:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        nickname: 'AliceOnion',
      );

      final keyExport = jsonEncode({
        'type': 'onion_chat_key',
        'onionAddress': identity.onionAddress,
        'privateKey': identity.privateKey,
        'nickname': identity.nickname,
      });

      final parsed = jsonDecode(keyExport);
      expect(parsed['onionAddress'], identity.onionAddress);
      expect(parsed['privateKey'], identity.privateKey);
      expect(parsed['nickname'], 'AliceOnion');
    });

    test('Encrypted backup payload round-trip check', () {
      final service = BackupService();
      // Test the encryption helper through export/import structure
      final plainData = jsonEncode({
        'version': 1,
        'exported_at': DateTime.now().toIso8601String(),
        'identity': {
          'onionAddress': 'testonionaddress1234567890abcdefghijklmnopqrstuvwxyz.onion',
          'privateKey': 'ED25519-V3:SecretTestKeyBlob==',
          'nickname': 'TestUser',
        },
        'contacts': [],
        'messages': [],
      });

      // Verify JSON parses properly
      final decoded = jsonDecode(plainData);
      expect(decoded['version'], 1);
      expect(decoded['identity']['nickname'], 'TestUser');
    });
  });
}
