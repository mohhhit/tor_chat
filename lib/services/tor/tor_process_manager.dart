import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/tor_status.dart';

class TorProcessManager {
  static const MethodChannel _nativeChannel = MethodChannel('com.onionchat.tor_chat/native');

  Process? _torProcess;
  TorStatus _status = const TorStatus();
  final StreamController<TorStatus> _statusController = StreamController<TorStatus>.broadcast();
  final StreamController<String> _logController = StreamController<String>.broadcast();
  final List<String> _recentLogs = [];
  Completer<bool>? _bootstrapCompleter;

  TorStatus get status => _status;
  Stream<TorStatus> get statusStream => _statusController.stream;
  Stream<String> get logStream => _logController.stream;
  List<String> get logs => List.unmodifiable(_recentLogs);
  bool get isRunning => _torProcess != null;

  void _updateStatus(TorStatus newStatus) {
    _status = newStatus;
    _statusController.add(_status);
  }

  void _addLog(String line) {
    line = line.trim();
    if (line.isEmpty) return;
    _recentLogs.add(line);
    if (_recentLogs.length > 300) {
      _recentLogs.removeAt(0);
    }
    _logController.add(line);

    // Parse bootstrap progress
    // Example: [notice] Bootstrapped 80% (conn_or): Connecting to the Tor network
    final match = RegExp(r'Bootstrapped\s+(\d+)%\s*\((.*?)\):\s*(.*)').firstMatch(line);
    if (match != null) {
      final progress = int.tryParse(match.group(1)!) ?? 0;
      final phase = match.group(2) ?? '';
      final summary = match.group(3) ?? '';

      final isDone = progress >= 100;
      _updateStatus(_status.copyWith(
        state: isDone ? TorConnectionState.connected : TorConnectionState.bootstrapping,
        bootstrapProgress: progress,
        bootstrapSummary: summary.isNotEmpty ? summary : phase,
      ));

      if (isDone && _bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
        _bootstrapCompleter!.complete(true);
      }
    }
  }

  /// Finds the tor executable cross-platform
  Future<String?> findTorExecutable({String? customPath}) async {
    if (customPath != null && customPath.isNotEmpty) {
      final file = File(customPath);
      if (await file.exists()) return file.path;
    }

    // 1. On Android, check native library directory for libtor.so
    if (Platform.isAndroid) {
      try {
        final String? nativePath = await _nativeChannel.invokeMethod<String>('getNativeTorPath');
        if (nativePath != null && await File(nativePath).exists()) {
          return nativePath;
        }
      } catch (e) {
        _addLog('[notice] Native Android library query: $e');
      }
    }

    final exeName = Platform.isWindows ? 'tor.exe' : 'tor';

    // 2. Check relative to current working directory (e.g. during desktop development)
    final devPath = p.join(Directory.current.path, 'assets', 'tor', 'windows', 'tor', exeName);
    if (await File(devPath).exists()) {
      return devPath;
    }

    // 3. Check bundled with executable in desktop release build
    final resolvedExeDir = p.dirname(Platform.resolvedExecutable);
    final bundledPaths = [
      p.join(resolvedExeDir, 'data', 'flutter_assets', 'assets', 'tor', 'windows', 'tor', exeName),
      p.join(resolvedExeDir, 'tor', exeName),
      p.join(resolvedExeDir, exeName),
    ];
    for (final bp in bundledPaths) {
      if (await File(bp).exists()) {
        return bp;
      }
    }

    // 4. Check AppData / AppSupport directory
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final appDataTor = p.join(appSupportDir.path, 'tor', exeName);
      if (await File(appDataTor).exists()) {
        return appDataTor;
      }
    } catch (_) {}

