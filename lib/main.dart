import 'dart:io';
import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/chat_provider.dart';
import 'providers/identity_provider.dart';
import 'providers/tor_provider.dart';
import 'services/p2p/chat_coordinator.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme/app_theme.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite FFI and Desktop window/tray/notification controls
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    try {
      await localNotifier.setup(
        appName: 'TorChat P2P',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    } catch (e) {
      debugPrint('LocalNotifier setup error: $e');
    }

    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1100, 750),
      minimumSize: Size(700, 500),
      center: true,
      title: 'TorChat P2P',
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      // Intercept window close button so clicking [X] minimizes to tray
      await windowManager.setPreventClose(true);
    });
  }

  // Start Tor and P2P Coordinator in background
  ChatCoordinator.instance.initialize().catchError((err) {
    debugPrint('Coordinator initialization error: $err');
  });

  runApp(const TorChatApp());
}

class TorChatApp extends StatefulWidget {
  const TorChatApp({super.key});

  @override
  State<TorChatApp> createState() => _TorChatAppState();
}

class _TorChatAppState extends State<TorChatApp> with WindowListener, TrayListener, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initSystemTray();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final isForeground = state == AppLifecycleState.resumed;
    ChatCoordinator.instance.isAppInForeground = isForeground;
    if (isForeground) {
      ChatCoordinator.instance.isWindowVisible = true;
      ChatCoordinator.instance.isWindowFocused = true;
      navigatorKey.currentContext?.read<ChatProvider>().refreshActiveChat();
      navigatorKey.currentContext?.read<TorProvider>().checkBatteryOptimization();
    }
  }

  Future<void> _initSystemTray() async {
    try {
      await trayManager.setIcon('assets/icons/app_icon.ico');
      await trayManager.setToolTip('TorChat P2P - Online & Listening');

      final Menu menu = Menu(
        items: [
          MenuItem(
            key: 'show_window',
            label: 'Open TorChat',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit_app',
            label: 'Quit TorChat',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (e) {
      debugPrint('Tray initialization error: $e');
    }
  }

  @override
  void onWindowFocus() {
    ChatCoordinator.instance.isWindowFocused = true;
    ChatCoordinator.instance.isWindowVisible = true;
    navigatorKey.currentContext?.read<ChatProvider>().refreshActiveChat();
  }

  @override
  void onWindowBlur() {
    ChatCoordinator.instance.isWindowFocused = false;
  }

  @override
  void onWindowMinimize() {
    ChatCoordinator.instance.isWindowVisible = false;
    ChatCoordinator.instance.isWindowFocused = false;
  }

  @override
  void onWindowRestore() {
    ChatCoordinator.instance.isWindowVisible = true;
    ChatCoordinator.instance.isWindowFocused = true;
    navigatorKey.currentContext?.read<ChatProvider>().refreshActiveChat();
  }

  /// When user clicks the window [X] close button, hide to tray instead of quitting
  @override
  void onWindowClose() async {
    final isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      ChatCoordinator.instance.isWindowVisible = false;
      ChatCoordinator.instance.isWindowFocused = false;
      await windowManager.hide();
    }
  }

  /// Left-click tray icon to restore and focus window
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
    ChatCoordinator.instance.isWindowVisible = true;
    ChatCoordinator.instance.isWindowFocused = true;
    navigatorKey.currentContext?.read<ChatProvider>().refreshActiveChat();
  }

  /// Right-click tray icon to show context menu
  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_window') {
      await windowManager.show();
      await windowManager.focus();
      ChatCoordinator.instance.isWindowVisible = true;
      ChatCoordinator.instance.isWindowFocused = true;
      navigatorKey.currentContext?.read<ChatProvider>().refreshActiveChat();
    } else if (menuItem.key == 'exit_app') {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TorProvider()),
        ChangeNotifierProvider(create: (_) => IdentityProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'TorChat P2P',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const HomeScreen(),
      ),
    );
  }
}
