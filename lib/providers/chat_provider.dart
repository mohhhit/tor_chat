import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../services/p2p/chat_coordinator.dart';
import '../services/p2p/peer_client.dart';
import '../services/storage/database_helper.dart';

class ChatScrollState {
  final double offset;
  final DateTime? lastMessageTimestamp;
  const ChatScrollState({required this.offset, this.lastMessageTimestamp});
}

class ChatProvider extends ChangeNotifier {
  final ChatCoordinator _coordinator = ChatCoordinator.instance;
  final DatabaseHelper _db = DatabaseHelper.instance;

  List<Contact> _contacts = [];
  Contact? _selectedContact;
  List<ChatMessage> _activeMessages = [];
  bool _isLoading = false;
  final Map<String, PeerPingResult> _pingCache = {};
  final Map<String, ChatScrollState> _scrollStates = {};

  StreamSubscription<ChatMessage>? _incomingMsgSub;
  StreamSubscription<ChatMessage>? _sentMsgSub;
  StreamSubscription<Map<String, dynamic>>? _receiptSub;
  StreamSubscription<String>? _chatSelectionSub;
  StreamSubscription<Map<String, String>>? _messageDeletedSub;

  ChatProvider() {
    _init();
  }

  List<Contact> get contacts => _contacts;
  Contact? get selectedContact => _selectedContact;
  List<ChatMessage> get activeMessages => _activeMessages;
  bool get isLoading => _isLoading;
  Map<String, PeerPingResult> get pingCache => _pingCache;

  bool _isSameOnion(String a, String b) {
    return a.trim().toLowerCase() == b.trim().toLowerCase();
  }

  void _init() {
    loadContacts();

    _incomingMsgSub = _coordinator.incomingMessages.listen((msg) async {
      final isCurrentChat = _selectedContact != null &&
          _isSameOnion(_selectedContact!.onionAddress, msg.chatOnion);

      if (isCurrentChat) {
        if (!_activeMessages.any((m) => m.id == msg.id)) {
          _activeMessages.add(msg);
        }
        await _db.clearUnread(msg.chatOnion);
      }
      await loadContacts();
      notifyListeners();
    });

    _sentMsgSub = _coordinator.sentMessages.listen((msg) async {
      final isCurrentChat = _selectedContact != null &&
          _isSameOnion(_selectedContact!.onionAddress, msg.chatOnion);

      if (isCurrentChat) {
        if (!_activeMessages.any((m) => m.id == msg.id)) {
          _activeMessages.add(msg);
        }
      }
      await loadContacts();
      notifyListeners();
    });

    _receiptSub = _coordinator.receipts.listen((receipt) {
      final msgId = receipt['id'] as String;
      final status = receipt['status'] as MessageStatus;

      final index = _activeMessages.indexWhere((m) => m.id == msgId);
      if (index != -1) {
        final current = _activeMessages[index].status;
        if (current == MessageStatus.read && status != MessageStatus.read) {
          return;
        }
        if (current == MessageStatus.delivered && status == MessageStatus.sending) {
          return;
        }
        _activeMessages[index] = _activeMessages[index].copyWith(status: status);
        notifyListeners();
      }
    });

    _chatSelectionSub = _coordinator.chatSelectionRequests.listen((chatOnion) async {
      await loadContacts();
      final contact = _contacts.cast<Contact?>().firstWhere(
        (c) => c != null && _isSameOnion(c.onionAddress, chatOnion),
        orElse: () => null,
      );
      if (contact != null) {
        await selectChat(contact);
      } else {
        final dbContact = await _db.getContact(chatOnion);
        if (dbContact != null) {
          await selectChat(dbContact);
        }
      }
    });

    _messageDeletedSub = _coordinator.messageDeletions.listen((deletion) async {
      final msgId = deletion['id'];
      final index = _activeMessages.indexWhere((m) => m.id == msgId);
      if (index != -1) {
        _activeMessages[index] = _activeMessages[index].copyWith(
          isDeleted: true,
          content: '',
          mediaPath: null,
        );
      }
      await loadContacts();
      notifyListeners();
    });
  }

  Future<void> loadContacts() async {
    _contacts = await _db.getAllContacts();
    notifyListeners();
  }

  Future<void> selectChat(Contact? contact) async {
    _selectedContact = contact;
    _coordinator.activeChatOnion = contact?.onionAddress;

    if (contact != null) {
      _coordinator.dismissNotification(contact.onionAddress);
      _coordinator.prewarmPeerConnection(contact.onionAddress);

      // Fetch unread incoming message IDs to send read receipt to peer
      final unreadIds = await _db.getUnreadIncomingMessageIds(contact.onionAddress);

      // Mark locally as read and clear unread count
      await _db.markIncomingMessagesAsRead(contact.onionAddress);
      await _db.clearUnread(contact.onionAddress);
      await loadMessages(contact.onionAddress);
      await loadContacts();

      // Dispatch read receipts to remote peer
      if (unreadIds.isNotEmpty) {
        _coordinator.sendReadReceipts(
          peerOnion: contact.onionAddress,
          messageIds: unreadIds,
        );
      }
    } else {
      _activeMessages = [];
      notifyListeners();
    }
  }

