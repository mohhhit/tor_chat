import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../models/message.dart';

typedef OnMessageReceived = Future<void> Function(ChatMessage message, String? senderNickname);
typedef OnReceiptReceived = Future<void> Function(String messageId, MessageStatus status);

class PeerServer {
  final int port;
  final String myOnionAddress;
  final String myNickname;
  HttpServer? _server;
  OnMessageReceived? onMessageReceived;
  OnReceiptReceived? onReceiptReceived;

  PeerServer({
    this.port = 8765,
    required this.myOnionAddress,
    required this.myNickname,
  });

  bool get isRunning => _server != null;

  /// Starts the local HTTP server listening for forwarded Tor Onion connections
  Future<void> start() async {
    if (_server != null) return;

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handleRequest, onError: (err) {
      // Server error
    });
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // Add security and CORS headers
    request.response.headers.set('X-Content-Type-Options', 'nosniff');
    request.response.headers.set('Server', 'TorChatP2P/1.0');

    try {
      final path = request.uri.path;

      if (request.method == 'GET' && path == '/api/v1/ping') {
        _sendJsonResponse(request, HttpStatus.ok, {
          'status': 'pong',
          'onion': myOnionAddress,
          'nickname': myNickname,
          'time': DateTime.now().toIso8601String(),
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/message') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);

        final id = data['id'] as String;
        final sender = (data['sender'] as String).trim();
        final recipient = (data['recipient'] as String?)?.trim() ?? myOnionAddress;
        final content = data['content'] as String;
        final senderNick = data['nickname'] as String?;
        final timestampStr = data['timestamp'] as String?;
        final timestamp = timestampStr != null
            ? DateTime.tryParse(timestampStr) ?? DateTime.now()
            : DateTime.now();

        final incomingMsg = ChatMessage(
          id: id,
          chatOnion: sender,
          senderOnion: sender,
          recipientOnion: recipient,
          content: content,
          timestamp: timestamp,
          isOutgoing: false,
          status: MessageStatus.delivered,
        );

        if (onMessageReceived != null) {
          await onMessageReceived!(incomingMsg, senderNick);
        }

        _sendJsonResponse(request, HttpStatus.ok, {
          'status': 'delivered',
          'id': id,
          'timestamp': DateTime.now().toIso8601String(),
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/receipt') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);

        final id = data['id'] as String;
        final statusStr = data['status'] as String? ?? 'delivered';
        final status = MessageStatus.fromString(statusStr);

        if (onReceiptReceived != null) {
          await onReceiptReceived!(id, status);
        }

        _sendJsonResponse(request, HttpStatus.ok, {'status': 'ok'});
        return;
      }

      // Default 404
      _sendJsonResponse(request, HttpStatus.notFound, {'error': 'Endpoint not found'});
    } catch (e) {
      _sendJsonResponse(request, HttpStatus.internalServerError, {'error': e.toString()});
    }
  }

  void _sendJsonResponse(HttpRequest request, int statusCode, Map<String, dynamic> body) {
    try {
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.json;
      final jsonBytes = utf8.encode(jsonEncode(body));
      request.response.contentLength = jsonBytes.length;
      request.response.add(jsonBytes);
      request.response.close();
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
  }
}
