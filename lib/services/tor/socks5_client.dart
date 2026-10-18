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

class Socks5Client {
  final String proxyHost;
  final int proxyPort;

  Socks5Client({
    this.proxyHost = '127.0.0.1',
    this.proxyPort = 9050,
  });

  /// Establishes a raw TCP tunnel to [targetHost] (e.g. an .onion address) on [targetPort]
  /// through the Tor SOCKS5 proxy.
  Future<Socket> connect({
    required String targetHost,
    required int targetPort,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);

    try {
      // 1. Initial Greeting / Auth method selection
      // [VER=5, NMETHODS=1, METHOD=0 (No Auth)]
      socket.add([0x05, 0x01, 0x00]);
      await socket.flush();

      final greetingResponse = await _readExactBytes(socket, 2, timeout);
      if (greetingResponse[0] != 0x05 || greetingResponse[1] != 0x00) {
        throw Exception(
          'SOCKS5 proxy authentication negotiation failed (Code: ${greetingResponse[1]})',
        );
      }

      // 2. Connection request for domain name (ATYP=0x03)
      final hostBytes = ascii.encode(targetHost);
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
      final replyHeader = await _readExactBytes(socket, 4, timeout);
      final rep = replyHeader[1];
      if (rep != 0x00) {
        final reason = _getReplyErrorMessage(rep);
        throw Exception('SOCKS5 connection to $targetHost:$targetPort failed: $reason (code: $rep)');
      }

      final atyp = replyHeader[3];
      int remainingBytesToSkip = 0;
      if (atyp == 0x01) {
        // IPv4: 4 bytes address + 2 bytes port
        remainingBytesToSkip = 4 + 2;
      } else if (atyp == 0x03) {
        // Domain: 1 byte len + domain bytes + 2 bytes port
        final domainLenBytes = await _readExactBytes(socket, 1, timeout);
        final domainLen = domainLenBytes[0];
        remainingBytesToSkip = domainLen + 2;
      } else if (atyp == 0x04) {
        // IPv6: 16 bytes address + 2 bytes port
        remainingBytesToSkip = 16 + 2;
      }

      if (remainingBytesToSkip > 0) {
        await _readExactBytes(socket, remainingBytesToSkip, timeout);
      }

      return socket;
    } catch (e) {
      socket.destroy();
      rethrow;
    }
  }

  /// Sends an HTTP request through the SOCKS5 proxy to the peer's onion service
  Future<Socks5Response> sendHttpRequest({
    required String method,
    required String onionAddress,
    required String path,
    int port = 80,
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final cleanHost = onionAddress.trim();
    final socket = await connect(targetHost: cleanHost, targetPort: port, timeout: timeout);

    try {
      final bodyBytes = body != null ? utf8.encode(body) : <int>[];
      final reqHeaders = <String, String>{
        'Host': cleanHost,
        'User-Agent': 'TorChatP2P/1.0',
        'Connection': 'close',
        'Content-Type': 'application/json',
        'Content-Length': bodyBytes.length.toString(),
        ...?headers,
      };

      final buffer = StringBuffer();
      buffer.write('$method $path HTTP/1.1\r\n');
      for (final entry in reqHeaders.entries) {
        buffer.write('${entry.key}: ${entry.value}\r\n');
      }
      buffer.write('\r\n');

      socket.add(utf8.encode(buffer.toString()));
      if (bodyBytes.isNotEmpty) {
        socket.add(bodyBytes);
      }
      await socket.flush();

      // Read response
      final rawResponse = await _readAllBytes(socket, timeout);
      return _parseHttpResponse(rawResponse);
    } finally {
      socket.destroy();
    }
  }

  Future<Uint8List> _readExactBytes(Socket socket, int count, Duration timeout) async {
    final builder = BytesBuilder();
    final completer = Completer<Uint8List>();
    late StreamSubscription<Uint8List> sub;

    void cleanup() {
      sub.cancel();
    }

    sub = socket.listen(
      (data) {
        builder.add(data);
        if (builder.length >= count) {
          cleanup();
          completer.complete(builder.toBytes().sublist(0, count));
        }
      },
      onError: (e) {
        cleanup();
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        cleanup();
        if (!completer.isCompleted) {
          completer.completeError(Exception('Socket closed prematurely waiting for $count bytes'));
        }
      },
      cancelOnError: true,
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        cleanup();
        throw TimeoutException('SOCKS5 handshake read timed out waiting for $count bytes');
      },
    );
  }

  Future<Uint8List> _readAllBytes(Socket socket, Duration timeout) async {
    final builder = BytesBuilder();
    final completer = Completer<Uint8List>();

    socket.listen(
      builder.add,
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(builder.toBytes());
      },
      cancelOnError: true,
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        if (builder.isNotEmpty) {
          return builder.toBytes();
        }
        throw TimeoutException('SOCKS5 request read timed out');
      },
    );
  }

  Socks5Response _parseHttpResponse(Uint8List rawBytes) {
    final rawText = utf8.decode(rawBytes, allowMalformed: true);
    final headerEnd = rawText.indexOf('\r\n\r\n');
    if (headerEnd == -1) {
      return Socks5Response(
        statusCode: 500,
        headers: {},
        body: rawText,
      );
    }

    final headerText = rawText.substring(0, headerEnd);
    final bodyText = rawText.substring(headerEnd + 4);

    final lines = headerText.split('\r\n');
    int statusCode = 200;
    if (lines.isNotEmpty) {
      final parts = lines[0].split(' ');
      if (parts.length >= 2) {
        statusCode = int.tryParse(parts[1]) ?? 200;
      }
    }

    final headers = <String, String>{};
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];
      final colon = line.indexOf(':');
      if (colon != -1) {
        final k = line.substring(0, colon).trim().toLowerCase();
        final v = line.substring(colon + 1).trim();
        headers[k] = v;
      }
    }

    return Socks5Response(
      statusCode: statusCode,
      headers: headers,
      body: bodyText,
    );
  }

  String _getReplyErrorMessage(int rep) {
    switch (rep) {
      case 0x01:
        return 'General SOCKS server failure';
      case 0x02:
        return 'Connection not allowed by ruleset';
      case 0x03:
        return 'Network unreachable';
      case 0x04:
        return 'Host unreachable (peer onion service may be offline or circuit building)';
      case 0x05:
        return 'Connection refused by peer';
      case 0x06:
        return 'TTL expired';
      case 0x07:
        return 'Command not supported';
      case 0x08:
        return 'Address type not supported';
      default:
        return 'Unknown SOCKS error';
    }
  }
}
