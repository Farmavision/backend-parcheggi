import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
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

class SensorFusionEngine extends ChangeNotifier {
  static final Completer<void> initialPermissionsCompleter = Completer<void>();
  static const MethodChannel _classicBtChannel = MethodChannel('com.parknow.app/classic_bt');
  static const MethodChannel _bgServiceChannel = MethodChannel('parknow/bg_service');

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
  int sessionSteps = 0;
  bool isCarBtConnected = false;

  int tGpsNoStepSec = 30;
  bool isHighAccuracyGpsActive = false;
  int gpsWindowRemainingSec = 0;
  int _noStepGpsCycleCount = 0;
  bool _inCarPromptDeliveredInUi = false;

  final Future<void> Function(double lat, double lon, String method) onCarParked;
  final Future<void> Function(int estimatedMinutes) onApproachingCar100m;
  final Future<void> Function(int estimatedMinutes)? onManualReleaseConfirmed;
  final Future<void> Function(int estimatedMinutes)? onEtaUpdated;
  final Future<void> Function() onCarReleased;
  final void Function(String reason)? onAutoShareSkipped;
  final void Function(String ssid)? onUnknownWifiDetected;
  final void Function(String mac, String name)? onUnknownBluetoothDetected;
  final VoidCallback? onPromptAreYouInCar;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _btCheckTimer;
  Timer? _nativeSyncFallbackTimer;

  double geofenceRadiusMeters = 100.0;
  bool _manualReleaseConfirmed = false;
  bool _autoShareSkippedNotified = false;

  late AutoReleaseManager _autoReleaseManager;

