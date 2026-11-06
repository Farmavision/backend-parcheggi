import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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
  String _gpsStatus = 'In attesa di rilevamento...';
  String _bleStatus = 'Pronto per la scansione';
  bool _isLoadingGps = false;
  bool _isScanningBle = false;
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
          _gpsStatus = 'I servizi di localizzazione GPS sono disattivati.';
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
          _gpsStatus = 'Permessi negati permanentemente. Abilitali dalle impostazioni.';
          _isLoadingGps = false;
        });
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );

      setState(() {
        _gpsStatus = 'Lat: ${position.latitude.toStringAsFixed(5)}, Lon: ${position.longitude.toStringAsFixed(5)}';
        _isLoadingGps = false;
      });
    } catch (e) {
      setState(() {
        _gpsStatus = 'Errore GPS: $e';
        _isLoadingGps = false;
      });
    }
  }

  Future<void> _scanBleDevices() async {
    setState(() {
      _isScanningBle = true;
      _bleStatus = 'Scansione sensori nelle vicinanze...';
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

      var subscription = FlutterBluePlus.onScanResults.listen((results) {
        setState(() {
          _scanResults = results;
        });
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      await FlutterBluePlus.isScanning.where((val) => val == false).first;

      setState(() {
        _bleStatus = 'Scansione completata (${_scanResults.length} dispositivi trovati)';
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
                      label: const Text('Rileva la mia posizione'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
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
