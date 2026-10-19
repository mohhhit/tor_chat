import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';
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
  final StreamController<String> _chatSelectionController =
      StreamController<String>.broadcast();
  final StreamController<Map<String, String>> _messageDeletedController =
      StreamController<Map<String, String>>.broadcast();

  ChatCoordinator._init() {
    _socks5 = Socks5Client(proxyHost: '127.0.0.1', proxyPort: _socksPort);
    _peerClient = PeerClient(socks5: _socks5);
  }

  TorProcessManager get torManager => _torManager;
  TorControlClient get torControl => _torControl;
  BackupService get backupService => _backup;
  UserIdentity? get activeIdentity => _activeIdentity;
  Stream<ChatMessage> get incomingMessages => _incomingMessageController.stream;
  final _sentMessageController = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get sentMessages => _sentMessageController.stream;
  Stream<Map<String, dynamic>> get receipts => _receiptController.stream;
  Stream<String> get chatSelectionRequests => _chatSelectionController.stream;
  final _resetToInboxController = StreamController<void>.broadcast();
  Stream<void> get resetToInboxRequests => _resetToInboxController.stream;
  Stream<Map<String, String>> get messageDeletions => _messageDeletedController.stream;
  Stream<TorStatus> get torStatusStream => _torManager.statusStream;
  TorStatus get torStatus => _torManager.status;
  final Map<String, LocalNotification> _activeWindowsNotifications = {};

  String? activeChatOnion;
  bool isAppInForeground = true;
  bool isWindowVisible = true;
  bool isWindowFocused = true;

  /// Determines if the user is actively viewing this specific chat right now on screen
  bool isViewingChat(String chatOnion) {
    if (activeChatOnion == null) return false;
    if (activeChatOnion!.trim().toLowerCase() != chatOnion.trim().toLowerCase()) return false;
    if (!isAppInForeground) return false;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (!isWindowVisible || !isWindowFocused) return false;
    }
    return true;
  }

  void requestSelectChat(String chatOnion) => _chatSelectionController.add(chatOnion);

  /// Queues and dispatches read receipts to the peer for one or more message IDs with SQLite persistence
  Future<void> sendReadReceipts({
    required String peerOnion,
    required List<String> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    await _db.addPendingReadReceipts(peerOnion, messageIds);
    _processOutbox(targetPeer: peerOnion);
  }

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
      _torManager.addExternalLog('[notice] Connected and authenticated with Tor Control Port');
    } catch (e) {
      _torManager.addExternalLog('[warn] Tor Control Port connection: $e');
    }

    // 4. Register or restore Onion Service
    await _setupOnionService();

    // 5. Start incoming P2P Server
    await _startPeerServer();

    // 6. Start Outbox background retry worker
    _startOutboxWorker();

    // 7. Listen for Android native notifications click and reset to inbox
    if (Platform.isAndroid) {
      const MethodChannel('com.onionchat.tor_chat/native').setMethodCallHandler((call) async {
        if (call.method == 'onSelectChat') {
          final chatOnion = call.arguments as String?;
          if (chatOnion != null && chatOnion.isNotEmpty) {
            _chatSelectionController.add(chatOnion);
          }
        } else if (call.method == 'onResetToInbox') {
          _resetToInboxController.add(null);
        } else if (call.method == 'onNotificationReply') {
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args != null) {
            final chatOnion = args['chatOnion'] as String?;
            final content = args['content'] as String?;
            if (chatOnion != null && content != null && content.trim().isNotEmpty) {
              await sendMessage(
                recipientOnion: chatOnion,
                content: content.trim(),
              );
            }
          }
        }
      });
    }
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
      _torManager.addExternalLog('[notice] Onion service registered: $fullAddress');
    } catch (e) {
      if (e.toString().contains('550') || e.toString().contains('collision')) {
        _torManager.addExternalLog('[notice] Onion service already active on Tor daemon.');
      } else {
        _torManager.addExternalLog('[error] Failed to register Onion Service: $e');
      }
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
      final isCurrentlyViewingChat = isViewingChat(msg.chatOnion);

      final initialStatus = isCurrentlyViewingChat ? MessageStatus.read : MessageStatus.delivered;
      final msgToSave = msg.copyWith(status: initialStatus);

      final summaryText = msg.isDeleted
          ? (msg.isOutgoing ? '🚫 You deleted this message' : '🚫 This message was deleted')
          : (msg.messageType == MessageType.image
              ? (msg.content.isNotEmpty ? '📷 ${msg.content}' : '📷 Photo')
              : msg.content);

      // Auto-save unknown contact
      final existingContact = await _db.getContact(msg.chatOnion);
      if (existingContact == null) {
        final newContact = Contact(
          onionAddress: msg.chatOnion,
          nickname: senderNick?.isNotEmpty == true ? senderNick! : 'Peer_${msg.chatOnion.substring(0, 6)}',
          lastSeen: DateTime.now(),
          lastMessage: summaryText,
          lastMessageTimestamp: msg.timestamp,
          unreadCount: isCurrentlyViewingChat ? 0 : 1,
        );
        await _db.saveContact(newContact);
      } else {
        await _db.updateContactLastMessage(
          onionAddress: msg.chatOnion,
          lastMessage: summaryText,
          timestamp: msg.timestamp,
        );
        if (!isCurrentlyViewingChat) {
          await _db.incrementUnread(msg.chatOnion);
        }
      }

      // Save message
      await _db.insertMessage(msgToSave);
      _incomingMessageController.add(msgToSave);

      // Local display name: ALWAYS prioritize the user's custom saved contact nickname!
      final displayName = existingContact?.nickname ??
          (senderNick?.isNotEmpty == true ? senderNick! : 'Peer (${msg.chatOnion.substring(0, 8)}...)');

      // Only trigger system notifications if the user is NOT actively viewing this chat!
      if (!isCurrentlyViewingChat) {
        if (Platform.isAndroid) {
          try {
            const MethodChannel('com.onionchat.tor_chat/native').invokeMethod(
              'showIncomingNotification',
              {
                'sender': displayName,
                'content': summaryText,
                'chatOnion': msg.chatOnion,
              },
            );
          } catch (_) {}
        } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          try {
            final cleanOnion = msg.chatOnion.trim().toLowerCase();
            final oldNotification = _activeWindowsNotifications[cleanOnion];
            if (oldNotification != null) {
              try {
                await oldNotification.close();
              } catch (_) {}
            }

            final notification = LocalNotification(
              identifier: 'chat_$cleanOnion',
              title: displayName,
              body: summaryText,
              actions: [
                LocalNotificationAction(text: 'Reply'),
              ],
            );
            notification.onClick = () async {
              await windowManager.show();
              await windowManager.focus();
              isWindowVisible = true;
              isWindowFocused = true;
              _chatSelectionController.add(msg.chatOnion);
            };
            notification.onClickAction = (actionIndex) async {
              await windowManager.show();
              await windowManager.focus();
              isWindowVisible = true;
              isWindowFocused = true;
              _chatSelectionController.add(msg.chatOnion);
            };
            _activeWindowsNotifications[cleanOnion] = notification;
            await notification.show();
          } catch (e) {
            _torManager.addExternalLog('[warn] Desktop notification error: $e');
          }
        }
      }

      // Pre-warm return circuit and flush queued outgoing messages
      _peerClient.prewarmPeer(msg.senderOnion);
      _processOutbox(targetPeer: msg.senderOnion);

      return initialStatus;
    };

    _peerServer!.onReceiptReceived = (msgId, status) async {
      final updated = await _db.updateMessageStatus(msgId, status);
      if (updated) {
        _receiptController.add({'id': msgId, 'status': status});
      }
    };

    _peerServer!.onMessageDeleted = (msgId, senderOnion) async {
      await _db.markMessageDeletedForEveryone(msgId);
      _messageDeletedController.add({'id': msgId, 'chatOnion': senderOnion});
      _torManager.addExternalLog('[notice] Peer $senderOnion deleted message $msgId for everyone');
    };

    await _peerServer!.start();
  }

  Timer? _outboxTimer;
  bool _isProcessingOutbox = false;
  final Set<String?> _pendingOutboxTargets = {};

  void _startOutboxWorker() {
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _processOutbox();
    });
    // Run immediately on launch
    _processOutbox();
  }

  /// Pre-warms the Tor connection to the selected peer in the background
  void prewarmPeerConnection(String peerOnion) {
    _peerClient.prewarmPeer(peerOnion);
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

    // Trigger Outbox processing immediately
    _processOutbox(targetPeer: cleanRecipient);
    _sentMessageController.add(msg);

    return msg;
  }

  /// Persistent media directory for sent/received photos
  Future<Directory> getMediaDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final mediaDir = Directory(p.join(docsDir.path, 'tor_chat', 'media'));
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    return mediaDir;
  }

  /// Sends a photo peer-to-peer over the Tor network
  Future<ChatMessage> sendImageMessage({
    required String recipientOnion,
    required String originalImagePath,
    String caption = '',
  }) async {
    if (_activeIdentity == null) {
      throw Exception('Identity not initialized');
    }

    final messageId = _uuid.v4();
    final now = DateTime.now();
    final cleanRecipient = recipientOnion.trim();

    // Copy to persistent local media directory
    final mediaDir = await getMediaDirectory();
    final localCopy = File(p.join(mediaDir.path, '$messageId.jpg'));
    await File(originalImagePath).copy(localCopy.path);

    final summaryText = caption.trim().isNotEmpty ? '📷 ${caption.trim()}' : '📷 Photo';

    final msg = ChatMessage(
      id: messageId,
      chatOnion: cleanRecipient,
      senderOnion: _activeIdentity!.onionAddress,
      recipientOnion: cleanRecipient,
      content: caption.trim(),
      timestamp: now,
      isOutgoing: true,
      status: MessageStatus.sending,
      mediaPath: localCopy.path,
      messageType: MessageType.image,
    );

    // Save message locally immediately
    await _db.insertMessage(msg);
    await _db.updateContactLastMessage(
      onionAddress: cleanRecipient,
      lastMessage: summaryText,
      timestamp: now,
    );

    // Trigger Outbox processing immediately
    _processOutbox(targetPeer: cleanRecipient);
    _sentMessageController.add(msg);

    return msg;
  }

  /// Cancels and removes the active notification for this chat
  void dismissNotification(String chatOnion) {
    final cleanOnion = chatOnion.trim().toLowerCase();
    if (Platform.isAndroid) {
      try {
        const MethodChannel('com.onionchat.tor_chat/native').invokeMethod(
          'dismissNotification',
          {'chatOnion': cleanOnion},
        );
      } catch (_) {}
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final old = _activeWindowsNotifications.remove(cleanOnion);
      if (old != null) {
        try {
          old.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _processOutbox({String? targetPeer}) async {
    _pendingOutboxTargets.add(targetPeer);
    if (_isProcessingOutbox) {
      return;
    }
    _isProcessingOutbox = true;

    try {
      while (_pendingOutboxTargets.isNotEmpty) {
        final targets = Set<String?>.from(_pendingOutboxTargets);
        _pendingOutboxTargets.clear();

        if (targets.contains(null)) {
          await _processPendingOutgoingMessages();
          await _processPendingReceipts();
          await _processPendingDeletes();
        } else {
          for (final peer in targets) {
            if (peer != null) {
              await _processPendingOutgoingMessages(targetPeer: peer);
              await _processPendingReceipts(targetPeer: peer);
              await _processPendingDeletes(targetPeer: peer);
            }
          }
        }
      }
    } finally {
      _isProcessingOutbox = false;
    }
  }

  Future<void> _processPendingOutgoingMessages({String? targetPeer}) async {
    try {
      final pending = await _db.getPendingOutgoingMessages();
      if (pending.isEmpty) return;

      final Map<String, List<ChatMessage>> byPeer = {};
      for (final msg in pending) {
        if (targetPeer != null && msg.recipientOnion != targetPeer) continue;
        byPeer.putIfAbsent(msg.recipientOnion, () => []).add(msg);
      }

      if (byPeer.isEmpty) return;

      for (final entry in byPeer.entries) {
        final peerOnion = entry.key;
        final messages = entry.value;

        // If peer onion address is invalid, mark as failed permanently
        if (!peerOnion.endsWith('.onion') || peerOnion.length < 20) {
          for (final msg in messages) {
            await _db.updateMessageStatus(msg.id, MessageStatus.failed);
            _receiptController.add({'id': msg.id, 'status': MessageStatus.failed});
          }
          continue;
        }

        for (final msg in messages) {
          try {
            _torManager.addExternalLog('[notice] Outbox sending ${msg.id.substring(0, 8)} to $peerOnion...');
            final confirmedStatus = await _peerClient.sendMessage(
              peerOnion: peerOnion,
              message: msg,
              myNickname: _activeIdentity?.nickname ?? 'Anonymous',
              timeout: const Duration(seconds: 30),
            );

            final updated = await _db.updateMessageStatus(msg.id, confirmedStatus);
            if (updated) {
              _receiptController.add({'id': msg.id, 'status': confirmedStatus});
            }
            _torManager.addExternalLog('[notice] Message ${msg.id.substring(0, 8)} confirmed: ${confirmedStatus.name}!');
          } catch (e) {
            _torManager.addExternalLog('[notice] Peer $peerOnion unreachable ($e). Kept in queue for infinite auto-retry.');
            _socks5.invalidatePeer(peerOnion);
            // Do not mark failed; keep in sending so background worker retries infinitely
            break;
          }
        }
      }
    } catch (e) {
      _torManager.addExternalLog('[warn] Outbox error: $e');
    }
  }

  Future<void> _processPendingReceipts({String? targetPeer}) async {
    try {
      final pendingReceipts = await _db.getPendingReadReceipts();
      if (pendingReceipts.isEmpty) return;

      for (final entry in pendingReceipts.entries) {
        final peerOnion = entry.key;
        final ids = entry.value;
        if (targetPeer != null && peerOnion != targetPeer) continue;
        if (ids.isEmpty) continue;

        try {
          final ok = await _peerClient.sendReceipt(
            peerOnion: peerOnion,
            messageIds: ids,
            status: MessageStatus.read,
            timeout: const Duration(seconds: 25),
          );
          if (ok) {
            await _db.removePendingReadReceipts(ids);
            _torManager.addExternalLog('[notice] Delivered ${ids.length} read receipts to $peerOnion');
          } else {
            _socks5.invalidatePeer(peerOnion);
          }
        } catch (_) {
          _socks5.invalidatePeer(peerOnion);
        }
      }
    } catch (_) {}
  }

  Future<void> _processPendingDeletes({String? targetPeer}) async {
    if (_activeIdentity == null) return;
    try {
      final pending = await _db.getPendingDeletes();
      if (pending.isEmpty) return;

      for (final entry in pending.entries) {
        final peerOnion = entry.key;
        final ids = entry.value;
        if (targetPeer != null && peerOnion != targetPeer) continue;
        if (ids.isEmpty) continue;

        for (final msgId in ids) {
          try {
            final ok = await _peerClient.sendDeleteMessage(
              peerOnion: peerOnion,
              messageId: msgId,
              myOnion: _activeIdentity!.onionAddress,
              timeout: const Duration(seconds: 25),
            );
            if (ok) {
              await _db.removePendingDelete(msgId);
              _torManager.addExternalLog('[notice] Delivered queued delete for $msgId to $peerOnion');
            } else {
              _socks5.invalidatePeer(peerOnion);
            }
          } catch (_) {
            _socks5.invalidatePeer(peerOnion);
          }
        }
      }
    } catch (_) {}
  }

  /// Deletes a message locally for the active user only (WhatsApp "Delete for me")
  Future<void> deleteMessageForMe(ChatMessage message) async {
    await _db.deleteMessageForMe(message.id);
  }

  /// Deletes a message for both sender and recipient (WhatsApp "Delete for everyone")
  Future<void> deleteMessageForEveryone(ChatMessage message) async {
    if (_activeIdentity == null) return;

    // 1. Mark as deleted locally
    await _db.markMessageDeletedForEveryone(message.id);
    _messageDeletedController.add({'id': message.id, 'chatOnion': message.chatOnion});

    // 2. Queue in pending_deletes for persistent guaranteed delivery
    await _db.addPendingDelete(message.recipientOnion, message.id);

    // 3. Trigger Outbox worker immediately
    _processOutbox(targetPeer: message.recipientOnion);
  }

  /// Retries sending a previously failed message
  Future<void> retryMessage(ChatMessage msg) async {
    await _db.updateMessageStatus(msg.id, MessageStatus.sending);
    _receiptController.add({'id': msg.id, 'status': MessageStatus.sending});
    _processOutbox(targetPeer: msg.recipientOnion);
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

  /// Checks if battery optimizations are ignored on Android
  Future<bool> isBatteryOptimizationIgnored() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await const MethodChannel('com.onionchat.tor_chat/native')
          .invokeMethod<bool>('isBatteryOptimizationIgnored');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Requests the system dialog to ignore battery optimizations on Android
  Future<void> requestIgnoreBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel('com.onionchat.tor_chat/native')
          .invokeMethod('requestIgnoreBatteryOptimization');
    } catch (_) {}
  }

  /// Shuts down all components cleanly
  Future<void> dispose() async {
    await _peerServer?.stop();
    await _torControl.disconnect();
    await _torManager.stopTor();
    await _incomingMessageController.close();
    await _receiptController.close();
    await _chatSelectionController.close();
    await _messageDeletedController.close();
  }
}

