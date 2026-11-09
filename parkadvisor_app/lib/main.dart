import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const ParkAdvisorApp());
}

class ParkAdvisorApp extends StatelessWidget {
  const ParkAdvisorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ParkAdvisor',
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

  String _gpsStatus = 'In attesa di rilevamento...';
  String _bleStatus = 'Pronto per la scansione';
  String _apiStatus = 'Nessuna richiesta effettuata';
  
  bool _isLoadingGps = false;
  bool _isScanningBle = false;
  bool _isLoadingApi = false;

  double? _currentLat;
  double? _currentLon;

  List<dynamic> _nearbySpots = [];
  List<ScanResult> _scanResults = [];

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isLoadingGps = true;
      _gpsStatus = 'Richiesta posizione in corso...';
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _gpsStatus = 'I servizi GPS sono disattivati.';
          _isLoadingGps = false;
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _gpsStatus = 'Permesso posizione negato dall\'utente.';
            _isLoadingGps = false;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _gpsStatus = 'Permessi negati permanentemente.';
          _isLoadingGps = false;
        });
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _currentLat = position.latitude;
        _currentLon = position.longitude;
        _gpsStatus = 'Lat: ${position.latitude.toStringAsFixed(5)}, Lon: ${position.longitude.toStringAsFixed(5)}';
        _isLoadingGps = false;
      });

      // Interroga automaticamente il server dopo aver rilevato la posizione
      await _fetchNearbyParkings(position.latitude, position.longitude);
    } catch (e) {
      setState(() {
        _gpsStatus = 'Errore GPS: $e';
        _isLoadingGps = false;
      });
    }
  }

  Future<void> _fetchNearbyParkings(double lat, double lon) async {
    setState(() {
      _isLoadingApi = true;
      _apiStatus = 'Interrogazione backend in corso...';
      _nearbySpots.clear();
    });

    try {
      final url = Uri.parse('$_backendBaseUrl/api/parking/nearby?lat=$lat&lon=$lon');
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _nearbySpots = data['spots'] ?? [];
          _apiStatus = 'Trovati ${_nearbySpots.length} stalli disponibili';
          _isLoadingApi = false;
        });
      } else {
        setState(() {
          _apiStatus = 'Errore server: codice HTTP ${response.statusCode}';
          _isLoadingApi = false;
        });
      }
    } catch (e) {
      setState(() {
        _apiStatus = 'Connessione fallita: $e';
        _isLoadingApi = false;
      });
    }
  }

  Future<void> _scanBleDevices() async {
    setState(() {
      _isScanningBle = true;
      _bleStatus = 'Scansione sensori in corso...';
      _scanResults.clear();
    });

    try {
      if (await FlutterBluePlus.isSupported == false) {
        setState(() {
          _bleStatus = 'Bluetooth non supportato su questo dispositivo.';
          _isScanningBle = false;
        });
        return;
      }

      // Richiede all'utente di abilitare il Bluetooth se spento
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }

      var subscription = FlutterBluePlus.onScanResults.listen((results) {
        setState(() {
          _scanResults = results;
        });
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      await FlutterBluePlus.isScanning.where((val) => val == false).first;

      setState(() {
        _bleStatus = 'Scansione terminata (${_scanResults.length} dispositivi)';
        _isScanningBle = false;
      });

      subscription.cancel();
    } catch (e) {
      setState(() {
        _bleStatus = 'Errore Bluetooth: $e';
        _isScanningBle = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ParkAdvisor', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Scheda GPS
            Card(
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.location_on, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Posizione Utente (GPS)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(_gpsStatus, style: const TextStyle(fontSize: 15)),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _isLoadingGps ? null : _getCurrentLocation,
                      icon: _isLoadingGps
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.my_location),
                      label: const Text('Rileva posizione e cerca parcheggi'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Scheda Parcheggi Disponibili da Backend
            Card(
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.local_parking, color: Colors.green),
                        SizedBox(width: 8),
                        Text('Stalli Liberi (Backend)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(_apiStatus, style: const TextStyle(fontSize: 15)),
                    if (_isLoadingApi)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: LinearProgressIndicator(),
                      ),
                    if (_nearbySpots.isNotEmpty) ...[
                      const Divider(height: 24),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _nearbySpots.length,
                        itemBuilder: (context, index) {
                          final spot = _nearbySpots[index];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.check_circle, color: Colors.green),
                            title: Text(spot['name'] ?? 'Stallo sconosciuto', style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('ID: ${spot['id']} - Sensore: ${spot['sensorBleId']}'),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Scheda Sensori BLE
            Card(
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.bluetooth_searching, color: Colors.blue),
                        SizedBox(width: 8),
                        Text('Sensori Parcheggio (BLE)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(_bleStatus, style: const TextStyle(fontSize: 15)),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _isScanningBle ? null : _scanBleDevices,
                      icon: _isScanningBle
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search),
                      label: const Text('Cerca sensori vicini'),
                    ),
                    if (_scanResults.isNotEmpty) ...[
                      const Divider(height: 24),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _scanResults.length > 5 ? 5 : _scanResults.length,
                        itemBuilder: (context, index) {
                          final device = _scanResults[index].device;
                          final rssi = _scanResults[index].rssi;
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.sensors),
                            title: Text(device.platformName.isNotEmpty ? device.platformName : 'Dispositivo sconosciuto'),
                            subtitle: Text('ID: ${device.remoteId}'),
                            trailing: Text('$rssi dBm'),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
