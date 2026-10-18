import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/tor_status.dart';
import '../services/p2p/chat_coordinator.dart';

class TorProvider extends ChangeNotifier {
  final ChatCoordinator _coordinator = ChatCoordinator.instance;
  TorStatus _status = const TorStatus();
  StreamSubscription<TorStatus>? _statusSub;
  StreamSubscription<String>? _logSub;

  bool _isBatteryIgnored = true;
  bool get isBatteryIgnored => _isBatteryIgnored;

  TorProvider() {
    _status = _coordinator.torStatus;
    _statusSub = _coordinator.torStatusStream.listen((newStatus) {
      _status = newStatus;
      notifyListeners();
    });
    checkBatteryOptimization();
  }

  Future<void> checkBatteryOptimization() async {
    _isBatteryIgnored = await _coordinator.isBatteryOptimizationIgnored();
    notifyListeners();
  }

  Future<void> requestIgnoreBatteryOptimization() async {
    await _coordinator.requestIgnoreBatteryOptimization();
    await Future.delayed(const Duration(seconds: 1));
    await checkBatteryOptimization();
  }

  TorStatus get status => _status;
  bool get isConnected => _status.isConnected;
  int get bootstrapProgress => _status.bootstrapProgress;
  String get bootstrapSummary => _status.bootstrapSummary;
  List<String> get logs => _coordinator.torManager.logs;

  Future<void> restartTor() async {
    await _coordinator.torManager.stopTor();
    await _coordinator.initialize();
    notifyListeners();
  }

  Future<void> requestNewCircuit() async {
    try {
      await _coordinator.torControl.signalNewNym();
    } catch (_) {}
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _logSub?.cancel();
    super.dispose();
  }
}

