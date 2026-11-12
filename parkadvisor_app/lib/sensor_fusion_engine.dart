import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:pedometer/pedometer.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

enum VehicleState {
  driving,      // Velocità > 12 km/h o connesso al BT dell'auto
  stopping,     // Velocità ~ 0 (possibile semaforo o sosta)
  parked,       // Velocità 0 + (BT auto disconnesso O rotazione giroscopio + passi rilevati)
  leavingSoon,  // Utente in cammino entro 100m dall'auto parcheggiata
}

class SensorFusionEngine extends ChangeNotifier {
  VehicleState currentState = VehicleState.driving;

  // Posizione live dell'utente (per aggiornamento fluido puntatore celeste)
  double? currentUserLat;
  double? currentUserLon;

  // Dati auto parcheggiata
  double? parkedLat;
  double? parkedLon;
  double? distanceFromCarMeters;
  String? targetCarBluetoothMac;

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
  Timer? _btCheckTimer;

  bool _gyroTransitionDetected = false;
  bool _notified100m = false;

  SensorFusionEngine({
    required this.onCarParked,
    required this.onApproachingCar100m,
    required this.onCarReleased,
  });

  Future<void> initialize() async {
    // Richiesta esplicita a runtime del permesso attività fisica per il pedometro Android
    await Permission.activityRecognition.request();

    final prefs = await SharedPreferences.getInstance();
    parkedLat = prefs.getDouble('parked_lat');
    parkedLon = prefs.getDouble('parked_lon');
    targetCarBluetoothMac = prefs.getString('car_bt_mac');

    if (parkedLat != null && parkedLon != null) {
      currentState = VehicleState.parked;
    }

    _startGpsStream();
    _startGyroscopeStream();
    _startPedometerStreams();
    _startCarBluetoothMonitor();
    notifyListeners();
  }

  Future<void> setCarBluetoothMac(String mac) async {
    targetCarBluetoothMac = mac.toUpperCase();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('car_bt_mac', targetCarBluetoothMac!);
    notifyListeners();
  }

  // 1. Stream GPS continuo: posizione live, velocità, geofence 100m e rilascio rapido
  void _startGpsStream() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2,
    );

    _posSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position pos) {
      currentUserLat = pos.latitude;
      currentUserLon = pos.longitude;
      currentSpeedKmh = (pos.speed < 0 ? 0 : pos.speed) * 3.6;

      if ((currentState == VehicleState.parked || currentState == VehicleState.leavingSoon) &&
          parkedLat != null &&
          parkedLon != null) {
        distanceFromCarMeters = Geolocator.distanceBetween(
          pos.latitude,
          pos.longitude,
          parkedLat!,
          parkedLon!,
        );

        // Raggio 100m + movimento pedonale (pedometro o velocità camminata 1.5-7.5 km/h)
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

        // Rilascio rapido ottimizzato: velocità > 12 km/h e distanza > 15 m dallo stallo
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

  // 4. Monitoraggio connessione Bluetooth auto
  void _startCarBluetoothMonitor() {
    _btCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (targetCarBluetoothMac == null || targetCarBluetoothMac!.isEmpty) return;

      try {
        final connectedDevices = FlutterBluePlus.connectedDevices;
        final wasConnected = isCarBtConnected;
        isCarBtConnected = connectedDevices.any(
          (d) => d.remoteId.str.toUpperCase() == targetCarBluetoothMac,
        );

        if (wasConnected && !isCarBtConnected && currentSpeedKmh < 2.0) {
          final pos = await Geolocator.getCurrentPosition();
          await _confirmParked(pos.latitude, pos.longitude, 'BT_DISCONNECT+GPS_ZERO');
        }

        if (!wasConnected && isCarBtConnected &&
            (currentState == VehicleState.parked || currentState == VehicleState.leavingSoon)) {
          await _triggerCarReleased();
        }
        notifyListeners();
      } catch (_) {}
    });
  }

  Future<void> _evaluateParkingCondition(Position pos) async {
    if (currentState != VehicleState.stopping) return;

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
    currentState = VehicleState.driving;
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
    _btCheckTimer?.cancel();
    super.dispose();
  }
}
