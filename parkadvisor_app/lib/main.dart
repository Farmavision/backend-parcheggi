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
      onUnknownWifiDetected: _promptSaveUnknownWifi,
      onUnknownBluetoothDetected: _promptSaveUnknownBluetooth,
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

  // Popup automatico al rilevamento di una nuova rete Wi-Fi
  void _promptSaveUnknownWifi(String ssid) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.wifi, color: Colors.indigo, size: 32),
        title: const Text('Nuova rete Wi-Fi rilevata'),
        content: Text(
          'Sei connesso a "$ssid".\n\n'
          'Vuoi registrarla come rete di Casa o Lavoro per attivare in automatico la modalità Stay at Home (senza pubblicare stalli in garage/cortile)?',
        ),
        actions: [
          TextButton(
            onPressed: () {
              _sensorEngine.ignoreWifi(ssid);
              Navigator.pop(ctx);
            },
            child: const Text('Ignora'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.work, size: 16),
            label: const Text('Lavoro'),
            onPressed: () async {
              await _sensorEngine.saveWifiAsWork(ssid);
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.home, size: 16),
            label: const Text('Casa'),
            onPressed: () async {
              await _sensorEngine.saveWifiAsHome(ssid);
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  // Popup automatico al rilevamento di una nuova connessione Bluetooth
  void _promptSaveUnknownBluetooth(String mac, String name) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.directions_car, color: Colors.indigo, size: 32),
        title: const Text('Nuovo dispositivo Bluetooth'),
        content: Text(
          'Il telefono si è collegato a "$name" ($mac).\n\n'
          'È il sistema Bluetooth della tua auto? Se confermi, ParkNow! rileverà automaticamente quando sali e scendi.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              _sensorEngine.ignoreBluetoothDevice(mac);
              Navigator.pop(ctx);
            },
            child: const Text('No, ignora'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _sensorEngine.setCarBluetoothDevice(mac, name);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Sì, è la mia auto'),
          ),
        ],
      ),
    );
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

  Future<void> _openConnectivityProfileDialog() async {
    final classicPaired = await _sensorEngine.getPairedClassicBluetoothDevices();
    final bleConnected = FlutterBluePlus.connectedDevices;

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Profilo Connettività Account'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('1. Reti Wi-Fi Private (Stay at Home / Work):', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Wi-Fi attuale: ${_sensorEngine.currentConnectedWifiSsid ?? "Non connesso"}', style: const TextStyle(fontSize: 12)),
              Text('Casa: ${_sensorEngine.homeWifiSsid ?? "Non impostato"} | Lavoro: ${_sensorEngine.workWifiSsid ?? "Non impostato"}',
                  style: const TextStyle(fontSize: 12, color: Colors.indigo)),
              if (_sensorEngine.currentConnectedWifiSsid != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.home, size: 16),
                        label: const Text('Salva Casa', style: TextStyle(fontSize: 11)),
                        onPressed: () async {
                          await _sensorEngine.saveWifiAsHome(_sensorEngine.currentConnectedWifiSsid!);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.work, size: 16),
                        label: const Text('Salva Lavoro', style: TextStyle(fontSize: 11)),
                        onPressed: () async {
                          await _sensorEngine.saveWifiAsWork(_sensorEngine.currentConnectedWifiSsid!);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                    ),
                  ],
                ),
              ],
              const Divider(height: 20),
              const Text('2. Bluetooth Auto (Classico & BLE):', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              if (classicPaired.isEmpty && bleConnected.isEmpty)
                const Text('Nessun dispositivo Bluetooth trovato.', style: TextStyle(color: Colors.grey, fontSize: 12))
              else ...[
                ...classicPaired.map((d) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.directions_car, color: Colors.indigo),
                      title: Text(d['name'] ?? 'Auto BT'),
                      subtitle: Text('${d['mac']} (BT Classico)'),
                      onTap: () {
                        _sensorEngine.setCarBluetoothDevice(d['mac']!, d['name'] ?? 'Auto BT');
                        Navigator.pop(ctx);
                      },
                    )),
                ...bleConnected.map((d) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.bluetooth, color: Colors.blue),
                      title: Text(d.platformName.isNotEmpty ? d.platformName : 'Dispositivo BLE'),
                      subtitle: Text('${d.remoteId.str} (BLE)'),
                      onTap: () {
                        _sensorEngine.setCarBluetoothDevice(
                          d.remoteId.str,
                          d.platformName.isNotEmpty ? d.platformName : 'Auto BLE',
                        );
                        Navigator.pop(ctx);
                      },
                    )),
              ],
            ],
          ),
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

    for (var spot in _availableSpots) {
      final double spotLat = (spot['latitude'] as num).toDouble();
      final double spotLon = (spot['longitude'] as num).toDouble();

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
            icon: const Icon(Icons.settings_bluetooth),
            tooltip: 'Configura BT Auto e Wi-Fi Casa/Lavoro',
            onPressed: _openConnectivityProfileDialog,
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
                        backgroundColor: _sensorEngine.currentState == VehicleState.stayAtHome
                            ? Colors.teal
                            : Colors.indigo,
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
                    'Wi-Fi: ${_sensorEngine.currentConnectedWifiSsid ?? "Dati mobili"}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(
                    'BT Auto: ${_sensorEngine.targetCarBluetoothName ?? _sensorEngine.targetCarBluetoothMac ?? "Non associato"}',
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
