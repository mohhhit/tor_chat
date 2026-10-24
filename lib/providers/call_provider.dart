import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/call_packet.dart';
import '../models/call_session.dart';
import '../models/message.dart';
import '../services/audio/call_audio_service.dart';
import '../services/p2p/chat_coordinator.dart';
import '../services/p2p/peer_server.dart';

class CallProvider extends ChangeNotifier {
  final CallAudioService _audio = CallAudioService();
  final Uuid _uuid = const Uuid();

  CallSession? _currentCall;
  WebSocket? _callSocket;
  StreamSubscription? _socketSub;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _durationTimer;
  Timer? _pingTimer;
  Timer? _ringingTimeoutTimer;
  Timer? _connectingTimeoutTimer;
  int _sequenceNumber = 0;
  bool _isCallScreenOpen = false;
  bool _isConnectingMedia = false;

  CallSession? get currentCall => _currentCall;
  bool get hasActiveCall => _currentCall != null && !_currentCall!.hasEnded;
  bool get isPttSpeaking => _audio.isRecording;
  bool get isCallScreenOpen => _isCallScreenOpen;
  bool get isSpeakerphone => _audio.isSpeakerphone;
  InputDevice? get selectedInputDevice => _audio.selectedInputDevice;

  Future<void> toggleSpeakerphone() async {
    final next = !_audio.isSpeakerphone;
    await _audio.setSpeakerphone(next);
    _currentCall?.isSpeakerOn = next;
    notifyListeners();
  }

  Future<List<InputDevice>> getInputDevices() => _audio.getInputDevices();

  Future<void> switchInputDevice(InputDevice? device) async {
    await _audio.setInputDevice(device);
    if (_audio.isRecording) {
      await _audio.stopMicrophoneStream();
      _micSub?.cancel();
      _micSub = null;
      if (_currentCall?.isActive == true &&
          (_currentCall?.mode == CallMode.fullDuplex || isPttSpeaking)) {
        await _startContinuousMicrophone();
      }
    }
    notifyListeners();
  }

  void setCallScreenOpen(bool open) {
    _isCallScreenOpen = open;
    notifyListeners();
  }

  void forceResetCall() {
    final session = _currentCall;
    if (session != null) {
      _handleCallEndedInternal(CallState.ended, reason: 'Reset by user');
    }
    _currentCall = null;
    notifyListeners();
  }

  CallProvider() {
    _initServerBindings();
  }

  void _initServerBindings() {
    // Connect callbacks to PeerServer whenever coordinator initializes
    final server = ChatCoordinator.instance.peerServer;
    if (server != null) {
      _bindServerCallbacks(server);
    }
    // Also listen for coordinator changes
    ChatCoordinator.instance.onServerStarted = (srv) {
      _bindServerCallbacks(srv);
    };

    ChatCoordinator.instance.onNativeAcceptCall = (callId, chatOnion) {
      if (_currentCall != null && _currentCall!.state == CallState.incomingRinging) {
        acceptCall();
      }
    };

    ChatCoordinator.instance.onNativeDeclineCall = (callId) {
      if (_currentCall != null && _currentCall!.state == CallState.incomingRinging) {
        rejectCall();
      }
    };
  }

  void _bindServerCallbacks(PeerServer server) {
    server.onCallInviteReceived = _handleIncomingInvite;
    server.onCallAcceptReceived = _handleCallAccept;
    server.onCallRejectReceived = _handleCallReject;
    server.onCallHangupReceived = _handleCallHangup;
    server.onCallStreamUpgrade = _handleIncomingStreamUpgrade;
  }

  /// Starts an outgoing voice call to [peerOnion]
  Future<void> startCall({
    required String peerOnion,
    String? peerNickname,
    CallMode mode = CallMode.fullDuplex,
  }) async {
    if (hasActiveCall) return;

    final myOnion = ChatCoordinator.instance.activeIdentity?.onionAddress ?? '';
    final myNickname = ChatCoordinator.instance.activeIdentity?.nickname ?? 'Anonymous';
    final callId = _uuid.v4();
    final ephemeralKey = _generateEphemeralKey();

    final session = CallSession(
      callId: callId,
      peerOnion: peerOnion,
      peerNickname: peerNickname,
      isOutgoing: true,
      state: CallState.checkingAvailability,
      mode: mode,
      startedAt: DateTime.now(),
      ephemeralKey: ephemeralKey,
    );

    _currentCall = session;
    notifyListeners();

    // Start background signaling to verify peer availability and trigger ringing
    _sendInviteInBackground(session, myOnion, myNickname);
  }

