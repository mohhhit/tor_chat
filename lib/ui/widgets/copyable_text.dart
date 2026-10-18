import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

class CopyableText extends StatefulWidget {
  final String label;
  final String text;
  final bool isSensitive;
  final int maxLines;

  const CopyableText({
    super.key,
    required this.label,
    required this.text,
    this.isSensitive = false,
    this.maxLines = 1,
  });

  @override
  State<CopyableText> createState() => _CopyableTextState();
}

class _CopyableTextState extends State<CopyableText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final displayText = widget.isSensitive && !_revealed
        ? '••••••••••••••••••••••••••••••••••••••••'
        : widget.text;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Row(
                children: [
                  if (widget.isSensitive)
                    IconButton(
                      icon: Icon(
                        _revealed ? Icons.visibility_off : Icons.visibility,
                        size: 16,
                        color: AppTheme.textSecondary,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: _revealed ? 'Hide' : 'Reveal',
                      onPressed: () {
                        setState(() {
                          _revealed = !_revealed;
                        });
                      },
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16, color: AppTheme.torPurpleLight),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Copy to clipboard',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${widget.label} copied to clipboard!'),
                          duration: const Duration(seconds: 2),
                          backgroundColor: AppTheme.torPurple,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            displayText,
            maxLines: widget.maxLines,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppTheme.textPrimary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
