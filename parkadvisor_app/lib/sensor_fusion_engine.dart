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
  int nPassi = 50;
  int t0PassiSec = 30;
  int anchoredPendingSteps = 0;
  bool isHighAccuracyGpsActive = false;
  int gpsWindowRemainingSec = 0;
  int _noStepGpsCycleCount = 0;
  bool _inCarPromptDeliveredInUi = false;
  bool _releasePromptDeliveredInUi = false;
  bool _nativeOnFixedWifi = false;
  bool _isAppInForeground = true;

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
    final activelyOnFixedWifi = _nativeOnFixedWifi || isOnKnownPrivateWifi;
    if (!activelyOnFixedWifi) {
      final isAnchoredPlace = userActivityState == UserActivityState.atHome || userActivityState == UserActivityState.atWork;
      final stepText = isAnchoredPlace
          ? 'Passi: $anchoredPendingSteps/$nPassi'
          : 'Passi: $sessionSteps';
      segments.add('Vel: ${currentSpeedKmh.toStringAsFixed(1)} km/h | $stepText');
    }
    if (isCarParked) {
      final dist = distanceFromCarMeters != null ? ' (${distanceFromCarMeters!.round()}m)' : '';
      segments.add('Parcheggio attivo$dist');
    } else {
      segments.add('Nessun parcheggio attivo');
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
    return (homeWifiSsid != null && homeWifiSsid!.isNotEmpty && clean.toLowerCase() == homeWifiSsid!.toLowerCase()) ||
        (workWifiSsid != null && workWifiSsid!.isNotEmpty && clean.toLowerCase() == workWifiSsid!.toLowerCase());
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

  void setAppForegroundState(bool inForeground) {
    _isAppInForeground = inForeground;
    if (inForeground) {
      _startFallbackSyncTimer();
      syncFromNativeBackgroundService();
    } else {
      _nativeSyncFallbackTimer?.cancel();
      _nativeSyncFallbackTimer = null;
    }
  }

  void _startFallbackSyncTimer() {
    _nativeSyncFallbackTimer?.cancel();
    _nativeSyncFallbackTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isAppInForeground) {
        syncFromNativeBackgroundService();
      }
    });
  }

  void _applyNativeSnapshotMap(Map<String, dynamic> snap) {
    final nativeHome = (snap['homeWifiSsid'] as String?)?.trim() ?? '';
    if (nativeHome.isNotEmpty && homeWifiSsid != nativeHome) {
      homeWifiSsid = nativeHome;
      SharedPreferences.getInstance().then((p) => p.setString('home_wifi_ssid', nativeHome));
    }
    final nativeWork = (snap['workWifiSsid'] as String?)?.trim() ?? '';
    if (nativeWork.isNotEmpty && workWifiSsid != nativeWork) {
      workWifiSsid = nativeWork;
      SharedPreferences.getInstance().then((p) => p.setString('work_wifi_ssid', nativeWork));
    }

    if (snap.containsKey('onFixedWifi')) {
      _nativeOnFixedWifi = snap['onFixedWifi'] == true;
    }
    final nativeConnectedWifi = (snap['connectedWifiSsid'] as String?)?.trim() ?? '';
    if (nativeConnectedWifi.isNotEmpty) {
      currentConnectedWifiSsid = nativeConnectedWifi;
    } else if (snap.containsKey('onFixedWifi') && !_nativeOnFixedWifi) {
      currentConnectedWifiSsid = null;
    }

    final nativeState = snap['userActivityState'] as String?;
    isHighAccuracyGpsActive = snap['gpsActive'] == true;
    gpsWindowRemainingSec = (snap['gpsRemainingSec'] as num?)?.toInt() ?? 0;
    _noStepGpsCycleCount = (snap['gpsCycle'] as num?)?.toInt() ?? 0;
    currentSpeedKmh = (snap['speedKmh'] as num?)?.toDouble() ?? 0.0;
    sessionSteps = (snap['sessionSteps'] as num?)?.toInt() ?? 0;
    anchoredPendingSteps = (snap['anchoredSteps'] as num?)?.toInt() ?? 0;
    if (snap['nPassi'] != null) nPassi = (snap['nPassi'] as num).toInt();
    if (snap['t0PassiSec'] != null) t0PassiSec = (snap['t0PassiSec'] as num).toInt();
    if (snap['carBtConnected'] != null) {
      isCarBtConnected = snap['carBtConnected'] == true;
    }

    if (_nativeOnFixedWifi && isOnKnownPrivateWifi) {
      final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
      final isHome = homeWifiSsid != null && homeWifiSsid!.isNotEmpty && clean.toLowerCase() == homeWifiSsid!.toLowerCase();
      userActivityState = isHome ? UserActivityState.atHome : UserActivityState.atWork;
      isHighAccuracyGpsActive = false;
      gpsWindowRemainingSec = 0;
    } else if (nativeState != null) {
      userActivityState = _parseNativeState(nativeState);
    }

    final hasParked = snap['hasParked'] == true;
    if (hasParked) {
      parkedLat = (snap['parkedLat'] as num?)?.toDouble() ?? parkedLat;
      parkedLon = (snap['parkedLon'] as num?)?.toDouble() ?? parkedLon;
      if (currentState != VehicleState.leavingSoon) {
        currentState = VehicleState.parked;
      }
    } else if (snap.containsKey('hasParked')) {
      parkedLat = null;
      parkedLon = null;
      if (currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) {
        currentState = isOnKnownPrivateWifi ? VehicleState.stayAtHome : VehicleState.driving;
      }
    }

    final pendingInCar = snap['promptInCar'] == true;
    if (pendingInCar && !_inCarPromptDeliveredInUi) {
      _inCarPromptDeliveredInUi = true;
      _bgServiceChannel.invokeMethod('syncConfigToNative', {'clearPromptInCar': true});
      onPromptAreYouInCar?.call();
    } else if (!pendingInCar) {
      _inCarPromptDeliveredInUi = false;
    }

    final pendingRelease = snap['promptRelease'] == true;
    if (pendingRelease && !_releasePromptDeliveredInUi) {
      _releasePromptDeliveredInUi = true;
      _bgServiceChannel.invokeMethod('syncConfigToNative', {'clearPromptRelease': true});
      onApproachingCar100m(estimatedMinutesToRelease);
    } else if (!pendingRelease) {
      _releasePromptDeliveredInUi = false;
    }
  }

  Future<void> _pushConfigToNative({String? forceUserState, bool isSimulation = false}) async {
    try {
      final rawRes = await _bgServiceChannel.invokeMethod('syncConfigToNative', {
        'homeWifiSsid': homeWifiSsid ?? '',
        'workWifiSsid': workWifiSsid ?? '',
        'uiDetectedWifiSsid': currentConnectedWifiSsid ?? '',
        'carBtMac': targetCarBluetoothMac ?? '',
        'tGpsNoStepSec': tGpsNoStepSec,
        'nPassi': nPassi,
        't0PassiSec': t0PassiSec,
        'geofenceRadiusM': geofenceRadiusMeters.round(),
        'parkedLat': parkedLat,
        'parkedLon': parkedLon,
        if (isSimulation) 'isSimulation': true,
        if (forceUserState != null) 'forceUserState': forceUserState,
      });
      if (rawRes is Map) {
        _applyNativeSnapshotMap(Map<String, dynamic>.from(rawRes));
      }
    } catch (_) {}
  }

  Future<void> syncFromNativeBackgroundService() async {
    try {
      await _checkCurrentWifi(promptIfUnknown: false);
      final rawSnap = await _bgServiceChannel.invokeMethod('getNativeStateSnapshot');
      if (rawSnap is Map) {
        _applyNativeSnapshotMap(Map<String, dynamic>.from(rawSnap));
      } else if (isOnKnownPrivateWifi) {
        final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
        final isWork = workWifiSsid != null && workWifiSsid!.isNotEmpty && clean.toLowerCase() == workWifiSsid!.toLowerCase();
        userActivityState = isWork ? UserActivityState.atWork : UserActivityState.atHome;
        isHighAccuracyGpsActive = false;
        gpsWindowRemainingSec = 0;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> initialize() async {
    _bgServiceChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNativeStateUpdated') {
        if (call.arguments is Map) {
          _applyNativeSnapshotMap(Map<String, dynamic>.from(call.arguments as Map));
          notifyListeners();
        } else {
          await syncFromNativeBackgroundService();
        }
      }
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      parkedLat = prefs.getDouble('parked_lat');
      parkedLon = prefs.getDouble('parked_lon');
      autoShareEnabled = prefs.getBool('auto_share_enabled') ?? true;
      targetCarBluetoothMac = prefs.getString('car_bt_mac');
      targetCarBluetoothName = prefs.getString('car_bt_name');
      final savedHome = prefs.getString('home_wifi_ssid');
      if (savedHome != null && savedHome.isNotEmpty) homeWifiSsid = savedHome;
      final savedWork = prefs.getString('work_wifi_ssid');
      if (savedWork != null && savedWork.isNotEmpty) workWifiSsid = savedWork;
      tGpsNoStepSec = (prefs.getInt('tgps_senzapasso_sec') ?? 30).clamp(10, 180);
      nPassi = (prefs.getInt('n_passi') ?? 50).clamp(5, 500);
      t0PassiSec = (prefs.getInt('t0_passi_sec') ?? 30).clamp(5, 300);
      geofenceRadiusMeters = (prefs.getInt('geofence_radius_m') ?? 100).toDouble();
      _ignoredWifis = prefs.getStringList('ignored_wifis') ?? [];
      _ignoredBtMacs = prefs.getStringList('ignored_bt_macs') ?? [];
      if (parkedLat != null && parkedLon != null) currentState = VehicleState.parked;
    } catch (_) {}

    _setupClassicBluetoothListener();
    _startBleBluetoothMonitor();
    _startWifiMonitor();
    _startFallbackSyncTimer();

    for (final perm in [
      Permission.locationWhenInUse,
      Permission.activityRecognition,
      Permission.bluetoothConnect,
      Permission.notification,
    ]) {
      try {
        await perm.request();
      } catch (_) {}
    }

    try {
      await _bgServiceChannel.invokeMethod('startMonitorService');
    } catch (_) {}

    await _checkCurrentWifi(promptIfUnknown: true);
    await _pushConfigToNative();
    await syncFromNativeBackgroundService();

    if (!initialPermissionsCompleter.isCompleted) {
      initialPermissionsCompleter.complete();
    }
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
    nPassi = (prefs.getInt('n_passi') ?? 50).clamp(5, 500);
    t0PassiSec = (prefs.getInt('t0_passi_sec') ?? 30).clamp(5, 300);
    geofenceRadiusMeters = (prefs.getInt('geofence_radius_m') ?? 100).toDouble();
    await _pushConfigToNative();
    await syncFromNativeBackgroundService();
  }

  Future<void> confirmUserInCarFromPrompt() async {
    userActivityState = UserActivityState.inCar;
    isHighAccuracyGpsActive = false;
    try {
      await _bgServiceChannel.invokeMethod('confirmInCar');
      await _pushConfigToNative(forceUserState: 'inCar');
    } catch (_) {}
    notifyListeners();
  }

  Future<void> dismissUserInCarPrompt() async {
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
    _bgServiceChannel.invokeMethod('syncConfigToNative', {'dismissReleaseNotif': true});
    final eta = customMinutes ?? estimatedMinutesToRelease;
    if (onManualReleaseConfirmed != null) await onManualReleaseConfirmed!(eta);
    notifyListeners();
  }

  void cancelAutoRelease() {
    _autoReleaseManager.cancelCountdown();
    _bgServiceChannel.invokeMethod('syncConfigToNative', {'dismissReleaseNotif': true});
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
    await _pushConfigToNative(forceUserState: 'inCar');
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
    if (workWifiSsid != null && workWifiSsid!.toLowerCase() == clean.toLowerCase()) {
      workWifiSsid = null;
    }
    currentConnectedWifiSsid = clean;
    _nativeOnFixedWifi = true;
    userActivityState = UserActivityState.atHome;
    isHighAccuracyGpsActive = false;
    gpsWindowRemainingSec = 0;
    _pendingWifiConfirmationSsid = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('home_wifi_ssid', clean);
    if (workWifiSsid == null) await prefs.remove('work_wifi_ssid');
    await _bgServiceChannel.invokeMethod('syncConfigToNative', {
      'homeWifiSsid': clean,
      if (workWifiSsid == null) 'clearWorkWifi': true,
      'forceUserState': 'atHome',
    });
    await syncFromNativeBackgroundService();
    notifyListeners();
  }

  Future<void> saveWifiAsWork(String ssid) async {
    final clean = ssid.replaceAll('"', '').trim();
    workWifiSsid = clean;
    if (homeWifiSsid != null && homeWifiSsid!.toLowerCase() == clean.toLowerCase()) {
      homeWifiSsid = null;
    }
    currentConnectedWifiSsid = clean;
    _nativeOnFixedWifi = true;
    userActivityState = UserActivityState.atWork;
    isHighAccuracyGpsActive = false;
    gpsWindowRemainingSec = 0;
    _pendingWifiConfirmationSsid = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('work_wifi_ssid', clean);
    if (homeWifiSsid == null) await prefs.remove('home_wifi_ssid');
    await _bgServiceChannel.invokeMethod('syncConfigToNative', {
      'workWifiSsid': clean,
      if (homeWifiSsid == null) 'clearHomeWifi': true,
      'forceUserState': 'atWork',
    });
    await syncFromNativeBackgroundService();
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
      final savedHome = prefs.getString('home_wifi_ssid');
      if (savedHome != null && savedHome.isNotEmpty) homeWifiSsid = savedHome;
      final savedWork = prefs.getString('work_wifi_ssid');
      if (savedWork != null && savedWork.isNotEmpty) workWifiSsid = savedWork;

      final info = NetworkInfo();
      final ssid = await info.getWifiName();
      if (ssid != null && ssid.isNotEmpty && ssid != '<unknown ssid>') {
        final clean = ssid.replaceAll('"', '').trim();
        final changed = currentConnectedWifiSsid != clean;
        currentConnectedWifiSsid = clean;
        if (changed) {
          await _bgServiceChannel.invokeMethod('syncConfigToNative', {'uiDetectedWifiSsid': clean});
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
        final results = await Connectivity().checkConnectivity();
        if (!results.contains(ConnectivityResult.wifi)) {
          currentConnectedWifiSsid = null;
          _pendingWifiConfirmationSsid = null;
        }
      }
    } catch (_) {}
  }

  void _startWifiMonitor() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) async {
      await _checkCurrentWifi(promptIfUnknown: true);
      await _pushConfigToNative();
      await syncFromNativeBackgroundService();
    });
  }

  void _startBleBluetoothMonitor() {
    _btCheckTimer?.cancel();
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
        final pos = (method == 'SIMULATION' || isOnKnownPrivateWifi)
            ? (await Geolocator.getLastKnownPosition() ??
                await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.low)
                    .timeout(const Duration(seconds: 2)))
            : await Geolocator.getCurrentPosition()
                .timeout(const Duration(seconds: 4));
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
    _releasePromptDeliveredInUi = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('parked_lat', parkedLat!);
    await prefs.setDouble('parked_lon', parkedLon!);

    await _pushConfigToNative(isSimulation: method == 'SIMULATION');
    notifyListeners();
    unawaited(onCarParked(parkedLat!, parkedLon!, method));
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

    await _pushConfigToNative();
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
