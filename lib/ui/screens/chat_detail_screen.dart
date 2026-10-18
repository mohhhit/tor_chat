import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/contact.dart';
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
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _isPinging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().selectChat(widget.contact);
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    await context.read<ChatProvider>().sendMessage(text);
    _scrollToBottom();
    _focusNode.requestFocus();
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

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final messages = chatProvider.activeMessages;
    final pingResult = chatProvider.pingCache[widget.contact.onionAddress];

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppTheme.torPurple,
              child: Text(
                widget.contact.nickname.isNotEmpty ? widget.contact.nickname[0].toUpperCase() : 'P',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.contact.nickname,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: widget.contact.onionAddress));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Onion address copied!')),
                      );
                    },
                    child: Text(
                      widget.contact.onionAddress.length > 20
                          ? '${widget.contact.onionAddress.substring(0, 16)}...onion'
                          : widget.contact.onionAddress,
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
              if (val == 'delete') {
                context.read<ChatProvider>().deleteContact(widget.contact.onionAddress);
                Navigator.pop(context);
              }
            },
            itemBuilder: (context) => [
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
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return ChatBubble(
                        message: msg,
                        onRetry: msg.status.name == 'failed'
                            ? () => chatProvider.retryMessage(msg)
                            : null,
                      );
                    },
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
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      focusNode: _focusNode,
                      maxLines: 4,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
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
    );
  }
}