    // 5. Check system PATH
    try {
      final res = await Process.run(Platform.isWindows ? 'where' : 'which', [exeName]);
      if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
        final path = res.stdout.toString().trim().split(RegExp(r'[\r\n]+')).first;
        if (await File(path).exists()) {
          return path;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Starts the Tor process and waits for bootstrap completion
  Future<bool> startTor({
    String? customExecutablePath,
    int socksPort = 9050,
    int controlPort = 9051,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (_torProcess != null) {
      return true;
    }

    _updateStatus(_status.copyWith(
      state: TorConnectionState.starting,
      bootstrapProgress: 0,
      bootstrapSummary: 'Locating Tor executable or running daemon...',
      socksPort: socksPort,
      controlPort: controlPort,
    ));

    // First check if an existing Tor daemon (e.g. Orbot on Android or system Tor daemon) is already running
    try {
      final testSock = await Socket.connect('127.0.0.1', controlPort, timeout: const Duration(seconds: 1));
      testSock.destroy();
      _addLog('[notice] Detected existing Tor service running on ControlPort $controlPort (e.g. Orbot/daemon)');
      _updateStatus(_status.copyWith(
        state: TorConnectionState.connected,
        bootstrapProgress: 100,
        bootstrapSummary: 'Connected to existing Tor daemon',
      ));
      return true;
    } catch (_) {
      // No existing daemon, proceed to launch bundled Tor
    }

    final torExe = await findTorExecutable(customPath: customExecutablePath);
    if (torExe == null) {
      final err = Platform.isAndroid
          ? 'Tor executable not found. On Android, you can also start Orbot (the official Tor app) to provide the Tor connection.'
          : 'Tor executable not found. Please ensure Tor is installed or bundled in assets.';
      _updateStatus(_status.copyWith(
        state: TorConnectionState.error,
        errorMessage: err,
        bootstrapSummary: err,
      ));
      _addLog('[error] $err');
      return false;
    }

    _addLog('[notice] Found Tor executable at: $torExe');

    // Create a dedicated data directory for this app
    final docsDir = await getApplicationDocumentsDirectory();
    final torDataDir = Directory(p.join(docsDir.path, 'tor_chat', 'tor_data'));
    if (!await torDataDir.exists()) {
      await torDataDir.create(recursive: true);
    }

    _updateStatus(_status.copyWith(
      state: TorConnectionState.bootstrapping,
      bootstrapProgress: 5,
      bootstrapSummary: 'Launching Tor process...',
    ));

    _bootstrapCompleter = Completer<bool>();

    try {
      final args = [
        '--SocksPort', '$socksPort',
        '--ControlPort', '$controlPort',
        '--DataDirectory', torDataDir.path,
        '--CookieAuthentication', '0',
        '--Log', 'notice stdout',
        '--ClientOnly', '1',
      ];

      _addLog('[notice] Starting Tor with args: ${args.join(" ")}');

      _torProcess = await Process.start(torExe, args);

      // Listen to stdout
      _torProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
        _addLog,
        onError: (err) {
          _addLog('[error] stdout error: $err');
        },
      );

      // Listen to stderr
      _torProcess!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (errLine) {
          _addLog('[stderr] $errLine');
        },
      );

      _torProcess!.exitCode.then((code) {
        _addLog('[notice] Tor process exited with code $code');
        _torProcess = null;
        if (_status.state != TorConnectionState.stopped) {
          _updateStatus(_status.copyWith(
            state: TorConnectionState.stopped,
            bootstrapSummary: 'Tor process terminated (code: $code)',
          ));
        }
      });

      // Wait for bootstrap or timeout
      return await _bootstrapCompleter!.future.timeout(
        timeout,
        onTimeout: () {
          if (_status.bootstrapProgress > 0) {
            // Tor is running and progressing, don't fail outright
            _addLog('[warn] Bootstrap taking longer than expected, continuing in background...');
            return true;
          }
          throw TimeoutException('Tor bootstrap timed out after ${timeout.inSeconds}s');
        },
      );
    } catch (e) {
      _updateStatus(_status.copyWith(
        state: TorConnectionState.error,
        errorMessage: e.toString(),
        bootstrapSummary: 'Failed to launch Tor: $e',
      ));
      _addLog('[error] Launch failure: $e');
      return false;
    }
  }

  /// Stops the running Tor process gracefully
  Future<void> stopTor() async {
    if (_torProcess != null) {
      _addLog('[notice] Stopping Tor process...');
      _torProcess!.kill(ProcessSignal.sigterm);
      await Future.delayed(const Duration(milliseconds: 500));
      _torProcess?.kill(ProcessSignal.sigkill);
      _torProcess = null;
    }
    _updateStatus(_status.copyWith(
      state: TorConnectionState.stopped,
      bootstrapProgress: 0,
      bootstrapSummary: 'Stopped',
    ));
  }
}

