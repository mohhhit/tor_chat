import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../providers/chat_provider.dart';
import '../../providers/identity_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/copyable_text.dart';

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final _nicknameController = TextEditingController();

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  void _showEditNicknameDialog(BuildContext context, String currentNick) {
    _nicknameController.text = currentNick;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Nickname'),
        content: TextField(
          controller: _nicknameController,
          decoration: const InputDecoration(labelText: 'Nickname'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = _nicknameController.text.trim();
              if (newName.isNotEmpty) {
                context.read<IdentityProvider>().updateNickname(newName);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _exportFullBackupDialog(BuildContext context) {
    final passwordCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.archive, color: AppTheme.torPurpleLight),
            SizedBox(width: 8),
            Text('Export Full Backup'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This exports your Onion Private Key, all your contacts, and unlimited chat history. You can restore this file on any new device.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Encryption Password (Optional)',
                hintText: 'Leave empty for unencrypted backup',
                prefixIcon: Icon(Icons.lock, size: 20),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final pwd = passwordCtrl.text.trim();
              final backupData = await context.read<IdentityProvider>().exportFullBackup(
                    password: pwd.isNotEmpty ? pwd : null,
                  );

              final uri = await FilePicker.saveFile(
                dialogTitle: 'Save TorChat Backup',
                fileName: 'torchat_backup_${DateTime.now().millisecondsSinceEpoch}.json',
                bytes: utf8.encode(backupData),
              );

              if (uri != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Backup saved successfully to: ${uri.path}'),
                    backgroundColor: AppTheme.onlineGreen,
                  ),
                );
              }
            },
            child: const Text('Save Backup File'),
          ),
        ],
      ),
    );
  }

  void _importKeyDialog(BuildContext context) {
    final keyCtrl = TextEditingController();
    final nickCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.vpn_key, color: AppTheme.torPurpleLight),
            SizedBox(width: 8),
            Text('Import Identity Key'),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste your ED25519-V3 private key from a previous device to restore your onion address.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: keyCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Private Key',
                  hintText: 'ED25519-V3:...',
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nickCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nickname (Optional)',
                  hintText: 'e.g. MyRestoredIdentity',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final key = keyCtrl.text.trim();
              if (key.isEmpty) return;
              Navigator.pop(ctx);

              final res = await context.read<IdentityProvider>().importPrivateKey(
                    key,
                    nickname: nickCtrl.text.trim(),
                  );

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(res.message),
                    backgroundColor: res.success ? AppTheme.onlineGreen : AppTheme.errorRed,
                  ),
                );
              }
            },
            child: const Text('Import & Activate Key'),
          ),
        ],
      ),
    );
  }

  void _restoreFullBackupDialog(BuildContext context) {
    final passwordCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.unarchive, color: AppTheme.torPurpleLight),
            SizedBox(width: 8),
            Text('Restore Full Backup'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select a backup file (.json) exported from your previous device to restore your identity, contacts, and chat history.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password (if backup was encrypted)',
                prefixIcon: Icon(Icons.lock, size: 20),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final files = await FilePicker.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['json', 'txt'],
              );

              if (files.isNotEmpty) {
                final file = files.first;
                final bytes = await file.readAsBytes();
                final content = utf8.decode(bytes);

                if (context.mounted) {
                  final pwd = passwordCtrl.text.trim();
                  final idProvider = context.read<IdentityProvider>();
                  final chatProvider = context.read<ChatProvider>();
                  final messenger = ScaffoldMessenger.of(context);

                  final res = await idProvider.importBackup(
                    content,
                    password: pwd.isNotEmpty ? pwd : null,
                  );

                  await chatProvider.loadContacts();
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(res.message),
                      backgroundColor: res.success ? AppTheme.onlineGreen : AppTheme.errorRed,
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              }
            },
            child: const Text('Select Backup File'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final idProvider = context.watch<IdentityProvider>();
    final onionAddress = idProvider.onionAddress ?? 'Generating Onion Address...';
    final privateKey = idProvider.privateKey ?? 'Generating Key...';
    final nickname = idProvider.nickname;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Identity & Keys'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Identity Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 28,
                              backgroundColor: AppTheme.torPurple,
                              child: Text(
                                nickname.isNotEmpty ? nickname[0].toUpperCase() : 'A',
                                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        nickname,
                                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(Icons.edit, size: 16, color: AppTheme.textSecondary),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        tooltip: 'Edit nickname',
                                        onPressed: () => _showEditNicknameDialog(context, nickname),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'P2P Onion Identity (V3 Hidden Service)',
                                    style: TextStyle(fontSize: 12, color: AppTheme.onlineGreen),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        // QR Code
                        if (idProvider.onionAddress != null)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: QrImageView(
                              data: idProvider.onionAddress!,
                              version: QrVersions.auto,
                              size: 160.0,
                              backgroundColor: Colors.white,
                            ),
                          ),
                        const SizedBox(height: 20),
                        CopyableText(
                          label: 'Your Onion Address',
                          text: onionAddress,
                          maxLines: 2,
                        ),
                        const SizedBox(height: 12),
                        CopyableText(
                          label: 'Secret Private Key (ED25519-V3)',
                          text: privateKey,
                          isSensitive: true,
                          maxLines: 2,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Key Export & Backup Section
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.cloud_upload_outlined, color: AppTheme.torPurpleLight),
                            SizedBox(width: 8),
                            Text('Export & Migration', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Move to a new device or keep a secure backup of your keys, contacts, and unlimited chats.',
                          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.key, size: 18),
                                label: const Text('Export Keys Only'),
                                onPressed: () async {
                                  final keyData = await idProvider.exportKeys();
                                  Clipboard.setData(ClipboardData(text: keyData));
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Identity key JSON copied to clipboard!'),
                                        backgroundColor: AppTheme.torPurple,
                                      ),
                                    );
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.archive, size: 18),
                                label: const Text('Export Full Backup'),
                                onPressed: () => _exportFullBackupDialog(context),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Key Import & Chat Restore Section
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.cloud_download_outlined, color: AppTheme.torPurpleLight),
                            SizedBox(width: 8),
                            Text('Import & Restore', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Restore your identity key or previous chat history from an export file or key string.',
                          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.vpn_key_outlined, size: 18),
                                label: const Text('Import Private Key'),
                                onPressed: () => _importKeyDialog(context),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.unarchive, size: 18),
                                label: const Text('Restore Full Backup'),
                                onPressed: () => _restoreFullBackupDialog(context),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
