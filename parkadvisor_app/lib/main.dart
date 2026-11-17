import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'profile_screen.dart';
import 'sensor_fusion_engine.dart';

void main() => runApp(const ParkNowApp());

class ParkNowApp extends StatelessWidget {
  const ParkNowApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ParkNow!',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
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
  static const String _backendBaseUrl = 'https://parknow-api.onrender.com';
  static const String _userId = 'USER-001';

  final MapController _mapController = MapController();
  LatLng _currentCenter = const LatLng(41.85784, 12.55860);

  late SensorFusionEngine _sensorEngine;
  List<dynamic> _availableSpots = [];
  String _apiStatus = 'Sincronizzazione mappa...';
  bool _isLoadingApi = false;
  bool _hasUserLocation = false;
  int _searchRadiusM = 500;

  Map<String, String> get _headers => {'Content-Type': 'application/json', 'Accept': 'application/json'};

  @override
  void initState() {
    super.initState();
    _sensorEngine = SensorFusionEngine(
      onCarParked: _handleCarParked,
      onApproachingCar100m: _handleApproachingCar100m,
      onManualReleaseConfirmed: _handleManualReleaseConfirmed,
      onEtaUpdated: _handleEtaUpdated,
      onCarReleased: _handleCarReleased,
      onAutoShareSkipped: _handleAutoShareSkipped,
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

  Future<void> _loadSearchRadius() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('search_radius_m') ?? 500;
    if (mounted) setState(() => _searchRadiusM = saved);
  }

  Future<void> _initPermissionsAndEngine() async {
    await _loadSearchRadius();
    await Geolocator.requestPermission();
    await _sensorEngine.initialize();
    await _centerAndRefreshMap();
  }

  void _promptSaveUnknownWifi(String ssid) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.wifi, color: Colors.indigo, size: 32),
        title: const Text('Nuova rete Wi-Fi rilevata'),
        content: Text('Sei connesso a "$ssid". Vuoi registrarla come Casa o Lavoro?'),
        actions: [
          TextButton(onPressed: () { _sensorEngine.ignoreWifi(ssid); Navigator.pop(ctx); }, child: const Text('Ignora')),
          OutlinedButton(onPressed: () async { await _sensorEngine.saveWifiAsWork(ssid); if (ctx.mounted) Navigator.pop(ctx); }, child: const Text('Lavoro')),
          ElevatedButton(onPressed: () async { await _sensorEngine.saveWifiAsHome(ssid); if (ctx.mounted) Navigator.pop(ctx); }, child: const Text('Casa')),
        ],
      ),
    );
  }

  void _promptSaveUnknownBluetooth(String mac, String name) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.directions_car, color: Colors.indigo, size: 32),
        title: const Text('Nuovo dispositivo Bluetooth'),
        content: Text('Collegato a "$name" ($mac). È la tua auto?'),
        actions: [
          TextButton(onPressed: () { _sensorEngine.ignoreBluetoothDevice(mac); Navigator.pop(ctx); }, child: const Text('Ignora')),
          ElevatedButton(onPressed: () async { await _sensorEngine.setCarBluetoothDevice(mac, name); if (ctx.mounted) Navigator.pop(ctx); }, child: const Text('Sì, è la mia auto')),
        ],
      ),
    );
  }

  Future<void> _handleCarParked(double lat, double lon, String method) async {
    try {
      await http.post(Uri.parse('$_backendBaseUrl/api/parking/park'), headers: _headers,
        body: json.encode({'userId': _userId, 'latitude': lat, 'longitude': lon, 'detectionMethod': method}));
      await _fetchAvailableSpots(_currentCenter.latitude, _currentCenter.longitude);
    } catch (_) {}
  }

  Future<void> _handleApproachingCar100m(int estimatedMinutes) async {
    if (!mounted) return;
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.notifications_active, color: Colors.orange, size: 34),
        title: const Text('Stai tornando all\'auto (< 100m)'),
        content: Text(
          'Confermi che stai liberando il parcheggio tra circa $estimatedMinutes minuti?\n\n'
          'Nota anti-frode: i crediti vengono accreditati alla partenza entro il tempo limite; in caso di mancata partenza scatta una penalità.\n\n'
          'Se ignori questo avviso, il rilascio partirà in automatico all\'aggancio BT/GPS/Giroscopio (se attivo nel profilo).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ignora')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white),
            onPressed: () async { Navigator.pop(ctx); await _sensorEngine.confirmManualReleaseIntent(); },
            child: const Text('Conferma rilascio'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleEtaUpdated(int m) async {
    try { await http.post(Uri.parse("$_backendBaseUrl/api/parking/leaving"), headers: _headers, body: json.encode({"userId": _userId, "availableInMinutes": m})); } catch (_) {}
  }
  Future<void> _handleManualReleaseConfirmed(int estimatedMinutes) async {
    try {
      final res = await http.post(Uri.parse('$_backendBaseUrl/api/parking/confirm-release'), headers: _headers,
        body: json.encode({'userId': _userId, 'availableInMinutes': estimatedMinutes}));
      if (res.statusCode == 200 && mounted) {
        final delta = json.decode(res.body)['deltaMinutes'] ?? 5;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.orange.shade800, content: Text('Rilascio confermato! Libera il posto entro $delta min per ricevere i crediti.')),
        );
      }
      await _fetchAvailableSpots(_currentCenter.latitude, _currentCenter.longitude);
    } catch (_) {}
  }

  void _handleAutoShareSkipped() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Partenza rilevata, ma la condivisione automatica è disattivata nel profilo.')),
    );
  }

  Future<void> _handleCarReleased() async {
    try {
      final res = await http.post(Uri.parse('$_backendBaseUrl/api/parking/release'), headers: _headers,
        body: json.encode({'userId': _userId}));
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        final awarded = data['creditsAwarded'] ?? 0;
        final balance = data['newBalance'];
        if (awarded > 0) {
          final prefs = await SharedPreferences.getInstance();
          if (balance != null) await prefs.setInt('credits_balance', (balance as num).toInt());
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(backgroundColor: Colors.green.shade700, content: Text('Stallo liberato! +$awarded crediti accreditati (Saldo: $balance)')),
          );
        }
      }
      await _fetchAvailableSpots(_currentCenter.latitude, _currentCenter.longitude);
    } catch (_) {}
  }

  Future<void> _centerAndRefreshMap() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final newPos = LatLng(pos.latitude, pos.longitude);
      setState(() { _currentCenter = newPos; _hasUserLocation = true; });
      _mapController.move(newPos, 17.0);
      await _fetchAvailableSpots(pos.latitude, pos.longitude);
    } catch (e) {
      setState(() => _apiStatus = 'Errore GPS: $e');
    }
  }

  Future<void> _fetchAvailableSpots(double lat, double lon) async {
    setState(() { _isLoadingApi = true; _apiStatus = 'Ricerca stalli entro ${_searchRadiusM}m...'; });
    try {
      final url = Uri.parse('$_backendBaseUrl/api/parking/nearby?lat=$lat&lon=$lon&radius=$_searchRadiusM');
      final response = await http.get(url, headers: _headers).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final spots = json.decode(response.body)['spots'] as List<dynamic>? ?? [];
        setState(() {
          _availableSpots = spots;
          _apiStatus = spots.isEmpty ? 'Nessuno stallo entro ${_searchRadiusM}m' : '${spots.length} stalli disponibili entro ${_searchRadiusM}m';
          _isLoadingApi = false;
        });
      } else {
        setState(() { _apiStatus = 'Errore server (HTTP ${response.statusCode})'; _isLoadingApi = false; });
      }
    } catch (e) {
      setState(() { _apiStatus = 'Errore connessione: $e'; _isLoadingApi = false; });
    }
  }

  Future<void> _openConnectivityProfileDialog() async {
    final classicPaired = await _sensorEngine.getPairedClassicBluetoothDevices();
    final bleConnected = FlutterBluePlus.connectedDevices;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Profilo Connettività'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Wi-Fi attuale: ${_sensorEngine.currentConnectedWifiSsid ?? "Non connesso"}', style: const TextStyle(fontSize: 12)),
            Text('Casa: ${_sensorEngine.homeWifiSsid ?? "-"} | Lavoro: ${_sensorEngine.workWifiSsid ?? "-"}', style: const TextStyle(fontSize: 12, color: Colors.indigo)),
            const Divider(height: 16),
            ...classicPaired.map((d) => ListTile(
              dense: true, leading: const Icon(Icons.directions_car, color: Colors.indigo),
              title: Text(d['name'] ?? 'Auto BT'), subtitle: Text(d['mac'] ?? ''),
              onTap: () { _sensorEngine.setCarBluetoothDevice(d['mac']!, d['name'] ?? 'Auto BT'); Navigator.pop(ctx); },
            )),
            ...bleConnected.map((d) => ListTile(
              dense: true, leading: const Icon(Icons.bluetooth, color: Colors.blue),
              title: Text(d.platformName.isNotEmpty ? d.platformName : 'BLE'), subtitle: Text(d.remoteId.str),
              onTap: () { _sensorEngine.setCarBluetoothDevice(d.remoteId.str, d.platformName.isNotEmpty ? d.platformName : 'Auto BLE'); Navigator.pop(ctx); },
            )),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Chiudi'))],
      ),
    );
  }

  Widget _buildCarSpotBadge(Color c, {int? mins}) => Container(
    decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2.5)),
    alignment: Alignment.center,
    child: mins != null
        ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text("$mins", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15, height: 1.0)),
            const Text("min", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 9, height: 1.0)),
          ])
        : const Icon(Icons.directions_car, color: Colors.white, size: 22),
  );

  @override
  void dispose() {
    _sensorEngine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Marker> markers = [];
    if (_hasUserLocation) {
      markers.add(Marker(point: _currentCenter, width: 36, height: 36, child: const Icon(Icons.my_location, color: Colors.blue, size: 26)));
    }
    if (_sensorEngine.parkedLat != null && _sensorEngine.parkedLon != null) {
      markers.add(Marker(
        point: LatLng(_sensorEngine.parkedLat!, _sensorEngine.parkedLon!), width: 44, height: 44,
        child: _buildCarSpotBadge(_sensorEngine.isManualReleaseConfirmed ? Colors.orange : Colors.indigo, mins: _sensorEngine.isManualReleaseConfirmed ? _sensorEngine.estimatedMinutesToRelease : null),
      ));
    }
    for (var spot in _availableSpots) {
      final double sLat = (spot['latitude'] as num).toDouble(), sLon = (spot['longitude'] as num).toDouble();
      if (_sensorEngine.parkedLat != null && Geolocator.distanceBetween(sLat, sLon, _sensorEngine.parkedLat!, _sensorEngine.parkedLon!) < 3.0) continue;
      final bool isLeaving = spot['status'] == 'LEAVING_SOON';
      markers.add(Marker(
        point: LatLng(sLat, sLon), width: 44, height: 44,
        child: GestureDetector(
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isLeaving ? 'In liberazione tra ${spot['availableInMinutes']} min (${spot['distanceMeters']}m)' : 'Stallo LIBERO (${spot['distanceMeters']}m)'),
          )),
          child: _buildCarSpotBadge(isLeaving ? Colors.orange : Colors.green, mins: isLeaving ? ((spot['availableInMinutes'] as num?)?.toInt() ?? 1) : null),
        ),
      ));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ParkNow!', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Profilo, Veicolo e Crediti',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
              await _loadSearchRadius();
              await _sensorEngine.reloadUserPreferences();
              await _fetchAvailableSpots(_currentCenter.latitude, _currentCenter.longitude);
            },
          ),
          IconButton(icon: const Icon(Icons.settings_bluetooth), onPressed: _openConnectivityProfileDialog),
        ],
      ),
      body: Column(children: [
        Expanded(
          flex: 52,
          child: Stack(children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(initialCenter: _currentCenter, initialZoom: 17.0),
              children: [
                TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.parkadvisor_app'),
                MarkerLayer(markers: markers),
              ],
            ),
            Positioned(
              top: 10, left: 10, right: 10,
              child: Card(child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  Icon(_isLoadingApi ? Icons.sync : Icons.local_parking, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_apiStatus, style: const TextStyle(fontWeight: FontWeight.w600))),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: _centerAndRefreshMap),
                ]),
              )),
            ),
          ]),
        ),
        Expanded(
          flex: 48,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Stato Sensor Fusion:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                Chip(
                  label: Text(_sensorEngine.currentState.name.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  backgroundColor: _sensorEngine.currentState == VehicleState.stayAtHome ? Colors.teal : Colors.indigo,
                ),
              ]),
              const SizedBox(height: 6),
              Text('Velocità: ${_sensorEngine.currentSpeedKmh.toStringAsFixed(1)} km/h | Giroscopio: ${_sensorEngine.gyroscopeMagnitude.toStringAsFixed(2)} rad/s', style: const TextStyle(fontSize: 13)),
              Text('Pedometro: ${_sensorEngine.pedestrianStatus} (${_sensorEngine.sessionSteps} passi) | Auto-share: ${_sensorEngine.autoShareEnabled ? "ON" : "OFF"}', style: const TextStyle(fontSize: 13)),
              Text('BT Auto: ${_sensorEngine.targetCarBluetoothName ?? _sensorEngine.targetCarBluetoothMac ?? "Non associato"} | Raggio: ${_searchRadiusM}m', style: const TextStyle(fontSize: 13)),
              if (_sensorEngine.distanceFromCarMeters != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Distanza dall\'auto: ${_sensorEngine.distanceFromCarMeters!.toStringAsFixed(1)} m (Soglia: 100m)', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.indigo)),
                ),
              const Divider(height: 20),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => _sensorEngine.forceParkHere(), child: const Text('1. Parcheggia', style: TextStyle(fontSize: 12)))),
                const SizedBox(width: 6),
                Expanded(child: OutlinedButton(onPressed: () => _sensorEngine.forceLeavingSoon(), child: const Text('2. Entro 100m', style: TextStyle(fontSize: 12)))),
                const SizedBox(width: 6),
                Expanded(child: OutlinedButton(onPressed: () => _sensorEngine.forceReleaseCar(), child: const Text('3. Ripartito', style: TextStyle(fontSize: 12)))),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}
