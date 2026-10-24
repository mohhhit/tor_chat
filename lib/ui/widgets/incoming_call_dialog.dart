import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../main.dart';
import '../../models/call_session.dart';
import '../../providers/call_provider.dart';
import '../screens/active_call_screen.dart';
import '../theme/app_theme.dart';

class IncomingCallDialog extends StatefulWidget {
  final CallSession call;

  const IncomingCallDialog({super.key, required this.call});

  @override
  State<IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<IncomingCallDialog> {
  bool _hasAnsweredOrDeclined = false;

  void _accept() {
    if (_hasAnsweredOrDeclined) return;
    _hasAnsweredOrDeclined = true;

    context.read<CallProvider>().acceptCall();
    Navigator.of(context, rootNavigator: true).pop();
    navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const ActiveCallScreen()),
    );
  }

  void _decline() {
    if (_hasAnsweredOrDeclined) return;
    _hasAnsweredOrDeclined = true;

    context.read<CallProvider>().rejectCall();
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final currentCall = context.watch<CallProvider>().currentCall;
    if (!_hasAnsweredOrDeclined &&
        (currentCall == null || currentCall.state != CallState.incomingRinging)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_hasAnsweredOrDeclined && context.mounted && Navigator.of(context, rootNavigator: true).canPop()) {
          _hasAnsweredOrDeclined = true;
          Navigator.of(context, rootNavigator: true).pop();
        }
      });
      return const SizedBox.shrink();
    }

    final callerName = widget.call.peerNickname ?? 'Unknown Peer';
    final onionShort = widget.call.peerOnion.length > 16
        ? '${widget.call.peerOnion.substring(0, 10)}...${widget.call.peerOnion.substring(widget.call.peerOnion.length - 6)}'
        : widget.call.peerOnion;

    return Dialog(
      backgroundColor: AppTheme.surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tor Security Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.torPurple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.security, size: 14, color: AppTheme.torPurpleLight),
                  SizedBox(width: 6),
                  Text(
                    'P2P Tor Voice Call',
                    style: TextStyle(
                      color: AppTheme.torPurpleLight,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Caller Avatar
            CircleAvatar(
              radius: 40,
              backgroundColor: AppTheme.torPurple.withValues(alpha: 0.25),
              child: Text(
                callerName.isNotEmpty ? callerName[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: AppTheme.torPurpleLight,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Caller Name
            Text(
              callerName,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),

            // Onion address
            Text(
              onionShort,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 12),

            const Text(
              'Incoming call via Tor...',
              style: TextStyle(
                color: AppTheme.torPurpleLight,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 32),

            // Accept / Decline Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Decline Button
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton(
                      heroTag: 'decline_call',
                      backgroundColor: Colors.redAccent,
                      onPressed: _decline,
                      child: const Icon(Icons.call_end, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    const Text('Decline', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                  ],
                ),

                // Accept Button
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton(
                      heroTag: 'accept_call',
                      backgroundColor: Colors.green,
                      onPressed: _accept,
                      child: const Icon(Icons.call, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    const Text('Accept', style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
