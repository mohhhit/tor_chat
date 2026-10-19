import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../models/contact.dart';
import '../../models/message.dart';
import '../../providers/chat_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_bubble.dart';

class ChatDetailScreen extends StatefulWidget {
  final Contact contact;

  const ChatDetailScreen({super.key, required this.contact});

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final TextEditingController _textController = TextEditingController();
  late final ScrollController _scrollController;
  final FocusNode _focusNode = FocusNode();
  late ChatProvider _chatProvider;
  bool _isPinging = false;
  double _currentScrollOffset = 0.0;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    final cp = context.read<ChatProvider>();
    final saved = cp.getScrollState(widget.contact.onionAddress);

    // If new messages appeared since user last read this chat, start at 0.0 (newest messages).
    // If no new messages appeared, preserve the scroll offset where the user left off.
    final hadNewMessages = widget.contact.unreadCount > 0 ||
        (saved != null &&
            saved.lastMessageTimestamp != null &&
            widget.contact.lastMessageTimestamp != null &&
            widget.contact.lastMessageTimestamp!.isAfter(saved.lastMessageTimestamp!));

    final initialOffset = (hadNewMessages || saved == null) ? 0.0 : saved.offset;
    _currentScrollOffset = initialOffset;
    _scrollController = ScrollController(initialScrollOffset: initialOffset);