  bool get isCarParked => parkedLat != null && parkedLon != null;
  bool get isManualReleaseConfirmed => _manualReleaseConfirmed;

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
    return (homeWifiSsid != null && clean.toLowerCase() == homeWifiSsid!.toLowerCase()) ||
        (workWifiSsid != null && clean.toLowerCase() == workWifiSsid!.toLowerCase());
  }

  UserActivityState _parseNativeState(String? code) {
    switch (code) {
      case 'atHome':
        return UserActivityState.atHome;
      case 'atWork':
        return UserActivityState.atWork;
      case 'moving':
        return UserActivityState.moving;
      case 'inCar':
        return UserActivityState.inCar;
      case 'still':
      default:
        return UserActivityState.still;
    }
  }

  Future<void> syncFromNativeBackgroundService() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      await _checkCurrentWifi(promptIfUnknown: false);

      final nativeState = prefs.getString('native_user_state');
      isHighAccuracyGpsActive = prefs.getBool('native_gps_active') ?? false;
      gpsWindowRemainingSec = prefs.getInt('native_gps_remaining_sec') ?? 0;
      _noStepGpsCycleCount = prefs.getInt('native_gps_cycle') ?? 0;
      currentSpeedKmh = prefs.getDouble('native_speed_kmh') ?? 0.0;
      sessionSteps = prefs.getInt('native_session_steps') ?? 0;
      if (prefs.containsKey('native_car_bt_connected')) {
        isCarBtConnected = prefs.getBool('native_car_bt_connected') ?? isCarBtConnected;
      }

      if (isOnKnownPrivateWifi) {
        final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
        final isWork = workWifiSsid != null && clean.toLowerCase() == workWifiSsid!.toLowerCase();
        userActivityState = isWork ? UserActivityState.atWork : UserActivityState.atHome;
        isHighAccuracyGpsActive = false;
        gpsWindowRemainingSec = 0;
        final expectedNative = isWork ? 'atWork' : 'atHome';
        if (nativeState != expectedNative) {
          await prefs.setString('native_user_state', expectedNative);
          await prefs.setBool('native_gps_active', false);
        }
      } else if (nativeState != null) {
        userActivityState = _parseNativeState(nativeState);
      }

      parkedLat = prefs.getDouble('parked_lat');
      parkedLon = prefs.getDouble('parked_lon');
      if (parkedLat != null && parkedLon != null) {
        if (currentState != VehicleState.leavingSoon) {
          currentState = VehicleState.parked;
        }
      } else if (currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) {
        currentState = isOnKnownPrivateWifi ? VehicleState.stayAtHome : VehicleState.driving;
      }

      final pendingInCar = prefs.getBool('native_prompt_in_car') ?? false;
      if (pendingInCar && !_inCarPromptDeliveredInUi) {
        _inCarPromptDeliveredInUi = true;
        await prefs.setBool('native_prompt_in_car', false);
        onPromptAreYouInCar?.call();
      } else if (!pendingInCar) {
        _inCarPromptDeliveredInUi = false;
      }

      notifyListeners();
    } catch (_) {}
  }

  Future<void> initialize() async {
    await [Permission.activityRecognition, Permission.bluetoothConnect, Permission.locationWhenInUse, Permission.notification].request();

    _bgServiceChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNativeStateUpdated') {
        await syncFromNativeBackgroundService();
      }
    });

    try {
      await _bgServiceChannel.invokeMethod('startMonitorService');
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
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
    _startBleBluetoothMonitor();
    await _checkCurrentWifi(promptIfUnknown: true);
    _startWifiMonitor();
    await syncFromNativeBackgroundService();

    _nativeSyncFallbackTimer?.cancel();
    _nativeSyncFallbackTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      syncFromNativeBackgroundService();
    });

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
    await syncFromNativeBackgroundService();
  }

  Future<void> confirmUserInCarFromPrompt() async {
    userActivityState = UserActivityState.inCar;
    isHighAccuracyGpsActive = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('native_user_state', 'inCar');
    await prefs.setBool('native_prompt_in_car', false);
    try {
      await _bgServiceChannel.invokeMethod('confirmInCar');
    } catch (_) {}
    notifyListeners();
  }

  Future<void> dismissUserInCarPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('native_prompt_in_car', false);
    try {
      await _bgServiceChannel.invokeMethod('denyInCar');
    } catch (_) {}
  }

  Future<void> confirmParkingLeftFromPrompt() async {
    await confirmUserInCarFromPrompt();
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
    final eta = customMinutes ?? estimatedMinutesToRelease;
    if (onManualReleaseConfirmed != null) await onManualReleaseConfirmed!(eta);
    notifyListeners();
  }

  void cancelAutoRelease() {
    _autoReleaseManager.cancelCountdown();
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
    isHighAccuracyGpsActive = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('car_bt_mac', targetCarBluetoothMac!);
    await prefs.setString('car_bt_name', name);
    await prefs.setString('native_user_state', 'inCar');
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
    final clean = ssid.replaceAll('"', '').trim();
    homeWifiSsid = clean;
    currentConnectedWifiSsid = clean;
    userActivityState = UserActivityState.atHome;
    isHighAccuracyGpsActive = false;
    gpsWindowRemainingSec = 0;
    _pendingWifiConfirmationSsid = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('home_wifi_ssid', clean);
    await prefs.setString('ui_detected_wifi_ssid', clean);
    await prefs.setString('native_user_state', 'atHome');
    await prefs.setBool('native_gps_active', false);
    notifyListeners();
    await syncFromNativeBackgroundService();
  }

  Future<void> saveWifiAsWork(String ssid) async {
    final clean = ssid.replaceAll('"', '').trim();
    workWifiSsid = clean;
    currentConnectedWifiSsid = clean;
    userActivityState = UserActivityState.atWork;
    isHighAccuracyGpsActive = false;
    gpsWindowRemainingSec = 0;
    _pendingWifiConfirmationSsid = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('work_wifi_ssid', clean);
    await prefs.setString('ui_detected_wifi_ssid', clean);
    await prefs.setString('native_user_state', 'atWork');
    await prefs.setBool('native_gps_active', false);
    notifyListeners();
    await syncFromNativeBackgroundService();
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
          if (!connected && !isCarParked && !isOnKnownPrivateWifi) {
            await _recordParkingSpot('BLUETOOTH_DISCONNECT');
          } else if (connected) {
            userActivityState = UserActivityState.inCar;
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
      final info = NetworkInfo();
      final ssid = await info.getWifiName();
      if (ssid != null && ssid.isNotEmpty && ssid != '<unknown ssid>') {
        final clean = ssid.replaceAll('"', '').trim();
        currentConnectedWifiSsid = clean;
        if (prefs.getString('ui_detected_wifi_ssid') != clean) {
          await prefs.setString('ui_detected_wifi_ssid', clean);
        }
        if (isOnKnownPrivateWifi) {
          _pendingWifiConfirmationSsid = null;
          _autoReleaseManager.cancelCountdown();
        } else if (promptIfUnknown && !_ignoredWifis.contains(clean) && _lastPromptedWifi != clean) {
          _lastPromptedWifi = clean;
          _pendingWifiConfirmationSsid = clean;
          onUnknownWifiDetected?.call(clean);
        }
      } else {
        currentConnectedWifiSsid = null;
        _pendingWifiConfirmationSsid = null;
        if (prefs.containsKey('ui_detected_wifi_ssid')) {
          await prefs.remove('ui_detected_wifi_ssid');
        }
      }
    } catch (_) {}
  }

  void _startWifiMonitor() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) async {
      await _checkCurrentWifi(promptIfUnknown: true);
      await syncFromNativeBackgroundService();
    });
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
    _manualReleaseConfirmed = false;

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
    _nativeSyncFallbackTimer?.cancel();
    _connectivitySub?.cancel();
    _btCheckTimer?.cancel();
    _autoReleaseManager.dispose();
    super.dispose();
  }
}
