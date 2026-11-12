import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'sensor_fusion_engine.dart';

void main() {
  runApp(const ParkNowApp());
}

class ParkNowApp extends StatelessWidget {
  const ParkNowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ParkNow!',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _backendBaseUrl = 'https://bug-free-space-couscous-7vgr7pjj9grqcpw4p-3000.app.github.dev';
  static const String _userId = 'USER-001';

  final MapController _mapController = MapController();
  LatLng _currentCenter = const LatLng(41.85784, 12.55860);

  late SensorFusionEngine _sensorEngine;
  List<dynamic> _availableSpots = [];
  String _apiStatus = 'Sincronizzazione mappa...';
  bool _isLoadingApi = false;
  bool _hasUserLocation = false;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'bypass-tunnel-reminder': 'true',
      };

  @override
  void initState() {
    super.initState();
    _sensorEngine = SensorFusionEngine(
      onCarParked: _handleCarParked,
      onApproachingCar100m: _handleApproachingCar100m,
      onCarReleased: _handleCarReleased,
    );
    _sensorEngine.addListener(() {
      if (!mounted) return;
      if (_sensorEngine.currentUserLat != null && _sensorEngine.currentUserLon != null) {
        _currentCenter = LatLng(_sensorEngine.currentUserLat!, _sensorEngine.currentUserLon!);
        _hasUserLocation = true;
      }
      setState(() {});
    });
    _initPermissionsAndEngine();
  }

  Future<void> _initPermissionsAndEngine() async {
    await Geolocator.requestPermission();
    await _sensorEngine.initialize();
    await _centerAndRefreshMap();
  }

  Future<void> _handleCarParked(double lat, double lon, String method) async {
    try {
      await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/park'),
        headers: _headers,
        body: json.encode({
          'userId': _userId,
          'latitude': lat,
          'longitude': lon,
          'detectionMethod': method,
        }),
      );
      await _fetchAvailableSpots(_currentCenter.latitude, _currentCenter.longitude);
    } catch (_) {}
  }

  Future<void> _handleApproachingCar100m(int estimatedMinutes) async {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stai tornando all\'auto'),
        content: Text(
          'Sei entrato nel raggio di 100m dalla tua auto parcheggiata. '
          'Vuoi segnalare che lo stallo si libererà tra $estimatedMinutes minuti?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Non ora'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _sendLeavingSoonToServer(estimatedMinutes);
            },
            child: const Text('Conferma uscita'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendLeavingSoonToServer(int minutes) async {
    try {
      await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/leaving'),
        headers: _headers,
        body: json.encode({
          'userId': _userId,
          'availableInMinutes': minutes,
        }),
      );
      await _fetchAvailableSpots(_currentCenter.latitude, _currentCenter.longitude);
    } catch (_) {}
  }

  Future<void> _handleCarReleased() async {
    try {
      await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/release'),
        headers: _headers,
        body: json.encode({'userId': _userId}),
      );
      await _fetchAvailableSpots(_currentCenter.latitude, _currentCenter.longitude);
    } catch (_) {}
  }

  Future<void> _centerAndRefreshMap() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final newPos = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _currentCenter = newPos;
        _hasUserLocation = true;
      });
      _mapController.move(newPos, 17.0);
      await _fetchAvailableSpots(pos.latitude, pos.longitude);
    } catch (e) {
      setState(() => _apiStatus = 'Errore GPS: $e');
    }
  }

  Future<void> _fetchAvailableSpots(double lat, double lon) async {
    setState(() {
      _isLoadingApi = true;
      _apiStatus = 'Ricerca stalli disponibili...';
    });

    try {
      final url = Uri.parse('$_backendBaseUrl/api/parking/nearby?lat=$lat&lon=$lon');
      final response = await http.get(url, headers: _headers).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final spots = data['spots'] as List<dynamic>? ?? [];
        setState(() {
          _availableSpots = spots;
          _apiStatus = spots.isEmpty
              ? 'Nessuno stallo libero in zona'
              : '${spots.length} stalli disponibili in zona';
          _isLoadingApi = false;
        });
      } else {
        setState(() {
          _apiStatus = 'Errore server (HTTP ${response.statusCode})';
          _isLoadingApi = false;
        });
      }
    } catch (e) {
      setState(() {
        _apiStatus = 'Errore connessione: $e';
        _isLoadingApi = false;
      });
    }
  }

  Future<void> _selectCarBluetoothDialog() async {
    final connected = FlutterBluePlus.connectedDevices;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Associa Bluetooth Auto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Seleziona il vivavoce/autoradio attualmente connesso per il rilevamento automatico della sosta:'),
            const SizedBox(height: 12),
            if (connected.isEmpty)
              const Text('Nessun dispositivo Bluetooth connesso al momento.', style: TextStyle(color: Colors.grey))
            else
              ...connected.map((d) => ListTile(
                    leading: const Icon(Icons.directions_car),
                    title: Text(d.platformName.isNotEmpty ? d.platformName : 'Dispositivo BT'),
                    subtitle: Text(d.remoteId.str),
                    onTap: () {
                      _sensorEngine.setCarBluetoothMac(d.remoteId.str);
                      Navigator.pop(ctx);
                    },
                  )),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Chiudi')),
        ],
      ),
    );
  }

  Widget _buildCarSpotBadge(Color badgeColor) {
    return Container(
      decoration: BoxDecoration(
        color: badgeColor,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: const Icon(Icons.directions_car, color: Colors.white, size: 22),
    );
  }

  @override
  void dispose() {
    _sensorEngine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Marker> markers = [];

    // 1. Posizione live dell'utente
    if (_hasUserLocation) {
      markers.add(
        Marker(
          point: _currentCenter,
          width: 36,
          height: 36,
          child: const Icon(Icons.my_location, color: Colors.blue, size: 26),
        ),
      );
    }

    // 2. Auto dell'utente parcheggiata (blu se PARKED, arancione se LEAVING_SOON)
    if (_sensorEngine.parkedLat != null && _sensorEngine.parkedLon != null) {
      final bool isUserLeaving = _sensorEngine.currentState == VehicleState.leavingSoon;
      markers.add(
        Marker(
          point: LatLng(_sensorEngine.parkedLat!, _sensorEngine.parkedLon!),
          width: 44,
          height: 44,
          child: _buildCarSpotBadge(isUserLeaving ? Colors.orange : Colors.indigo),
        ),
      );
    }

    // 3. Stalli disponibili / in liberazione dal backend (evitando sovrapposizione con la propria auto)
    for (var spot in _availableSpots) {
      final double spotLat = (spot['latitude'] as num).toDouble();
      final double spotLon = (spot['longitude'] as num).toDouble();

      // Se lo stallo corrisponde alla propria auto già disegnata al punto 2, non duplicare il marker
      if (_sensorEngine.parkedLat != null && _sensorEngine.parkedLon != null) {
        final double distFromOwnCar = Geolocator.distanceBetween(
          spotLat,
          spotLon,
          _sensorEngine.parkedLat!,
          _sensorEngine.parkedLon!,
        );
        if (distFromOwnCar < 3.0) continue;
      }

      final bool isLeavingSoon = spot['status'] == 'LEAVING_SOON';
      markers.add(
        Marker(
          point: LatLng(spotLat, spotLon),
          width: 44,
          height: 44,
          child: GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    isLeavingSoon
                        ? 'Stallo in liberazione tra ${spot['availableInMinutes']} min (${spot['distanceMeters']}m)'
                        : 'Stallo LIBERO (${spot['distanceMeters']}m)',
                  ),
                ),
              );
            },
            child: _buildCarSpotBadge(isLeavingSoon ? Colors.orange : Colors.green),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ParkNow!', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_connected),
            tooltip: 'Configura BT Auto',
            onPressed: _selectCarBluetoothDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 52,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(initialCenter: _currentCenter, initialZoom: 17.0),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.parkadvisor_app',
                    ),
                    MarkerLayer(markers: markers),
                  ],
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(_isLoadingApi ? Icons.sync : Icons.local_parking, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_apiStatus, style: const TextStyle(fontWeight: FontWeight.w600))),
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: _centerAndRefreshMap,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 48,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Stato Sensor Fusion:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      Chip(
                        label: Text(
                          _sensorEngine.currentState.name.toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                        backgroundColor: Colors.indigo,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Velocità: ${_sensorEngine.currentSpeedKmh.toStringAsFixed(1)} km/h  |  '
                    'Giroscopio: ${_sensorEngine.gyroscopeMagnitude.toStringAsFixed(2)} rad/s',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(
                    'Pedometro: ${_sensorEngine.pedestrianStatus} (${_sensorEngine.sessionSteps} passi)  |  '
                    'BT Auto: ${_sensorEngine.targetCarBluetoothMac ?? "Non associato"}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (_sensorEngine.distanceFromCarMeters != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Distanza dall\'auto parcheggiata: ${_sensorEngine.distanceFromCarMeters!.toStringAsFixed(1)} m (Soglia: 100m)',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.indigo),
                      ),
                    ),
                  const Divider(height: 20),
                  const Text('Simulazione Ciclo Sosta (Collaudo API + DB):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _sensorEngine.forceParkHere(),
                          child: const Text('1. Parcheggia qui', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _sensorEngine.forceLeavingSoon(),
                          child: const Text('2. Entro 100m', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _sensorEngine.forceReleaseCar(),
                          child: const Text('3. Ripartito', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
