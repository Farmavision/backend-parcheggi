import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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

  final MapController _mapController = MapController();
  LatLng _currentCenter = const LatLng(41.85790, 12.55858); // Posizione iniziale di default

  String _gpsStatus = 'In attesa di rilevamento...';
  String _bleStatus = 'Pronto per la scansione';
  String _apiStatus = 'Premi il pulsante per cercare stalli';
  
  bool _isLoadingGps = false;
  bool _isScanningBle = false;
  bool _isLoadingApi = false;
  bool _hasUserLocation = false;

  List<dynamic> _nearbySpots = [];
  List<ScanResult> _scanResults = [];

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isLoadingGps = true;
      _gpsStatus = 'Rilevamento GPS in corso...';
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
            _gpsStatus = 'Permesso posizione negato.';
            _isLoadingGps = false;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _gpsStatus = 'Permessi GPS negati permanentemente.';
          _isLoadingGps = false;
        });
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final newLocation = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentCenter = newLocation;
        _hasUserLocation = true;
        _gpsStatus = 'Lat: ${position.latitude.toStringAsFixed(5)}, Lon: ${position.longitude.toStringAsFixed(5)}';
        _isLoadingGps = false;
      });

      // Sposta la visuale della mappa sulla posizione rilevata
      _mapController.move(newLocation, 16.5);

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
      _apiStatus = 'Ricerca stalli vicini...';
      _nearbySpots.clear();
    });

    try {
      final url = Uri.parse('$_backendBaseUrl/api/parking/nearby?lat=$lat&lon=$lon');
      final response = await http.get(
        url,
        headers: {
          'Accept': 'application/json',
          'X-Github-Token': '',
          'bypass-tunnel-reminder': 'true',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _nearbySpots = data['spots'] ?? [];
          _apiStatus = 'Trovati ${_nearbySpots.length} stalli liberi';
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
        _apiStatus = 'Connessione fallita: $e';
        _isLoadingApi = false;
      });
    }
  }

  void _showSpotDetails(Map<String, dynamic> spot) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.local_parking, color: Colors.green, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      spot['name'] ?? 'Stallo Libero',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Codice Stallo: ${spot['id']}', style: const TextStyle(fontSize: 15)),
              Text('Sensore BLE associato: ${spot['sensorBleId']}', style: const TextStyle(fontSize: 15)),
              Text('Coordinate: ${spot['latitude']}, ${spot['longitude']}', style: const TextStyle(fontSize: 13, color: Colors.grey)),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check),
                  label: const Text('Chiudi scheda'),
                ),
              ),
            ],
          ),
        );
      },
    );
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
          _bleStatus = 'Bluetooth non supportato.';
          _isScanningBle = false;
        });
        return;
      }

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
        _bleStatus = 'Trovati ${_scanResults.length} dispositivi BLE';
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
    // Costruzione dei marker per la mappa
    final List<Marker> markers = [];

    // 1. Marker posizione utente (punto blu)
    if (_hasUserLocation) {
      markers.add(
        Marker(
          point: _currentCenter,
          width: 40,
          height: 40,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.25),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Icon(Icons.my_location, color: Colors.blue, size: 24),
            ),
          ),
        ),
      );
    }

    // 2. Marker per ogni stallo libero restituito dal backend (pin verdi cliccabili)
    for (var spot in _nearbySpots) {
      if (spot['latitude'] != null && spot['longitude'] != null) {
        markers.add(
          Marker(
            point: LatLng(
              (spot['latitude'] as num).toDouble(),
              (spot['longitude'] as num).toDouble(),
            ),
            width: 45,
            height: 45,
            child: GestureDetector(
              onTap: () => _showSpotDetails(spot),
              child: const Icon(
                Icons.location_on,
                color: Colors.green,
                size: 40,
              ),
            ),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ParkAdvisor', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Sezione superiore: Mappa interattiva (occupa il 55% dello schermo)
          Expanded(
            flex: 55,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentCenter,
                    initialZoom: 15.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.parkadvisor_app',
                    ),
                    MarkerLayer(markers: markers),
                  ],
                ),
                // Badge informativo in alto sulla mappa
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            _isLoadingApi ? Icons.sync : Icons.local_parking,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _apiStatus,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Sezione inferiore: Pannello comandi GPS e BLE
          Expanded(
            flex: 45,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _isLoadingGps ? null : _getCurrentLocation,
                    icon: _isLoadingGps
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.my_location),
                    label: const Text('Centra posizione e cerca stalli', style: TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(height: 6),
                  Text(_gpsStatus, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Sensori BLE vicini', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ElevatedButton.icon(
                        onPressed: _isScanningBle ? null : _scanBleDevices,
                        icon: _isScanningBle
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.bluetooth_searching, size: 18),
                        label: const Text('Scansiona'),
                      ),
                    ],
                  ),
                  Text(_bleStatus, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                  if (_scanResults.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _scanResults.length > 3 ? 3 : _scanResults.length,
                      itemBuilder: (context, index) {
                        final device = _scanResults[index].device;
                        final rssi = _scanResults[index].rssi;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.sensors, color: Colors.blue),
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
    );
  }
}