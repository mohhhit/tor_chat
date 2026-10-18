import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../services/p2p/chat_coordinator.dart';
import '../services/p2p/peer_client.dart';
import '../services/storage/database_helper.dart';

class ChatProvider extends ChangeNotifier {
  final ChatCoordinator _coordinator = ChatCoordinator.instance;
  final DatabaseHelper _db = DatabaseHelper.instance;

  List<Contact> _contacts = [];
  Contact? _selectedContact;
  List<ChatMessage> _activeMessages = [];
  bool _isLoading = false;
  final Map<String, PeerPingResult> _pingCache = {};

  StreamSubscription<ChatMessage>? _incomingMsgSub;
  StreamSubscription<Map<String, dynamic>>? _receiptSub;

  ChatProvider() {
    _init();
  }

  List<Contact> get contacts => _contacts;
  Contact? get selectedContact => _selectedContact;
  List<ChatMessage> get activeMessages => _activeMessages;
  bool get isLoading => _isLoading;
  Map<String, PeerPingResult> get pingCache => _pingCache;

  void _init() {
    loadContacts();

    _incomingMsgSub = _coordinator.incomingMessages.listen((msg) async {
      // If the incoming message belongs to currently opened chat
      if (_selectedContact != null && _selectedContact!.onionAddress == msg.chatOnion) {
        _activeMessages.add(msg);
        await _db.clearUnread(msg.chatOnion);
      }
      await loadContacts();
      notifyListeners();
    });

    _receiptSub = _coordinator.receipts.listen((receipt) {
      final msgId = receipt['id'] as String;
      final status = receipt['status'] as MessageStatus;

      final index = _activeMessages.indexWhere((m) => m.id == msgId);
      if (index != -1) {
        _activeMessages[index] = _activeMessages[index].copyWith(status: status);
        notifyListeners();
      }
    });
  }

  Future<void> loadContacts() async {
    _contacts = await _db.getAllContacts();
    notifyListeners();
  }

  Future<void> selectChat(Contact? contact) async {
    _selectedContact = contact;
    if (contact != null) {
      await _db.clearUnread(contact.onionAddress);
      await loadMessages(contact.onionAddress);
      await loadContacts();
    } else {
      _activeMessages = [];
      notifyListeners();
    }
  }

  Future<void> loadMessages(String chatOnion) async {
    _isLoading = true;
    notifyListeners();
    _activeMessages = await _db.getMessagesForChat(chatOnion);
    _isLoading = false;
    notifyListeners();
  }

  Future<void> sendMessage(String content) async {
    if (_selectedContact == null || content.trim().isEmpty) return;

    final sent = await _coordinator.sendMessage(
      recipientOnion: _selectedContact!.onionAddress,
      content: content.trim(),
    );

    _activeMessages.add(sent);
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

  Future<void> deleteContact(String onionAddress) async {
    await _db.deleteContact(onionAddress);
    if (_selectedContact?.onionAddress == onionAddress) {
      _selectedContact = null;
      _activeMessages = [];
    }
    await loadContacts();
  }

  Future<PeerPingResult> pingContact(String onionAddress) async {
    final res = await _coordinator.pingPeer(onionAddress);
    _pingCache[onionAddress] = res;
    notifyListeners();
    return res;
  }

  @override
  void dispose() {
    _incomingMsgSub?.cancel();
    _receiptSub?.cancel();
    super.dispose();
  }
}
