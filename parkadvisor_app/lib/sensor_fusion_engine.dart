import 'dart:convert';
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
  int deltaGpsMeters = 150;
  int tGraziaMin = 5;
  int tCountdownSec = 30;
  bool isDeviceCharging = false;
  bool departureCountdownActive = false;
  int departureCountdownSec = 0;
  String departureTriggerSource = '';
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
      if (gpsWindowRemainingSec <= 0) return 'GPS alta precisione (radar ${geofenceRadiusMeters.round()}+${deltaGpsMeters}m)';
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

  List<String> _splitCsv(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    return raw.split(',').map((e) => e.replaceAll('"', '').trim()).where((e) => e.isNotEmpty).toList();
  }

  bool _csvContains(String? raw, String item) {
    final target = item.replaceAll('"', '').trim().toLowerCase();
    if (target.isEmpty) return false;
    return _splitCsv(raw).any((e) => e.toLowerCase() == target);
  }

  String _csvAdd(String? raw, String item) {
    final clean = item.replaceAll('"', '').trim();
    final list = _splitCsv(raw);
    if (clean.isNotEmpty && !list.any((e) => e.toLowerCase() == clean.toLowerCase())) {
      list.add(clean);
    }
    return list.join(',');
  }

  String _csvRemove(String? raw, String item) {
    final target = item.replaceAll('"', '').trim().toLowerCase();
    return _splitCsv(raw).where((e) => e.toLowerCase() != target).join(',');
  }

  bool get isOnKnownPrivateWifi {
    if (currentConnectedWifiSsid == null || currentConnectedWifiSsid!.isEmpty) return false;
    final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
    return _csvContains(homeWifiSsid, clean) || _csvContains(workWifiSsid, clean);
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
    if (snap['geofenceRadiusM'] != null) geofenceRadiusMeters = (snap['geofenceRadiusM'] as num).toDouble();
    if (snap['deltaGpsM'] != null) deltaGpsMeters = (snap['deltaGpsM'] as num).toInt();
    if (snap['tGraziaMin'] != null) tGraziaMin = (snap['tGraziaMin'] as num).toInt();
    if (snap['tCountdownSec'] != null) tCountdownSec = (snap['tCountdownSec'] as num).toInt();
    if (snap['isCharging'] != null) isDeviceCharging = snap['isCharging'] == true;
    departureCountdownActive = snap['departureCountdownActive'] == true;
    departureCountdownSec = (snap['departureCountdownSec'] as num?)?.toInt() ?? 0;
    departureTriggerSource = (snap['departureTriggerSource'] as String?) ?? '';
    final nativeDist = (snap['distanceFromCarM'] as num?)?.toDouble();
    if (nativeDist != null) distanceFromCarMeters = nativeDist;
    else if (snap['hasParked'] == false) distanceFromCarMeters = null;
    final uLat = (snap['userLat'] as num?)?.toDouble();
    final uLon = (snap['userLon'] as num?)?.toDouble();
    if (uLat != null && uLon != null) { currentUserLat = uLat; currentUserLon = uLon; }
    if (snap['carBtConnected'] != null) {
      isCarBtConnected = snap['carBtConnected'] == true;
    }

    if (_nativeOnFixedWifi && isOnKnownPrivateWifi) {
      final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
      final isHome = _csvContains(homeWifiSsid, clean);
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
      final hadLocalParked = parkedLat != null || parkedLon != null || _manualReleaseConfirmed;
      parkedLat = null;
      parkedLon = null;
      distanceFromCarMeters = null;
      _manualReleaseConfirmed = false;
      if (hadLocalParked) {
        SharedPreferences.getInstance().then((p) {
          p.remove('parked_lat');
          p.remove('parked_lon');
        });
      }
      if (hadLocalParked || currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) {
        currentState = isOnKnownPrivateWifi ? VehicleState.stayAtHome : VehicleState.driving;
        unawaited(onCarReleased());
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

  Future<void> _pushConfigToNative({String? forceUserState, bool isSimulation = false, bool skipRemoteSync = false}) async {
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
        'deltaGpsM': deltaGpsMeters,
        'tGraziaMin': tGraziaMin,
        'tCountdownSec': tCountdownSec,
        'ignoredWifis': _ignoredWifis,
        'parkedLat': parkedLat,
        'parkedLon': parkedLon,
        if (isSimulation) 'isSimulation': true,
        if (!isSimulation && !skipRemoteSync) 'syncRemoteSpot': true,
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
      deltaGpsMeters = (prefs.getInt('delta_gps_m') ?? 150).clamp(50, 500);
      tGraziaMin = (prefs.getInt('t_grazia_min') ?? 5).clamp(1, 60);
      tCountdownSec = (prefs.getInt('t_countdown_sec') ?? 30).clamp(5, 120);
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
    deltaGpsMeters = (prefs.getInt('delta_gps_m') ?? 150).clamp(50, 500);
    tGraziaMin = (prefs.getInt('t_grazia_min') ?? 5).clamp(1, 60);
    tCountdownSec = (prefs.getInt('t_countdown_sec') ?? 30).clamp(5, 120);
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
    final hadParking = isCarParked || _manualReleaseConfirmed || currentState == VehicleState.leavingSoon;
    userActivityState = UserActivityState.inCar;
    isHighAccuracyGpsActive = false;
    if (hadParking) {
      await _triggerCarReleased(forceUserState: 'inCar');
    } else {
      await confirmUserInCarFromPrompt();
    }
  }

  Future<void> confirmManualReleaseIntent() => confirmManualRelease();

  Future<void> confirmManualRelease([int? customMinutes]) async {
    _manualReleaseConfirmed = true;
    currentState = VehicleState.leavingSoon;
    final eta = customMinutes ?? estimatedMinutesToRelease;
    _bgServiceChannel.invokeMethod('syncConfigToNative', {
      'confirmLeavingSoon': true,
      'etaMinutes': eta,
    });
    if (onManualReleaseConfirmed != null) await onManualReleaseConfirmed!(eta);
    notifyListeners();
  }

  Future<void> denyDepartureCountdown() async {
    departureCountdownActive = false;
    departureCountdownSec = 0;
    notifyListeners();
    try {
      await _bgServiceChannel.invokeMethod('denyInCar');
    } catch (_) {}
    await syncFromNativeBackgroundService();
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
    final upper = mac.trim().toUpperCase();
    targetCarBluetoothMac = _csvAdd(targetCarBluetoothMac, upper);
    targetCarBluetoothName = name;
    _ignoredBtMacs.removeWhere((m) => m.toUpperCase() == upper);
    isCarBtConnected = true;
    userActivityState = UserActivityState.inCar;
    isHighAccuracyGpsActive = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('car_bt_mac', targetCarBluetoothMac!);
    await prefs.setString('car_bt_name', name);
    await prefs.setStringList('ignored_bt_macs', _ignoredBtMacs);
    try {
      final rawMap = prefs.getString('car_bt_names_json');
      final Map<String, dynamic> names = rawMap != null ? Map<String, dynamic>.from(json.decode(rawMap)) : {};
      if (name.trim().isNotEmpty) names[upper] = name.trim();
      await prefs.setString('car_bt_names_json', json.encode(names));
    } catch (_) {}
    try {
      final rawRes = await _bgServiceChannel.invokeMethod('syncConfigToNative', {
        'carBtMac': targetCarBluetoothMac ?? '',
        'triggerCarBtConnected': true,
      });
      if (rawRes is Map) {
        _applyNativeSnapshotMap(Map<String, dynamic>.from(rawRes));
      }
    } catch (_) {}
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
    homeWifiSsid = _csvAdd(homeWifiSsid, clean);
    final updatedWork = _csvRemove(workWifiSsid, clean);
    workWifiSsid = updatedWork.isEmpty ? null : updatedWork;
    _ignoredWifis.removeWhere((w) => w.toLowerCase() == clean.toLowerCase());
    currentConnectedWifiSsid = clean;
    _nativeOnFixedWifi = true;
    userActivityState = UserActivityState.atHome;
    isHighAccuracyGpsActive = false;
    gpsWindowRemainingSec = 0;
    _pendingWifiConfirmationSsid = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('home_wifi_ssid', homeWifiSsid!);
    if (workWifiSsid == null) { await prefs.remove('work_wifi_ssid'); } else { await prefs.setString('work_wifi_ssid', workWifiSsid!); }
    await prefs.setStringList('ignored_wifis', _ignoredWifis);
    await _bgServiceChannel.invokeMethod('syncConfigToNative', {
      'homeWifiSsid': homeWifiSsid ?? '',
      'workWifiSsid': workWifiSsid ?? '',
      'ignoredWifis': _ignoredWifis,
      if (workWifiSsid == null) 'clearWorkWifi': true,
      'forceUserState': 'atHome',
    });
    await syncFromNativeBackgroundService();
    notifyListeners();
  }

  Future<void> saveWifiAsWork(String ssid) async {
    final clean = ssid.replaceAll('"', '').trim();
    workWifiSsid = _csvAdd(workWifiSsid, clean);
    final updatedHome = _csvRemove(homeWifiSsid, clean);
    homeWifiSsid = updatedHome.isEmpty ? null : updatedHome;
    _ignoredWifis.removeWhere((w) => w.toLowerCase() == clean.toLowerCase());
    currentConnectedWifiSsid = clean;
    _nativeOnFixedWifi = true;
    userActivityState = UserActivityState.atWork;
    isHighAccuracyGpsActive = false;
    gpsWindowRemainingSec = 0;
    _pendingWifiConfirmationSsid = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('work_wifi_ssid', workWifiSsid!);
    if (homeWifiSsid == null) { await prefs.remove('home_wifi_ssid'); } else { await prefs.setString('home_wifi_ssid', homeWifiSsid!); }
    await prefs.setStringList('ignored_wifis', _ignoredWifis);
    await _bgServiceChannel.invokeMethod('syncConfigToNative', {
      'workWifiSsid': workWifiSsid ?? '',
      'homeWifiSsid': homeWifiSsid ?? '',
      'ignoredWifis': _ignoredWifis,
      if (homeWifiSsid == null) 'clearHomeWifi': true,
      'forceUserState': 'atWork',
    });
    await syncFromNativeBackgroundService();
    notifyListeners();
  }

  Future<void> ignoreWifi(String ssid) async {
    final clean = ssid.replaceAll('"', '').trim();
    if (clean.isEmpty) return;
    if (!_ignoredWifis.any((w) => w.toLowerCase() == clean.toLowerCase())) {
      _ignoredWifis.add(clean);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ignored_wifis', _ignoredWifis);
      _pendingWifiConfirmationSsid = null;
      try {
        await _bgServiceChannel.invokeMethod('syncConfigToNative', {'ignoredWifis': _ignoredWifis});
      } catch (_) {}
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

  // [BLE_COUNTDOWN_FIX_V1]
  void _startBleBluetoothMonitor() {
    _btCheckTimer?.cancel();
    _btCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        final connected = FlutterBluePlus.connectedDevices;
        if (targetCarBluetoothMac != null && targetCarBluetoothMac!.isNotEmpty) {
          final found = connected.any((d) => _csvContains(targetCarBluetoothMac, d.remoteId.str));
          if (found && !isCarBtConnected) {
            isCarBtConnected = true;
            final rawRes = await _bgServiceChannel.invokeMethod('syncConfigToNative', {
              'carBtMac': targetCarBluetoothMac ?? '',
              'triggerCarBtConnected': true,
            });
            if (rawRes is Map) {
              _applyNativeSnapshotMap(Map<String, dynamic>.from(rawRes));
            }
            notifyListeners();
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

  Future<void> _triggerCarReleased({String? forceUserState}) async {
    _autoReleaseManager.cancelCountdown();
    parkedLat = null;
    parkedLon = null;
    distanceFromCarMeters = null;
    currentState = isOnKnownPrivateWifi ? VehicleState.stayAtHome : VehicleState.driving;
    _manualReleaseConfirmed = false;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('parked_lat');
    await prefs.remove('parked_lon');

    await _pushConfigToNative(forceUserState: forceUserState, skipRemoteSync: true);
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
