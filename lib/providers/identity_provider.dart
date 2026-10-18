import 'package:flutter/foundation.dart';
import '../models/identity.dart';
import '../services/p2p/chat_coordinator.dart';
import '../services/storage/backup_service.dart';

class IdentityProvider extends ChangeNotifier {
  final ChatCoordinator _coordinator = ChatCoordinator.instance;
  bool _isLoading = false;
  String? _errorMessage;

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  UserIdentity? get identity => _coordinator.activeIdentity;
  String? get onionAddress => _coordinator.activeIdentity?.onionAddress;
  String get nickname => _coordinator.activeIdentity?.nickname ?? 'Anonymous';
  String? get privateKey => _coordinator.activeIdentity?.privateKey;

  void refresh() {
    notifyListeners();
  }

  Future<void> updateNickname(String newNickname) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _coordinator.updateNickname(newNickname);
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<String> exportKeys() async {
    return await _coordinator.backupService.exportKeysOnly();
  }

  Future<String> exportFullBackup({String? password}) async {
    return await _coordinator.backupService.exportBackup(password: password);
  }

  Future<BackupResult> importPrivateKey(String key, {String? nickname}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _coordinator.importPrivateKey(key, nickname: nickname);
      return BackupResult(
        success: true,
        message: 'Key successfully imported! Onion address updated.',
        identity: _coordinator.activeIdentity,
      );
    } catch (e) {
      _errorMessage = e.toString();
      return BackupResult(success: false, message: e.toString());
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<BackupResult> importBackup(String backupJson, {String? password}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final res = await _coordinator.restoreFullBackup(backupJson, password: password);
      return res;
    } catch (e) {
      _errorMessage = e.toString();
      return BackupResult(success: false, message: e.toString());
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

