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

enum VehicleState {
  stayAtHome,   // Connesso al Wi-Fi Casa o Lavoro: GPS ad alta frequenza sospeso, nessuna pubblicazione stallo
  driving,      // Velocità > 12 km/h o connesso al BT dell'auto
  stopping,     // Velocità ~ 0 (possibile semaforo o sosta)
  parked,       // Velocità 0 + BT auto disconnesso (fuori Wi-Fi Casa/Lavoro) O giroscopio + passi
  leavingSoon,  // Utente in cammino entro 100m dall'auto parcheggiata
}

class SensorFusionEngine extends ChangeNotifier {
  static const MethodChannel _classicBtChannel = MethodChannel('com.parknow.app/classic_bt');

  VehicleState currentState = VehicleState.driving;

  // Posizione live dell'utente
  double? currentUserLat;
  double? currentUserLon;

  // Dati auto parcheggiata
  double? parkedLat;
  double? parkedLon;
  double? distanceFromCarMeters;

  // Profilo connettività account utente (BT Auto + Wi-Fi Casa/Lavoro)
  String? targetCarBluetoothMac;
  String? targetCarBluetoothName;
  String? homeWifiSsid;
  String? workWifiSsid;
  String? currentConnectedWifiSsid;

  // Telemetria sensori in tempo reale
  double currentSpeedKmh = 0.0;
  double gyroscopeMagnitude = 0.0;
  String pedestrianStatus = 'unknown';
  int sessionSteps = 0;
  int? _initialStepCount;
  bool isCarBtConnected = false;

  // Callback verso il backend
  final Future<void> Function(double lat, double lon, String method) onCarParked;
  final Future<void> Function(int estimatedMinutes) onApproachingCar100m;
  final Future<void> Function() onCarReleased;

  StreamSubscription<Position>? _posSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<PedestrianStatus>? _pedStatusSub;
  StreamSubscription<StepCount>? _stepCountSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _btCheckTimer;

  bool _gyroTransitionDetected = false;
  bool _notified100m = false;

  SensorFusionEngine({
    required this.onCarParked,
    required this.onApproachingCar100m,
    required this.onCarReleased,
  });

  bool get isOnKnownPrivateWifi {
    if (currentConnectedWifiSsid == null || currentConnectedWifiSsid!.isEmpty) return false;
    final clean = currentConnectedWifiSsid!.replaceAll('"', '').trim();
    return (homeWifiSsid != null && clean == homeWifiSsid) ||
           (workWifiSsid != null && clean == workWifiSsid);
  }

