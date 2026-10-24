import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tor_chat/services/tor/socks5_client.dart';

void main() {
  test('TorTunneledSocket can be upgraded to WebSocket via HttpClient.connectionFactory', () async {
    // 1. Start local HTTP server supporting WebSocket
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((HttpRequest req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((msg) {
          ws.add('echo: $msg');
        });
      }
    });

    try {
      // 2. Connect raw socket and simulate a handshake that consumes the raw stream
      final rawSocket = await Socket.connect('127.0.0.1', server.port);

      final tunneledSocket = TorTunneledSocket(rawSocket);
      rawSocket.listen(
        (data) => tunneledSocket.feedData(data),
        onError: (err) => tunneledSocket.feedError(err),
        onDone: () => tunneledSocket.feedDone(),
        cancelOnError: true,
      );

      // 3. Connect WebSocket using HttpClient with connectionFactory returning tunneledSocket
      final client = HttpClient();
      client.connectionFactory = (uri, proxyHost, proxyPort) {
        return Future.value(ConnectionTask.fromSocket(Future.value(tunneledSocket), () {}));
      };

      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws',
        customClient: client,
      );

      final completer = Completer<String>();
      ws.listen((data) {
        completer.complete(data.toString());
      });

      ws.add('hello tor');
      final reply = await completer.future.timeout(const Duration(seconds: 3));
      expect(reply, 'echo: hello tor');

      await ws.close();
      client.close(force: true);
    } finally {
      await server.close();
    }
  });

  test('TorTunneledSocket allows multiple sequential listeners without throwing StateError', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final rawSocket = await Socket.connect('127.0.0.1', server.port);
    final tunneled = TorTunneledSocket(rawSocket);

    // First listener attaches and cancels
    final sub1 = tunneled.listen((data) {});
    await sub1.cancel();

    // Second listener attaches without throwing 'Stream has already been listened to'
    expect(() {
      final sub2 = tunneled.listen((data) {});
      sub2.cancel();
    }, returnsNormally);

    await rawSocket.close();
    await server.close();
  });
}

