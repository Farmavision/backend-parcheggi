import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sensor_fusion_engine.dart';

Widget buildMapSpotBadge(Color color, {int? mins, bool showP = false}) {
  return Container(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2.5),
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
    ),
    alignment: Alignment.center,
    child: mins != null
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$mins', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15, height: 1.0)),
              const Text('min', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 9, height: 1.0)),
            ],
          )
        : showP
            ? const Text('P', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20, height: 1.0))
            : const Icon(Icons.directions_car, color: Colors.white, size: 22),
  );
}

class SearchParkingScreen extends StatefulWidget {
  final SensorFusionEngine sensorEngine;
  final String backendBaseUrl;
  final String userId;
  final int searchRadiusM;

  const SearchParkingScreen({
    super.key,
    required this.sensorEngine,
    required this.backendBaseUrl,
    required this.userId,
    required this.searchRadiusM,
  });

  @override
  State<SearchParkingScreen> createState() => _SearchParkingScreenState();
}

class _SearchParkingScreenState extends State<SearchParkingScreen> {
  final MapController _mapController = MapController();
  LatLng _center = const LatLng(41.85784, 12.55860);
  List<dynamic> _spots = [];
  int _feeSearch = 5;
  String _statusText = 'Ricerca stalli in corso...';
  bool _isLoading = false;
  bool _isReserving = false;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    if (widget.sensorEngine.currentUserLat != null && widget.sensorEngine.currentUserLon != null) {
      _center = LatLng(widget.sensorEngine.currentUserLat!, widget.sensorEngine.currentUserLon!);
    }
    widget.sensorEngine.addListener(_onEngineUpdate);
    _refreshLocationAndSpots();
    _pollingTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetchSpots(silent: true));
  }

  void _onEngineUpdate() {
    if (!mounted) return;
    if (widget.sensorEngine.currentUserLat != null && widget.sensorEngine.currentUserLon != null) {
      _center = LatLng(widget.sensorEngine.currentUserLat!, widget.sensorEngine.currentUserLon!);
    }
    setState(() {});
  }

  Future<void> _refreshLocationAndSpots() async {
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      setState(() => _center = LatLng(pos.latitude, pos.longitude));
      _mapController.move(_center, 17.0);
    } catch (_) {}
    await _fetchSpots();
  }

  Future<void> _fetchSpots({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
        _statusText = 'Ricerca entro ${widget.searchRadiusM}m...';
      });
    }
    try {
      final url = Uri.parse(
        '${widget.backendBaseUrl}/api/parking/nearby?lat=${_center.latitude}&lon=${_center.longitude}&radius=${widget.searchRadiusM}',
      );
      final res = await http.get(url, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        final body = json.decode(res.body);
        final spots = body['spots'] as List<dynamic>? ?? [];
        setState(() {
          _spots = spots;
          _feeSearch = (body['feeSearch'] as num?)?.toInt() ?? 5;
          _statusText = spots.isEmpty
              ? 'Nessuno stallo entro ${widget.searchRadiusM}m'
              : '${spots.length} stalli disponibili entro ${widget.searchRadiusM}m';
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _statusText = 'Errore connessione server'; _isLoading = false; });
    }
  }

  void _showConfirmReservationDialog(String spotId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.local_parking, color: Colors.green.shade700, size: 36),
        title: const Text('Richiesta di prenotazione'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Confermi di voler prenotare questo parcheggio?',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.shade700),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.account_balance_wallet, size: 20, color: Colors.amber.shade900),
                  const SizedBox(width: 8),
                  Text(
                    'Costo: $_feeSearch crediti',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.amber.shade900),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _executeReservation(spotId);
            },
            child: const Text('Conferma'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeReservation(String spotId) async {
    if (_isReserving) return;
    setState(() => _isReserving = true);

    try {
      final res = await http
          .post(
            Uri.parse('${widget.backendBaseUrl}/api/parking/reserve'),
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: json.encode({'userId': widget.userId, 'spotId': spotId}),
          )
          .timeout(const Duration(seconds: 12));

      if (!mounted) return;
      setState(() => _isReserving = false);

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final newBal = (data['newBalance'] as num?)?.toInt();
        if (newBal != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('credits_balance', newBal);
        }
        final reservedSpot = data['spot'] as Map<String, dynamic>;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SpotReservationScreen(
              backendBaseUrl: widget.backendBaseUrl,
              spotData: reservedSpot,
            ),
          ),
        );
        await _fetchSpots();
      } else {
        final err = json.decode(res.body)['error'] ?? 'Impossibile prenotare lo stallo';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.red.shade700, content: Text(err.toString())),
        );
        await _fetchSpots();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isReserving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Errore di connessione durante la prenotazione')),
      );
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    widget.sensorEngine.removeListener(_onEngineUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Marker> markers = [
      Marker(point: _center, width: 36, height: 36, child: const Icon(Icons.my_location, color: Colors.blue, size: 26)),
    ];

    for (final rawSpot in _spots) {
      final spot = rawSpot as Map<String, dynamic>;
      final double sLat = (spot['latitude'] as num).toDouble();
      final double sLon = (spot['longitude'] as num).toDouble();
      if (widget.sensorEngine.parkedLat != null &&
          Geolocator.distanceBetween(sLat, sLon, widget.sensorEngine.parkedLat!, widget.sensorEngine.parkedLon!) < 3.0) {
        continue;
      }
      final bool isLeaving = spot['status'] == 'LEAVING_SOON';
      final int? etaMin = isLeaving ? ((spot['availableInMinutes'] as num?)?.toInt() ?? 1) : null;

      markers.add(
        Marker(
          point: LatLng(sLat, sLon),
          width: 46,
          height: 46,
          child: GestureDetector(
            onTap: () => _showConfirmReservationDialog(spot['id'].toString()),
            child: buildMapSpotBadge(
              Colors.green.shade600,
              mins: etaMin,
              showP: !isLeaving,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cerca Parcheggio'),
        backgroundColor: Colors.green.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.my_location), tooltip: 'Centra su di me', onPressed: _refreshLocationAndSpots),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: _center, initialZoom: 17.0),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.parkadvisor_app'),
              MarkerLayer(markers: markers),
            ],
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Card(
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(_isLoading || _isReserving ? Icons.sync : Icons.local_parking, color: Colors.green.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_statusText, style: const TextStyle(fontWeight: FontWeight.w600)),
                          const Text('Tocca un segnaposto verde per prenotare', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: () => _fetchSpots()),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