    _focusNode.onKeyEvent = (node, event) {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        if (event is KeyDownEvent) {
          final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter;
          if (isEnter) {
            if (HardwareKeyboard.instance.isShiftPressed) {
              // Shift+Enter: Insert newline at current cursor position
              final text = _textController.text;
              final selection = _textController.selection;
              final start = selection.start >= 0 ? selection.start : text.length;
              final end = selection.end >= 0 ? selection.end : text.length;
              final newText = text.replaceRange(start, end, '\n');
              _textController.value = TextEditingValue(
                text: newText,
                selection: TextSelection.collapsed(offset: start + 1),
              );
              return KeyEventResult.handled;
            } else {
              // Plain Enter: Send message on Windows
              _sendMessage();
              return KeyEventResult.handled;
            }
          }
        }
      }
      return KeyEventResult.ignored;
    };

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().selectChat(widget.contact);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chatProvider = context.read<ChatProvider>();
  }

  @override
  void dispose() {
    final lastTimestamp = _chatProvider.activeMessages.isNotEmpty
        ? _chatProvider.activeMessages.last.timestamp
        : widget.contact.lastMessageTimestamp;
    _chatProvider.saveScrollState(
      widget.contact.onionAddress,
      _currentScrollOffset,
      lastTimestamp,
    );
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    await context.read<ChatProvider>().sendMessage(text, recipientOnion: widget.contact.onionAddress);
    _scrollToBottom();
    _focusNode.requestFocus();
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Share Media',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildAttachmentOption(
                    sheetCtx: sheetCtx,
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    color: Colors.purpleAccent,
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _pickAndSendImage(ImageSource.gallery);
                    },
                  ),
                  _buildAttachmentOption(
                    sheetCtx: sheetCtx,
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    color: Colors.pinkAccent,
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _pickAndSendImage(ImageSource.camera);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentOption({
    required BuildContext sheetCtx,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      );

      if (picked != null && mounted) {
        final file = File(picked.path);
        _showImagePreviewDialog(file);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not access ${source == ImageSource.camera ? "camera" : "gallery"}: $e'),
            backgroundColor: AppTheme.errorRed,
          ),
        );
      }
    }
  }

  void _showImagePreviewDialog(File imageFile) {
    final captionController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.85,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 340),
                    child: Image.file(
                      imageFile,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: captionController,
                  autofocus: false,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    hintText: 'Add a caption... (optional)',
                    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.torPurple),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('Send'),
            onPressed: () async {
              final caption = captionController.text.trim();
              Navigator.pop(dialogCtx);
              await context.read<ChatProvider>().sendImage(imageFile.path, caption: caption, recipientOnion: widget.contact.onionAddress);
              _scrollToBottom();
            },
          ),
        ],
      ),
    );
  }

  void _pingPeer() async {
    setState(() => _isPinging = true);
    final res = await context.read<ChatProvider>().pingContact(widget.contact.onionAddress);
    setState(() => _isPinging = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            res.isOnline
                ? 'Peer is ONLINE! Latency: ${res.latency?.inMilliseconds} ms'
                : 'Peer unreachable: ${res.error ?? "Offline"}',
          ),
          backgroundColor: res.isOnline ? AppTheme.onlineGreen : AppTheme.errorRed,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _showEditNicknameDialog(Contact contact) {
    final nameController = TextEditingController(text: contact.nickname);
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.edit_note, color: AppTheme.torPurpleLight, size: 24),
            SizedBox(width: 8),
            Text('Edit Contact Name', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set a local nickname for this contact. This name is private to your device only and is never broadcast or shared with others.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Contact Name',
                hintText: 'e.g. Alice, Bob, Work',
                prefixIcon: Icon(Icons.person, color: AppTheme.textSecondary, size: 20),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                final newName = nameController.text.trim();
                if (newName.isNotEmpty) {
                  Navigator.pop(dialogCtx);
                  context.read<ChatProvider>().updateContactNickname(contact.onionAddress, newName);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.torPurple),
            onPressed: () {
              final newName = nameController.text.trim();
              if (newName.isNotEmpty) {
                Navigator.pop(dialogCtx);
                context.read<ChatProvider>().updateContactNickname(contact.onionAddress, newName);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Contact contact) async {
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
      final isWide = MediaQuery.of(context).size.width >= 750;
      await context.read<ChatProvider>().deleteContact(widget.contact.onionAddress);
      if (!isWide && mounted) {
        Navigator.maybePop(context);
      }
    }
  }

  void _showDeleteMessageDialog(ChatMessage message) {
    final canDeleteForEveryone = message.isOutgoing && !message.isDeleted;
    final canCopy = message.content.isNotEmpty && !message.isDeleted;

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          message.isDeleted ? 'Message' : 'Message Options',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        content: canDeleteForEveryone
            ? const Text(
                'Choose an action for this message.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              )
            : null,
        actionsOverflowDirection: VerticalDirection.down,
        actionsAlignment: MainAxisAlignment.end,
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        actions: [
          if (canCopy)
            TextButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18, color: Colors.white),
              label: const Text(
                'Copy text',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: message.content));
                Navigator.pop(dialogCtx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Message copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          if (canDeleteForEveryone)
            TextButton.icon(
              icon: const Icon(Icons.delete_sweep_outlined, size: 18, color: AppTheme.torPurpleLight),
              label: const Text(
                'Delete for everyone',
                style: TextStyle(
                  color: AppTheme.torPurpleLight,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              onPressed: () {
                Navigator.pop(dialogCtx);
                context.read<ChatProvider>().deleteMessageForEveryone(message);
              },
            ),
          TextButton.icon(
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white70),
            label: const Text(
              'Delete for me',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
            onPressed: () {
              Navigator.pop(dialogCtx);
              context.read<ChatProvider>().deleteMessageForMe(message);
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final contact = chatProvider.contacts.firstWhere(
      (c) => c.onionAddress.toLowerCase() == widget.contact.onionAddress.toLowerCase(),
      orElse: () => widget.contact,
    );
    final messages = chatProvider.activeMessages;
    final pingResult = chatProvider.pingCache[contact.onionAddress];

    if (messages.length != _lastMessageCount) {
      final prevCount = _lastMessageCount;
      _lastMessageCount = messages.length;
      if (prevCount > 0 && messages.length > prevCount) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients && _scrollController.offset < 120) {
            _scrollToBottom();
          }
        });
      }
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final isWide = MediaQuery.of(context).size.width >= 750;
          if (isWide) {
            context.read<ChatProvider>().selectChat(null);
          } else {
            Navigator.maybePop(context);
          }
        },
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: InkWell(
            onTap: () => _showEditNicknameDialog(contact),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: AppTheme.torPurple,
                    child: Text(
                      contact.nickname.isNotEmpty ? contact.nickname[0].toUpperCase() : 'P',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                contact.nickname,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.edit_outlined, size: 14, color: AppTheme.textSecondary),
                          ],
                        ),
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: contact.onionAddress));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Onion address copied!')),
                            );
                          },
                          child: Text(
                            contact.onionAddress.length > 20
                                ? '${contact.onionAddress.substring(0, 16)}...onion'
                                : contact.onionAddress,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            IconButton(
              icon: _isPinging
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(
                      Icons.wifi_tethering,
                      color: pingResult?.isOnline == true ? AppTheme.onlineGreen : AppTheme.textSecondary,
                    ),
              tooltip: 'Ping Peer Reachability over Tor',
              onPressed: _isPinging ? null : _pingPeer,
            ),
            PopupMenuButton<String>(
              onSelected: (val) {
                if (val == 'edit_name') {
                  _showEditNicknameDialog(contact);
                } else if (val == 'delete') {
                  _confirmDelete(contact);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'edit_name',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 18, color: AppTheme.torPurpleLight),
                      SizedBox(width: 8),
                      Text('Edit contact name'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, size: 18, color: AppTheme.errorRed),
                      SizedBox(width: 8),
                      Text('Delete Conversation', style: TextStyle(color: AppTheme.errorRed)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      body: Column(
        children: [
          // Security disclaimer header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppTheme.surface,
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 14, color: AppTheme.onlineGreen),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Direct Peer-to-Peer Onion Connection • End-to-End Encrypted via Tor V3',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Messages View
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.mark_chat_read_outlined, size: 48, color: AppTheme.textSecondary.withValues(alpha: 0.4)),
                        const SizedBox(height: 12),
                        const Text(
                          'No messages yet',
                          style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Send a message to initiate direct P2P communication.',
                          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollEndNotification) {
                        _currentScrollOffset = notification.metrics.pixels;
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[messages.length - 1 - index];
                        return ChatBubble(
                          key: ValueKey(msg.id),
                          message: msg,
                          onRetry: msg.status.name == 'failed'
                              ? () => chatProvider.retryMessage(msg)
                              : null,
                          onDelete: () => _showDeleteMessageDialog(msg),
                        );
                      },
                    ),
                  ),
          ),

          // Message Input Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: AppTheme.surface,
              border: Border(top: BorderSide(color: AppTheme.cardBorder)),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    onPressed: _showAttachmentSheet,
                    icon: const Icon(Icons.add, size: 24, color: AppTheme.torPurpleLight),
                    tooltip: 'Send Image or Take Photo',
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      focusNode: _focusNode,
                      maxLines: 5,
                      minLines: 1,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Type an encrypted message...',
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send_rounded, size: 20),
                    style: IconButton.styleFrom(
                      backgroundColor: AppTheme.torPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}
