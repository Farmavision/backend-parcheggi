import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);

    _sensorEngine = SensorFusionEngine(
      onCarParked: _handleCarParked,
      onApproachingCar100m: _handleApproachingCar100m,
      onManualReleaseConfirmed: _handleManualReleaseConfirmed,
      onEtaUpdated: _handleEtaUpdated,
      onCarReleased: _handleCarReleased,
      onAutoShareSkipped: _handleAutoShareSkipped,
      onUnknownWifiDetected: _promptSaveUnknownWifi,
      onUnknownBluetoothDetected: _promptSaveUnknownBluetooth,
      onPromptAreYouInCar: _promptAreYouInCar,
    );
    _sensorEngine.addListener(() {
      if (!mounted) return;
      setState(() {});
      _syncDepartureFullScreenAlert();
    });
    _initApp();
    _antiFraudWatchTimer = Timer.periodic(const Duration(seconds: 15), (_) => _checkPendingReleaseExpiration());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sensorEngine.setAppForegroundState(true);
    } else if (state == AppLifecycleState.paused) {
      _sensorEngine.setAppForegroundState(false);
    }
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
    unawaited(_loadLocalAndRemoteUser());
    await _sensorEngine.initialize();
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      await const MethodChannel('parknow/bg_service').invokeMethod('requestFullScreenIntentPermission');
    } catch (_) {}
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

  bool _isDepartureAlertOpen = false;
  BuildContext? _departureAlertCtx;

  String _departureSourceLabel(String src) {
    switch (src) {
      case 'bt':
        return 'Connessione Bluetooth Auto rilevata';
      case 'charging':
        return 'Ricarica in auto (USB / Induttiva) rilevata';
      case 'gps':
        return 'Movimento veicolare GPS rilevato';
      default:
        return 'Ingresso in auto rilevato';
    }
  }

  void _syncDepartureFullScreenAlert() {
    if (!mounted) return;
    if (_sensorEngine.departureCountdownActive && !_isDepartureAlertOpen) {
      _isDepartureAlertOpen = true;
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_sensorEngine.departureCountdownActive) {
          _isDepartureAlertOpen = false;
          return;
        }
        showGeneralDialog(
          context: context,
          barrierDismissible: false,
          barrierColor: const Color(0xF2121629),
          transitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (dlgCtx, _, __) {
            _departureAlertCtx = dlgCtx;
            return PopScope(
              canPop: false,
              child: Scaffold(
                backgroundColor: const Color(0xFF121629),
                body: SafeArea(
                  child: AnimatedBuilder(
                    animation: _sensorEngine,
                    builder: (context, _) {
                      final total = _sensorEngine.tCountdownSec > 0 ? _sensorEngine.tCountdownSec : 30;
                      final rem = _sensorEngine.departureCountdownSec.clamp(0, total);
                      final progress = total > 0 ? rem / total : 0.0;
                      final srcLabel = _departureSourceLabel(_sensorEngine.departureTriggerSource);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.indigoAccent.withOpacity(0.22),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.indigoAccent.withOpacity(0.6)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.directions_car_filled, color: Colors.amberAccent, size: 18),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          srcLabel,
                                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 28),
                                const Text(
                                  'Il sistema ha rilevato la ripartenza',
                                  style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold, height: 1.2),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _sensorEngine.isCarParked
                                      ? 'Stato impostato su In Auto. Allo scadere del conto alla rovescia il parcheggio verrà rilasciato automaticamente.'
                                      : 'Stato impostato su In Auto. Allo scadere del conto alla rovescia la ripartenza sarà confermata automaticamente.',
                                  style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                            SizedBox(
                              width: 190,
                              height: 190,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  SizedBox(
                                    width: 190,
                                    height: 190,
                                    child: CircularProgressIndicator(
                                      value: progress,
                                      strokeWidth: 12,
                                      backgroundColor: Colors.white12,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        rem <= 10 ? Colors.redAccent : Colors.amberAccent,
                                      ),
                                    ),
                                  ),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '$rem',
                                        style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.w900),
                                      ),
                                      const Text(
                                        'secondi',
                                        style: TextStyle(color: Colors.white60, fontSize: 15, letterSpacing: 1.1),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              children: [
                                const Text(
                                  'Non sei in auto? Premi il tasto qui sotto per annullare:',
                                  style: TextStyle(color: Colors.white60, fontSize: 13),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  height: 62,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red.shade600,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      elevation: 6,
                                    ),
                                    onPressed: () async {
                                      await _sensorEngine.denyDepartureCountdown();
                                    },
                                    icon: const Icon(Icons.close_rounded, size: 28),
                                    label: const Text(
                                      'NEGA',
                                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ).whenComplete(() {
          _isDepartureAlertOpen = false;
          _departureAlertCtx = null;
        });
      });
    } else if (!_sensorEngine.departureCountdownActive && _isDepartureAlertOpen) {
      final ctx = _departureAlertCtx;
      _departureAlertCtx = null;
      _isDepartureAlertOpen = false;
      if (ctx != null && ctx.mounted) {
        Navigator.of(ctx).pop();
      }
    }
  }

  void _promptAreYouInCar() {
    if (!mounted) return;
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.mediumImpact();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.directions_car, color: Colors.deepPurple, size: 34),
        title: const Text('Sei in auto?'),
        content: const Text('Rilevato spostamento superiore a 10 km/h senza Bluetooth auto collegato.'),
        actions: [
          TextButton(
            onPressed: () {
              _sensorEngine.dismissUserInCarPrompt();
              Navigator.pop(ctx);
            },
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _sensorEngine.confirmUserInCarFromPrompt();
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) _promptDidYouLeaveParking();
            },
            child: const Text('Sì, sono in auto'),
          ),
        ],
      ),
    );
  }

  void _promptDidYouLeaveParking() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.local_parking, color: Colors.orange, size: 34),
        title: const Text('Hai appena lasciato il parcheggio?'),
        content: const Text('Confermi di aver lasciato lo stallo così da avviare la segnalazione di rilascio?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (ctx.mounted) Navigator.pop(ctx);
              await _sensorEngine.confirmParkingLeftFromPrompt();
            },
            child: const Text('Sì, libera parcheggio'),
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
        title: const Text('Stai lasciando il parcheggio?'),
        content: Text('Rilevato stato In Movimento (arrivo stimato in $minLabel).\n\nConferma per segnalare lo stallo in rilascio o rifiuta se non stai prendendo l\'auto.'),
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
        final alreadyFree = data['alreadyFree'] == true;
        final awarded = (data['creditsAwarded'] as num?)?.toInt() ?? (alreadyFree ? 0 : 10);
        if (newBal != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('credits_balance', newBal);
          setState(() => _creditsBalance = newBal);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.green.shade700,
            content: Text(
              awarded > 0
                  ? 'Stallo liberato con successo! +$awarded crediti guadagnati.'
                  : 'Stallo liberato sulla mappa! Saldo crediti aggiornato.',
            ),
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
    WidgetsBinding.instance.removeObserver(this);
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
              await _sensorEngine.reloadUserPreferences();
              _loadLocalAndRemoteUser();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: () {
              switch (_sensorEngine.userActivityState) {
                case UserActivityState.atHome:
                case UserActivityState.atWork:
                  return Colors.indigo.shade50;
                case UserActivityState.still:
                  return Colors.amber.shade50;
                case UserActivityState.moving:
                  return Colors.green.shade50;
                case UserActivityState.inCar:
                  return Colors.deepPurple.shade50;
              }
            }(),
            child: ListTile(
              leading: Icon(
                () {
                  switch (_sensorEngine.userActivityState) {
                    case UserActivityState.atHome:
                      return Icons.home;
                    case UserActivityState.atWork:
                      return Icons.work;
                    case UserActivityState.still:
                      return Icons.person_pin_circle;
                    case UserActivityState.moving:
                      return Icons.directions_walk;
                    case UserActivityState.inCar:
                      return Icons.directions_car;
                  }
                }(),
                color: () {
                  switch (_sensorEngine.userActivityState) {
                    case UserActivityState.atHome:
                    case UserActivityState.atWork:
                      return Colors.indigo.shade800;
                    case UserActivityState.still:
                      return Colors.amber.shade900;
                    case UserActivityState.moving:
                      return Colors.green.shade800;
                    case UserActivityState.inCar:
                      return Colors.deepPurple.shade800;
                  }
                }(),
                size: 36,
              ),
              title: Text(
                'Stato utente: ${_sensorEngine.userActivityLabel}',
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
                onPressed: () async {
                  await _sensorEngine.simulateParkHere();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        duration: Duration(seconds: 2),
                        content: Text('Parcheggio simulato attivo! Fai 3+ passi fuori Wi-Fi per testare il rilascio.'),
                      ),
                    );
                  }
                },
                icon: Icon(
                  _sensorEngine.isCarParked ? Icons.check_circle : Icons.pin_drop,
                  color: _sensorEngine.isCarParked ? Colors.green.shade700 : null,
                ),
                label: Text(_sensorEngine.isCarParked ? '1. Parcheggio Attivo (Riarma)' : '1. Simula Parcheggio'),
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