  Future<void> _sendInviteInBackground(
    CallSession session,
    String myOnion,
    String myNickname,
  ) async {
    try {
      final peerClient = ChatCoordinator.instance.peerClient;
      final inviteResult = await peerClient.sendCallInvite(
        peerOnion: session.peerOnion,
        callId: session.callId,
        myOnion: myOnion,
        myNickname: myNickname,
        ephemeralKey: session.ephemeralKey!,
        mode: session.mode,
        timeout: const Duration(seconds: 30),
      );

      if (_currentCall?.callId != session.callId) return;

      final status = inviteResult['status'] as String? ?? 'error';

      if (status == 'busy') {
        _handleCallEndedInternal(CallState.busy, reason: 'Peer is on another call');
        return;
      }

      if (status == 'declined' || status == 'rejected') {
        _handleCallEndedInternal(CallState.rejected, reason: 'Call was declined');
        return;
      }

      if (status == 'ringing' || status == 'accepted') {
        // Front party verified online and call is ringing!
        session.state = CallState.outgoingRinging;
        notifyListeners();

        // Start 45s ringing timeout
        _ringingTimeoutTimer?.cancel();
        _ringingTimeoutTimer = Timer(const Duration(seconds: 45), () {
          if (_currentCall?.callId == session.callId &&
              _currentCall?.state == CallState.outgoingRinging) {
            _handleCallEndedInternal(CallState.ended, reason: 'No answer');
          }
        });

        // Start outgoing ringback tone
        _audio.startOutgoingRingtone();

        if (status == 'accepted') {
          await _connectOutgoingMediaStream(session);
        }
      } else {
        final err = inviteResult['error'] ?? 'Peer offline';
        _handleCallEndedInternal(CallState.unavailable, reason: 'Peer is unavailable or offline ($err)');
      }
    } catch (e) {
      if (_currentCall?.callId == session.callId) {
        _handleCallEndedInternal(CallState.unavailable, reason: 'Peer unreachable on Tor ($e)');
      }
    }
  }

  Future<void> _connectOutgoingMediaStream(CallSession session) async {
    if (_isConnectingMedia || _callSocket != null) return;
    _isConnectingMedia = true;
    try {
      session.state = CallState.connecting;
      _startConnectingTimeout(session);
      notifyListeners();

      final peerClient = ChatCoordinator.instance.peerClient;
      final ws = await peerClient.connectCallStream(
        peerOnion: session.peerOnion,
        callId: session.callId,
      );

      _setupMediaSocket(ws, session);
    } catch (e) {
      _handleCallEndedInternal(CallState.ended, reason: 'Media connection failed: $e');
    } finally {
      _isConnectingMedia = false;
    }
  }

  /// Callee handles incoming call invitation from PeerServer
  Future<Map<String, dynamic>> _handleIncomingInvite(Map<String, dynamic> data) async {
    final callId = data['call_id'] as String;
    final caller = data['caller'] as String;
    final nickname = data['nickname'] as String?;
    final key = data['key'] as String?;
    final modeStr = data['mode'] as String?;

    if (hasActiveCall) {
      return {'status': 'busy'};
    }

    final session = CallSession(
      callId: callId,
      peerOnion: caller,
      peerNickname: nickname,
      isOutgoing: false,
      state: CallState.incomingRinging,
      mode: CallMode.fromJson(modeStr),
      startedAt: DateTime.now(),
      ephemeralKey: key,
    );

    _currentCall = session;
    notifyListeners();

    // Trigger ringtones and system notifications
    if (Platform.isAndroid) {
      try {
        const MethodChannel('com.onionchat.tor_chat/native').invokeMethod(
          'showIncomingCallNotification',
          {
            'callerOnion': caller,
            'callerNickname': nickname ?? 'Unknown Peer',
            'callId': callId,
          },
        );
        const MethodChannel('com.onionchat.tor_chat/native').invokeMethod('playDefaultRingtone');
      } catch (_) {}
    } else {
      _audio.startIncomingRingtone();
    }

    return {'status': 'ringing'};
  }

