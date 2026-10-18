enum TorConnectionState {
  stopped,
  starting,
  bootstrapping,
  connected,
  error;

  String get label {
    switch (this) {
      case TorConnectionState.stopped:
        return 'Tor Inactive';
      case TorConnectionState.starting:
        return 'Starting Tor...';
      case TorConnectionState.bootstrapping:
        return 'Bootstrapping...';
      case TorConnectionState.connected:
        return 'Tor Onion Online';
      case TorConnectionState.error:
        return 'Tor Error';
    }
  }
}

class TorStatus {
  final TorConnectionState state;
  final int bootstrapProgress;
  final String bootstrapSummary;
  final String? onionAddress;
  final int socksPort;
  final int controlPort;
  final int localServerPort;
  final List<String> recentLogs;
  final String? errorMessage;

  const TorStatus({
    this.state = TorConnectionState.stopped,
    this.bootstrapProgress = 0,
    this.bootstrapSummary = 'Idle',
    this.onionAddress,
    this.socksPort = 9050,
    this.controlPort = 9051,
    this.localServerPort = 8765,
    this.recentLogs = const [],
    this.errorMessage,
  });

  bool get isConnected => state == TorConnectionState.connected;

  TorStatus copyWith({
    TorConnectionState? state,
    int? bootstrapProgress,
    String? bootstrapSummary,
    String? onionAddress,
    int? socksPort,
    int? controlPort,
    int? localServerPort,
    List<String>? recentLogs,
    String? errorMessage,
  }) {
    return TorStatus(
      state: state ?? this.state,
      bootstrapProgress: bootstrapProgress ?? this.bootstrapProgress,
      bootstrapSummary: bootstrapSummary ?? this.bootstrapSummary,
      onionAddress: onionAddress ?? this.onionAddress,
      socksPort: socksPort ?? this.socksPort,
      controlPort: controlPort ?? this.controlPort,
      localServerPort: localServerPort ?? this.localServerPort,
      recentLogs: recentLogs ?? this.recentLogs,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