  Future<void> initialize() async {
    await [
      Permission.activityRecognition,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final prefs = await SharedPreferences.getInstance();
    parkedLat = prefs.getDouble('parked_lat');
    parkedLon = prefs.getDouble('parked_lon');
    targetCarBluetoothMac = prefs.getString('car_bt_mac');
    targetCarBluetoothName = prefs.getString('car_bt_name');
    homeWifiSsid = prefs.getString('home_wifi_ssid');
    workWifiSsid = prefs.getString('work_wifi_ssid');

    if (parkedLat != null && parkedLon != null) {
      currentState = VehicleState.parked;
    }

    _setupClassicBluetoothListener();
    await _checkCurrentWifi();
    _startWifiMonitor();
    _startGpsStream();
    _startGyroscopeStream();
    _startPedometerStreams();
    _startBleBluetoothMonitor();
    notifyListeners();
  }

  // Salvataggio dispositivi sul profilo locale (pronto per sync API)
  Future<void> setCarBluetoothDevice(String mac, String name) async {
    targetCarBluetoothMac = mac.toUpperCase();
    targetCarBluetoothName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('car_bt_mac', targetCarBluetoothMac!);
    await prefs.setString('car_bt_name', name);
    notifyListeners();
  }

  Future<void> saveCurrentWifiAsHome() async {
    await _checkCurrentWifi();
    if (currentConnectedWifiSsid == null) return;
    homeWifiSsid = currentConnectedWifiSsid!.replaceAll('"', '').trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('home_wifi_ssid', homeWifiSsid!);
    _evaluateWifiStateTransition();
    notifyListeners();
  }

  Future<void> saveCurrentWifiAsWork() async {
    await _checkCurrentWifi();
    if (currentConnectedWifiSsid == null) return;
    workWifiSsid = currentConnectedWifiSsid!.replaceAll('"', '').trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('work_wifi_ssid', workWifiSsid!);
    _evaluateWifiStateTransition();
    notifyListeners();
  }

  Future<List>> getPairedClassicBluetoothDevices() async {
    try {
      final List<dynamic>? res = await _classicBtChannel.invokeMethod('getBondedDevices');
      if (res == null) return [];
      return res.map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  // Listener eventi Bluetooth Classico (A2DP / HFP vivavoce auto)
  void _setupClassicBluetoothListener() {
    _classicBtChannel.setMethodCallHandler((call) async {
      final String mac = (call.arguments as String? ?? '').toUpperCase();
      if (targetCarBluetoothMac == null || mac != targetCarBluetoothMac) return;

      if (call.method == 'onBtConnected') {
        isCarBtConnected = true;
        // Transizione immediata STAY_AT_HOME / PARKED -> DRIVING
        if (currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) {
          await _triggerCarReleased();
        } else {
          currentState = VehicleState.driving;
          notifyListeners();
        }
      } else if (call.method == 'onBtDisconnected') {
        isCarBtConnected = false;
        await _checkCurrentWifi();
        // Se non siamo agganciati al Wi-Fi di Casa/Lavoro, conferma subito la sosta pubblica
        if (!isOnKnownPrivateWifi && currentSpeedKmh < 5.0) {
          final pos = await Geolocator.getCurrentPosition();
          await _confirmParked(pos.latitude, pos.longitude, 'CLASSIC_BT_DISCONNECT');
        }
        notifyListeners();
      }
    });
  }

  // Monitoraggio Wi-Fi Casa / Lavoro
  void _startWifiMonitor() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) async {
      await _checkCurrentWifi();
      _evaluateWifiStateTransition();
      notifyListeners();
    });
  }

  Future<void> _checkCurrentWifi() async {
    try {
      final info = NetworkInfo();
      final ssid = await info.getWifiName();
      currentConnectedWifiSsid = ssid?.replaceAll('"', '').trim();
    } catch (_) {
      currentConnectedWifiSsid = null;
    }
  }

  void _evaluateWifiStateTransition() {
    if (isOnKnownPrivateWifi && !isCarBtConnected) {
      // Arrivato a Casa o al Lavoro: sospende stato guida e non pubblica stalli privati
      if (currentState != VehicleState.parked) {
        currentState = VehicleState.stayAtHome;
      }
    } else if (!isOnKnownPrivateWifi && currentState == VehicleState.stayAtHome) {
      // Uscito dal Wi-Fi Casa/Lavoro: riattiva rilevamento guida
      currentState = VehicleState.driving;
    }
  }

