import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:pedometer/pedometer.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auto_release_manager.dart'; // <-- Aggiunto import del nostro manager

enum VehicleState { stayAtHome, driving, stopping, parked, leavingSoon }

class SensorFusionEngine extends ChangeNotifier {
  static const MethodChannel _classicBtChannel = MethodChannel('com.parknow.app/classic_bt');
  VehicleState currentState = VehicleState.driving;

  double? currentUserLat;
  double? currentUserLon;
  double? parkedLat;
  double? parkedLon;
  double? distanceFromCarMeters;

  bool autoShareEnabled = true;
  String? targetCarBluetoothMac;
  String? targetCarBluetoothName;
  String? homeWifiSsid;
  String? workWifiSsid;
  String? currentConnectedWifiSsid;

  List<String> _ignoredWifis = [];
  List<String> _ignoredBtMacs = [];
  String? _lastPromptedWifi;
  String? _lastPromptedBtMac;

  double currentSpeedKmh = 0.0;
  double gyroscopeMagnitude = 0.0;
  String pedestrianStatus = 'unknown';
  int sessionSteps = 0;
  int? _initialStepCount;
  bool isCarBtConnected = false;

  final Future<void> Function(double lat, double lon, String method) onCarParked;
  final Future<void> Function(int estimatedMinutes) onApproachingCar100m;
  final Future<void> Function(int estimatedMinutes)? onManualReleaseConfirmed;
  final Future<void> Function(int estimatedMinutes)? onEtaUpdated;
  final Future<void> Function() onCarReleased;
  final void Function()? onAutoShareSkipped;
  final void Function(String ssid)? onUnknownWifiDetected;
  final void Function(String mac, String name)? onUnknownBluetoothDetected;

  StreamSubscription<Position>? _posSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<PedestrianStatus>? _pedStatusSub;
  StreamSubscription<StepCount>? _stepCountSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _btCheckTimer;

  bool _gyroTransitionDetected = false;
  bool _notified100m = false;
  bool _manualReleaseConfirmed = false;
  bool _autoShareSkippedNotified = false;
  int? _lastSentEta;
  bool get isManualReleaseConfirmed => _manualReleaseConfirmed;
  int get estimatedMinutesToRelease {
    final d = distanceFromCarMeters ?? 0.0;
    return (d <= 3.0 ? 0 : (d / 75.0).ceil()) + 1;
  }

  SensorFusionEngine({
    required this.onCarParked,
    required this.onApproachingCar100m,
    required this.onCarReleased,
    this.onManualReleaseConfirmed,
    this.onEtaUpdated,
    this.onAutoShareSkipped,
    this.onUnknownWifiDetected,
    this.onUnknownBluetoothDetected,
  });

  bool get isOnKnownPrivateWifi {
    if (currentConnectedWifiSsid == null || currentConnectedWifiSsid!.isEmpty) return false;
    final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
    return (homeWifiSsid != null && clean == homeWifiSsid) || (workWifiSsid != null && clean == workWifiSsid);
  }

  Future<void> initialize() async {
    await [Permission.activityRecognition, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    final prefs = await SharedPreferences.getInstance();
    parkedLat = prefs.getDouble('parked_lat');
    parkedLon = prefs.getDouble('parked_lon');
    autoShareEnabled = prefs.getBool('auto_share_enabled') ?? true;
    targetCarBluetoothMac = prefs.getString('car_bt_mac');
    targetCarBluetoothName = prefs.getString('car_bt_name');
    homeWifiSsid = prefs.getString('home_wifi_ssid');
    workWifiSsid = prefs.getString('work_wifi_ssid');
    _ignoredWifis = prefs.getStringList('ignored_wifis') ?? [];
    _ignoredBtMacs = prefs.getStringList('ignored_bt_macs') ?? [];

    if (parkedLat != null && parkedLon != null) currentState = VehicleState.parked;

    _setupClassicBluetoothListener();
    await _checkCurrentWifi(promptIfUnknown: true);
    _startWifiMonitor();
    _startGpsStream();
    _startGyroscopeStream();
    _startPedometerStreams();
    _startBleBluetoothMonitor();
    notifyListeners();
  }

  Future<void> reloadUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    autoShareEnabled = prefs.getBool('auto_share_enabled') ?? true;
    _autoShareSkippedNotified = false;
    final btMac = prefs.getString('car_bt_mac');
    if (btMac != null && btMac.isNotEmpty) targetCarBluetoothMac = btMac.toUpperCase();
    final homeWifi = prefs.getString('home_wifi_ssid');
    if (homeWifi != null && homeWifi.isNotEmpty) homeWifiSsid = homeWifi;
    _evaluateWifiStateTransition();
    notifyListeners();
  }

  Future<void> confirmManualReleaseIntent() async {
    _manualReleaseConfirmed = true;
    currentState = VehicleState.leavingSoon;
    if (parkedLat != null && parkedLon != null && currentUserLat != null && currentUserLon != null) {
      distanceFromCarMeters = Geolocator.distanceBetween(currentUserLat!, currentUserLon!, parkedLat!, parkedLon!);
    }
    final eta = estimatedMinutesToRelease;
    _lastSentEta = eta;
    if (onManualReleaseConfirmed != null) await onManualReleaseConfirmed!(eta);
    notifyListeners();
  }

  Future<void> setCarBluetoothDevice(String mac, String name) async {
    targetCarBluetoothMac = mac.toUpperCase();
    targetCarBluetoothName = name;
    isCarBtConnected = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('car_bt_mac', targetCarBluetoothMac!);
    await prefs.setString('car_bt_name', name);
    if (currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) {
      await _triggerCarReleased();
    } else {
      currentState = VehicleState.driving;
    }
    notifyListeners();
  }

  Future<void> ignoreBluetoothDevice(String mac) async {
    final upper = mac.toUpperCase();
    if (!_ignoredBtMacs.contains(upper)) {
      _ignoredBtMacs.add(upper);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ignored_bt_macs', _ignoredBtMacs);
    }
  }

  Future<void> saveWifiAsHome(String ssid) async {
    homeWifiSsid = ssid.replaceAll