  /// Refreshes current active chat conversation and clears unread when app/window regains focus
  Future<void> refreshActiveChat() async {
    if (_selectedContact != null) {
      _coordinator.dismissNotification(_selectedContact!.onionAddress);
      await selectChat(_selectedContact);
    } else {
      await loadContacts();
    }
  }

  Future<void> loadMessages(String chatOnion) async {
    _isLoading = true;
    notifyListeners();
    _activeMessages = await _db.getMessagesForChat(chatOnion);
    _isLoading = false;
    notifyListeners();
  }

  Future<void> sendMessage(String content, {String? recipientOnion}) async {
    final recipient = recipientOnion ?? _selectedContact?.onionAddress;
    if (recipient == null || content.trim().isEmpty) return;

    final sent = await _coordinator.sendMessage(
      recipientOnion: recipient,
      content: content.trim(),
    );

    if (!_activeMessages.any((m) => m.id == sent.id)) {
      _activeMessages.add(sent);
    }
    await loadContacts();
    notifyListeners();
  }

  Future<void> sendImage(String imagePath, {String caption = '', String? recipientOnion}) async {
    final recipient = recipientOnion ?? _selectedContact?.onionAddress;
    if (recipient == null) return;

    final sent = await _coordinator.sendImageMessage(
      recipientOnion: recipient,
      originalImagePath: imagePath,
      caption: caption,
    );

    if (!_activeMessages.any((m) => m.id == sent.id)) {
      _activeMessages.add(sent);
    }
    await loadContacts();
    notifyListeners();
  }

  Future<void> retryMessage(ChatMessage msg) async {
    await _coordinator.retryMessage(msg);
  }

  Future<void> addContact(String onionAddress, String nickname) async {
    String cleanOnion = onionAddress.trim();
    if (!cleanOnion.endsWith('.onion')) {
      cleanOnion = '$cleanOnion.onion';
    }

    final newContact = Contact(
      onionAddress: cleanOnion,
      nickname: nickname.trim().isNotEmpty ? nickname.trim() : 'Peer_${cleanOnion.substring(0, 6)}',
      addedAt: DateTime.now(),
    );

    await _db.saveContact(newContact);
    await loadContacts();
    await selectChat(newContact);
  }

  Future<void> updateContactNickname(String onionAddress, String newNickname) async {
    final cleanNick = newNickname.trim();
    if (cleanNick.isEmpty) return;

    await _db.updateContactNickname(onionAddress, cleanNick);
    if (_selectedContact != null && _isSameOnion(_selectedContact!.onionAddress, onionAddress)) {
      _selectedContact = _selectedContact!.copyWith(nickname: cleanNick);
    }
    await loadContacts();
    notifyListeners();
  }

  Future<void> deleteContact(String onionAddress) async {
    await _db.deleteContact(onionAddress);
    _scrollStates.remove(onionAddress.toLowerCase());
    if (_selectedContact?.onionAddress == onionAddress) {
      _selectedContact = null;
      _coordinator.activeChatOnion = null;
      _activeMessages = [];
    }
    await loadContacts();
  }

  ChatScrollState? getScrollState(String onionAddress) {
    return _scrollStates[onionAddress.toLowerCase()];
  }

  void saveScrollState(String onionAddress, double offset, DateTime? lastTimestamp) {
    _scrollStates[onionAddress.toLowerCase()] = ChatScrollState(
      offset: offset,
      lastMessageTimestamp: lastTimestamp,
    );
  }

  Future<PeerPingResult> pingContact(String onionAddress) async {
    final res = await _coordinator.pingPeer(onionAddress);
    _pingCache[onionAddress] = res;
    notifyListeners();
    return res;
  }

  Future<void> deleteMessageForMe(ChatMessage message) async {
    await _coordinator.deleteMessageForMe(message);
    _activeMessages.removeWhere((m) => m.id == message.id);
    await loadContacts();
    notifyListeners();
  }

  Future<void> deleteMessageForEveryone(ChatMessage message) async {
    await _coordinator.deleteMessageForEveryone(message);
    final index = _activeMessages.indexWhere((m) => m.id == message.id);
    if (index != -1) {
      _activeMessages[index] = _activeMessages[index].copyWith(
        isDeleted: true,
        content: '',
        mediaPath: null,
      );
    }
    await loadContacts();
    notifyListeners();
  }

  @override
  void dispose() {
    _incomingMsgSub?.cancel();
    _sentMsgSub?.cancel();
    _receiptSub?.cancel();
    _chatSelectionSub?.cancel();
    _messageDeletedSub?.cancel();
    super.dispose();
  }
}
