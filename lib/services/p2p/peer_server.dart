import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../models/message.dart';
import 'chat_coordinator.dart';

typedef OnMessageReceived = Future<MessageStatus?> Function(ChatMessage message, String? senderNickname);
typedef OnReceiptReceived = Future<void> Function(String messageId, MessageStatus status);
typedef OnMessageDeleted = Future<void> Function(String messageId, String senderOnion);
typedef OnCallInviteReceived = Future<Map<String, dynamic>> Function(Map<String, dynamic> data);
typedef OnCallAcceptReceived = Future<void> Function(Map<String, dynamic> data);
typedef OnCallRejectReceived = Future<void> Function(String callId, String reason);
typedef OnCallHangupReceived = Future<void> Function(String callId);
typedef OnCallStreamUpgrade = Future<void> Function(WebSocket socket, String callId);

class PeerServer {
  final int port;
  final String myOnionAddress;
  final String myNickname;
  HttpServer? _server;
  OnMessageReceived? onMessageReceived;
  OnReceiptReceived? onReceiptReceived;
  OnMessageDeleted? onMessageDeleted;
  OnCallInviteReceived? onCallInviteReceived;
  OnCallAcceptReceived? onCallAcceptReceived;
  OnCallRejectReceived? onCallRejectReceived;
  OnCallHangupReceived? onCallHangupReceived;
  OnCallStreamUpgrade? onCallStreamUpgrade;

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

        final typeStr = data['type'] as String? ?? 'text';
        final messageType = MessageType.fromString(typeStr);
        final isDeleted = (data['is_deleted'] == 1 || data['is_deleted'] == true);
        String? savedMediaPath;

        if (!isDeleted && messageType == MessageType.image && data['media_data'] != null) {
          try {
            final mediaBytes = base64Decode(data['media_data'] as String);
            final mediaDir = await ChatCoordinator.instance.getMediaDirectory();
            final fileName = '$id.jpg';
            final mediaFile = File(p.join(mediaDir.path, fileName));
            await mediaFile.writeAsBytes(mediaBytes);
            savedMediaPath = mediaFile.path;
          } catch (_) {}
        }

        final incomingMsg = ChatMessage(
          id: id,
          chatOnion: sender,
          senderOnion: sender,
          recipientOnion: recipient,
          content: isDeleted ? '' : content,
          timestamp: timestamp,
          isOutgoing: false,
          status: MessageStatus.delivered,
          mediaPath: savedMediaPath,
          messageType: messageType,
          isDeleted: isDeleted,
        );

        MessageStatus confirmedStatus = MessageStatus.delivered;
        if (onMessageReceived != null) {
          final res = await onMessageReceived!(incomingMsg, senderNick);
          if (res != null) {
            confirmedStatus = res;
          }
        }

        _sendJsonResponse(request, HttpStatus.ok, {
          'status': confirmedStatus.name,
          'id': id,
          'timestamp': DateTime.now().toIso8601String(),
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/delete') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);

        final id = data['id'] as String?;
        final sender = (data['sender'] as String?)?.trim();

        if (id != null && sender != null && onMessageDeleted != null) {
          await onMessageDeleted!(id, sender);
        }

        _sendJsonResponse(request, HttpStatus.ok, {'status': 'ok'});
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/receipt') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);

        final statusStr = data['status'] as String? ?? 'delivered';
        final status = MessageStatus.fromString(statusStr);

        final id = data['id'] as String?;
        final ids = (data['ids'] as List<dynamic>?)?.map((e) => e.toString()).toList();

        if (id != null && onReceiptReceived != null) {
          await onReceiptReceived!(id, status);
        }
        if (ids != null && onReceiptReceived != null) {
          for (final singleId in ids) {
            await onReceiptReceived!(singleId, status);
          }
        }

        _sendJsonResponse(request, HttpStatus.ok, {'status': 'ok'});
        return;
      }

      // Voice Call Media Stream Upgrade
      if (path == '/api/v1/call/stream') {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final callId = request.uri.queryParameters['call_id'] ?? '';
          final socket = await WebSocketTransformer.upgrade(request);
          if (onCallStreamUpgrade != null) {
            await onCallStreamUpgrade!(socket, callId);
          }
          return;
        }
      }

      // Voice Call Signaling Endpoints
      if (request.method == 'POST' && path == '/api/v1/call/invite') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);
        Map<String, dynamic> reply = {'status': 'ringing'};
        if (onCallInviteReceived != null) {
          reply = await onCallInviteReceived!(data);
        }
        _sendJsonResponse(request, HttpStatus.ok, reply);
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/call/accept') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);
        if (onCallAcceptReceived != null) {
          await onCallAcceptReceived!(data);
        }
        _sendJsonResponse(request, HttpStatus.ok, {'status': 'ok'});
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/call/reject') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);
        final callId = data['call_id'] as String? ?? '';
        final reason = data['reason'] as String? ?? 'declined';
        if (onCallRejectReceived != null) {
          await onCallRejectReceived!(callId, reason);
        }
        _sendJsonResponse(request, HttpStatus.ok, {'status': 'ok'});
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/call/hangup') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(bodyStr);
        final callId = data['call_id'] as String? ?? '';
        if (onCallHangupReceived != null) {
          await onCallHangupReceived!(callId);
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
      request.response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
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