  void _stopIncomingRingtonesAndNotifications() {
    _audio.stopRingtones();
    if (Platform.isAndroid) {
      try {
        const MethodChannel('com.onionchat.tor_chat/native').invokeMethod('dismissCallNotification');
        const MethodChannel('com.onionchat.tor_chat/native').invokeMethod('stopDefaultRingtone');
      } catch (_) {}
    }
  }

  void _startConnectingTimeout(CallSession session) {
    _connectingTimeoutTimer?.cancel();
    _connectingTimeoutTimer = Timer(const Duration(seconds: 40), () {
      if (_currentCall?.callId == session.callId &&
          _currentCall?.state == CallState.connecting) {
        _handleCallEndedInternal(CallState.ended, reason: 'Connection timed out');
      }
    });
  }

  /// Callee accepts the call
  Future<void> acceptCall() async {
    final session = _currentCall;
    if (session == null || session.state != CallState.incomingRinging) return;

    _stopIncomingRingtonesAndNotifications();
    session.state = CallState.connecting;
    _startConnectingTimeout(session);
    notifyListeners();

    final myOnion = ChatCoordinator.instance.activeIdentity?.onionAddress ?? '';
    final peerClient = ChatCoordinator.instance.peerClient;

    // Send accept notification to caller
    await peerClient.sendCallAccept(
      peerOnion: session.peerOnion,
      callId: session.callId,
      myOnion: myOnion,
      ephemeralKey: session.ephemeralKey ?? '',
      mode: session.mode,
    );

    // If caller's WebSocket upgrade already arrived, start call
    if (_callSocket != null) {
      _activateCallSession(session);
    }
  }

  /// Callee declines the call
  Future<void> rejectCall({String reason = 'declined'}) async {
    final session = _currentCall;
    if (session == null) return;

    _stopIncomingRingtonesAndNotifications();
    final peerClient = ChatCoordinator.instance.peerClient;
    peerClient.sendCallReject(
      peerOnion: session.peerOnion,
      callId: session.callId,
      reason: reason,
    );

    _handleCallEndedInternal(CallState.rejected, reason: reason);
  }

  /// Either peer hangs up the call
  Future<void> endCall() async {
    final session = _currentCall;
    if (session == null) return;

    final peerClient = ChatCoordinator.instance.peerClient;
    peerClient.sendCallHangup(
      peerOnion: session.peerOnion,
      callId: session.callId,
    );

    _handleCallEndedInternal(CallState.ended);
  }

  // --- Remote Signal Handlers ---

  Future<void> _handleCallAccept(Map<String, dynamic> data) async {
    final session = _currentCall;
    if (session == null || session.callId != data['call_id']) return;

    _ringingTimeoutTimer?.cancel();
    await _audio.stopRingtones();
    if (session.isOutgoing) {
      if (_callSocket == null) {
        await _connectOutgoingMediaStream(session);
      } else {
        _activateCallSession(session);
      }
    } else {
      _activateCallSession(session);
    }
  }

  Future<void> _handleCallReject(String callId, String reason) async {
    if (_currentCall?.callId == callId) {
      _handleCallEndedInternal(CallState.rejected, reason: reason);
    }
  }

  Future<void> _handleCallHangup(String callId) async {
    if (_currentCall?.callId == callId) {
      _handleCallEndedInternal(CallState.ended);
    }
  }

  Future<void> _handleIncomingStreamUpgrade(WebSocket socket, String callId) async {
    final session = _currentCall;
    if (session != null && session.callId == callId) {
      _setupMediaSocket(socket, session);
    } else {
      socket.close();
    }
  }

