import 'dart:async';
import 'dart:io';
import '../tor/socks5_client.dart';

class TorWebSocketClient {
  /// Connects to a WebSocket endpoint on a remote Tor onion hidden service
  /// through the local Tor SOCKS5 proxy without leaking IP or using cleartext DNS.
  static Future<WebSocket> connect({
    required Socks5Client socks5,
    required String peerOnion,
    required String path,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final cleanOnion = peerOnion.trim();
    final client = HttpClient();

    // Use Dart native connectionFactory to tunnel through Tor SOCKS5 without socket reuse bugs
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final future = socks5.createRawTunnel(
        cleanOnion,
        80,
        timeout: timeout,
      );
      return Future.value(ConnectionTask.fromSocket(future, () {}));
    };

    final cleanPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('ws://$cleanOnion$cleanPath');

    try {
      return await WebSocket.connect(
        uri.toString(),
        customClient: client,
      ).timeout(timeout);
    } catch (e) {
      client.close(force: true);
      rethrow;
    }
  }
}
