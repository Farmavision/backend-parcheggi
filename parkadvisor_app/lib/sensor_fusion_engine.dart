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

enum UserActivityState {
  atHome,      // "A casa"
  atWork,      // "Al lavoro"
  still,       // "Attualmente fermo"
  moving,      // "In Movimento"
  inCar,       // "In Auto"
}

class _GpsWindowSample {
  final DateTime timestamp;
  final double lat;
  final double lon;
  final double speedKmh;
  final double accuracy;
  _GpsWindowSample(this.timestamp, this.lat, this.lon, this.speedKmh, this.accuracy);
}

class SensorFusionEngine extends ChangeNotifier {
  static final Completer<void> initialPermissionsCompleter = Completer<void>();
  static const MethodChannel _classicBtChannel = MethodChannel('com.parknow.app/classic_bt');

  VehicleState currentState = VehicleState.driving;
  UserActivityState userActivityState = UserActivityState.still;

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
  double lastWindowAvgSpeedKmh = 0.0;
  double lastWindowInstSpeedKmh = 0.0;
  double gyroscopeMagnitude = 0.0;
  String pedestrianStatus = 'unknown';
  int sessionSteps = 0;
  int? _initialStepCount;
  bool isCarBtConnected = false;

  // Parametri algoritmo stato utente
  int tGpsNoStepSec = 30; // Tgps_senzapasso parametrico (default 30s)
  bool isHighAccuracyGpsActive = false;
  int gpsWindowRemainingSec = 0;
  int _noStepGpsCycleCount = 0; // 0 = primo ciclo 30s, 1 = ciclo di conferma 30s
  bool _gpsRestingAfterNoStepAnalysis = false;
  bool _carPromptShownInCurrentBout = false;

  final List<_GpsWindowSample> _gpsWindowSamples = [];
  Timer? _gpsWindowTimer;
  Timer? _noStepIdleCheckTimer;

  // Filtro gravità accelerometro per risveglio inerziale affidabile dallo stato "Attualmente fermo"
  double _gravX = 0.0;
  double _gravY = 0.0;
  double _gravZ = 0.0;
  bool _gravInitialized = false;
  int _inertialWakeupHits = 0;
  DateTime? _lastInertialHitAt;

  final Future<void> Function(double lat, double lon, String method) onCarParked;
  final Future<void> Function(int estimatedMinutes) onApproachingCar100m;
  final Future<void> Function(int estimatedMinutes)? onManualReleaseConfirmed;
  final Future<void> Function(int estimatedMinutes)? onEtaUpdated;
  final Future<void> Function() onCarReleased;
  final void Function(String reason)? onAutoShareSkipped;
  final void Function(String ssid)? onUnknownWifiDetected;
  final void Function(String mac, String name)? onUnknownBluetoothDetected;
  final VoidCallback? onPromptAreYouInCar;

  StreamSubscription<Position>? _posSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<PedestrianStatus>? _pedStatusSub;
  StreamSubscription<StepCount>? _stepCountSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _btCheckTimer;

  bool _notified100m = false;
  double geofenceRadiusMeters = 100.0;
  bool _passedThroughStall = false;
  int _vehicularSpeedSamples = 0;
  DateTime? _lastHumanStepAt;
  bool _manualReleaseConfirmed = false;
  bool _autoShareSkippedNotified = false;
  int? _lastSentEta;

  late AutoReleaseManager _autoReleaseManager;

  bool get isCarParked => parkedLat != null && parkedLon != null;
  bool get isManualReleaseConfirmed => _manualReleaseConfirmed;

  bool get _isStepDetected {
    if (pedestrianStatus == 'walking') return true;
    if (_lastHumanStepAt != null && DateTime.now().difference(_lastHumanStepAt!).inSeconds <= 5) {
      return true;
    }
    return false;
  }

