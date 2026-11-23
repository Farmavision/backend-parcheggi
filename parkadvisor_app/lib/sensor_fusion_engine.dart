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
import 'auto_release_manager.dart';

enum VehicleState { stayAtHome, driving, stopping, parked, leavingSoon }

class SensorFusionEngine extends ChangeNotifier {
  static final Completer<void> initialPermissionsCompleter = Completer<void>();
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
  String? _pendingWifiConfirmationSsid;
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
  final void Function(String reason)? onAutoShareSkipped;
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
  double geofenceRadiusMeters = 100.0;
  bool _passedThroughStall = false;
  int _vehicularSpeedSamples = 0;
  DateTime? _lastHumanStepAt;
  Timer? _gpsDeactivateTimer;
  bool _manualReleaseConfirmed = false;
  bool _autoShareSkippedNotified = false;
  int? _lastSentEta;

  late AutoReleaseManager _autoReleaseManager;

  bool get isCarParked => currentState == VehicleState.parked || currentState == VehicleState.leavingSoon;
  bool get isManualReleaseConfirmed => _manualReleaseConfirmed;

  String get statusMessage {
    if (currentState == VehicleState.stayAtHome) return 'Connesso a Wi-Fi privato (Casa/Lavoro)';
    if (currentState == VehicleState.parked) {
      final dist = distanceFromCarMeters != null ? ' (${distanceFromCarMeters!.round()}m dall\'auto)' : '';
      return 'Parcheggio attivo$dist';
    }
    if (currentState == VehicleState.leavingSoon) {
      return 'In avvicinamento: rilascio previsto tra $estimatedMinutesToRelease min';
    }
    return 'Velocità: ${currentSpeedKmh.toStringAsFixed(1)} km/h | Passi: $sessionSteps';
  }

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
  }) {
    _autoReleaseManager = AutoReleaseManager(
      onTriggerAutoRelease: () async {
        await _triggerCarReleased();
      },
    );
  }

  bool get isOnKnownPrivateWifi {
    if (currentConnectedWifiSsid == null || currentConnectedWifiSsid!.isEmpty) return false;
    final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
    return (homeWifiSsid != null && clean == homeWifiSsid) || (workWifiSsid != null && clean == workWifiSsid);
  }

  Future<void> initialize() async {
    await [Permission.activityRecognition, Permission.bluetoothConnect, Permission.locationWhenInUse, Permission.notification].request();
    try { await const MethodChannel('parknow/bg_service').invokeMethod('startMonitorService'); } catch (_) {}
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
    if (!initialPermissionsCompleter.isCompleted) initialPermissionsCompleter.complete();
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

  Future<void> confirmManualReleaseIntent() => confirmManualRelease();

  Future<void> confirmManualRelease([int? customMinutes]) async {
    _manualReleaseConfirmed = true;
    currentState = VehicleState.leavingSoon;
    if (parkedLat != null && parkedLon != null && currentUserLat != null && currentUserLon != null) {
      distanceFromCarMeters = Geolocator.distanceBetween(currentUserLat!, currentUserLon!, parkedLat!, parkedLon!);
        if (distanceFromCarMeters! <= 30.0) {
          _passedThroughStall = true;
        }
        if (_passedThroughStall && isCarBtConnected && distanceFromCarMeters! > 15.0) {
          _vehicularSpeedSamples = 0;
          _passedThroughStall = false;
          await _triggerCarReleased();
          return;
        }
        final double speedKmh = currentSpeedKmh;
        final bool stepsStopped = _lastHumanStepAt != null &&
            DateTime.now().difference(_lastHumanStepAt!).inSeconds >= 6;
        if (_passedThroughStall && stepsStopped && speedKmh >= 16.0 && distanceFromCarMeters! > 40.0) {
          _vehicularSpeedSamples++;
          if (_vehicularSpeedSamples >= 2) {
            _vehicularSpeedSamples = 0;
            _passedThroughStall = false;
            await _triggerCarReleased();
            return;
          }
        } else if (speedKmh < 10.0) {
          _vehicularSpeedSamples = 0;
        }
    }
    final eta = customMinutes ?? estimatedMinutesToRelease;
    _lastSentEta = eta;
    if (onManualReleaseConfirmed != null) await onManualReleaseConfirmed!(eta);
    notifyListeners();
  }

  void cancelAutoRelease() {
    _autoReleaseManager.cancelCountdown();
    _notified100m = true;
    notifyListeners();
  }

  void resetExpiredReleaseConfirmation() {
    _manualReleaseConfirmed = false;
    currentState = VehicleState.parked;
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
    homeWifiSsid = ssid.replaceAll('"', '').trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('home_wifi_ssid', homeWifiSsid!);
    _pendingWifiConfirmationSsid = null;
    _evaluateWifiStateTransition();
    _evaluateWifiStateTransition();
    notifyListeners();
  }

  Future<void> saveWifiAsWork(String ssid) async {
    workWifiSsid = ssid.replaceAll('"', '').trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('work_wifi_ssid', workWifiSsid!);
    _pendingWifiConfirmationSsid = null;
    _evaluateWifiStateTransition();
    _evaluateWifiStateTransition();
    notifyListeners();
  }

  Future<void> ignoreWifi(String ssid) async {
    final clean = ssid.replaceAll('"', '').trim();
    if (!_ignoredWifis.contains(clean)) {
      _ignoredWifis.add(clean);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ignored_wifis', _ignoredWifis);
      _pendingWifiConfirmationSsid = null;
    }
  }

  void _setupClassicBluetoothListener() {
    _classicBtChannel.setMethodCallHandler((call) async {
      if (call.method == 'onBluetoothDeviceChanged') {
        final args = Map<String, dynamic>.from(call.arguments ?? {});
        final mac = (args['mac'] as String?)?.toUpperCase() ?? '';
        final name = (args['name'] as String?) ?? 'Dispositivo BT';
        final connected = args['connected'] == true;
        if (targetCarBluetoothMac != null && mac == targetCarBluetoothMac) {
          isCarBtConnected = connected;
          if (!connected && currentState == VehicleState.driving) {
            await _recordParkingSpot('BLUETOOTH_DISCONNECT');
          } else if (connected && isCarParked) {
            await _triggerCarReleased();
          }
          notifyListeners();
        } else if (connected && mac.isNotEmpty && !_ignoredBtMacs.contains(mac) && _lastPromptedBtMac != mac) {
          _lastPromptedBtMac = mac;
          onUnknownBluetoothDetected?.call(mac, name);
        }
      }
    });
  }

  Future<void> _checkCurrentWifi({bool promptIfUnknown = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      homeWifiSsid = prefs.getString('home_wifi_ssid');
      workWifiSsid = prefs.getString('work_wifi_ssid');
      final info = NetworkInfo();
      final ssid = await info.getWifiName();
      if (ssid != null && ssid.isNotEmpty && ssid != '<unknown ssid>') {
        final clean = ssid.replaceAll('"', '').trim();
        currentConnectedWifiSsid = clean;
        _evaluateWifiStateTransition();
        if (isOnKnownPrivateWifi) {
          _pendingWifiConfirmationSsid = null;
          _autoReleaseManager.cancelCountdown();
        } else if (promptIfUnknown && !_ignoredWifis.contains(clean) && _lastPromptedWifi != clean) {
          _lastPromptedWifi = clean;
          _pendingWifiConfirmationSsid = clean;
          _autoReleaseManager.cancelCountdown();
          onUnknownWifiDetected?.call(clean);
        }
      } else {
        currentConnectedWifiSsid = null;
        _pendingWifiConfirmationSsid = null;
      }
    } catch (_) {}
  }

  void _startWifiMonitor() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) async {
      await _checkCurrentWifi(promptIfUnknown: true);
      notifyListeners();
    });
  }

  void _evaluateWifiStateTransition() {
    if (isOnKnownPrivateWifi) {
      if (currentState != VehicleState.stayAtHome) {
        currentState = VehicleState.stayAtHome;
      }
      _autoReleaseManager.cancelCountdown();
    } else if (!isOnKnownPrivateWifi && currentState == VehicleState.stayAtHome) {
      currentState = VehicleState.driving;
    }
  }

  void _startGpsStream() {
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((pos) async {
      currentUserLat = pos.latitude;
      currentUserLon = pos.longitude;
      currentSpeedKmh = max(0.0, pos.speed * 3.6);

      if (isCarParked && parkedLat != null && parkedLon != null) {
        distanceFromCarMeters = Geolocator.distanceBetween(currentUserLat!, currentUserLon!, parkedLat!, parkedLon!);
        if (distanceFromCarMeters! <= geofenceRadiusMeters && !_notified100m) {
          _notified100m = true;
          if (!isOnKnownPrivateWifi && _pendingWifiConfirmationSsid == null) { _autoReleaseManager.startCountdownIfBetaTester(); }
          await onApproachingCar100m(estimatedMinutesToRelease);
        } else if (distanceFromCarMeters! > 130.0) {
          _notified100m = false; _passedThroughStall = false; _vehicularSpeedSamples = 0; _passedThroughStall = false; _vehicularSpeedSamples = 0;
          _autoReleaseManager.cancelCountdown();
        }
        if (_manualReleaseConfirmed && onEtaUpdated != null) {
          final eta = estimatedMinutesToRelease;
          if (_lastSentEta != eta) {
            _lastSentEta = eta;
            await onEtaUpdated!(eta);
          }
        }
      } else if (currentState == VehicleState.driving && currentSpeedKmh < 2.0 && _gyroTransitionDetected && !isCarBtConnected) {
        await _recordParkingSpot('SENSOR_FUSION');
      }
      notifyListeners();
    });
  }

  void _startGyroscopeStream() {
    _gyroSub = gyroscopeEventStream().listen((event) {
      gyroscopeMagnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (gyroscopeMagnitude > 2.2) {
        _gyroTransitionDetected = true;
      }
    });
  }

  void _startPedometerStreams() {
    _pedStatusSub = Pedometer.pedestrianStatusStream.listen((status) {
      pedestrianStatus = status.status;
      notifyListeners();
    }, onError: (_) {});

    _stepCountSub = Pedometer.stepCountStream.listen((event) {
      _initialStepCount ??= event.steps;
      sessionSteps = event.steps - _initialStepCount!;
      notifyListeners();
    }, onError: (_) {});
  }

  void _startBleBluetoothMonitor() {
    _btCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        final connected = FlutterBluePlus.connectedDevices;
        if (targetCarBluetoothMac != null) {
          final found = connected.any((d) => d.remoteId.str.toUpperCase() == targetCarBluetoothMac);
          if (found && isCarParked) {
            isCarBtConnected = true;
            await _triggerCarReleased();
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _recordParkingSpot(String method) async {
    if (!autoShareEnabled) {
      if (!_autoShareSkippedNotified) {
        _autoShareSkippedNotified = true;
        onAutoShareSkipped?.call('Condivisione automatica disattivata');
      }
      return;
    }
    if (isOnKnownPrivateWifi) return;
    if (currentUserLat == null || currentUserLon == null) {
      try {
        final pos = await Geolocator.getCurrentPosition();
        currentUserLat = pos.latitude;
        currentUserLon = pos.longitude;
      } catch (_) {
        currentUserLat ??= 40.8518;
        currentUserLon ??= 14.2681;
      }
    }
    parkedLat = currentUserLat;
    parkedLon = currentUserLon;
    distanceFromCarMeters = 0.0;
    currentState = VehicleState.parked;
    _notified100m = false; _passedThroughStall = false; _vehicularSpeedSamples = 0; _passedThroughStall = false; _vehicularSpeedSamples = 0;
    _manualReleaseConfirmed = false;
    _gyroTransitionDetected = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('parked_lat', parkedLat!);
    await prefs.setDouble('parked_lon', parkedLon!);

    await onCarParked(parkedLat!, parkedLon!, method);
    notifyListeners();
  }

  Future<void> _triggerCarReleased() async {
    _autoReleaseManager.cancelCountdown();
    parkedLat = null;
    parkedLon = null;
    distanceFromCarMeters = null;
    currentState = VehicleState.driving;
    _notified100m = false; _passedThroughStall = false; _vehicularSpeedSamples = 0; _passedThroughStall = false; _vehicularSpeedSamples = 0;
    _manualReleaseConfirmed = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('parked_lat');
    await prefs.remove('parked_lon');

    await onCarReleased();
    notifyListeners();
  }

  Future<void> simulateParkHere() async {
    await _recordParkingSpot('SIMULATION');
  }

  Future<void> simulateApproach100m() async {
    if (!isCarParked) await simulateParkHere();
    distanceFromCarMeters = 45.0;
    _notified100m = true;
    if (!isOnKnownPrivateWifi && _pendingWifiConfirmationSsid == null) { _autoReleaseManager.startCountdownIfBetaTester(); }
    await onApproachingCar100m(estimatedMinutesToRelease);
    notifyListeners();
  }

  Future<void> simulateDeparture() async {
    await _triggerCarReleased();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _gyroSub?.cancel();
    _pedStatusSub?.cancel();
    _stepCountSub?.cancel();
    _connectivitySub?.cancel();
    _btCheckTimer?.cancel();
    _autoReleaseManager.dispose();
    super.dispose();
  }
}
