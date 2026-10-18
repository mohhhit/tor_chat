import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';
import '../theme/app_theme.dart';

class AddContactDialog extends StatefulWidget {
  const AddContactDialog({super.key});

  @override
  State<AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<AddContactDialog> {
  final _onionController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _onionController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  void _submit() async {
    if (_formKey.currentState?.validate() != true) return;

    final onion = _onionController.text.trim();
    final nick = _nicknameController.text.trim();

    await context.read<ChatProvider>().addContact(onion, nick);
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.person_add, color: AppTheme.torPurpleLight, size: 22),
          SizedBox(width: 10),
          Text('Add Peer Contact', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the contact\'s V3 Onion Address. This creates a direct, peer-to-peer end-to-end encrypted connection.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _onionController,
                decoration: const InputDecoration(
                  labelText: 'Onion Address (.onion)',
                  hintText: 'e.g. 2gzyxa5...onion',
                  prefixIcon: Icon(Icons.link, size: 20, color: AppTheme.textSecondary),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter an onion address';
                  }
                  final clean = val.trim();
                  if (clean.length < 16) {
                    return 'Address is too short';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _nicknameController,
                decoration: const InputDecoration(
                  labelText: 'Contact Nickname',
                  hintText: 'e.g. Alice, Bob, Workspace',
                  prefixIcon: Icon(Icons.badge, size: 20, color: AppTheme.textSecondary),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please give this contact a name';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Add Contact'),
        ),
      ],
    );
  }
}

