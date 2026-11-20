import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'map_modes_screen.dart';
import 'profile_screen.dart';
import 'sensor_fusion_engine.dart';
import 'notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().init();
  runApp(const ParkNowApp());
}

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

  late SensorFusionEngine _sensorEngine;
  int _searchRadiusM = 500;
  int _creditsBalance = 50;
  Timer? _antiFraudWatchTimer;

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
      if (mounted) setState(() {});
    });
    _initApp();
    _antiFraudWatchTimer = Timer.periodic(const Duration(seconds: 15), (_) => _checkPendingReleaseExpiration());
  }

  Future<void> _loadLocalAndRemoteUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _searchRadiusM = prefs.getInt('search_radius_m') ?? 500;
        _creditsBalance = prefs.getInt('credits_balance') ?? 50;
      });
    }
    try {
      final res = await http
          .get(Uri.parse('$_backendBaseUrl/api/user/profile?userId=$_userId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        final remoteBal = (data['credits_balance'] as num?)?.toInt();
        final remoteRad = (data['search_radius_m'] as num?)?.toInt();
        if (remoteBal != null) {
          await prefs.setInt('credits_balance', remoteBal);
          setState(() => _creditsBalance = remoteBal);
        }
        if (remoteRad != null) {
          await prefs.setInt('search_radius_m', remoteRad);
          setState(() => _searchRadiusM = remoteRad);
        }
      }
    } catch (_) {}
  }

  Future<void> _initApp() async {
    await _loadLocalAndRemoteUser();
    await Geolocator.requestPermission();
    await _sensorEngine.initialize();
  }

  Future<void> _checkPendingReleaseExpiration() async {
    if (!mounted || !_sensorEngine.isManualReleaseConfirmed) return;
    try {
      final res = await http
          .get(Uri.parse('$_backendBaseUrl/api/parking/my-spot?userId=$_userId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && mounted) {
        final spot = json.decode(res.body)['spot'];
        if (spot == null || spot['status'] == 'OCCUPIED') {
          _sensorEngine.resetExpiredReleaseConfirmation();
          await _loadLocalAndRemoteUser();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.red.shade700,
                content: Text('Anti-frode: stallo non liberato entro il limite. Penalità applicata (Saldo: $_creditsBalance).'),
              ),
            );
          }
        }
      }
    } catch (_) {}
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
      await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/park'),
        headers: _headers,
        body: json.encode({'userId': _userId, 'latitude': lat, 'longitude': lon, 'detectionMethod': method}),
      );
    } catch (_) {}
  }

  Future<void> _handleApproachingCar100m(int estimatedMinutes) async {
    if (!mounted) return;
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    final minLabel = estimatedMinutes == 1 ? '1 minuto' : '$estimatedMinutes minuti';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.notifications_active, color: Colors.orange, size: 34),
        title: const Text('Ti stai avvicinando all\'auto!'),
        content: Text('Sei entro 100m dal tuo veicolo (arrivo stimato in $minLabel).\n\nSe ignori questo avviso, il rilascio scatterà automaticamente solo alla ripartenza in auto.'),
        actions: [
          TextButton(
            onPressed: () {
              _sensorEngine.cancelAutoRelease();
              Navigator.pop(ctx);
            },
            child: const Text('Rifiuta / Non parto'),
          ),
          ElevatedButton(
            onPressed: () {
              _sensorEngine.confirmManualRelease(estimatedMinutes);
              Navigator.pop(ctx);
            },
            child: const Text('Conferma Rilascio'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleManualReleaseConfirmed(int minutes) async {
    try {
      await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/confirm-release'),
        headers: _headers,
        body: json.encode({'userId': _userId, 'availableInMinutes': minutes}),
      );
    } catch (_) {}
  }

  Future<void> _handleEtaUpdated(int minutes) async {
    try {
      await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/leaving'),
        headers: _headers,
        body: json.encode({'userId': _userId, 'availableInMinutes': minutes}),
      );
    } catch (_) {}
  }

  Future<void> _handleCarReleased() async {
    try {
      final res = await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/release'),
        headers: _headers,
        body: json.encode({'userId': _userId}),
      );
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        final newBal = (data['newBalance'] as num?)?.toInt();
        final awarded = (data['creditsAwarded'] as num?)?.toInt() ?? 10;
        if (newBal != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('credits_balance', newBal);
          setState(() => _creditsBalance = newBal);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.green.shade700,
            content: Text('Stallo liberato con successo! +$awarded crediti guadagnati.'),
          ),
        );
      }
    } catch (_) {}
  }

  void _handleAutoShareSkipped(String reason) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Auto-condivisione saltata: $reason')),
    );
  }

  @override
  void dispose() {
    _antiFraudWatchTimer?.cancel();
    _sensorEngine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ParkNow!'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(16)),
              child: Text('$_creditsBalance cr', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Profilo e Impostazioni',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
              _loadLocalAndRemoteUser();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: _sensorEngine.isCarParked ? Colors.orange.shade50 : Colors.green.shade50,
            child: ListTile(
              leading: Icon(
                _sensorEngine.isCarParked ? Icons.local_parking : Icons.directions_car,
                color: _sensorEngine.isCarParked ? Colors.orange.shade800 : Colors.green.shade800,
                size: 36,
              ),
              title: Text(
                _sensorEngine.isCarParked ? 'Auto Parcheggiata' : 'In Movimento / Nessuna Sosta',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(_sensorEngine.statusMessage),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FindMyCarScreen(
                          sensorEngine: _sensorEngine,
                          backendBaseUrl: _backendBaseUrl,
                          userId: _userId,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.directions_car),
                  label: const Text('Trova la mia auto', textAlign: TextAlign.center),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SearchParkingScreen(
                          sensorEngine: _sensorEngine,
                          backendBaseUrl: _backendBaseUrl,
                          userId: _userId,
                          searchRadiusM: _searchRadiusM,
                        ),
                      ),
                    );
                    _loadLocalAndRemoteUser();
                  },
                  icon: const Icon(Icons.local_parking),
                  label: const Text('Trova parcheggio', textAlign: TextAlign.center),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Pannello Collaudo & Simulazione', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _sensorEngine.simulateParkHere(),
                icon: const Icon(Icons.pin_drop),
                label: const Text('1. Simula Parcheggio'),
              ),
              OutlinedButton.icon(
                onPressed: () => _sensorEngine.simulateApproach100m(),
                icon: const Icon(Icons.radar),
                label: const Text('2. Simula Avvicinamento 100m'),
              ),
              OutlinedButton.icon(
                onPressed: () => _sensorEngine.simulateDeparture(),
                icon: const Icon(Icons.exit_to_app),
                label: const Text('3. Simula Ripartenza'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}