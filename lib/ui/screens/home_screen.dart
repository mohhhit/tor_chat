import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/onion_status_badge.dart';
import 'add_contact_dialog.dart';
import 'chat_detail_screen.dart';
import 'identity_screen.dart';
import 'tor_settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchFilter = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openAddContact() {
    showDialog(
      context: context,
      builder: (_) => const AddContactDialog(),
    );
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 750;

        Widget contactsListWidget = Scaffold(
          appBar: AppBar(
            title: const Row(
              children: [
                Icon(Icons.security, color: AppTheme.torPurpleLight, size: 24),
                SizedBox(width: 10),
                Text('TorChat P2P', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5)),
              ],
            ),
            actions: [
              const OnionStatusBadge(),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.vpn_key_outlined),
                tooltip: 'My Keys & Identity',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const IdentityScreen()),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Tor Settings & Logs',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TorSettingsScreen()),
                  );
                },
              ),
              const SizedBox(width: 8),
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
                            onTap: () {
                              if (isWide) {
                                chatProvider.selectChat(c);
                              } else {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ChatDetailScreen(contact: c),
                                  ),
                                );
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
                width: 360,
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
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.shield_outlined, size: 72, color: AppTheme.textSecondary.withValues(alpha: 0.3)),
                            const SizedBox(height: 16),
                            const Text(
                              'Select a conversation to start chatting',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'All communications are routed directly over the decentralized Tor network.',
                              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                            ),
                            const SizedBox(height: 24),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.person_add, size: 18),
                              label: const Text('Add Contact'),
                              onPressed: _openAddContact,
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
