import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'providers/chat_provider.dart';
import 'providers/identity_provider.dart';
import 'providers/tor_provider.dart';
import 'services/p2p/chat_coordinator.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite FFI for desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Start Tor and P2P Coordinator in background
  ChatCoordinator.instance.initialize().catchError((err) {
    debugPrint('Coordinator initialization error: $err');
  });

  runApp(const TorChatApp());
}

class TorChatApp extends StatelessWidget {
  const TorChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TorProvider()),
        ChangeNotifierProvider(create: (_) => IdentityProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
      ],
      child: MaterialApp(
        title: 'TorChat P2P',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const HomeScreen(),
      ),
    );
  }
}