  String get userActivityLabel {
    switch (userActivityState) {
      case UserActivityState.atHome:
        return 'A casa';
      case UserActivityState.atWork:
        return 'Al lavoro';
      case UserActivityState.still:
        return 'Attualmente fermo';
      case UserActivityState.moving:
        return 'In Movimento';
      case UserActivityState.inCar:
        return 'In Auto';
    }
  }

  String get gpsPowerStateLabel {
    if (isHighAccuracyGpsActive) {
      final cycleText = _noStepGpsCycleCount > 0 ? 'conferma' : 'analisi';
      return 'GPS alta precisione ($cycleText ${gpsWindowRemainingSec}s)';
    }
    return 'GPS in risparmio';
  }

  String get statusMessage {
    final segments = <String>[gpsPowerStateLabel];
    if (userActivityState != UserActivityState.atHome && userActivityState != UserActivityState.atWork) {
      segments.add('Vel: ${currentSpeedKmh.toStringAsFixed(1)} km/h | Passi: $sessionSteps');
    }
    if (isCarParked) {
      final dist = distanceFromCarMeters != null ? ' (${distanceFromCarMeters!.round()}m)' : '';
      segments.add('Parcheggio attivo$dist');
    }
    return segments.join(' • ');
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
    this.onPromptAreYouInCar,
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
    tGpsNoStepSec = (prefs.getInt('tgps_senzapasso_sec') ?? 30).clamp(10, 180);
    geofenceRadiusMeters = (prefs.getInt('geofence_radius_m') ?? 100).toDouble();
    _ignoredWifis = prefs.getStringList('ignored_wifis') ?? [];
    _ignoredBtMacs = prefs.getStringList('ignored_bt_macs') ?? [];

    if (parkedLat != null && parkedLon != null) currentState = VehicleState.parked;

    _setupClassicBluetoothListener();
    _startGyroscopeStream();
    _startInertialWakeupMonitor();
    _startPedometerStreams();
    _startBleBluetoothMonitor();
    await _checkCurrentWifi(promptIfUnknown: true);
    _startWifiMonitor();
    if (!initialPermissionsCompleter.isCompleted) initialPermissionsCompleter.complete();
    notifyListeners();
  }