  void _setupMediaSocket(WebSocket socket, CallSession session) {
    if (_callSocket != null && _callSocket != socket) {
      try {
        _callSocket?.close();
      } catch (_) {}
    }
    _callSocket = socket;
    _socketSub?.cancel();
    _socketSub = null;

    _socketSub = socket.listen(
      (data) {
        if (data is List<int>) {
          _handleIncomingPacket(Uint8List.fromList(data), session);
        }
      },
      onError: (err) {
        _handleCallEndedInternal(CallState.ended, reason: 'Media stream dropped: $err');
      },
      onDone: () {
        _handleCallEndedInternal(CallState.ended, reason: 'Peer disconnected media');
      },
      cancelOnError: true,
    );

    _activateCallSession(session);
  }

  void _activateCallSession(CallSession session) {
    _ringingTimeoutTimer?.cancel();
    _connectingTimeoutTimer?.cancel();
    session.state = CallState.active;
    session.connectedAt = DateTime.now();
    _audio.stopRingtones();
    _audio.initVoiceStream();

    // Start timer for duration
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });

    // Start periodic RTT latency ping
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _sendPing();
    });

    // If Full-Duplex mode, start microphone capture immediately
    if (session.mode == CallMode.fullDuplex) {
      _startContinuousMicrophone();
    }

    notifyListeners();
  }

  // --- Audio & Media Streaming ---

  /// Handles Push-To-Talk state changes (held / released)
  Future<void> setPttSpeaking(bool speaking) async {
    final session = _currentCall;
    if (session == null || !session.isActive) return;

    if (speaking) {
      // User held the PTT button -> transmit speaking status & stream mic
      _sendPacket(CallPacketType.pttSpeaking, Uint8List(0));
      await _startContinuousMicrophone();
    } else {
      // User released the PTT button -> stop recording & transmit idle status
      await _audio.stopMicrophoneStream();
      _micSub?.cancel();
      _micSub = null;
      _sendPacket(CallPacketType.pttIdle, Uint8List(0));
    }
    notifyListeners();
  }

  Future<void> _startContinuousMicrophone() async {
    try {
      final stream = await _audio.startMicrophoneStream();
      _micSub?.cancel();
      _micSub = stream.listen((pcmChunk) {
        if (_currentCall?.isActive == true) {
          _sendPacket(CallPacketType.audio, pcmChunk);
        }
      });
    } catch (e) {
      debugPrint('Failed to start microphone: $e');
    }
  }

  void toggleMute() {
    final session = _currentCall;
    if (session == null) return;
    session.isMuted = !session.isMuted;
    _audio.setMuted(session.isMuted);
    _sendPacket(session.isMuted ? CallPacketType.mute : CallPacketType.unmute, Uint8List(0));
    notifyListeners();
  }

  void toggleMode() {
    final session = _currentCall;
    if (session == null) return;
    if (session.mode == CallMode.pushToTalk) {
      session.mode = CallMode.fullDuplex;
      _startContinuousMicrophone();
    } else {
      session.mode = CallMode.pushToTalk;
      _audio.stopMicrophoneStream();
      _micSub?.cancel();
      _micSub = null;
    }
    notifyListeners();
  }

  void _sendPacket(CallPacketType type, Uint8List payload) {
    if (_callSocket == null || _callSocket!.readyState != WebSocket.open) return;
    final packet = CallPacket(
      type: type,
      sequence: ++_sequenceNumber,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    final key = _currentCall?.ephemeralKey ?? '';
    final encPacket = packet.encryptWithKey(key);
    _callSocket!.add(encPacket.toBytes());
  }

  void _sendPing() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final bdata = ByteData(8)..setUint64(0, now, Endian.big);
    _sendPacket(CallPacketType.ping, bdata.buffer.asUint8List());
  }

  void _handleIncomingPacket(Uint8List rawBytes, CallSession session) {
    try {
      final key = session.ephemeralKey ?? '';
      final rawPacket = CallPacket.fromBytes(rawBytes);
      final packet = rawPacket.decryptWithKey(key);

      switch (packet.type) {
        case CallPacketType.audio:
          if (!session.isPeerMuted) {
            _audio.playAudioChunk(packet.payload);
          }
          break;
        case CallPacketType.pttSpeaking:
          session.isPeerSpeaking = true;
          notifyListeners();
          break;
        case CallPacketType.pttIdle:
          session.isPeerSpeaking = false;
          notifyListeners();
          break;
        case CallPacketType.mute:
          session.isPeerMuted = true;
          notifyListeners();
          break;
        case CallPacketType.unmute:
          session.isPeerMuted = false;
          notifyListeners();
          break;
        case CallPacketType.ping:
          // Reply with pong carrying same timestamp
          _sendPacket(CallPacketType.pong, packet.payload);
          break;
        case CallPacketType.pong:
          if (packet.payload.length >= 8) {
            final sentTime = ByteData.sublistView(packet.payload).getUint64(0, Endian.big);
            final now = DateTime.now().millisecondsSinceEpoch;
            session.rttMs = max(0, now - sentTime);
            notifyListeners();
          }
          break;
      }
    } catch (e) {
      debugPrint('Error handling call packet: $e');
    }
  }

  void _handleCallEndedInternal(CallState finalState, {String? reason}) {
    final session = _currentCall;
    if (session == null) return;

    session.state = finalState;
    session.endReason = reason;
    session.endedAt = DateTime.now();

    _stopIncomingRingtonesAndNotifications();
    _audio.stopMicrophoneStream();
    _audio.stopVoiceStream();
    _micSub?.cancel();
    _micSub = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _ringingTimeoutTimer?.cancel();
    _ringingTimeoutTimer = null;
    _connectingTimeoutTimer?.cancel();
    _connectingTimeoutTimer = null;

    _isConnectingMedia = false;
    try {
      _callSocket?.close();
    } catch (_) {}
    _callSocket = null;
    _socketSub?.cancel();
    _socketSub = null;

    // Log call event to chat history
    _logCallToChat(session, reason);

    notifyListeners();

    // Auto-clear ended session after 4 seconds to let the user see the result
    Timer(const Duration(seconds: 4), () {
      if (_currentCall?.callId == session.callId) {
        _currentCall = null;
        notifyListeners();
      }
    });
  }

  void _logCallToChat(CallSession session, String? reason) {
    try {
      String callSummary;
      if (session.connectedAt != null) {
        callSummary = 'Voice Call (${session.formattedDuration})';
      } else if (session.state == CallState.rejected) {
        callSummary = session.isOutgoing ? 'Call Declined' : 'Missed Voice Call';
      } else if (session.state == CallState.busy) {
        callSummary = 'Peer Busy';
      } else if (session.state == CallState.unavailable) {
        callSummary = session.isOutgoing ? 'Unanswered Call (Peer Offline)' : 'Missed Voice Call';
      } else {
        callSummary = session.isOutgoing ? 'Unanswered Call' : 'Missed Voice Call';
      }

      final chatMsg = ChatMessage(
        id: _uuid.v4(),
        chatOnion: session.peerOnion,
        senderOnion: session.isOutgoing
            ? (ChatCoordinator.instance.activeIdentity?.onionAddress ?? '')
            : session.peerOnion,
        recipientOnion: session.isOutgoing
            ? session.peerOnion
            : (ChatCoordinator.instance.activeIdentity?.onionAddress ?? ''),
        content: '📞 $callSummary',
        timestamp: session.startedAt,
        isOutgoing: session.isOutgoing,
        status: MessageStatus.delivered,
        messageType: MessageType.call,
      );

      ChatCoordinator.instance.databaseHelper.insertMessage(chatMsg);
      ChatCoordinator.instance.databaseHelper.updateContactLastMessage(
        onionAddress: session.peerOnion,
        lastMessage: chatMsg.content,
        timestamp: chatMsg.timestamp,
      );
      ChatCoordinator.instance.notifyMessageLogged(chatMsg);
    } catch (e) {
      debugPrint('Error logging call to database: $e');
    }
  }

  static String _generateEphemeralKey() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    return base64UrlEncode(bytes);
  }

  @override
  void dispose() {
    _ringingTimeoutTimer?.cancel();
    _connectingTimeoutTimer?.cancel();
    _durationTimer?.cancel();
    _pingTimer?.cancel();
    _micSub?.cancel();
    _socketSub?.cancel();
    _callSocket?.close();
    _audio.dispose();
    super.dispose();
  }
}
