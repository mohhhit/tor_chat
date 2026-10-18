import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/tor_status.dart';
import '../../providers/tor_provider.dart';
import '../screens/tor_settings_screen.dart';
import '../theme/app_theme.dart';

class OnionStatusBadge extends StatelessWidget {
  const OnionStatusBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<TorProvider>(
      builder: (context, tor, _) {
        final state = tor.status.state;
        final progress = tor.status.bootstrapProgress;

        Color dotColor;
        String label;
        Widget icon;

        switch (state) {
          case TorConnectionState.connected:
            dotColor = AppTheme.onlineGreen;
            label = 'Tor Online';
            icon = Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: dotColor.withValues(alpha: 0.6),
                    blurRadius: 6,
                    spreadRadius: 2,
                  ),
                ],
              ),
            );
            break;
          case TorConnectionState.bootstrapping:
          case TorConnectionState.starting:
            dotColor = AppTheme.warningAmber;
            label = '$progress%';
            icon = SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: progress > 0 ? progress / 100 : null,
                color: dotColor,
              ),
            );
            break;
          case TorConnectionState.error:
            dotColor = AppTheme.errorRed;
            label = 'Tor Error';
            icon = Icon(Icons.error_outline, size: 14, color: dotColor);
            break;
          case TorConnectionState.stopped:
            dotColor = Colors.grey;
            label = 'Tor Offline';
            icon = Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            );
            break;
        }

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TorSettingsScreen()),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.cardColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: dotColor.withValues(alpha: 0.4), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: dotColor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
