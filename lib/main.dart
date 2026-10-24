import 'dart:io';
import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'models/call_session.dart';
import 'providers/call_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/identity_provider.dart';
import 'providers/tor_provider.dart';
import 'services/p2p/chat_coordinator.dart';
import 'ui/screens/active_call_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/incoming_call_dialog.dart';

String _resolveAppIconPath() {
  if (Platform.isWindows) {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final packagedPath = [
        exeDir,
        'data',
        'flutter_assets',
        'assets',
        'icons',
        'app_icon.ico',
      ].join(Platform.pathSeparator);
      if (File(packagedPath).existsSync()) {
        return packagedPath;
      }
      final localDevPath = [
        Directory.current.path,
        'assets',
        'icons',
        'app_icon.ico',
      ].join(Platform.pathSeparator);
      if (File(localDevPath).existsSync()) {
        return localDevPath;
      }
    } catch (e) {
      debugPrint('Error resolving app icon path: $e');
    }
  }
  return 'assets/icons/app_icon.ico';
}

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
      final iconPath = _resolveAppIconPath();
      await windowManager.setIcon(iconPath);
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
      ChatCoordinator.instance.wakeTor();
      navigatorKey.currentContext?.read<ChatProvider>().refreshActiveChat();
      navigatorKey.currentContext?.read<TorProvider>().checkBatteryOptimization();
    }
  }

  Future<void> _initSystemTray() async {
    try {
      final iconPath = _resolveAppIconPath();
      await trayManager.setIcon(iconPath);
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
        ChangeNotifierProvider(create: (_) => CallProvider()),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'TorChat P2P',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        builder: (context, child) => CallManagerOverlay(child: child ?? const SizedBox.shrink()),
        home: const HomeScreen(),
      ),
    );
  }
}

class CallManagerOverlay extends StatefulWidget {
  final Widget child;
  const CallManagerOverlay({super.key, required this.child});

  @override
  State<CallManagerOverlay> createState() => _CallManagerOverlayState();
}

class _CallManagerOverlayState extends State<CallManagerOverlay> {
  bool _isShowingIncomingDialog = false;

  @override
  Widget build(BuildContext context) {
    final callProvider = context.watch<CallProvider>();
    final call = callProvider.currentCall;

    if (call != null &&
        call.state == CallState.incomingRinging &&
        !_isShowingIncomingDialog) {
      _isShowingIncomingDialog = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          try {
            await windowManager.show();
            await windowManager.focus();
          } catch (_) {}
        }

        final navState = navigatorKey.currentState;
        if (navState != null && navState.mounted) {
          await showDialog(
            context: navState.context,
            barrierDismissible: false,
            builder: (_) => IncomingCallDialog(call: call),
          );
        }
        _isShowingIncomingDialog = false;
      });
    }

    final showCallBanner = call != null &&
        !call.hasEnded &&
        call.state != CallState.incomingRinging &&
        !callProvider.isCallScreenOpen;

    return Stack(
      children: [
        widget.child,
        if (showCallBanner)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            right: 16,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  navigatorKey.currentState?.push(
                    MaterialPageRoute(builder: (_) => const ActiveCallScreen()),
                  );
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceDark,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.torPurpleLight, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: call.isActive
                              ? AppTheme.onlineGreen.withValues(alpha: 0.2)
                              : AppTheme.torPurple.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          call.isActive ? Icons.phone_in_talk : Icons.phone_forwarded,
                          color: call.isActive ? AppTheme.onlineGreen : AppTheme.torPurpleLight,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              call.peerNickname ?? 'Tor Voice Call',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.white,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              call.isActive
                                  ? 'Tap to return • ${call.formattedDuration}'
                                  : (call.state == CallState.connecting
                                      ? 'Connecting Tor circuits...'
                                      : 'Calling...'),
                              style: TextStyle(
                                fontSize: 11,
                                color: call.isActive ? AppTheme.onlineGreen : AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.call_end, color: Colors.redAccent, size: 20),
                        tooltip: 'End Call',
                        onPressed: () {
                          callProvider.endCall();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
