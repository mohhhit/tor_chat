import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/call_session.dart';
import '../../providers/call_provider.dart';
import '../theme/app_theme.dart';

class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _autoCloseTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<CallProvider>().setCallScreenOpen(true);
    });
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    context.read<CallProvider>().setCallScreenOpen(false);
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callProvider = context.watch<CallProvider>();
    final session = callProvider.currentCall;

    if (session == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      });
      return const Scaffold(backgroundColor: AppTheme.bgDark);
    }

    if (session.hasEnded && _autoCloseTimer == null) {
      _autoCloseTimer = Timer(const Duration(milliseconds: 3500), () {
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      });
    }

    final peerName = session.peerNickname ?? 'Peer';
    final onionShort = session.peerOnion.length > 20
        ? '${session.peerOnion.substring(0, 12)}...${session.peerOnion.substring(session.peerOnion.length - 8)}'
        : session.peerOnion;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          // Minimize / back returns to chat while call stays active in background
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.bgDark,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 28),
            tooltip: 'Minimize call',
            onPressed: () => Navigator.pop(context),
          ),
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.surfaceDark,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.security, size: 14, color: AppTheme.torPurpleLight),
                const SizedBox(width: 6),
                const Text(
                  'Tor Encrypted P2P',
                  style: TextStyle(fontSize: 12, color: AppTheme.torPurpleLight),
                ),
                if (session.isActive && session.rttMs > 0) ...[
                  const SizedBox(width: 8),
                  _buildLatencyIndicator(session.rttMs),
                ],
              ],
            ),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),

              // Peer Avatar
              Center(
                child: ScaleTransition(
                  scale: (session.isPeerSpeaking || callProvider.isPttSpeaking)
                      ? _pulseAnimation
                      : const AlwaysStoppedAnimation(1.0),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: session.isPeerSpeaking
                            ? Colors.greenAccent
                            : (callProvider.isPttSpeaking
                                ? AppTheme.torPurpleLight
                                : Colors.transparent),
                        width: 3,
                      ),
                    ),
                    child: CircleAvatar(
                      radius: 54,
                      backgroundColor: AppTheme.torPurple.withValues(alpha: 0.25),
                      child: Text(
                        peerName.isNotEmpty ? peerName[0].toUpperCase() : '?',
                        style: const TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.torPurpleLight,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Peer Name & Onion
              Text(
                peerName,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                onionShort,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 12),

              // Call State / Duration
              _buildCallStatusText(session),
              const Spacer(),

              // Speaking Indicator Banner
              if (session.isActive)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildSpeakingStatusBanner(session, callProvider),
                ),

              const SizedBox(height: 24),

              // Main PTT / Audio Action Area
              if (session.isActive)
                if (session.mode == CallMode.pushToTalk)
                  _buildPttButton(callProvider)
                else
                  _buildFullDuplexVisualizer(session),

              const Spacer(),

              // Bottom Call Controls
              _buildBottomControls(context, session, callProvider),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCallStatusText(CallSession session) {
    if (session.state == CallState.checkingAvailability) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.torPurpleLight),
              ),
              SizedBox(width: 8),
              Text(
                'Calling...',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          SizedBox(height: 6),
          Text(
            'Checking peer availability over Tor...',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      );
    }
    if (session.state == CallState.outgoingRinging) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Ringing...',
            style: TextStyle(color: Colors.amberAccent, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 4),
          Text(
            'Peer device verified online & ringing',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      );
    }
    if (session.state == CallState.incomingRinging) {
      return const Text(
        'Incoming Call...',
        style: TextStyle(color: Colors.greenAccent, fontSize: 18, fontWeight: FontWeight.bold),
      );
    }
    if (session.state == CallState.connecting) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.greenAccent),
              ),
              SizedBox(width: 8),
              Text(
                'Connecting audio stream...',
                style: TextStyle(color: Colors.greenAccent, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          SizedBox(height: 4),
          Text(
            'Establishing encrypted Tor media tunnel',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
          ),
        ],
      );
    }
    if (session.isActive) {
      return Text(
        session.formattedDuration,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      );
    }
    if (session.state == CallState.unavailable) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Peer Unavailable',
            style: TextStyle(color: AppTheme.errorRed, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              session.endReason ?? 'Peer is currently offline or unreachable on Tor',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    if (session.state == CallState.rejected) {
      return const Text(
        'Call Declined',
        style: TextStyle(color: AppTheme.errorRed, fontSize: 18, fontWeight: FontWeight.bold),
      );
    }
    if (session.state == CallState.busy) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Peer Busy',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 4),
          Text(
            'Peer is currently on another call',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Call Ended',
          style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        if (session.endReason != null && session.endReason!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            session.endReason!,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildLatencyIndicator(int rttMs) {
    Color indicatorColor = Colors.green;
    if (rttMs > 1000) {
      indicatorColor = Colors.orange;
    }
    if (rttMs > 1500) {
      indicatorColor = Colors.redAccent;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: indicatorColor),
        ),
        const SizedBox(width: 4),
        Text(
          '${rttMs}ms',
          style: TextStyle(fontSize: 11, color: indicatorColor, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildSpeakingStatusBanner(CallSession session, CallProvider callProvider) {
    if (session.isPeerSpeaking) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.volume_up, size: 18, color: Colors.greenAccent),
            SizedBox(width: 8),
            Text(
              'Peer is speaking...',
              style: TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );
    }
    if (callProvider.isPttSpeaking) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.torPurple.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.torPurpleLight.withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic, size: 18, color: AppTheme.torPurpleLight),
            SizedBox(width: 8),
            Text(
              'Transmitting audio over Tor...',
              style: TextStyle(color: AppTheme.torPurpleLight, fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }
    return const SizedBox(height: 38);
  }

  /// Big tactile Push-to-Talk button
  Widget _buildPttButton(CallProvider callProvider) {
    final isTransmitting = callProvider.isPttSpeaking;
    return GestureDetector(
      onTapDown: (_) => callProvider.setPttSpeaking(true),
      onTapUp: (_) => callProvider.setPttSpeaking(false),
      onTapCancel: () => callProvider.setPttSpeaking(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: isTransmitting ? 150 : 130,
        height: isTransmitting ? 150 : 130,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: isTransmitting
                ? [AppTheme.torPurple, AppTheme.torPurpleLight]
                : [AppTheme.surfaceDark, const Color(0xFF2E3747)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: isTransmitting
                  ? AppTheme.torPurple.withValues(alpha: 0.6)
                  : Colors.black26,
              blurRadius: isTransmitting ? 28 : 12,
              spreadRadius: isTransmitting ? 4 : 0,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isTransmitting ? Icons.mic : Icons.mic_none,
              size: isTransmitting ? 48 : 42,
              color: isTransmitting ? Colors.white : AppTheme.torPurpleLight,
            ),
            const SizedBox(height: 6),
            Text(
              isTransmitting ? 'TRANSMITTING' : 'HOLD TO TALK',
              style: TextStyle(
                color: isTransmitting ? Colors.white : AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullDuplexVisualizer(CallSession session) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hearing, size: 24, color: AppTheme.torPurpleLight),
          SizedBox(width: 12),
          Text(
            'Hands-free Full-Duplex Active',
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls(
    BuildContext context,
    CallSession session,
    CallProvider callProvider,
  ) {
    if (session.hasEnded) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: SizedBox(
          width: 180,
          height: 48,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: AppTheme.cardBorder),
              ),
            ),
            icon: const Icon(Icons.close_rounded, size: 20),
            label: const Text('Dismiss', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
        ),
      );
    }

    if (!session.isActive) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: IconButton.filled(
          iconSize: 32,
          style: IconButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.all(18),
          ),
          icon: const Icon(Icons.call_end),
          tooltip: 'Cancel Call',
          onPressed: () {
            callProvider.endCall();
            Navigator.pop(context);
          },
        ),
      );
    }

    final isSpeaker = callProvider.isSpeakerphone;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute Button
          IconButton.filledTonal(
            iconSize: 26,
            style: IconButton.styleFrom(
              backgroundColor: session.isMuted
                  ? Colors.red.withValues(alpha: 0.2)
                  : AppTheme.surfaceDark,
              foregroundColor: session.isMuted ? Colors.redAccent : Colors.white,
              padding: const EdgeInsets.all(15),
            ),
            icon: Icon(session.isMuted ? Icons.mic_off : Icons.mic),
            tooltip: session.isMuted ? 'Unmute' : 'Mute',
            onPressed: callProvider.toggleMute,
          ),

          // Audio Route Button (Speakerphone on Android / Audio Device Selector on Desktop)
          if (Platform.isAndroid)
            IconButton.filledTonal(
              iconSize: 26,
              style: IconButton.styleFrom(
                backgroundColor: isSpeaker
                    ? AppTheme.torPurple.withValues(alpha: 0.3)
                    : AppTheme.surfaceDark,
                foregroundColor: isSpeaker ? AppTheme.torPurpleLight : Colors.white70,
                padding: const EdgeInsets.all(15),
              ),
              icon: Icon(isSpeaker ? Icons.volume_up : Icons.phone_in_talk),
              tooltip: isSpeaker ? 'Speakerphone ON (tap for Earpiece)' : 'Earpiece ON (tap for Speakerphone)',
              onPressed: callProvider.toggleSpeakerphone,
            )
          else
            IconButton.filledTonal(
              iconSize: 26,
              style: IconButton.styleFrom(
                backgroundColor: callProvider.selectedInputDevice != null
                    ? AppTheme.torPurple.withValues(alpha: 0.3)
                    : AppTheme.surfaceDark,
                foregroundColor: callProvider.selectedInputDevice != null
                    ? AppTheme.torPurpleLight
                    : Colors.white70,
                padding: const EdgeInsets.all(15),
              ),
              icon: const Icon(Icons.headset_mic_rounded),
              tooltip: 'Choose Microphone / Audio Device',
              onPressed: () => _showAudioDeviceDialog(context, callProvider),
            ),

          // Mode Toggle (PTT vs Hands-Free)
          IconButton.filledTonal(
            iconSize: 26,
            style: IconButton.styleFrom(
              backgroundColor: session.mode == CallMode.pushToTalk
                  ? AppTheme.torPurple.withValues(alpha: 0.25)
                  : AppTheme.surfaceDark,
              foregroundColor: session.mode == CallMode.pushToTalk
                  ? AppTheme.torPurpleLight
                  : Colors.white70,
              padding: const EdgeInsets.all(15),
            ),
            icon: Icon(session.mode == CallMode.pushToTalk ? Icons.radio : Icons.record_voice_over),
            tooltip: session.mode == CallMode.pushToTalk ? 'Switch to Hands-Free' : 'Switch to Walkie-Talkie (PTT)',
            onPressed: callProvider.toggleMode,
          ),

          // Hangup Button
          IconButton.filled(
            iconSize: 30,
            style: IconButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.all(16),
            ),
            icon: const Icon(Icons.call_end),
            tooltip: 'End Call',
            onPressed: () {
              callProvider.endCall();
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  void _showAudioDeviceDialog(BuildContext context, CallProvider callProvider) async {
    final devices = await callProvider.getInputDevices();
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final currentId = callProvider.selectedInputDevice?.id;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.headset_mic_rounded, color: AppTheme.torPurpleLight, size: 22),
                      SizedBox(width: 10),
                      Text(
                        'Choose Audio Input / Microphone',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Select which microphone or Bluetooth headset TorChat should record from.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.settings_suggest, color: Colors.white70),
                    title: const Text('System Default Device', style: TextStyle(color: Colors.white)),
                    trailing: currentId == null
                        ? const Icon(Icons.check_circle, color: AppTheme.torPurpleLight)
                        : null,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    tileColor: currentId == null ? AppTheme.torPurple.withValues(alpha: 0.15) : null,
                    onTap: () {
                      callProvider.switchInputDevice(null);
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 6),
                  ...devices.map((dev) {
                    final isSelected = dev.id == currentId;
                    final isBluetooth = dev.label.toLowerCase().contains('bluetooth') ||
                        dev.label.toLowerCase().contains('headset') ||
                        dev.label.toLowerCase().contains('buds') ||
                        dev.label.toLowerCase().contains('earphone') ||
                        dev.label.toLowerCase().contains('hands-free');

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        leading: Icon(
                          isBluetooth ? Icons.bluetooth_audio : Icons.mic,
                          color: isSelected ? AppTheme.torPurpleLight : Colors.white70,
                        ),
                        title: Text(
                          dev.label.isNotEmpty ? dev.label : 'Audio Device (${dev.id})',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle, color: AppTheme.torPurpleLight)
                            : null,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        tileColor: isSelected ? AppTheme.torPurple.withValues(alpha: 0.15) : null,
                        onTap: () {
                          callProvider.switchInputDevice(dev);
                          Navigator.pop(ctx);
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

