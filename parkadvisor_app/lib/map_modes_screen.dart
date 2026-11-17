import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'sensor_fusion_engine.dart';

Widget buildMapSpotBadge(Color color, {int? mins}) {
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
        : const Icon(Icons.directions_car, color: Colors.white, size: 22),
  );
}

class SearchParkingScreen extends StatefulWidget {
  final SensorFusionEngine sensorEngine;
  final String backendBaseUrl;
  final int searchRadiusM;

  const SearchParkingScreen({
    super.key,
    required this.sensorEngine,
    required this.backendBaseUrl,
    required this.searchRadiusM,
  });

  @override
  State<SearchParkingScreen> createState() => _SearchParkingScreenState();
}

class _SearchParkingScreenState extends State<SearchParkingScreen> {
  final MapController _mapController = MapController();
  LatLng _center = const LatLng(41.85784, 12.55860);
  List<dynamic> _spots = [];
  String _statusText = 'Ricerca stalli in corso...';
  bool _isLoading = false;
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
        final spots = json.decode(res.body)['spots'] as List<dynamic>? ?? [];
        setState(() {
          _spots = spots;
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

    for (final spot in _spots) {
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
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    isLeaving
                        ? 'Stallo in liberazione tra $etaMin min (${spot['distanceMeters']}m da te)'
                        : 'Stallo LIBERO (${spot['distanceMeters']}m da te)',
                  ),
                ),
              );
            },
            child: buildMapSpotBadge(isLeaving ? Colors.orange : Colors.green, mins: etaMin),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cerca Parcheggio'),
        backgroundColor: Colors.teal.shade700,
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
                    Icon(_isLoading ? Icons.sync : Icons.local_parking, color: Colors.teal.shade700),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_statusText, style: const TextStyle(fontWeight: FontWeight.w600))),
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

class FindMyCarScreen extends StatefulWidget {
  final SensorFusionEngine sensorEngine;
  final String backendBaseUrl;
  final String userId;

  const FindMyCarScreen({
    super.key,
    required this.sensorEngine,
    required this.backendBaseUrl,
    required this.userId,
  });

  @override
  State<FindMyCarScreen> createState() => _FindMyCarScreenState();
}

class _FindMyCarScreenState extends State<FindMyCarScreen> {
  final MapController _mapController = MapController();
  LatLng? _carPos;
  LatLng? _userPos;
  bool _loadingRemote = false;

  @override
  void initState() {
    super.initState();
    if (widget.sensorEngine.parkedLat != null && widget.sensorEngine.parkedLon != null) {
      _carPos = LatLng(widget.sensorEngine.parkedLat!, widget.sensorEngine.parkedLon!);
    }
    if (widget.sensorEngine.currentUserLat != null && widget.sensorEngine.currentUserLon != null) {
      _userPos = LatLng(widget.sensorEngine.currentUserLat!, widget.sensorEngine.currentUserLon!);
    }
    widget.sensorEngine.addListener(_onEngineUpdate);
    _initPositions();
  }

  void _onEngineUpdate() {
    if (!mounted) return;
    if (widget.sensorEngine.parkedLat != null && widget.sensorEngine.parkedLon != null) {
      _carPos = LatLng(widget.sensorEngine.parkedLat!, widget.sensorEngine.parkedLon!);
    }
    if (widget.sensorEngine.currentUserLat != null && widget.sensorEngine.currentUserLon != null) {
      _userPos = LatLng(widget.sensorEngine.currentUserLat!, widget.sensorEngine.currentUserLon!);
    }
    setState(() {});
  }

  Future<void> _initPositions() async {
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (mounted) setState(() => _userPos = LatLng(pos.latitude, pos.longitude));
    } catch (_) {}

    if (_carPos == null) {
      setState(() => _loadingRemote = true);
      try {
        final res = await http
            .get(Uri.parse('${widget.backendBaseUrl}/api/parking/my-spot?userId=${widget.userId}'))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200 && mounted) {
          final spot = json.decode(res.body)['spot'];
          if (spot != null && spot['latitude'] != null && spot['longitude'] != null) {
            _carPos = LatLng((spot['latitude'] as num).toDouble(), (spot['longitude'] as num).toDouble());
          }
        }
      } catch (_) {}
      if (mounted) setState(() => _loadingRemote = false);
    }

    if (_carPos != null && mounted) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _mapController.move(_carPos!, 17.5);
      });
    }
  }

  @override
  void dispose() {
    widget.sensorEngine.removeListener(_onEngineUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double? distMeters = (_carPos != null && _userPos != null)
        ? Geolocator.distanceBetween(_userPos!.latitude, _userPos!.longitude, _carPos!.latitude, _carPos!.longitude)
        : widget.sensorEngine.distanceFromCarMeters;

    final List<Marker> markers = [];
    if (_userPos != null) {
      markers.add(Marker(point: _userPos!, width: 36, height: 36, child: const Icon(Icons.my_location, color: Colors.blue, size: 26)));
    }
    if (_carPos != null) {
      final bool showMins = widget.sensorEngine.isManualReleaseConfirmed;
      markers.add(
        Marker(
          point: _carPos!,
          width: 48,
          height: 48,
          child: buildMapSpotBadge(
            showMins ? Colors.orange : Colors.indigo,
            mins: showMins ? widget.sensorEngine.estimatedMinutesToRelease : null,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trova la mia auto'),
        backgroundColor: Colors.indigo.shade800,
        foregroundColor: Colors.white,
      ),
      body: _loadingRemote
          ? const Center(child: CircularProgressIndicator())
          : _carPos == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.directions_car_outlined, size: 64, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        const Text(
                          'Nessun parcheggio attivo',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Quando parcheggi l\'auto, qui vedrai la posizione esatta dello stallo e la distanza a piedi per raggiungerla.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(initialCenter: _carPos!, initialZoom: 17.5),
                      children: [
                        TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.parkadvisor_app'),
                        MarkerLayer(markers: markers),
                      ],
                    ),
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: MediaQuery.of(context).padding.bottom + 14,
                      child: Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.directions_car, color: Colors.indigo.shade800, size: 28),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          distMeters != null
                                              ? 'Distanza dall\'auto: ${distMeters.round()} metri'
                                              : 'Posizione auto registrata',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                        ),
                                        Text(
                                          'Tempo stimato uscita: ${widget.sensorEngine.estimatedMinutesToRelease} min (camminata + 1 min)',
                                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      icon: const Icon(Icons.center_focus_strong, size: 18),
                                      label: const Text('Centra auto'),
                                      onPressed: () => _mapController.move(_carPos!, 18.0),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.orange.shade800,
                                        foregroundColor: Colors.white,
                                      ),
                                      icon: const Icon(Icons.timer, size: 18),
                                      label: Text(widget.sensorEngine.isManualReleaseConfirmed ? 'In rilascio' : 'Libera stallo'),
                                      onPressed: widget.sensorEngine.isManualReleaseConfirmed
                                          ? null
                                          : () async => await widget.sensorEngine.confirmManualReleaseIntent(),
                                    ),
                                  ),
                                ],
                              ),
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