  // 1. Stream GPS continuo
  void _startGpsStream() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2,
    );

    _posSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position pos) {
      currentUserLat = pos.latitude;
      currentUserLon = pos.longitude;
      currentSpeedKmh = (pos.speed < 0 ? 0 : pos.speed) * 3.6;

      // Se l'utente è a casa/lavoro fermo, ignora il rumore GPS
      if (currentState == VehicleState.stayAtHome && currentSpeedKmh < 12.0) {
        notifyListeners();
        return;
      }

      if ((currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) &&
          parkedLat != null &&
          parkedLon != null) {
        distanceFromCarMeters = Geolocator.distanceBetween(
          pos.latitude,
          pos.longitude,
          parkedLat!,
          parkedLon!,
        );

        final bool isWalking = pedestrianStatus == 'walking' ||
            (currentSpeedKmh >= 1.5 && currentSpeedKmh <= 7.5);

        if (distanceFromCarMeters! <= 100.0 &&
            isWalking &&
            !_notified100m &&
            currentState == VehicleState.parked) {
          _notified100m = true;
          currentState = VehicleState.leavingSoon;
          onApproachingCar100m(2);
        }

        // Rilascio rapido: velocità > 12 km/h e distanza > 15 m dallo stallo
        if (currentSpeedKmh > 12.0 && distanceFromCarMeters! > 15.0) {
          _triggerCarReleased();
        }
      } else {
        if (currentSpeedKmh > 12.0) {
          currentState = VehicleState.driving;
          _gyroTransitionDetected = false;
          _initialStepCount = null;
          sessionSteps = 0;
        } else if (currentSpeedKmh < 1.5 && currentState == VehicleState.driving) {
          currentState = VehicleState.stopping;
        }

        _evaluateParkingCondition(pos);
      }

      notifyListeners();
    });
  }

  // 2. Giroscopio
  void _startGyroscopeStream() {
    _gyroSub = gyroscopeEventStream().listen((GyroscopeEvent event) {
      if (currentState == VehicleState.stayAtHome) return;
      gyroscopeMagnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (currentSpeedKmh < 1.5 && gyroscopeMagnitude > 1.8) {
        _gyroTransitionDetected = true;
      }
    });
  }

  // 3. Pedometro
  void _startPedometerStreams() {
    _pedStatusSub = Pedometer.pedestrianStatusStream.listen(
      (PedestrianStatus event) {
        pedestrianStatus = event.status;
        notifyListeners();
      },
      onError: (_) {
        pedestrianStatus = 'unavailable';
        notifyListeners();
      },
    );

    _stepCountSub = Pedometer.stepCountStream.listen(
      (StepCount event) {
        if (currentSpeedKmh < 2.0) {
          _initialStepCount ??= event.steps;
          sessionSteps = event.steps - _initialStepCount!;
        } else {
          _initialStepCount = null;
          sessionSteps = 0;
        }
        notifyListeners();
      },
      onError: (_) {},
    );
  }

  // 4. Fallback BLE per dispositivi Bluetooth Low Energy
  void _startBleBluetoothMonitor() {
    _btCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (targetCarBluetoothMac == null || targetCarBluetoothMac!.isEmpty) return;

      try {
        final connectedDevices = FlutterBluePlus.connectedDevices;
        final bool bleConnected = connectedDevices.any(
          (d) => d.remoteId.str.toUpperCase() == targetCarBluetoothMac,
        );

        if (bleConnected && !isCarBtConnected) {
          isCarBtConnected = true;
          if (currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) {
            await _triggerCarReleased();
          } else {
            currentState = VehicleState.driving;
          }
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  Future<void> _evaluateParkingCondition(Position pos) async {
    if (currentState != VehicleState.stopping || isOnKnownPrivateWifi) return;

    final bool inertialWalkConfirmed = _gyroTransitionDetected &&
        (sessionSteps >= 6 || pedestrianStatus == 'walking');

    if (inertialWalkConfirmed) {
      await _confirmParked(pos.latitude, pos.longitude, 'GYRO+PEDOMETER+GPS_ZERO');
    }
  }

  Future<void> _confirmParked(double lat, double lon, String method) async {
    currentState = VehicleState.parked;
    parkedLat = lat;
    parkedLon = lon;
    distanceFromCarMeters = 0.0;
    _notified100m = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('parked_lat', lat);
    await prefs.setDouble('parked_lon', lon);

    await onCarParked(lat, lon, method);
    notifyListeners();
  }

  Future<void> _triggerCarReleased() async {
    currentState = isOnKnownPrivateWifi ? VehicleState.stayAtHome : VehicleState.driving;
    parkedLat = null;
    parkedLon = null;
    distanceFromCarMeters = null;
    _notified100m = false;
    _gyroTransitionDetected = false;
    sessionSteps = 0;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('parked_lat');
    await prefs.remove('parked_lon');

    await onCarReleased();
    notifyListeners();
  }

  Future<void> forceParkHere() async {
    final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    await _confirmParked(pos.latitude, pos.longitude, 'MANUAL_SENSOR_TEST');
  }

  Future<void> forceLeavingSoon() async {
    if (parkedLat == null) return;
    currentState = VehicleState.leavingSoon;
    _notified100m = true;
    await onApproachingCar100m(2);
    notifyListeners();
  }

  Future<void> forceReleaseCar() async {
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
    super.dispose();
  }
}
