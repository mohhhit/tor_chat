import 'dart:async';
import 'package:uuid/uuid.dart';
import '../../models/contact.dart';
import '../../models/identity.dart';
import '../../models/message.dart';
import '../../models/tor_status.dart';
import '../storage/backup_service.dart';
import '../storage/database_helper.dart';
import '../tor/socks5_client.dart';
import '../tor/tor_control_client.dart';
import '../tor/tor_process_manager.dart';
import 'peer_client.dart';
import 'peer_server.dart';

class ChatCoordinator {
  static final ChatCoordinator instance = ChatCoordinator._init();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final BackupService _backup = BackupService();
  final TorProcessManager _torManager = TorProcessManager();
  final TorControlClient _torControl = TorControlClient();
  final Uuid _uuid = const Uuid();

  late Socks5Client _socks5;
  late PeerClient _peerClient;
  PeerServer? _peerServer;

  UserIdentity? _activeIdentity;
  final int _localServerPort = 8765;
  final int _socksPort = 9050;
  final int _controlPort = 9051;

  final StreamController<ChatMessage> _incomingMessageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<Map<String, dynamic>> _receiptController =
      StreamController<Map<String, dynamic>>.broadcast();

  ChatCoordinator._init() {
    _socks5 = Socks5Client(proxyHost: '127.0.0.1', proxyPort: _socksPort);
    _peerClient = PeerClient(socks5: _socks5);
  }

  TorProcessManager get torManager => _torManager;
  TorControlClient get torControl => _torControl;
  BackupService get backupService => _backup;
  UserIdentity? get activeIdentity => _activeIdentity;
  Stream<ChatMessage> get incomingMessages => _incomingMessageController.stream;
  Stream<Map<String, dynamic>> get receipts => _receiptController.stream;
  Stream<TorStatus> get torStatusStream => _torManager.statusStream;
  TorStatus get torStatus => _torManager.status;

  /// Full startup flow: launches Tor, connects Control Port, sets up Onion Service & P2P Server
  Future<void> initialize({String? customTorPath}) async {
    // 1. Load cached identity if present
    _activeIdentity = await _db.getIdentity();

    // 2. Start Tor Process
    final torStarted = await _torManager.startTor(
      customExecutablePath: customTorPath,
      socksPort: _socksPort,
      controlPort: _controlPort,
    );

    if (!torStarted) {
      return;
    }

    // 3. Connect to Tor Control Port
    try {
      await _torControl.connect();
      await _torControl.authenticate();
    } catch (e) {
      // Could not connect to control port
      return;
    }

    // 4. Register or restore Onion Service
    await _setupOnionService();

    // 5. Start incoming P2P Server
    await _startPeerServer();
  }

  Future<void> _setupOnionService() async {
    try {
      final OnionServiceResult onionRes = await _torControl.addOnion(
        virtualPort: 80,
        targetPort: _localServerPort,
        existingPrivateKey: _activeIdentity?.privateKey,
      );

      final fullAddress = onionRes.fullOnionAddress;

      if (_activeIdentity == null) {
        // First-time user: persist generated identity
        _activeIdentity = UserIdentity(
          onionAddress: fullAddress,
          privateKey: onionRes.privateKey,
          nickname: 'Anon_${fullAddress.substring(0, 6)}',
        );
        await _db.saveIdentity(_activeIdentity!);
      } else {
        // Ensure onion address matches
        _activeIdentity = _activeIdentity!.copyWith(
          onionAddress: fullAddress,
          privateKey: onionRes.privateKey.isNotEmpty ? onionRes.privateKey : _activeIdentity!.privateKey,
        );
        await _db.saveIdentity(_activeIdentity!);
      }
    } catch (e) {
      // Onion service setup error
    }
  }

  Future<void> _startPeerServer() async {
    if (_activeIdentity == null) return;

    await _peerServer?.stop();

    _peerServer = PeerServer(
      port: _localServerPort,
      myOnionAddress: _activeIdentity!.onionAddress,
      myNickname: _activeIdentity!.nickname,
    );

    _peerServer!.onMessageReceived = (msg, senderNick) async {
      // Auto-save unknown contact
      final existingContact = await _db.getContact(msg.chatOnion);
      if (existingContact == null) {
        final newContact = Contact(
          onionAddress: msg.chatOnion,
          nickname: senderNick?.isNotEmpty == true ? senderNick! : 'Peer_${msg.chatOnion.substring(0, 6)}',
          lastSeen: DateTime.now(),
          lastMessage: msg.content,
          lastMessageTimestamp: msg.timestamp,
          unreadCount: 1,
        );
        await _db.saveContact(newContact);
      } else {
        await _db.updateContactLastMessage(
          onionAddress: msg.chatOnion,
          lastMessage: msg.content,
          timestamp: msg.timestamp,
        );
        await _db.incrementUnread(msg.chatOnion);
      }

      // Save message
      await _db.insertMessage(msg);
      _incomingMessageController.add(msg);
    };

    _peerServer!.onReceiptReceived = (msgId, status) async {
      await _db.updateMessageStatus(msgId, status);
      _receiptController.add({'id': msgId, 'status': status});
    };

    await _peerServer!.start();
  }

