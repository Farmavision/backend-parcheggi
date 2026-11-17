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
        title: const Text('Stai tornando all\'auto (< 100m)'),
        content: Text(
          'Confermi che stai liberando il parcheggio tra circa $minLabel (camminata + 1 min messa in moto)?\n\n'
          'Nota anti-frode: i crediti vengono accreditati alla partenza entro il tempo limite; in caso di mancata partenza scatta una penalità.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ignora')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              await _sensorEngine.confirmManualReleaseIntent();
            },
            child: const Text('Conferma rilascio'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleManualReleaseConfirmed(int estimatedMinutes) async {
    try {
      final res = await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/confirm-release'),
        headers: _headers,
        body: json.encode({'userId': _userId, 'availableInMinutes': estimatedMinutes}),
      );
      if (res.statusCode == 200 && mounted) {
        final delta = json.decode(res.body)['deltaMinutes'] ?? 5;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.orange.shade800,
            content: Text('Rilascio confermato ($estimatedMinutes min)! Libera entro $delta min per ricevere i crediti.'),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _handleEtaUpdated(int m) async {
    try {
      await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/leaving'),
        headers: _headers,
        body: json.encode({'userId': _userId, 'availableInMinutes': m}),
      );
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
      final res = await http.post(
        Uri.parse('$_backendBaseUrl/api/parking/release'),
        headers: _headers,
        body: json.encode({'userId': _userId}),
      );
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        final awarded = data['creditsAwarded'] ?? 0;
        final balance = (data['newBalance'] as num?)?.toInt();
        if (balance != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('credits_balance', balance);
          setState(() => _creditsBalance = balance);
        }
        if (awarded > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.green.shade700,
              content: Text('Stallo liberato! +$awarded crediti accreditati (Saldo: $_creditsBalance)'),
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _openConnectivityProfileDialog() async {
    final classicPaired = await _sensorEngine.getPairedClassicBluetoothDevices();
    final bleConnected = FlutterBluePlus.connectedDevices;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connettività Auto & Casa'),
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

  Widget _buildPrimaryActionTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color startColor,
    required Color endColor,
    required VoidCallback onTap,
    String? badgeText,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [startColor, endColor], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [BoxShadow(color: startColor.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 4))],
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          if (badgeText != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                              child: Text(badgeText, style: TextStyle(color: startColor, fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13)),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 18),
              ],
            ),
          ),
        ),
      ),
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
    final bool hasParkedCar = _sensorEngine.parkedLat != null && _sensorEngine.parkedLon != null;
    final bool isReleasing = _sensorEngine.isManualReleaseConfirmed;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ParkNow!', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.indigo.shade800,
        foregroundColor: Colors.white,
        actions: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet, size: 16, color: Colors.amberAccent),
                  const SizedBox(width: 5),
                  Text('$_creditsBalance', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ],
              ),
            ),
          ),
          IconButton(icon: const Icon(Icons.settings_bluetooth), tooltip: 'BT Auto e Wi-Fi Casa', onPressed: _openConnectivityProfileDialog),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Profilo e Impostazioni',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
              await _loadLocalAndRemoteUser();
              await _sensorEngine.reloadUserPreferences();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 1. Scheda Stato Sosta e Rilascio rapido
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              color: isReleasing
                  ? Colors.orange.shade50
                  : hasParkedCar
                      ? Colors.indigo.shade50
                      : Colors.grey.shade100,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isReleasing
                              ? Icons.timer
                              : hasParkedCar
                                  ? Icons.local_parking
                                  : Icons.sensors,
                          color: isReleasing ? Colors.orange.shade800 : Colors.indigo.shade800,
                          size: 28,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isReleasing
                                    ? 'Rilascio confermato (${_sensorEngine.estimatedMinutesToRelease} min)'
                                    : hasParkedCar
                                        ? 'Auto parcheggiata'
                                        : 'Stato: ${_sensorEngine.currentState.name.toUpperCase()}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              Text(
                                isReleasing
                                    ? 'Libera il posto entro il tempo limite per ricevere i crediti'
                                    : hasParkedCar
                                        ? (_sensorEngine.distanceFromCarMeters != null
                                            ? 'Distanza attuale: ${_sensorEngine.distanceFromCarMeters!.round()} m dal veicolo'
                                            : 'Posizione salvata e protetta')
                                        : 'Sensor Fusion attiva • Auto-share ${_sensorEngine.autoShareEnabled ? "ON" : "OFF"}',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (hasParkedCar && !isReleasing) ...[
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade800,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.notifications_active),
                        label: const Text('Sto tornando all\'auto • Segnala rilascio', style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () async => await _sensorEngine.confirmManualReleaseIntent(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            // 2. Pulsante Principale: CERCA PARCHEGGIO
            _buildPrimaryActionTile(
              title: 'Cerca parcheggio',
              subtitle: 'Apri la mappa degli stalli liberi entro $_searchRadiusM m',
              icon: Icons.travel_explore,
              startColor: Colors.teal.shade700,
              endColor: Colors.teal.shade500,
              badgeText: '${_searchRadiusM}m',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SearchParkingScreen(
                      userId: _userId,
                      sensorEngine: _sensorEngine,
                      backendBaseUrl: _backendBaseUrl,
                      searchRadiusM: _searchRadiusM,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 14),

            // 3. Pulsante Principale: TROVA LA MIA AUTO
            _buildPrimaryActionTile(
              title: 'Trova la mia auto',
              subtitle: hasParkedCar
                  ? 'Visualizza su mappa lo stallo dove hai parcheggiato'
                  : 'Controlla sulla mappa l\'ultimo parcheggio registrato',
              icon: Icons.directions_car,
              startColor: Colors.indigo.shade800,
              endColor: Colors.blue.shade600,
              badgeText: hasParkedCar
                  ? (_sensorEngine.distanceFromCarMeters != null ? '${_sensorEngine.distanceFromCarMeters!.round()}m' : 'ATTIVO')
                  : null,
              onTap: () {
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
            ),
            const SizedBox(height: 22),

            // 4. Telemetria compatta e comandi di simulazione test
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Telemetria: ${_sensorEngine.currentSpeedKmh.toStringAsFixed(1)} km/h • '
                    'Passi: ${_sensorEngine.sessionSteps} • '
                    'BT: ${_sensorEngine.targetCarBluetoothName ?? "Non associato"}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 10),
                  const Text('Simulazione Ciclo Sosta (Collaudo):', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(child: OutlinedButton(onPressed: () => _sensorEngine.forceParkHere(), child: const Text('1. Parcheggia', style: TextStyle(fontSize: 11)))),
                      const SizedBox(width: 6),
                      Expanded(child: OutlinedButton(onPressed: () => _sensorEngine.forceLeavingSoon(), child: const Text('2. Entro 100m', style: TextStyle(fontSize: 11)))),
                      const SizedBox(width: 6),
                      Expanded(child: OutlinedButton(onPressed: () => _sensorEngine.forceReleaseCar(), child: const Text('3. Ripartito', style: TextStyle(fontSize: 11)))),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
