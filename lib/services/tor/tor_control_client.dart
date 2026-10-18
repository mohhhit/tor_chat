import 'dart:async';
import 'dart:convert';
import 'dart:io';

class OnionServiceResult {
  final String serviceId; // e.g. <56 chars>.onion
  final String privateKey; // e.g. ED25519-V3:...

  OnionServiceResult({
    required this.serviceId,
    required this.privateKey,
  });

  String get fullOnionAddress => serviceId.endsWith('.onion') ? serviceId : '$serviceId.onion';
}

class TorControlClient {
  final String host;
  final int port;
  Socket? _socket;
  final StreamController<String> _eventController = StreamController<String>.broadcast();
  Completer<List<String>>? _pendingCommandCompleter;
  final List<String> _commandResponseBuffer = [];
  bool _authenticated = false;

  TorControlClient({
    this.host = '127.0.0.1',
    this.port = 9051,
  });

  bool get isConnected => _socket != null;
  bool get isAuthenticated => _authenticated;
  Stream<String> get events => _eventController.stream;

  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {
    if (_socket != null) return;

    _socket = await Socket.connect(host, port, timeout: timeout);
    _socket!.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
      _handleIncomingLine,
      onError: (err) {
        _cleanup();
      },
      onDone: () {
        _cleanup();
      },
    );
  }

  void _handleIncomingLine(String line) {
    line = line.trim();
    if (line.isEmpty) return;

    // Check if this is an asynchronous event notice (starts with 650)
    if (line.startsWith('650')) {
      _eventController.add(line);
      return;
    }

    // Accumulate lines for the active synchronous command
    _commandResponseBuffer.add(line);

    // End of command response: 250 OK, 250 ..., or error 5xx, 4xx (non-hyphenated 3rd char)
    // Note: multi-line responses have '-' or '+' after the status code, e.g. 250-ServiceID=...
    // Final line has a space: '250 OK' or '552 ...'
    if (line.length >= 3) {
      final delimiter = line.length > 3 ? line[3] : ' ';
      if (delimiter == ' ') {
        final completer = _pendingCommandCompleter;
        _pendingCommandCompleter = null;
        final response = List<String>.from(_commandResponseBuffer);
        _commandResponseBuffer.clear();
        completer?.complete(response);
      }
    }
  }

  Future<List<String>> sendCommand(String command, {Duration timeout = const Duration(seconds: 15)}) async {
    if (_socket == null) {
      try {
        await connect();
        await authenticate();
      } catch (e) {
        throw Exception('Tor Control socket disconnected and auto-reconnect failed: $e');
      }
    }

    while (_pendingCommandCompleter != null) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    _pendingCommandCompleter = Completer<List<String>>();
    _commandResponseBuffer.clear();

    _socket!.writeln(command);
    await _socket!.flush();

    return _pendingCommandCompleter!.future.timeout(
      timeout,
      onTimeout: () {
        _pendingCommandCompleter = null;
        throw TimeoutException('Tor Control command timed out: $command');
      },
    );
  }

  /// Authenticates with Tor Control Port. Uses empty string for CookieAuthentication=0 / blank password.
  Future<bool> authenticate([String password = '']) async {
    final response = await sendCommand('AUTHENTICATE "$password"');
    if (response.isNotEmpty && response.first.startsWith('250')) {
      _authenticated = true;
      // Enable async event monitoring
      try {
        await sendCommand('SETEVENTS STATUS_CLIENT NOTICE WARN ERR');
      } catch (_) {}
      return true;
    }
    throw Exception('Tor Authentication failed: ${response.join("\n")}');
  }

  /// Creates a dynamic V3 Onion Service or loads an existing one using [existingPrivateKey] (ED25519-V3:...)
  Future<OnionServiceResult> addOnion({
    required int virtualPort,
    required int targetPort,
    String? existingPrivateKey,
  }) async {
    final String keySpec = (existingPrivateKey != null && existingPrivateKey.trim().isNotEmpty)
        ? existingPrivateKey.trim()
        : 'NEW:ED25519-V3';

    // ADD_ONION <KeySpec> Flags=Detach Port=<virtualPort>,127.0.0.1:<targetPort>
    final cmd = 'ADD_ONION $keySpec Flags=Detach Port=$virtualPort,127.0.0.1:$targetPort';
    final response = await sendCommand(cmd);

    String? serviceId;
    String? privateKey = existingPrivateKey;

    for (final line in response) {
      if (line.contains('ServiceID=')) {
        serviceId = line.split('ServiceID=')[1].trim();
      } else if (line.contains('PrivateKey=')) {
        privateKey = line.split('PrivateKey=')[1].trim();
      }
    }

    if (serviceId == null) {
      throw Exception('ADD_ONION failed to return ServiceID: ${response.join("\n")}');
    }

    return OnionServiceResult(
      serviceId: serviceId,
      privateKey: privateKey ?? '',
    );
  }

  /// Destroys a previously registered onion service
  Future<void> delOnion(String serviceId) async {
    final cleanId = serviceId.replaceAll('.onion', '').trim();
    await sendCommand('DEL_ONION $cleanId');
  }

  /// Request a clean new Tor circuit (NEWNYM)
  Future<void> signalNewNym() async {
    try {
      await sendCommand('SIGNAL NEWNYM');
    } catch (_) {}
  }

  /// Get current bootstrap progress info
  Future<int> getBootstrapProgress() async {
    try {
      final response = await sendCommand('GETINFO status/bootstrap-phase');
      // Example response: 250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done"
      for (final line in response) {
        final match = RegExp(r'PROGRESS=(\d+)').firstMatch(line);
        if (match != null) {
          return int.tryParse(match.group(1)!) ?? 0;
        }
      }
    } catch (_) {}
    return 0;
  }

  void _cleanup() {
    _socket?.destroy();
    _socket = null;
    _authenticated = false;
    if (_pendingCommandCompleter != null && !_pendingCommandCompleter!.isCompleted) {
      _pendingCommandCompleter!.completeError(Exception('Tor Control socket closed'));
      _pendingCommandCompleter = null;
    }
  }

  Future<void> disconnect() async {
    _cleanup();
  }
}
