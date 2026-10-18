import 'dart:async';
import 'dart:convert';
import '../../models/message.dart';
import '../tor/socks5_client.dart';

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

  /// Sends a chat message to the remote peer's onion address
  Future<bool> sendMessage({
    required String peerOnion,
    required ChatMessage message,
    required String myNickname,
    Duration timeout = const Duration(seconds: 40),
  }) async {
    try {
      final payload = {
        'id': message.id,
        'sender': message.senderOnion,
        'recipient': message.recipientOnion,
        'content': message.content,
        'nickname': myNickname,
        'timestamp': message.timestamp.toIso8601String(),
      };

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
          return resData['status'] == 'delivered';
        } catch (_) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
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
    required String messageId,
    required MessageStatus status,
  }) async {
    try {
      final payload = {
        'id': messageId,
        'status': status.name,
      };

      final response = await socks5.sendHttpRequest(
        method: 'POST',
        onionAddress: peerOnion,
        path: '/api/v1/receipt',
        body: jsonEncode(payload),
        timeout: const Duration(seconds: 25),
      );
      return response.isSuccess;
    } catch (_) {
      return false;
    }
  }
}

