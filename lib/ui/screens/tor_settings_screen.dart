import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/tor_status.dart';
import '../../providers/tor_provider.dart';
import '../theme/app_theme.dart';

class TorSettingsScreen extends StatefulWidget {
  const TorSettingsScreen({super.key});

  @override
  State<TorSettingsScreen> createState() => _TorSettingsScreenState();
}

class _TorSettingsScreenState extends State<TorSettingsScreen> {
  final ScrollController _scrollController = ScrollController();
  final bool _autoScroll = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tor = context.watch<TorProvider>();
    final status = tor.status;

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tor Diagnostics & Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Request New Circuit (NEWNYM)',
            onPressed: () async {
              await tor.requestNewCircuit();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Sent SIGNAL NEWNYM to Tor. New circuit requested.'),
                    backgroundColor: AppTheme.torPurple,
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          status.state.label,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: status.isConnected
                                ? AppTheme.onlineGreen
                                : (status.state == TorConnectionState.bootstrapping
                                    ? AppTheme.warningAmber
                                    : AppTheme.errorRed),
                          ),
                        ),
                        Text(
                          '${status.bootstrapProgress}%',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: status.bootstrapProgress / 100,
                        minHeight: 8,
                        backgroundColor: AppTheme.cardBorder,
                        color: status.isConnected ? AppTheme.onlineGreen : AppTheme.warningAmber,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      status.bootstrapSummary,
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    ),
                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildPortInfo('SOCKS5 Port', status.socksPort.toString()),
                        _buildPortInfo('Control Port', status.controlPort.toString()),
                        _buildPortInfo('Local P2P Port', status.localServerPort.toString()),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('New Tor Circuit'),
                            onPressed: () => tor.requestNewCircuit(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.power_settings_new, size: 16),
                            label: const Text('Restart Tor Process'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.cardBorder,
                            ),
                            onPressed: () => tor.restartTor(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (Platform.isAndroid) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(
                        tor.isBatteryIgnored ? Icons.check_circle_outline : Icons.battery_alert_outlined,
                        color: tor.isBatteryIgnored ? AppTheme.onlineGreen : AppTheme.warningAmber,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tor.isBatteryIgnored ? 'Background Activity: Unrestricted' : 'Background Activity: Restricted',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              tor.isBatteryIgnored
                                  ? 'App will receive peer messages 24/7 even when closed.'
                                  : 'Allow unrestricted battery to prevent Android from killing Tor when swiped from recents.',
                              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      if (!tor.isBatteryIgnored) ...[
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.torPurple,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => tor.requestIgnoreBatteryOptimization(),
                          child: const Text('Allow'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Live Log Console Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.terminal, size: 18, color: AppTheme.torPurpleLight),
                    SizedBox(width: 8),
                    Text('Tor Log Stream', style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('Copy Logs', style: TextStyle(fontSize: 12)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: tor.logs.join('\n')));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Logs copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Log Console Body
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0C0D14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                padding: const EdgeInsets.all(12),
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: tor.logs.length,
                  itemBuilder: (context, index) {
                    final line = tor.logs[index];
                    Color logColor = const Color(0xFFC0C5D8);
                    if (line.contains('[warn]')) logColor = AppTheme.warningAmber;
                    if (line.contains('[error]') || line.contains('[err]')) logColor = AppTheme.errorRed;
                    if (line.contains('Bootstrapped 100%')) logColor = AppTheme.onlineGreen;

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText(
                        line,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: logColor,
                          height: 1.3,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortInfo(String title, String value) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
