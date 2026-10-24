import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

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

  TorTunneledSocket detachToTunneledSocket() {
    final tunneled = TorTunneledSocket(socket);

    // Emit any buffered data already read during SOCKS5 handshake
    if (_buffer.length > 0) {
      tunneled.feedData(_buffer.takeBytes());
    }

    if (_isClosed) {
      tunneled.feedDone();
    } else if (_error != null) {
      tunneled.feedError(_error!);
    } else {
      _subscription.onData((data) {
        tunneled.feedData(data);
      });
      _subscription.onError((err, st) {
        tunneled.feedError(err, st);
      });
      _subscription.onDone(() {
        tunneled.feedDone();
      });
    }

    return tunneled;
  }

  Future<void> cancel() async {
    await _subscription.cancel();
  }
}

/// A Socket wrapper that implements [Socket] and extends [Stream<Uint8List>].
/// Allows handshaking a raw TCP connection (like SOCKS5) without exhausting the
/// socket's single-subscription stream before handing it to HttpClient / WebSocket.
/// Safely supports multiple or sequential listeners without throwing "Stream has already been listened to".
class TorTunneledSocket extends Stream<Uint8List> implements Socket {
  final Socket _rawSocket;
  final List<Uint8List> _buffer = [];
  bool _isClosed = false;
  Object? _error;
  StackTrace? _stackTrace;
  void Function(Uint8List)? _onData;
  Function? _onError;
  void Function()? _onDone;

  TorTunneledSocket(this._rawSocket);

  void feedData(Uint8List data) {
    if (_onData != null) {
      _onData!(data);
    } else {
      _buffer.add(data);
    }
  }

  void feedError(Object error, [StackTrace? stackTrace]) {
    _error = error;
    _stackTrace = stackTrace;
    if (_onError != null) {
      if (_onError is void Function(Object, StackTrace)) {
        (_onError as void Function(Object, StackTrace))(error, stackTrace ?? StackTrace.current);
      } else {
        (_onError as void Function(Object))(error);
      }
    }
  }

  void feedDone() {
    _isClosed = true;
    if (_onDone != null) {
      _onDone!();
    }
  }

  @override
  InternetAddress get address => _rawSocket.address;

  @override
  int get port => _rawSocket.port;

  @override
  InternetAddress get remoteAddress => _rawSocket.remoteAddress;

  @override
  int get remotePort => _rawSocket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) => _rawSocket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _rawSocket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _rawSocket.setRawOption(option);

  @override
  void destroy() => _rawSocket.destroy();

  @override
  Future close() => _rawSocket.close();

  @override
  Future get done => _rawSocket.done;

  @override
  void add(List<int> data) => _rawSocket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _rawSocket.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _rawSocket.addStream(stream);

  @override
  Future flush() => _rawSocket.flush();

  @override
  void write(Object? object) => _rawSocket.write(object);

  @override
  void writeAll(Iterable objects, [String separator = ""]) => _rawSocket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _rawSocket.writeCharCode(charCode);

  @override
  void writeln([Object? object = ""]) => _rawSocket.writeln(object);

  @override
  Encoding get encoding => _rawSocket.encoding;

  @override
  set encoding(Encoding value) => _rawSocket.encoding = value;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    _onError = onError;
    _onDone = onDone;

    // Deliver any queued buffer immediately to the new listener
    if (_buffer.isNotEmpty && onData != null) {
      final chunks = List<Uint8List>.from(_buffer);
      _buffer.clear();
      scheduleMicrotask(() {
        for (final chunk in chunks) {
          if (_onData != null) _onData!(chunk);
        }
        if (_isClosed && _onDone != null) {
          _onDone!();
        }
      });
    } else if (_isClosed && onDone != null) {
      scheduleMicrotask(onDone);
    }

    if (_error != null && onError != null) {
      scheduleMicrotask(() {
        if (_onError != null) {
          if (_onError is void Function(Object, StackTrace)) {
            (_onError as void Function(Object, StackTrace))(_error!, _stackTrace ?? StackTrace.current);
          } else {
            (_onError as void Function(Object))(_error!);
          }
        }
      });
    }

    return _TunneledSocketSubscription(this);
  }
}

class _TunneledSocketSubscription implements StreamSubscription<Uint8List> {
  final TorTunneledSocket _tunneled;
  bool _isPaused = false;

  _TunneledSocketSubscription(this._tunneled);

  @override
  Future<void> cancel() async {
    _tunneled._onData = null;
    _tunneled._onError = null;
    _tunneled._onDone = null;
  }

  @override
  void onData(void Function(Uint8List data)? handleData) {
    _tunneled._onData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _tunneled._onError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _tunneled._onDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    _isPaused = true;
    resumeSignal?.then((_) => resume());
  }

  @override
  void resume() {
    _isPaused = false;
  }

