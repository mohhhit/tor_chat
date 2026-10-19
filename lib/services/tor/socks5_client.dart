import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Socks5Response {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  Socks5Response({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Helper class to read from a single-subscription Socket stream with framing support
class _SocketBufferReader {
  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _buffer = BytesBuilder();
  Completer<void>? _waiter;
  bool _isClosed = false;
  Object? _error;

  _SocketBufferReader(this.socket) {
    _subscription = socket.listen(
      (data) {
        _buffer.add(data);
        if (_waiter != null && !_waiter!.isCompleted) {
          _waiter!.complete();
          _waiter = null;
        }
      },
      onError: (err) {
        _error = err;
        if (_waiter != null && !_waiter!.isCompleted) {
          _waiter!.completeError(err);
          _waiter = null;
        }
      },
      onDone: () {
        _isClosed = true;
        if (_waiter != null && !_waiter!.isCompleted) {
          _waiter!.complete();
          _waiter = null;
        }
      },
      cancelOnError: true,
    );
  }

  bool get isClosed => _isClosed || _error != null;

  Future<Uint8List> readExact(int count, Duration timeout) async {
    final sw = Stopwatch()..start();
    while (_buffer.length < count) {
      if (_isClosed) {
        throw Exception('Socket closed prematurely (needed $count bytes, got ${_buffer.length})');
      }
      if (_error != null) {
        throw _error!;
      }
      final remaining = timeout - sw.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Timed out waiting for $count bytes from SOCKS5');
      }
      _waiter = Completer<void>();
      await _waiter!.future.timeout(remaining);
    }

    final all = _buffer.takeBytes();
    final chunk = all.sublist(0, count);
    if (all.length > count) {
      _buffer.add(all.sublist(count));
    }
    return chunk;
  }

  Future<Uint8List> readUntil(List<int> delimiter, Duration timeout) async {
    final sw = Stopwatch()..start();
    while (true) {
      final currentBytes = _buffer.toBytes();
      final idx = _findSublist(currentBytes, delimiter);
      if (idx != -1) {
        final endPos = idx + delimiter.length;
        final all = _buffer.takeBytes();
        final result = all.sublist(0, endPos);
        if (all.length > endPos) {
          _buffer.add(all.sublist(endPos));
        }
        return result;
      }
      if (_isClosed) {
        if (_buffer.length > 0) return _buffer.takeBytes();
        throw Exception('Socket closed while searching for HTTP delimiter');
      }
      if (_error != null) {
        throw _error!;
      }
      final remaining = timeout - sw.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Timed out waiting for HTTP header delimiter');
      }
      _waiter = Completer<void>();
      await _waiter!.future.timeout(remaining);
    }
  }

  static int _findSublist(Uint8List source, List<int> pattern) {
    if (pattern.isEmpty || source.length < pattern.length) return -1;
    for (int i = 0; i <= source.length - pattern.length; i++) {
      bool match = true;
      for (int j = 0; j < pattern.length; j++) {
        if (source[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  Future<Uint8List> readRemaining(Duration timeout) async {
    final sw = Stopwatch()..start();
    while (!_isClosed) {
      final remaining = timeout - sw.elapsed;
      if (remaining <= Duration.zero) {
        break;
      }
      _waiter = Completer<void>();
      try {
        await _waiter!.future.timeout(remaining);
      } on TimeoutException {
        break;
      }
    }
    return _buffer.takeBytes();
  }

  Future<Socks5Response> readHttpResponse(Duration timeout) async {
    // 1. Read header block until \r\n\r\n
    final headerBytes = await readUntil([13, 10, 13, 10], timeout);
    final headerStr = utf8.decode(headerBytes, allowMalformed: true);
    final lines = headerStr.split('\r\n');
    if (lines.isEmpty || lines[0].isEmpty) {
      throw Exception('Empty HTTP response from peer');
    }

    final statusParts = lines[0].split(' ');
    final statusCode = statusParts.length >= 2 ? int.tryParse(statusParts[1]) ?? 500 : 500;

    final headers = <String, String>{};
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];
      final colon = line.indexOf(':');
      if (colon > 0) {
        final key = line.substring(0, colon).trim().toLowerCase();
        final value = line.substring(colon + 1).trim();
        headers[key] = value;
      }
    }

    // 2. Read body framed by Content-Length
    final contentLengthStr = headers['content-length'];
    final contentLength = contentLengthStr != null ? int.tryParse(contentLengthStr) : null;

    String body = '';
    if (contentLength != null && contentLength >= 0) {
      if (contentLength > 0) {
        final bodyBytes = await readExact(contentLength, timeout);
        body = utf8.decode(bodyBytes, allowMalformed: true);
      }
    } else {
      // Fallback for non-framed responses
      final bodyBytes = await readRemaining(const Duration(seconds: 3));
      body = utf8.decode(bodyBytes, allowMalformed: true);
    }

    return Socks5Response(
      statusCode: statusCode,
      headers: headers,
      body: body,
    );
  }

  Future<void> cancel() async {
    await _subscription.cancel();
  }
}

class _PooledSocket {
  final Socket socket;
  final _SocketBufferReader reader;
  final DateTime createdAt;
  DateTime lastUsed;
  bool isBusy = false;

  _PooledSocket({required this.socket, required this.reader})
      : createdAt = DateTime.now(),
        lastUsed = DateTime.now();

  bool get isClosed => reader.isClosed;

  /// Closes and discards sockets that are older than 5 minutes or idle for more than 110 seconds.
  /// Tor keep-alive connections stay active across user typing delays without establishing duplicate circuits.
  bool get isExpired {
    final now = DateTime.now();
    return now.difference(createdAt) > const Duration(minutes: 5) ||
           now.difference(lastUsed) > const Duration(seconds: 110);
  }

  Future<void> close() async {
    try {
      await reader.cancel();
      socket.destroy();
    } catch (_) {}
  }
}

class Socks5Client {
  final String proxyHost;
  final int proxyPort;
  final Map<String, _PooledSocket> _pool = {};
  final Map<String, Future<void>> _peerQueues = {};

  Socks5Client({
    this.proxyHost = '127.0.0.1',
    this.proxyPort = 9050,
  });

  /// Serializes operations to the same peer to guarantee in-order HTTP requests
  /// and reuse the persistent keep-alive socket safely without stream interleaving.
  Future<T> _synchronized<T>(String key, Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _peerQueues[key] ?? Future.value();

    final current = prev.then((_) async {
      try {
        final res = await action();
        completer.complete(res);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }, onError: (_) async {
      try {
        final res = await action();
        completer.complete(res);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    _peerQueues[key] = current.whenComplete(() {
      if (identical(_peerQueues[key], current)) {
        _peerQueues.remove(key);
      }
    });

    return completer.future;
  }

  /// Closes and removes any active connection to [onionAddress] from the pool
  Future<void> invalidatePeer(String onionAddress, {int port = 80}) async {
    final cleanHost = onionAddress.trim();
    final poolKey = '$cleanHost:$port';
    final pooled = _pool.remove(poolKey);
    if (pooled != null) {
      await pooled.close();
    }
  }

  /// Establishes and handshakes a raw Tor SOCKS5 TCP tunnel to [targetHost]:[targetPort]
  Future<_PooledSocket> _createConnection(String targetHost, int targetPort, Duration timeout) async {
    final cleanHost = targetHost.trim();
    final socket = await Socket.connect(proxyHost, proxyPort, timeout: const Duration(seconds: 10));
    final reader = _SocketBufferReader(socket);

    try {
      // 1. Initial Greeting / Auth method selection
      // [VER=5, NMETHODS=1, METHOD=0 (No Auth)]
      socket.add([0x05, 0x01, 0x00]);
      await socket.flush();

      final greetingResponse = await reader.readExact(2, const Duration(seconds: 5));
      if (greetingResponse[0] != 0x05 || greetingResponse[1] != 0x00) {
        throw Exception(
          'SOCKS5 proxy authentication failed (Code: ${greetingResponse[1]})',
        );
      }

      // 2. Connection request for domain name (ATYP=0x03)
      final hostBytes = ascii.encode(cleanHost);
      final req = BytesBuilder();
      req.add([
        0x05, // VER
        0x01, // CMD: CONNECT
        0x00, // RSV
        0x03, // ATYP: DOMAINNAME
        hostBytes.length, // Domain length
      ]);
      req.add(hostBytes);
      req.add([(targetPort >> 8) & 0xFF, targetPort & 0xFF]); // Port in network byte order

      socket.add(req.toBytes());
      await socket.flush();

      // 3. Read server reply header: [VER, REP, RSV, ATYP]
      final replyHeader = await reader.readExact(4, timeout);
      final rep = replyHeader[1];
      if (rep != 0x00) {
        final reason = _getReplyErrorMessage(rep);
        throw Exception('Tor connection to $cleanHost:$targetPort failed: $reason (REP code: $rep)');
      }

      final atyp = replyHeader[3];
      int remainingBytesToSkip = 0;
      if (atyp == 0x01) {
        // IPv4: 4 bytes address + 2 bytes port
        remainingBytesToSkip = 4 + 2;
      } else if (atyp == 0x03) {
        // Domain: 1 byte len + domain bytes + 2 bytes port
        final domainLenBytes = await reader.readExact(1, const Duration(seconds: 5));
        final domainLen = domainLenBytes[0];
        remainingBytesToSkip = domainLen + 2;
      } else if (atyp == 0x04) {
        // IPv6: 16 bytes address + 2 bytes port
        remainingBytesToSkip = 16 + 2;
      }

      if (remainingBytesToSkip > 0) {
        await reader.readExact(remainingBytesToSkip, const Duration(seconds: 5));
      }

      return _PooledSocket(socket: socket, reader: reader);
    } catch (e) {
      await reader.cancel();
      socket.destroy();
      rethrow;
    }
  }

  /// Sends an HTTP request through the persistent SOCKS5 connection pool
  /// Reuses existing open Tor circuits to achieve sub-second latency
  Future<Socks5Response> sendHttpRequest({
    required String method,
    required String onionAddress,
    required String path,
    int port = 80,
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(seconds: 40),
  }) {
    final cleanHost = onionAddress.trim();
    final poolKey = '$cleanHost:$port';

    return _synchronized(poolKey, () async {
      // Try up to 2 attempts: 1st with pooled connection, 2nd with fresh connection if old timed out
      for (int attempt = 0; attempt < 2; attempt++) {
        _PooledSocket? pooled = _pool[poolKey];

        if (pooled != null && (pooled.isClosed || pooled.isExpired)) {
          await pooled.close();
          if (identical(_pool[poolKey], pooled)) {
            _pool.remove(poolKey);
          }
          pooled = null;
        }

        bool isFresh = false;
        if (pooled == null) {
          pooled = await _createConnection(cleanHost, port, timeout);
          isFresh = true;
          _pool[poolKey] = pooled;
        }

        pooled.isBusy = true;
        pooled.lastUsed = DateTime.now();

        try {
          final bodyBytes = body != null ? utf8.encode(body) : <int>[];
          final reqHeaders = <String, String>{
            'Host': cleanHost,
            'User-Agent': 'TorChatP2P/1.0',
            'Connection': 'keep-alive',
            'Content-Length': bodyBytes.length.toString(),
            if (body != null) 'Content-Type': 'application/json; charset=utf-8',
            ...?headers,
          };

          final buffer = StringBuffer();
          buffer.write('$method $path HTTP/1.1\r\n');
          for (final entry in reqHeaders.entries) {
            buffer.write('${entry.key}: ${entry.value}\r\n');
          }
          buffer.write('\r\n');

          pooled.socket.add(utf8.encode(buffer.toString()));
          if (bodyBytes.isNotEmpty) {
            pooled.socket.add(bodyBytes);
          }
          await pooled.socket.flush();

          final response = await pooled.reader.readHttpResponse(timeout);

          if (response.headers['connection']?.toLowerCase() == 'close') {
            await pooled.close();
            if (identical(_pool[poolKey], pooled)) {
              _pool.remove(poolKey);
            }
          } else {
            pooled.isBusy = false;
            pooled.lastUsed = DateTime.now();
          }

          return response;
        } catch (e) {
          await pooled.close();
          if (identical(_pool[poolKey], pooled)) {
            _pool.remove(poolKey);
          }
          // If recycled connection closed while idle in pool, transparently retry once with fresh connection
          if (!isFresh && attempt == 0) {
            continue;
          }
          rethrow;
        }
      }

      throw Exception('Failed to send request through Tor to $cleanHost');
    });
  }

  /// Pre-warms an onion circuit in the background so the user's first message delivers instantly
  Future<void> prewarm(String onionAddress, {int port = 80}) async {
    final cleanHost = onionAddress.trim();
    final poolKey = '$cleanHost:$port';

    final existing = _pool[poolKey];
    if (existing != null && !existing.isClosed && !existing.isExpired) {
      return;
    }

    return _synchronized(poolKey, () async {
      final pooled = _pool[poolKey];
      if (pooled != null && !pooled.isClosed && !pooled.isExpired) {
        return;
      }
      if (pooled != null) {
        await pooled.close();
        if (identical(_pool[poolKey], pooled)) {
          _pool.remove(poolKey);
        }
      }
      try {
        final newConn = await _createConnection(cleanHost, port, const Duration(seconds: 35));
        _pool[poolKey] = newConn;
      } catch (_) {
        // Prewarm is best-effort background
      }
    });
  }

  /// Closes all pooled connections on shutdown
  Future<void> closeAll() async {
    for (final pooled in _pool.values) {
      await pooled.close();
    }
    _pool.clear();
  }

  String _getReplyErrorMessage(int rep) {
    switch (rep) {
      case 0x01:
        return 'General SOCKS server failure (Tor cannot establish circuit)';
      case 0x02:
        return 'Connection not allowed by ruleset';
      case 0x03:
        return 'Network unreachable';
      case 0x04:
        return 'Host unreachable (Peer onion service is offline or not yet published)';
      case 0x05:
        return 'Connection refused by peer';
      case 0x06:
        return 'TTL expired';
      case 0x07:
        return 'Command not supported';
      case 0x08:
        return 'Address type not supported';
      default:
        return 'SOCKS5 error code $rep';
    }
  }
}