  Future<void> reloadUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    autoShareEnabled = prefs.getBool('auto_share_enabled') ?? true;
    _autoShareSkippedNotified = false;
    final btMac = prefs.getString('car_bt_mac');
    if (btMac != null && btMac.isNotEmpty) targetCarBluetoothMac = btMac.toUpperCase();
    final homeWifi = prefs.getString('home_wifi_ssid');
    if (homeWifi != null && homeWifi.isNotEmpty) homeWifiSsid = homeWifi;
    final workWifi = prefs.getString('work_wifi_ssid');
    if (workWifi != null && workWifi.isNotEmpty) workWifiSsid = workWifi;
    tGpsNoStepSec = (prefs.getInt('tgps_senzapasso_sec') ?? 30).clamp(10, 180);
    geofenceRadiusMeters = (prefs.getInt('geofence_radius_m') ?? 100).toDouble();
    _evaluateWifiStateTransition();
    notifyListeners();
  }

  Future<void> confirmUserInCarFromPrompt() async {
    userActivityState = UserActivityState.inCar;
    _gpsRestingAfterNoStepAnalysis = true;
    _noStepGpsCycleCount = 0;
    _stopHighAccuracyGpsWindow();
    notifyListeners();
  }

  Future<void> confirmParkingLeftFromPrompt() async {
    userActivityState = UserActivityState.inCar;
    _gpsRestingAfterNoStepAnalysis = true;
    _stopHighAccuracyGpsWindow();
    if (isCarParked) {
      await _triggerCarReleased();
    } else {
      notifyListeners();
    }
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
    currentState = isCarParked ? VehicleState.parked : VehicleState.driving;
    notifyListeners();
  }

  Future<void> setCarBluetoothDevice(String mac, String name) async {
    targetCarBluetoothMac = mac.toUpperCase();
    targetCarBluetoothName = name;
    isCarBtConnected = true;
    userActivityState = UserActivityState.inCar;
    _gpsRestingAfterNoStepAnalysis = true;
    _stopHighAccuracyGpsWindow();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('car_bt_mac', targetCarBluetoothMac!);
    await prefs.setString('car_bt_name', name);
    if (isCarParked) {
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
    notifyListeners();
  }

  Future<void> saveWifiAsWork(String ssid) async {
    workWifiSsid = ssid.replaceAll('"', '').trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('work_wifi_ssid', workWifiSsid!);
    _pendingWifiConfirmationSsid = null;
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
          if (!connected) {
            if (!isCarParked && !isOnKnownPrivateWifi) {
              await _recordParkingSpot('BLUETOOTH_DISCONNECT');
            }
            _gpsRestingAfterNoStepAnalysis = false;
            _carPromptShownInCurrentBout = false;
            _evaluateNoFixedWifiAlgorithm();
          } else {
            userActivityState = UserActivityState.inCar;
            _gpsRestingAfterNoStepAnalysis = true;
            _stopHighAccuracyGpsWindow();
            if (isCarParked) {
              await _triggerCarReleased();
            }
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
      tGpsNoStepSec = (prefs.getInt('tgps_senzapasso_sec') ?? 30).clamp(10, 180);
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
        _evaluateWifiStateTransition();
        if (isCarParked && distanceFromCarMeters != null && distanceFromCarMeters! <= geofenceRadiusMeters && !_notified100m) {
          _notified100m = true;
          _autoReleaseManager.startCountdownIfBetaTester();
          await onApproachingCar100m(estimatedMinutesToRelease);
        }
      }
    } catch (_) {}
  }

  void _startWifiMonitor() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) async {
      await _checkCurrentWifi(promptIfUnknown: true);
      notifyListeners();
    });
  }

  // Punto 1: Connesso alla Wi-Fi fissa di casa o lavoro -> "A casa" o "Al lavoro" + GPS in risparmio
  void _evaluateWifiStateTransition() {
    if (isOnKnownPrivateWifi) {
      final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
      userActivityState = (workWifiSsid != null && clean == workWifiSsid)
          ? UserActivityState.atWork
          : UserActivityState.atHome;
      if (!isCarParked) {
        currentState = VehicleState.stayAtHome;
      }
      _autoReleaseManager.cancelCountdown();
      _noStepGpsCycleCount = 0;
      _gpsRestingAfterNoStepAnalysis = false;
      _carPromptShownInCurrentBout = false;
      _stopHighAccuracyGpsWindow();
    } else {
      if (currentState == VehicleState.stayAtHome) {
        currentState = isCarParked ? VehicleState.parked : VehicleState.driving;
      }
      _evaluateNoFixedWifiAlgorithm();
    }
  }

  // Punti 2 e 3: Non connesso a Wi-Fi fissa -> analisi passi / finestra GPS Tgps_senzapasso (30s)
  void _evaluateNoFixedWifiAlgorithm() {
    if (isOnKnownPrivateWifi) return;

    // Punto 3: Presenza di passo -> stato "In Movimento" senza attivazione di analisi GPS accurata
    if (_isStepDetected) {
      userActivityState = UserActivityState.moving;
      _noStepGpsCycleCount = 0;
      _gpsRestingAfterNoStepAnalysis = false;
      _stopHighAccuracyGpsWindow();
      return;
    }

    // Se già confermato In Auto con BT auto connesso, resta "In Auto" con GPS in risparmio
    if (userActivityState == UserActivityState.inCar && isCarBtConnected) {
      _stopHighAccuracyGpsWindow();
      return;
    }

    // Punto 2: Mancanza di passo -> attiva GPS accurato per Tgps_senzapasso (30s)
    if (!isHighAccuracyGpsActive && !_gpsRestingAfterNoStepAnalysis) {
      _startNoStepGpsWindow(cycleIndex: 0);
    }
  }

  void _startNoStepGpsWindow({required int cycleIndex}) {
    if (isOnKnownPrivateWifi || _isStepDetected) return;

    _stopHighAccuracyGpsWindow();
    isHighAccuracyGpsActive = true;
    _noStepGpsCycleCount = cycleIndex;
    gpsWindowRemainingSec = tGpsNoStepSec;
    _gpsWindowSamples.clear();
    currentSpeedKmh = 0.0;

    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
    ).listen((pos) async {
      currentUserLat = pos.latitude;
      currentUserLon = pos.longitude;
      final instKmh = max(0.0, pos.speed * 3.6);
      currentSpeedKmh = instKmh;

      if (pos.accuracy <= 25.0 || _gpsWindowSamples.isEmpty) {
        _gpsWindowSamples.add(
          _GpsWindowSample(DateTime.now(), pos.latitude, pos.longitude, instKmh, pos.accuracy),
        );
      }

      if (isCarParked && parkedLat != null && parkedLon != null) {
        distanceFromCarMeters = Geolocator.distanceBetween(currentUserLat!, currentUserLon!, parkedLat!, parkedLon!);
        if (distanceFromCarMeters! <= geofenceRadiusMeters && !_notified100m && !isOnKnownPrivateWifi && _pendingWifiConfirmationSsid == null) {
          _notified100m = true;
          _autoReleaseManager.startCountdownIfBetaTester();
          await onApproachingCar100m(estimatedMinutesToRelease);
        } else if (distanceFromCarMeters! > 130.0) {
          _notified100m = false;
          _passedThroughStall = false;
          _vehicularSpeedSamples = 0;
          _autoReleaseManager.cancelCountdown();
        }
        if (_manualReleaseConfirmed && onEtaUpdated != null) {
          final eta = estimatedMinutesToRelease;
          if (_lastSentEta != eta) {
            _lastSentEta = eta;
            await onEtaUpdated!(eta);
          }
        }
      }
      notifyListeners();
    });

    _gpsWindowTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (isOnKnownPrivateWifi || _isStepDetected) {
        timer.cancel();
        _evaluateNoFixedWifiAlgorithm();
        notifyListeners();
        return;
      }
      gpsWindowRemainingSec--;
      if (gpsWindowRemainingSec <= 0) {
        timer.cancel();
        await _evaluateNoStepGpsWindowResult();
      } else {
        notifyListeners();
      }
    });

    notifyListeners();
  }

  Future<void> _evaluateNoStepGpsWindowResult() async {
    double vMedia = 0.0;
    double vIst = currentSpeedKmh;

    if (_gpsWindowSamples.length >= 2) {
      final first = _gpsWindowSamples.first;
      final last = _gpsWindowSamples.last;
      final elapsedSec = max(1, last.timestamp.difference(first.timestamp).inSeconds);
      final netMeters = Geolocator.distanceBetween(first.lat, first.lon, last.lat, last.lon);
      final netAvgKmh = (netMeters / elapsedSec) * 3.6;
      final dopplerAvgKmh = _gpsWindowSamples.map((s) => s.speedKmh).reduce((a, b) => a + b) / _gpsWindowSamples.length;
      // Filtra rimbalzi GPS da fermo: spostamento netto <= 8m in 30s (< 1 km/h) usa la media Doppler
      vMedia = netMeters > 8.0 ? max(netAvgKmh, dopplerAvgKmh) : dopplerAvgKmh;

      final tail = _gpsWindowSamples.length >= 2
          ? _gpsWindowSamples.sublist(_gpsWindowSamples.length - 2)
          : _gpsWindowSamples;
      vIst = tail.map((s) => s.speedKmh).reduce((a, b) => a + b) / tail.length;
    } else if (_gpsWindowSamples.length == 1) {
      vMedia = _gpsWindowSamples.first.speedKmh;
      vIst = _gpsWindowSamples.first.speedKmh;
    }

    lastWindowAvgSpeedKmh = vMedia;
    lastWindowInstSpeedKmh = vIst;
    currentSpeedKmh = vIst;

    // Ramo 2a: v_media <= 1 km/h -> stato "Attualmente fermo", poi GPS in risparmio
    if (vMedia <= 1.0) {
      _stopHighAccuracyGpsWindow();
      userActivityState = UserActivityState.still;
      _noStepGpsCycleCount = 0;
      _gpsRestingAfterNoStepAnalysis = true;
      _carPromptShownInCurrentBout = false;
      notifyListeners();
      return;
    }

    // Ramo 2b: v_media > 1 km/h e v_ist <= 10 km/h -> stato "In Movimento", secondo ciclo di 30s poi riposo
    if (vIst <= 10.0) {
      userActivityState = UserActivityState.moving;
      if (_noStepGpsCycleCount == 0) {
        _startNoStepGpsWindow(cycleIndex: 1);
      } else {
        _stopHighAccuracyGpsWindow();
        _noStepGpsCycleCount = 0;
        _gpsRestingAfterNoStepAnalysis = true;
        notifyListeners();
      }
      return;
    }

    // Ramo 2c: v_media > 1 km/h e v_ist > 10 km/h -> verifica connessione Bluetooth auto
    _stopHighAccuracyGpsWindow();
    _noStepGpsCycleCount = 0;
    _gpsRestingAfterNoStepAnalysis = true;

    if (isCarBtConnected) {
      userActivityState = UserActivityState.inCar;
      if (isCarParked) {
        await _triggerCarReleased();
      } else {
        notifyListeners();
      }
    } else {
      userActivityState = UserActivityState.moving;
      if (!_carPromptShownInCurrentBout) {
        _carPromptShownInCurrentBout = true;
        onPromptAreYouInCar?.call();
      }
      notifyListeners();
    }
  }

  void _stopHighAccuracyGpsWindow() {
    _gpsWindowTimer?.cancel();
    _gpsWindowTimer = null;
    _posSub?.cancel();
    _posSub = null;
    isHighAccuracyGpsActive = false;
    gpsWindowRemainingSec = 0;
  }

  void _startGyroscopeStream() {
    _gyroSub = gyroscopeEventStream().listen((event) {
      gyroscopeMagnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    });
  }

  // Risveglio affidabile dallo stato "Attualmente fermo" (o riposo post-ciclo) tramite accelerometro lineare
  void _startInertialWakeupMonitor() {
    _accelSub = accelerometerEventStream().listen((event) {
      if (!_gravInitialized) {
        _gravX = event.x;
        _gravY = event.y;
        _gravZ = event.z;
        _gravInitialized = true;
        return;
      }
      _gravX = 0.9 * _gravX + 0.1 * event.x;
      _gravY = 0.9 * _gravY + 0.1 * event.y;
      _gravZ = 0.9 * _gravZ + 0.1 * event.z;
      final lx = event.x - _gravX;
      final ly = event.y - _gravY;
      final lz = event.z - _gravZ;
      final linearAcc = sqrt(lx * lx + ly * ly + lz * lz);

      if (!isOnKnownPrivateWifi && !_isStepDetected && !isHighAccuracyGpsActive && _gpsRestingAfterNoStepAnalysis) {
        if (linearAcc > 1.35) {
          final now = DateTime.now();
          if (_lastInertialHitAt == null || now.difference(_lastInertialHitAt!).inSeconds > 3) {
            _inertialWakeupHits = 1;
          } else {
            _inertialWakeupHits++;
          }
          _lastInertialHitAt = now;

          if (_inertialWakeupHits >= 2) {
            _inertialWakeupHits = 0;
            _gpsRestingAfterNoStepAnalysis = false;
            _startNoStepGpsWindow(cycleIndex: 0);
          }
        }
      }
    });
  }

  void _startPedometerStreams() {
    _pedStatusSub = Pedometer.pedestrianStatusStream.listen((status) {
      final previous = pedestrianStatus;
      pedestrianStatus = status.status;
      if (!isOnKnownPrivateWifi) {
        if (pedestrianStatus == 'walking') {
          _evaluateNoFixedWifiAlgorithm();
        } else if (previous == 'walking' && pedestrianStatus == 'stopped') {
          _gpsRestingAfterNoStepAnalysis = false;
          _evaluateNoFixedWifiAlgorithm();
        }
      }
      notifyListeners();
    }, onError: (_) {});

    _stepCountSub = Pedometer.stepCountStream.listen((event) {
      _initialStepCount ??= event.steps;
      final updatedSteps = event.steps - _initialStepCount!;
      if (updatedSteps > sessionSteps) {
        _lastHumanStepAt = DateTime.now();
        _noStepIdleCheckTimer?.cancel();
        _noStepIdleCheckTimer = Timer(const Duration(seconds: 6), () {
          if (!isOnKnownPrivateWifi && !_isStepDetected) {
            _gpsRestingAfterNoStepAnalysis = false;
            _evaluateNoFixedWifiAlgorithm();
            notifyListeners();
          }
        });
        if (!isOnKnownPrivateWifi) {
          _evaluateNoFixedWifiAlgorithm();
        }
      }
      sessionSteps = updatedSteps;
      notifyListeners();
    }, onError: (_) {});
  }

  void _startBleBluetoothMonitor() {
    _btCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        final connected = FlutterBluePlus.connectedDevices;
        if (targetCarBluetoothMac != null) {
          final found = connected.any((d) => d.remoteId.str.toUpperCase() == targetCarBluetoothMac);
          if (found) {
            isCarBtConnected = true;
            userActivityState = UserActivityState.inCar;
            _gpsRestingAfterNoStepAnalysis = true;
            _stopHighAccuracyGpsWindow();
            if (isCarParked) {
              await _triggerCarReleased();
            } else {
              notifyListeners();
            }
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _recordParkingSpot(String method) async {
    await _checkCurrentWifi(promptIfUnknown: false);
    if (!autoShareEnabled) {
      if (!_autoShareSkippedNotified) {
        _autoShareSkippedNotified = true;
        onAutoShareSkipped?.call('Condivisione automatica disattivata');
      }
      return;
    }
    if (isOnKnownPrivateWifi && method != 'SIMULATION') return;
    if (currentUserLat == null || currentUserLon == null) {
      try {
        final pos = isOnKnownPrivateWifi
            ? (await Geolocator.getLastKnownPosition() ??
                await Geolocator.getCurrentPosition(
                  desiredAccuracy: LocationAccuracy.low,
                ))
            : await Geolocator.getCurrentPosition();
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
    _notified100m = false;
    _passedThroughStall = false;
    _vehicularSpeedSamples = 0;
    _manualReleaseConfirmed = false;
    _carPromptShownInCurrentBout = false;

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
    currentState = isOnKnownPrivateWifi ? VehicleState.stayAtHome : VehicleState.driving;
    _notified100m = false;
    _passedThroughStall = false;
    _vehicularSpeedSamples = 0;
    _manualReleaseConfirmed = false;
    _carPromptShownInCurrentBout = false;

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
    if (!isOnKnownPrivateWifi && _pendingWifiConfirmationSsid == null) {
      _autoReleaseManager.startCountdownIfBetaTester();
    }
    await onApproachingCar100m(estimatedMinutesToRelease);
    notifyListeners();
  }

  Future<void> simulateDeparture() async {
    await _triggerCarReleased();
  }

  @override
  void dispose() {
    _stopHighAccuracyGpsWindow();
    _noStepIdleCheckTimer?.cancel();
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _pedStatusSub?.cancel();
    _stepCountSub?.cancel();
    _connectivitySub?.cancel();
    _btCheckTimer?.cancel();
    _autoReleaseManager.dispose();
    super.dispose();
  }
}