  @override
  bool get isPaused => _isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final completer = Completer<E>();
    _tunneled._onDone = () {
      completer.complete(futureValue as E);
    };
    _tunneled._onError = (err, [st]) {
      completer.completeError(err, st);
    };
    return completer.future;
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

class SocksTimeouts {
  static const handshake = Duration(seconds: 10);     // talking to local tor: should be instant
  static const connectReply = Duration(seconds: 120);  // onion rendezvous can be slow when cold
  static const warmConnectReply = Duration(seconds: 35); // existing or recent warm circuit
  static const httpRequest = Duration(seconds: 25);
}

class Socks5Client {
  final String proxyHost;
  final int proxyPort;
  final Map<String, _PooledSocket> _pool = {};
  final Map<String, Future<void>> _peerQueues = {};
  final Map<String, Future<_PooledSocket>> _inflightConnections = {};
  final Map<String, DateTime> _lastSuccessTime = {};

  Socks5Client({
    this.proxyHost = '127.0.0.1',
    this.proxyPort = 9050,
  });

  /// Checks if a live, non-expired pooled socket already exists for this peer,
  /// or if a request succeeded to this peer in the last 3 minutes.
  bool hasWarmConnection(String onionAddress, {int port = 80}) {
    final poolKey = '${onionAddress.trim()}:$port';
    final pooled = _pool[poolKey];
    if (pooled != null && !pooled.isClosed && !pooled.isExpired) {
      return true;
    }
    final lastSuccess = _lastSuccessTime[poolKey];
    if (lastSuccess != null) {
      final elapsed = DateTime.now().difference(lastSuccess);
      if (elapsed < const Duration(minutes: 3)) {
        return true;
      }
    }
    return false;
  }

  /// Creates a dedicated, non-pooled SOCKS5 tunnel to [targetHost]:[targetPort] and returns a live [Socket].
  /// Useful for long-lived streaming connections like WebSockets or Voice Calls.
  Future<Socket> createRawTunnel(
    String targetHost,
    int targetPort, {
    Duration? timeout,
  }) async {
    final isKnownWarm = hasWarmConnection(targetHost, port: targetPort);
    final pooled = await _createConnection(
      targetHost,
      targetPort,
      timeout: timeout,
      isKnownWarm: isKnownWarm,
    );
    return pooled.reader.detachToTunneledSocket();
  }

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
  Future<_PooledSocket> _createConnection(
    String targetHost,
    int targetPort, {
    Duration? timeout,
    bool isKnownWarm = false,
  }) async {
    final cleanHost = targetHost.trim();
    final socket = await Socket.connect(proxyHost, proxyPort, timeout: SocksTimeouts.handshake);
    final reader = _SocketBufferReader(socket);

    try {
      // 1. Initial Greeting / Auth method selection (local loopback, fast)
      socket.add([0x05, 0x01, 0x00]);
      await socket.flush();

      final greetingResponse = await reader.readExact(2, SocksTimeouts.handshake);
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
      // Split timeouts: give cold rendezvous up to 120s, warm circuits 45s
      final connectReplyTimeout = timeout ?? (isKnownWarm ? SocksTimeouts.warmConnectReply : SocksTimeouts.connectReply);
      final replyHeader = await reader.readExact(4, connectReplyTimeout);
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

  /// Deduplicates in-flight connection requests to the same peer so concurrent attempts
  /// do not start competing cold rendezvous circuits through Tor.
  Future<_PooledSocket> _getOrCreateConnection(
    String cleanHost,
    int port, {
    Duration? timeout,
    bool isKnownWarm = false,
  }) {
    final poolKey = '$cleanHost:$port';

    return _inflightConnections.putIfAbsent(poolKey, () async {
      final sw = Stopwatch()..start();
      try {
        final pooled = await _createConnection(
          cleanHost,
          port,
          timeout: timeout,
          isKnownWarm: isKnownWarm,
        );
        _pool[poolKey] = pooled;
        debugPrint('[tor_network] Connected to $cleanHost:$port in ${sw.elapsedMilliseconds}ms (${isKnownWarm ? "warm" : "cold"})');
        return pooled;
      } finally {
        _inflightConnections.remove(poolKey);
      }
    });
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
    Duration timeout = SocksTimeouts.httpRequest,
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
          final isWarm = hasWarmConnection(cleanHost, port: port);
          pooled = await _getOrCreateConnection(
            cleanHost,
            port,
            timeout: isWarm ? SocksTimeouts.warmConnectReply : SocksTimeouts.connectReply,
            isKnownWarm: isWarm,
          );
          isFresh = true;
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

          final sw = Stopwatch()..start();
          pooled.socket.add(utf8.encode(buffer.toString()));
          if (bodyBytes.isNotEmpty) {
            pooled.socket.add(bodyBytes);
          }
          await pooled.socket.flush();

          final response = await pooled.reader.readHttpResponse(timeout);
          debugPrint('[tor_network] $method $path -> HTTP ${response.statusCode} in ${sw.elapsedMilliseconds}ms');

          if (response.headers['connection']?.toLowerCase() == 'close') {
            await pooled.close();
            if (identical(_pool[poolKey], pooled)) {
              _pool.remove(poolKey);
            }
          } else {
            pooled.isBusy = false;
            pooled.lastUsed = DateTime.now();
          }

          _lastSuccessTime[poolKey] = DateTime.now();
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

    if (hasWarmConnection(cleanHost, port: port)) {
      return;
    }

    try {
      await _getOrCreateConnection(cleanHost, port, isKnownWarm: false);
    } catch (_) {
      // Prewarm is best-effort background
    }
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
