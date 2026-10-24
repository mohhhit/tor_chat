import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/message.dart';
import '../theme/app_theme.dart';

class ChatBubble extends StatefulWidget {
  final ChatMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onDelete;

  const ChatBubble({
    super.key,
    required this.message,
    this.onRetry,
    this.onDelete,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  bool _isHovered = false;

  void _openImageViewer(BuildContext context, String imagePath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(
              DateFormat('dd MMM yyyy, HH:mm').format(widget.message.timestamp),
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ),
          body: Center(
            child: InteractiveViewer(
              panEnabled: true,
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.file(
                File(imagePath),
                errorBuilder: (context, error, stackTrace) => const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.broken_image, size: 64, color: Colors.white54),
                    SizedBox(height: 12),
                    Text('Image file not found', style: TextStyle(color: Colors.white54)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isOut = message.isOutgoing;
    final isImage = message.messageType == MessageType.image && message.mediaPath != null;
    final isCall = message.messageType == MessageType.call;
    final timeStr = DateFormat('HH:mm').format(message.timestamp);

    // Call Log Entry in Timeline
    if (isCall && !message.isDeleted) {
      final isMissed = message.content.toLowerCase().contains('missed') ||
          message.content.toLowerCase().contains('unanswered') ||
          message.content.toLowerCase().contains('declined') ||
          message.content.toLowerCase().contains('busy');
      final callText = message.content.replaceFirst('📞 ', '');

      return Align(
        alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: widget.onDelete,
          onSecondaryTap: widget.onDelete,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            decoration: BoxDecoration(
              color: isOut ? AppTheme.torPurple.withValues(alpha: 0.6) : AppTheme.cardColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isOut ? 16 : 4),
                bottomRight: Radius.circular(isOut ? 4 : 16),
              ),
              border: Border.all(
                color: isMissed
                    ? AppTheme.errorRed.withValues(alpha: 0.4)
                    : (isOut ? AppTheme.torPurpleLight.withValues(alpha: 0.4) : AppTheme.cardBorder),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isMissed
                        ? AppTheme.errorRed.withValues(alpha: 0.15)
                        : (isOut ? AppTheme.torPurpleLight.withValues(alpha: 0.2) : AppTheme.surface),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isMissed
                        ? Icons.phone_missed_rounded
                        : (isOut ? Icons.phone_forwarded_rounded : Icons.phone_callback_rounded),
                    color: isMissed ? AppTheme.errorRed : (isOut ? Colors.white : AppTheme.onlineGreen),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        callText,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isMissed && !isOut ? AppTheme.errorRed : AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isOut ? 'Outgoing' : 'Incoming',
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                          ),
                          const SizedBox(width: 6),
                          const Text('•', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                          const SizedBox(width: 6),
                          Text(
                            timeStr,
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // WhatsApp-style Deleted Message Tombstone
    if (message.isDeleted) {
      return Align(
        alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: widget.onDelete,
          onSecondaryTap: widget.onDelete,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            decoration: BoxDecoration(
              color: isOut ? AppTheme.torPurple.withValues(alpha: 0.4) : AppTheme.cardColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isOut ? 16 : 4),
                bottomRight: Radius.circular(isOut ? 4 : 16),
              ),
              border: Border.all(
                color: isOut ? AppTheme.torPurpleLight.withValues(alpha: 0.2) : AppTheme.cardBorder,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.block_outlined,
                  size: 15,
                  color: isOut ? Colors.white60 : AppTheme.textSecondary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    isOut ? 'You deleted this message' : 'This message was deleted',
                    style: TextStyle(
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      color: isOut ? Colors.white70 : AppTheme.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 10,
                    color: isOut ? Colors.white60 : AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Align(
        alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: widget.onDelete,
          onSecondaryTap: widget.onDelete,
          child: Stack(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                decoration: BoxDecoration(
                  color: isOut ? AppTheme.torPurple : AppTheme.cardColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isOut ? 16 : 4),
                    bottomRight: Radius.circular(isOut ? 4 : 16),
                  ),
                  border: Border.all(
                    color: isOut ? AppTheme.torPurpleLight.withValues(alpha: 0.4) : AppTheme.cardBorder,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  crossAxisAlignment: isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    // Image Preview (if image message)
                    if (isImage) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: GestureDetector(
                          onTap: () => _openImageViewer(context, message.mediaPath!),
                          child: File(message.mediaPath!).existsSync()
                              ? ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 280,
                                    minWidth: 160,
                                  ),
                                  child: Image.file(
                                    File(message.mediaPath!),
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : Container(
                                  height: 120,
                                  width: 180,
                                  color: Colors.black26,
                                  child: const Center(
                                    child: Icon(Icons.broken_image, size: 36, color: Colors.white54),
                                  ),
                                ),
                        ),
                      ),
                      if (message.content.isNotEmpty) const SizedBox(height: 6),
                    ],

                    // Caption or Text Content
                    if (message.content.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          message.content,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppTheme.textPrimary,
                            height: 1.35,
                          ),
                        ),
                      ),

                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            timeStr,
                            style: TextStyle(
                              fontSize: 10,
                              color: isOut ? Colors.white70 : AppTheme.textSecondary,
                            ),
                          ),
                          if (isOut) ...[
                            const SizedBox(width: 4),
                            _buildStatusIcon(),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Desktop hover trigger menu (WhatsApp style chevron)
              if (_isHovered && widget.onDelete != null)
                Positioned(
                  top: 6,
                  right: isOut ? 20 : 20,
                  child: InkWell(
                    onTap: widget.onDelete,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.white70),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    switch (widget.message.status) {
      case MessageStatus.sending:
        // Single tick when sent / queued for delivery (WhatsApp style)
        return const Icon(Icons.check, size: 14, color: Colors.white60);
      case MessageStatus.delivered:
        // Double grey ticks when delivered to recipient's device
        return const Icon(Icons.done_all, size: 14, color: Colors.white70);
      case MessageStatus.read:
        // Double blue/cyan ticks when read by recipient (WhatsApp #34B7F1)
        return const Icon(Icons.done_all, size: 14, color: Color(0xFF34B7F1));
      case MessageStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 14, color: AppTheme.errorRed),
            if (widget.onRetry != null) ...[
              const SizedBox(width: 4),
              InkWell(
                onTap: widget.onRetry,
                child: const Text(
                  'Retry',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppTheme.errorRed,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ],
        );
    }
  }
}
