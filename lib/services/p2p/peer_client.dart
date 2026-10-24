import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../models/call_session.dart';
import '../../models/message.dart';
import '../tor/socks5_client.dart';
import 'tor_websocket_client.dart';

class PeerPingResult {
  final bool isOnline;
  final String? peerNickname;
  final Duration? latency;
  final String? error;

  PeerPingResult({
    required this.isOnline,
    this.peerNickname,
    this.latency,
    this.error,
  });
}

class PeerClient {
  final Socks5Client socks5;

  PeerClient({required this.socks5});

  /// Checks if an active keep-alive connection is already pooled for this peer
  bool hasWarmConnection(String peerOnion) => socks5.hasWarmConnection(peerOnion);

  /// Sends a chat message to the remote peer's onion address
  /// Returns confirmed [MessageStatus] on success (read or delivered)
  Future<MessageStatus> sendMessage({
    required String peerOnion,
    required ChatMessage message,
    required String myNickname,
    Duration timeout = SocksTimeouts.httpRequest,
  }) async {
    try {
      final Map<String, dynamic> payload = {
        'id': message.id,
        'sender': message.senderOnion,
        'recipient': message.recipientOnion,
        'content': message.isDeleted ? '' : message.content,
        'nickname': myNickname,
        'timestamp': message.timestamp.toIso8601String(),
        'type': message.messageType.name,
        'is_deleted': message.isDeleted ? 1 : 0,
      };

      if (!message.isDeleted && message.messageType == MessageType.image && message.mediaPath != null) {
        final file = File(message.mediaPath!);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          payload['media_data'] = base64Encode(bytes);
        }
      }

      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/message',
        body: jsonEncode(payload),
        timeout: timeout,
      );

      if (response.isSuccess) {
        try {
          final resData = jsonDecode(response.body);
          if (resData is Map && resData['status'] != null) {
            final returnedStatus = MessageStatus.fromString(resData['status'].toString());
            if (returnedStatus == MessageStatus.read) {
              return MessageStatus.read;
            }
          }
          return MessageStatus.delivered;
        } catch (_) {
          return MessageStatus.delivered;
        }
      }
      throw Exception('Peer returned HTTP ${response.statusCode}: ${response.body}');
    } catch (e) {
      rethrow;
    }
  }

  /// Pings a peer to verify their onion service is online and fetch their profile nickname
  Future<PeerPingResult> pingPeer(String peerOnion, {Duration timeout = const Duration(seconds: 30)}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await socks5.sendHttpRequest(
        method: 'GET',
        onionAddress: peerOnion,
        path: '/api/v1/ping',
        timeout: timeout,
      );
      stopwatch.stop();

      if (response.isSuccess) {
        try {
          final data = jsonDecode(response.body);
          return PeerPingResult(
            isOnline: true,
            peerNickname: data['nickname'] as String?,
            latency: stopwatch.elapsed,
          );
        } catch (_) {
          return PeerPingResult(isOnline: true, latency: stopwatch.elapsed);
        }
      }
      return PeerPingResult(isOnline: false, error: 'Peer returned status ${response.statusCode}');
    } catch (e) {
      stopwatch.stop();
      return PeerPingResult(isOnline: false, error: e.toString());
    }
  }

  /// Sends a read / delivery confirmation receipt to the remote peer
  Future<bool> sendReceipt({
    required String peerOnion,
    String? messageId,
    List<String>? messageIds,
    required MessageStatus status,
    Duration timeout = SocksTimeouts.httpRequest,
  }) async {
    try {
      final Map<String, dynamic> payload = {
        'status': status.name,
      };
      if (messageId != null) payload['id'] = messageId;
      if (messageIds != null && messageIds.isNotEmpty) payload['ids'] = messageIds;

      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/receipt',
        body: jsonEncode(payload),
        timeout: timeout,
      );
      return response.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// Sends a delete-for-everyone event to the remote peer
  Future<bool> sendDeleteMessage({
    required String peerOnion,
    required String messageId,
    required String myOnion,
    Duration timeout = SocksTimeouts.httpRequest,
  }) async {
    try {
      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/delete',
        body: jsonEncode({
          'id': messageId,
          'sender': myOnion,
        }),
        timeout: timeout,
      );
      return response.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// Pre-warms connection to peer in background
  Future<void> prewarmPeer(String peerOnion) => socks5.prewarm(peerOnion);

  /// Sends a voice call invitation to [peerOnion]
  Future<Map<String, dynamic>> sendCallInvite({
    required String peerOnion,
    required String callId,
    required String myOnion,
    required String myNickname,
    required String ephemeralKey,
    required CallMode mode,
    Duration timeout = const Duration(seconds: 40),
  }) async {
    try {
      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/call/invite',
        body: jsonEncode({
          'call_id': callId,
          'caller': myOnion,
          'nickname': myNickname,
          'key': ephemeralKey,
          'mode': mode.toJson(),
          'timestamp': DateTime.now().toIso8601String(),
        }),
        timeout: timeout,
      );

      if (response.isSuccess) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'status': 'error', 'error': 'Peer returned ${response.statusCode}'};
    } catch (e) {
      return {'status': 'error', 'error': e.toString()};
    }
  }

  /// Sends call accept signal to [peerOnion]
  Future<bool> sendCallAccept({
    required String peerOnion,
    required String callId,
    required String myOnion,
    required String ephemeralKey,
    required CallMode mode,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    try {
      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/call/accept',
        body: jsonEncode({
          'call_id': callId,
          'caller': myOnion,
          'key': ephemeralKey,
          'mode': mode.toJson(),
          'timestamp': DateTime.now().toIso8601String(),
        }),
        timeout: timeout,
      );
      return response.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// Sends call reject signal to [peerOnion]
  Future<bool> sendCallReject({
    required String peerOnion,
    required String callId,
    String reason = 'declined',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/call/reject',
        body: jsonEncode({
          'call_id': callId,
          'reason': reason,
        }),
        timeout: timeout,
      );
      return response.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// Sends call hangup signal to [peerOnion]
  Future<bool> sendCallHangup({
    required String peerOnion,
    required String callId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/call/hangup',
        body: jsonEncode({
          'call_id': callId,
        }),
        timeout: timeout,
      );
      return response.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// Connects to the peer's call WebSocket media stream over Tor
  Future<WebSocket> connectCallStream({
    required String peerOnion,
    required String callId,
    Duration timeout = const Duration(seconds: 45),
  }) {
    return TorWebSocketClient.connect(
      socks5: socks5,
      peerOnion: peerOnion,
      path: '/api/v1/call/stream?call_id=$callId',
      timeout: timeout,
    );
  }
}

