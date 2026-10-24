enum CallState {
  idle,
  checkingAvailability,
  outgoingRinging,
  incomingRinging,
  connecting,
  active,
  ended,
  rejected,
  busy,
  unavailable,
}

enum CallMode {
  pushToTalk,
  fullDuplex;

  String toJson() => name;
  static CallMode fromJson(String? val) {
    if (val == 'pushToTalk') return CallMode.pushToTalk;
    return CallMode.fullDuplex;
  }
}

class CallSession {
  final String callId;
  final String peerOnion;
  final String? peerNickname;
  final bool isOutgoing;
  CallState state;
  CallMode mode;
  final DateTime startedAt;
  DateTime? connectedAt;
  DateTime? endedAt;
  String? ephemeralKey;
  String? endReason;
  int rttMs;
  bool isMuted;
  bool isPeerMuted;
  bool isPeerSpeaking;
  bool isSpeakerOn;

  CallSession({
    required this.callId,
    required this.peerOnion,
    this.peerNickname,
    required this.isOutgoing,
    this.state = CallState.idle,
    this.mode = CallMode.fullDuplex,
    required this.startedAt,
    this.connectedAt,
    this.endedAt,
    this.ephemeralKey,
    this.endReason,
    this.rttMs = 0,
    this.isMuted = false,
    this.isPeerMuted = false,
    this.isPeerSpeaking = false,
    this.isSpeakerOn = false,
  });

  Duration get duration {
    if (connectedAt == null) return Duration.zero;
    final end = endedAt ?? DateTime.now();
    return end.difference(connectedAt!);
  }

  String get formattedDuration {
    final d = duration;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  bool get isCheckingAvailability => state == CallState.checkingAvailability;
  bool get isActive => state == CallState.active;
  bool get isRinging =>
      state == CallState.outgoingRinging || state == CallState.incomingRinging;
  bool get hasEnded =>
      state == CallState.ended ||
      state == CallState.rejected ||
      state == CallState.busy ||
      state == CallState.unavailable;
}

