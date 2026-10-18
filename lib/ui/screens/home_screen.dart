import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/contact.dart';
import '../../providers/chat_provider.dart';
import '../../services/p2p/chat_coordinator.dart';
import '../theme/app_theme.dart';
import '../widgets/onion_status_badge.dart';
import 'add_contact_dialog.dart';
import 'chat_detail_screen.dart';
import 'identity_screen.dart';
import 'tor_settings_screen.dart';
import '../../providers/tor_provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchFilter = '';
  StreamSubscription<String>? _chatNavSub;

  @override
  void initState() {
    super.initState();
    // On fresh app start, ensure no chat is auto-opened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ChatProvider>().selectChat(null);
      }
    });

    _chatNavSub = ChatCoordinator.instance.chatSelectionRequests.listen((chatOnion) async {
      if (!mounted) return;
      final chatProvider = context.read<ChatProvider>();
      await chatProvider.loadContacts();
      final contact = chatProvider.contacts.cast<Contact?>().firstWhere(
        (c) => c != null && c.onionAddress.toLowerCase() == chatOnion.toLowerCase(),
        orElse: () => null,
      );
      if (contact != null && mounted) {
        final isWide = MediaQuery.of(context).size.width >= 750;
        if (!isWide) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatDetailScreen(contact: contact),
            ),
          ).then((_) {
            chatProvider.selectChat(null);
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _chatNavSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _openAddContact() {
    showDialog(
      context: context,
      builder: (_) => const AddContactDialog(),
    );
  }

  void _confirmDeleteContact(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: AppTheme.errorRed),
            SizedBox(width: 8),
            Text('Delete Conversation'),
          ],
        ),
        content: Text(
          'Are you sure you want to delete the conversation with "${contact.nickname}" and all of its messages? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.errorRed,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await context.read<ChatProvider>().deleteContact(contact.onionAddress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final contacts = chatProvider.contacts.where((c) {
      if (_searchFilter.isEmpty) return true;
      final q = _searchFilter.toLowerCase();
      return c.nickname.toLowerCase().contains(q) ||
          c.onionAddress.toLowerCase().contains(q);
    }).toList();

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final cp = context.read<ChatProvider>();
          if (cp.selectedContact != null) {
            cp.selectChat(null);
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            if (Platform.isAndroid) {
              try {
                const MethodChannel('com.onionchat.tor_chat/native').invokeMethod('moveToBackground');
              } catch (_) {}
            }
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 750;

              Widget contactsListWidget = Scaffold(
                appBar: AppBar(
                  titleSpacing: 16,
                  title: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.security, color: AppTheme.torPurpleLight, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'TorChat',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, letterSpacing: 0.5),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    const OnionStatusBadge(compact: true),
                    IconButton(
                      icon: const Icon(Icons.vpn_key_outlined, size: 20),
                tooltip: 'My Keys & Identity',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const IdentityScreen()),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined, size: 20),
                tooltip: 'Tor Settings & Logs',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TorSettingsScreen()),
                  );
                },
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              // Search Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) {
                    setState(() {
                      _searchFilter = val.trim();
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Search chats or onion address...',
                    prefixIcon: const Icon(Icons.search, size: 20, color: AppTheme.textSecondary),
                    suffixIcon: _searchFilter.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchFilter = '');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),

              // Android Background Activity Warning Banner
              if (Platform.isAndroid && !context.watch<TorProvider>().isBatteryIgnored)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.torPurple.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.torPurpleLight.withValues(alpha: 0.4)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.battery_alert_outlined, color: AppTheme.warningAmber, size: 22),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Allow background activity so TorChat stays online when closed.',
                            style: TextStyle(fontSize: 12, height: 1.25),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () {
                            context.read<TorProvider>().requestIgnoreBatteryOptimization();
                          },
                          child: const Text('Allow', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.torPurpleLight)),
                        ),
                      ],
                    ),
                  ),
                ),

              // Contacts List
              Expanded(
                child: contacts.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.forum_outlined, size: 54, color: AppTheme.textSecondary.withValues(alpha: 0.4)),
                              const SizedBox(height: 14),
                              const Text(
                                'No Chats Yet',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Add a peer\'s onion address to start chatting, or import your previous chats from another device.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.person_add, size: 18),
                                label: const Text('Add Peer Contact'),
                                onPressed: _openAddContact,
                              ),
                              const SizedBox(height: 10),
                              TextButton.icon(
                                icon: const Icon(Icons.unarchive_outlined, size: 18),
                                label: const Text('Import Backup / Keys'),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const IdentityScreen()),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: contacts.length,
                        separatorBuilder: (context, index) => const Divider(height: 1, indent: 72),
                        itemBuilder: (context, index) {
                          final c = contacts[index];
                          final isSelected = isWide && chatProvider.selectedContact?.onionAddress == c.onionAddress;
                          final timeStr = c.lastMessageTimestamp != null
                              ? DateFormat('HH:mm').format(c.lastMessageTimestamp!)
                              : '';

                          return ListTile(
                            selected: isSelected,
                            selectedTileColor: AppTheme.torPurple.withValues(alpha: 0.15),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor: AppTheme.torPurple,
                                  child: Text(
                                    c.nickname.isNotEmpty ? c.nickname[0].toUpperCase() : 'P',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
                                  ),
                                ),
                                if (c.isOnline)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: AppTheme.onlineGreen,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: AppTheme.background, width: 2),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c.nickname,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (timeStr.isNotEmpty)
                                  Text(
                                    timeStr,
                                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                                  ),
                              ],
                            ),
                            subtitle: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c.lastMessage ?? (c.onionAddress.length > 20
                                        ? '${c.onionAddress.substring(0, 16)}...onion'
                                        : c.onionAddress),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: c.unreadCount > 0 ? AppTheme.textPrimary : AppTheme.textSecondary,
                                      fontWeight: c.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (c.unreadCount > 0)
                                  Container(
                                    margin: const EdgeInsets.only(left: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppTheme.torPurple,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      c.unreadCount.toString(),
                                      style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ],
                            ),
                            onLongPress: () => _confirmDeleteContact(c),
                            onTap: () {
                              chatProvider.selectChat(c);
                              if (!isWide) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ChatDetailScreen(contact: c),
                                  ),
                                ).then((_) {
                                  chatProvider.selectChat(null);
                                });
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            backgroundColor: AppTheme.torPurple,
            foregroundColor: Colors.white,
            onPressed: _openAddContact,
            tooltip: 'Add Peer Contact',
            child: const Icon(Icons.add_comment_rounded),
          ),
        );

        if (!isWide) {
          return contactsListWidget;
        }

        // Desktop Two-Pane Split Layout
        return Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 380,
                child: contactsListWidget,
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: chatProvider.selectedContact != null
                    ? ChatDetailScreen(
                        key: ValueKey(chatProvider.selectedContact!.onionAddress),
                        contact: chatProvider.selectedContact!,
                      )
                    : Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  color: AppTheme.torPurple.withValues(alpha: 0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.shield_outlined, size: 48, color: AppTheme.torPurpleLight),
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                'TorChat for Windows',
                                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'Send and receive end-to-end encrypted messages over the Tor network.\nNo centralized servers, no phone numbers, complete peer-to-peer anonymity.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
                              ),
                              const SizedBox(height: 24),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.person_add, size: 18),
                                label: const Text('Add Contact'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.torPurpleLight,
                                  side: const BorderSide(color: AppTheme.torPurple),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                ),
                                onPressed: _openAddContact,
                              ),
                              const SizedBox(height: 36),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.lock_outline, size: 13, color: AppTheme.textSecondary.withValues(alpha: 0.6)),
                                  const SizedBox(width: 6),
                                  Text(
                                    'End-to-end encrypted with Onion V3 hidden services',
                                    style: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.6), fontSize: 11),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    ),
  ),
  ),
  );
}
}