  /// Sends a message peer-to-peer over the Tor network
  Future<ChatMessage> sendMessage({
    required String recipientOnion,
    required String content,
  }) async {
    if (_activeIdentity == null) {
      throw Exception('Identity not initialized');
    }

    final messageId = _uuid.v4();
    final now = DateTime.now();
    final cleanRecipient = recipientOnion.trim();

    final msg = ChatMessage(
      id: messageId,
      chatOnion: cleanRecipient,
      senderOnion: _activeIdentity!.onionAddress,
      recipientOnion: cleanRecipient,
      content: content,
      timestamp: now,
      isOutgoing: true,
      status: MessageStatus.sending,
    );

    // Save message locally immediately
    await _db.insertMessage(msg);
    await _db.updateContactLastMessage(
      onionAddress: cleanRecipient,
      lastMessage: content,
      timestamp: now,
    );

    // Dispatch over Tor in background
    _dispatchOutgoingMessage(msg);

    return msg;
  }

  void _dispatchOutgoingMessage(ChatMessage msg) async {
    try {
      final success = await _peerClient.sendMessage(
        peerOnion: msg.recipientOnion,
        message: msg,
        myNickname: _activeIdentity?.nickname ?? 'Anonymous',
      );

      final newStatus = success ? MessageStatus.delivered : MessageStatus.failed;
      await _db.updateMessageStatus(msg.id, newStatus);
      _receiptController.add({'id': msg.id, 'status': newStatus});
    } catch (_) {
      await _db.updateMessageStatus(msg.id, MessageStatus.failed);
      _receiptController.add({'id': msg.id, 'status': MessageStatus.failed});
    }
  }

  /// Retries sending a previously failed message
  Future<void> retryMessage(ChatMessage msg) async {
    await _db.updateMessageStatus(msg.id, MessageStatus.sending);
    _receiptController.add({'id': msg.id, 'status': MessageStatus.sending});
    _dispatchOutgoingMessage(msg);
  }

  /// Updates user profile nickname
  Future<void> updateNickname(String newNickname) async {
    if (_activeIdentity == null) return;
    _activeIdentity = _activeIdentity!.copyWith(nickname: newNickname.trim());
    await _db.saveIdentity(_activeIdentity!);
    // Update local server nickname
    await _startPeerServer();
  }

  /// Imports an identity private key and reconfigures the onion service
  Future<void> importPrivateKey(String privateKey, {String? nickname}) async {
    try {
      // 1. Add onion service using this key
      final onionRes = await _torControl.addOnion(
        virtualPort: 80,
        targetPort: _localServerPort,
        existingPrivateKey: privateKey.trim(),
      );

      final fullAddress = onionRes.fullOnionAddress;
      final newIdentity = UserIdentity(
        onionAddress: fullAddress,
        privateKey: privateKey.trim(),
        nickname: nickname?.trim().isNotEmpty == true ? nickname!.trim() : 'Restored_${fullAddress.substring(0, 6)}',
      );

      _activeIdentity = newIdentity;
      await _db.saveIdentity(newIdentity);

      // 2. Restart local server with the restored address
      await _startPeerServer();
    } catch (e) {
      throw Exception('Failed to register imported onion service key: $e');
    }
  }

  /// Restores a full backup (identity + contacts + chat history)
  Future<BackupResult> restoreFullBackup(String backupJson, {String? password}) async {
    final result = await _backup.importBackup(backupJson, password: password);
    if (result.success && result.identity != null) {
      _activeIdentity = result.identity;
      // Re-register onion service with Tor
      try {
        await _torControl.addOnion(
          virtualPort: 80,
          targetPort: _localServerPort,
          existingPrivateKey: result.identity!.privateKey,
        );
        await _startPeerServer();
      } catch (_) {}
    }
    return result;
  }

  /// Pings a peer to test onion reachability
  Future<PeerPingResult> pingPeer(String peerOnion) async {
    return await _peerClient.pingPeer(peerOnion);
  }

  /// Shuts down all components cleanly
  Future<void> dispose() async {
    await _peerServer?.stop();
    await _torControl.disconnect();
    await _torManager.stopTor();
  }
}

