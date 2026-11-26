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
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
    ),
    alignment: Alignment.center,
    child: mins != null
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$mins', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15, height: 1.0)),
              const Text('min', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 9, height: 1.0)),
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
  const SearchParkingScreen({super.key, required this.sensorEngine, required this.backendBaseUrl, required this.userId, required this.searchRadiusM});
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
  StreamSubscription<Position>? _searchPosSub;

  @override
  void initState() {
    super.initState();
    final uLat = widget.sensorEngine.currentUserLat;
    final uLon = widget.sensorEngine.currentUserLon;
    if (uLat != null && uLon != null) _center = LatLng(uLat, uLon);
    widget.sensorEngine.addListener(_onEngineUpdate);
    _refreshLocationAndSpots();
    _pollingTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetchSpots(silent: true));
  }

  void _onEngineUpdate() {
    if (!mounted) return;
    final uLat = widget.sensorEngine.currentUserLat;
    final uLon = widget.sensorEngine.currentUserLon;
    if (uLat != null && uLon != null) _center = LatLng(uLat, uLon);
    setState(() {});
  }

  Future<void> _refreshLocationAndSpots() async {
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      setState(() => _center = LatLng(pos.latitude, pos.longitude));
      _mapController.move(_center, 17.0);
    } catch (_) {}
    _searchPosSub ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((pos) {
      if (!mounted) return;
      setState(() => _center = LatLng(pos.latitude, pos.longitude));
    });
    await _fetchSpots();
  }

  Future<void> _fetchSpots({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() { _isLoading = true; _statusText = 'Ricerca entro ${widget.searchRadiusM}m...'; });
    }
    try {
      final url = Uri.parse('${widget.backendBaseUrl}/api/parking/nearby?lat=${_center.latitude}&lon=${_center.longitude}&radius=${widget.searchRadiusM}');
      final res = await http.get(url, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        final body = json.decode(res.body);
        final spots = body['spots'] as List<dynamic>? ?? [];
        setState(() {
          _spots = spots;
          _feeSearch = (body['feeSearch'] as num?)?.toInt() ?? 5;
          _statusText = spots.isEmpty ? 'Nessuno stallo entro ${widget.searchRadiusM}m' : '${spots.length == 1 ? "1 stallo" : "${spots.length} stalli"} entro ${widget.searchRadiusM}m';
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _statusText = 'Errore connessione server'; _isLoading = false; });
    }
  }

  void _showConfirmDialog(String spotId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.local_parking, color: Colors.green.shade700, size: 36),
        title: const Text('Richiesta di prenotazione'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Confermi di voler prenotare questo parcheggio?', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Chip(
              avatar: const Icon(Icons.account_balance_wallet, color: Colors.amber),
              label: Text('Costo: $_feeSearch crediti', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
            onPressed: () { Navigator.pop(ctx); _executeReservation(spotId); },
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
      final res = await http.post(
        Uri.parse('${widget.backendBaseUrl}/api/parking/reserve'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: json.encode({'userId': widget.userId, 'spotId': spotId}),
      ).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() => _isReserving = false);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final newBal = (data['newBalance'] as num?)?.toInt();
        if (newBal != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('credits_balance', newBal);
        }
        if (!mounted) return;
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => SpotReservationScreen(backendBaseUrl: widget.backendBaseUrl, spotData: data['spot'] as Map<String, dynamic>),
        ));
        await _fetchSpots();
      } else {
        final err = json.decode(res.body)['error'] ?? 'Stallo non disponibile';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.red.shade700, content: Text(err.toString())));
        await _fetchSpots();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isReserving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Errore di connessione')));
      }
    }
  }

  @override
  void dispose() {
    _searchPosSub?.cancel();
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
      final pLat = widget.sensorEngine.parkedLat;
      final pLon = widget.sensorEngine.parkedLon;
      if (pLat != null && pLon != null && Geolocator.distanceBetween(sLat, sLon, pLat, pLon) < -1.0) continue;
      final bool isLeaving = spot['status'] == 'LEAVING_SOON';
      final int? etaMin = isLeaving ? ((spot['availableInMinutes'] as num?)?.toInt() ?? 1) : null;
      markers.add(Marker(
        point: LatLng(sLat, sLon),
        width: 46,
        height: 46,
        child: GestureDetector(
          onTap: () => _showConfirmDialog(spot['id'].toString()),
          child: buildMapSpotBadge(Colors.green.shade600, mins: etaMin, showP: !isLeaving),
        ),
      ));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cerca Parcheggio'),
        backgroundColor: Colors.green.shade800,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.my_location), onPressed: _refreshLocationAndSpots)],
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
            top: 12, left: 12, right: 12,
            child: Card(
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

class SpotReservationScreen extends StatefulWidget {
  final String backendBaseUrl;
  final Map<String, dynamic> spotData;
  const SpotReservationScreen({super.key, required this.backendBaseUrl, required this.spotData});
  @override
  State<SpotReservationScreen> createState() => _SpotReservationScreenState();
}

class _SpotReservationScreenState extends State<SpotReservationScreen> {
  late bool _isFreeNow;
  late int _remainingMinutes;
  bool _isCancelled = false;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _isFreeNow = widget.spotData['isFreeNow'] == true;
    _remainingMinutes = (widget.spotData['availableInMinutes'] as num?)?.toInt() ?? 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 15), (_) => _pollSpotStatus());
  }

  Future<void> _pollSpotStatus() async {
    final spotId = widget.spotData['id'];
    if (spotId == null) return;
    try {
      final res = await http.get(Uri.parse('${widget.backendBaseUrl}/api/parking/spot/$spotId')).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        setState(() {
          _isFreeNow = data['isFreeNow'] == true;
          _isCancelled = data['isCancelled'] == true;
          _remainingMinutes = (data['availableInMinutes'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double lat = (widget.spotData['latitude'] as num).toDouble();
    final double lon = (widget.spotData['longitude'] as num).toDouble();
    final String address = (widget.spotData['address'] ?? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}').toString();
    final ownerCar = (widget.spotData['ownerCar'] as Map<String, dynamic>?) ?? {};
    final String carFullName = [(ownerCar['brand'] ?? '').toString().trim(), (ownerCar['model'] ?? '').toString().trim()].where((e) => e.isNotEmpty).join(' ');
    final String color = (ownerCar['color'] ?? '').toString().trim();
    final String plateVisible = (ownerCar['plateVisible'] ?? '').toString().trim();
    final String waitTitle = _isCancelled
        ? 'Prenotazione annullata'
        : _isFreeNow
            ? 'Libero ora'
            : 'Libero tra $_remainingMinutes ${_remainingMinutes == 1 ? "minuto" : "minuti"}';

    return Scaffold(
      appBar: AppBar(title: const Text('Stallo Prenotato'), backgroundColor: Colors.green.shade800, foregroundColor: Colors.white),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: 185,
              width: double.infinity,
              child: Image.network(
                '${widget.backendBaseUrl}/api/parking/streetview?lat=$lat&lon=$lon',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.blueGrey.shade100,
                  alignment: Alignment.center,
                  child: const Icon(Icons.streetview, size: 48, color: Colors.blueGrey),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: _isCancelled ? Colors.red.shade50 : Colors.green.shade50,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: _isCancelled ? Colors.red.shade700 : Colors.green.shade700,
                child: Icon(_isCancelled ? Icons.cancel : (_isFreeNow ? Icons.local_parking : Icons.timer), color: Colors.white),
              ),
              title: Text(waitTitle, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _isCancelled ? Colors.red.shade900 : Colors.green.shade900)),
              subtitle: Text(_isCancelled ? 'Veicolo non partito entro il limite.' : (_isFreeNow ? 'Pronto per essere occupato.' : 'Conducente in uscita dallo stallo.')),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.location_on, color: Colors.red.shade700),
              title: const Text('Indirizzo specifico', style: TextStyle(fontSize: 12, color: Colors.grey)),
              subtitle: Text(address, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: address));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Indirizzo copiato')));
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.directions_car, color: Colors.indigo.shade800),
              title: Text(carFullName.isNotEmpty ? carFullName : 'Veicolo registrato', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(color.isNotEmpty ? 'Colore: $color' : 'Auto in uscita'),
              trailing: plateVisible.isNotEmpty ? Chip(label: Text('*****$plateVisible', style: const TextStyle(fontWeight: FontWeight.bold))) : null,
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade800, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
            icon: const Icon(Icons.navigation),
            label: const Text('AVVIA NAVIGAZIONE ALLO STALLO', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: _isCancelled
                ? null
                : () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => NavigateToSpotScreen(backendBaseUrl: widget.backendBaseUrl, spotData: widget.spotData, initialIsFreeNow: _isFreeNow, initialRemainingMinutes: _remainingMinutes),
                    )),
          ),
        ),
      ),
    );
  }
}

class NavigateToSpotScreen extends StatefulWidget {
  final String backendBaseUrl;
  final Map<String, dynamic> spotData;
  final bool initialIsFreeNow;
  final int initialRemainingMinutes;
  const NavigateToSpotScreen({super.key, required this.backendBaseUrl, required this.spotData, required this.initialIsFreeNow, required this.initialRemainingMinutes});
  @override
  State<NavigateToSpotScreen> createState() => _NavigateToSpotScreenState();
}

class _NavigateToSpotScreenState extends State<NavigateToSpotScreen> {
  final MapController _mapController = MapController();
  late LatLng _destPos;
  LatLng? _userPos;
  bool _followUser = true;
  late bool _isFreeNow;
  late int _remainingMinutes;
  StreamSubscription<Position>? _navPosSub;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _destPos = LatLng((widget.spotData['latitude'] as num).toDouble(), (widget.spotData['longitude'] as num).toDouble());
    _isFreeNow = widget.initialIsFreeNow;
    _remainingMinutes = widget.initialRemainingMinutes;
    _startNavigationStream();
    _statusTimer = Timer.periodic(const Duration(seconds: 15), (_) => _pollSpotStatus());
  }

  Future<void> _startNavigationStream() async {
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (mounted) {
        setState(() => _userPos = LatLng(pos.latitude, pos.longitude));
        if (_followUser) _mapController.move(_userPos!, 17.5);
      }
    } catch (_) {}
    _navPosSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 3),
    ).listen((pos) {
      if (!mounted) return;
      final newPos = LatLng(pos.latitude, pos.longitude);
      setState(() => _userPos = newPos);
      if (_followUser) _mapController.move(newPos, 17.5);
    });
  }

  Future<void> _pollSpotStatus() async {
    final spotId = widget.spotData['id'];
    if (spotId == null) return;
    try {
      final res = await http.get(Uri.parse('${widget.backendBaseUrl}/api/parking/spot/$spotId')).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        setState(() {
          _isFreeNow = data['isFreeNow'] == true;
          _remainingMinutes = (data['availableInMinutes'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _navPosSub?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String address = (widget.spotData['address'] ?? 'Destinazione stallo').toString();
    final double? distMeters = _userPos != null ? Geolocator.distanceBetween(_userPos!.latitude, _userPos!.longitude, _destPos.latitude, _destPos.longitude) : null;
    final String distLabel = distMeters == null ? 'Calcolo...' : (distMeters >= 1000 ? '${(distMeters / 1000).toStringAsFixed(1)} km' : '${distMeters.round()} m');
    final String etaLabel = _isFreeNow ? 'Libero ora' : 'Libero tra $_remainingMinutes ${_remainingMinutes == 1 ? "minuto" : "minuti"}';
    return Scaffold(
      appBar: AppBar(title: const Text('Navigazione allo stallo'), backgroundColor: Colors.indigo.shade800, foregroundColor: Colors.white),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _userPos ?? _destPos,
              initialZoom: 17.5,
              onPositionChanged: (_, g) { if (g && _followUser) setState(() => _followUser = false); },
            ),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.parkadvisor_app'),
              if (_userPos != null) PolylineLayer(polylines: [Polyline(points: [_userPos!, _destPos], strokeWidth: 5.5, color: Colors.indigo.shade700)]),
              MarkerLayer(markers: [
                Marker(point: _destPos, width: 48, height: 48, child: buildMapSpotBadge(Colors.green.shade700, mins: _isFreeNow ? null : _remainingMinutes, showP: _isFreeNow)),
                if (_userPos != null) Marker(point: _userPos!, width: 40, height: 40, child: Container(decoration: BoxDecoration(color: Colors.indigo.shade800, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2.5)), child: const Icon(Icons.navigation, color: Colors.white, size: 20))),
              ]),
            ],
          ),
          Positioned(
            top: 12, left: 12, right: 12,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(address, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const Divider(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Distanza: $distLabel', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Chip(backgroundColor: Colors.green.shade100, label: Text(etaLabel, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.green.shade900))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: Row(
            children: [
              Expanded(child: OutlinedButton.icon(icon: Icon(_followUser ? Icons.gps_fixed : Icons.gps_not_fixed), label: Text(_followUser ? 'Centrato' : 'Ricentra'), onPressed: () { setState(() => _followUser = true); if (_userPos != null) _mapController.move(_userPos!, 17.5); })),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white), icon: const Icon(Icons.check_circle), label: const Text('Arrivato'), onPressed: () => Navigator.popUntil(context, (r) => r.isFirst))),
            ],
          ),
        ),
      ),
    );
  }
}

class FindMyCarScreen extends StatefulWidget {
  final SensorFusionEngine sensorEngine;
  final String backendBaseUrl;
  final String userId;
  const FindMyCarScreen({super.key, required this.sensorEngine, required this.backendBaseUrl, required this.userId});
  @override
  State<FindMyCarScreen> createState() => _FindMyCarScreenState();
}

class _FindMyCarScreenState extends State<FindMyCarScreen> {
  final MapController _mapController = MapController();
  LatLng? _carPos;
  LatLng? _userPos;
  bool _loadingRemote = false;
  StreamSubscription<Position>? _findCarPosSub;

  @override
  void initState() {
    super.initState();
    final pLat = widget.sensorEngine.parkedLat;
    final pLon = widget.sensorEngine.parkedLon;
    _carPos = (pLat != null && pLon != null) ? LatLng(pLat, pLon) : null;
    final uLat = widget.sensorEngine.currentUserLat;
    final uLon = widget.sensorEngine.currentUserLon;
    if (uLat != null && uLon != null) _userPos = LatLng(uLat, uLon);
    widget.sensorEngine.addListener(_onEngineUpdate);
    _initPositions();
  }

  void _onEngineUpdate() {
    if (!mounted) return;
    final pLat = widget.sensorEngine.parkedLat;
    final pLon = widget.sensorEngine.parkedLon;
    if (pLat != null && pLon != null) _carPos = LatLng(pLat, pLon);
    final uLat = widget.sensorEngine.currentUserLat;
    final uLon = widget.sensorEngine.currentUserLon;
    if (uLat != null && uLon != null) _userPos = LatLng(uLat, uLon);
    setState(() {});
  }

  Future<void> _initPositions() async {
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (mounted) setState(() => _userPos = LatLng(pos.latitude, pos.longitude));
    } catch (_) {}
    _findCarPosSub ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((pos) {
      if (!mounted) return;
      setState(() => _userPos = LatLng(pos.latitude, pos.longitude));
    });
    if (_carPos == null) {
      setState(() => _loadingRemote = true);
      try {
        final res = await http.get(Uri.parse('${widget.backendBaseUrl}/api/parking/my-spot?userId=${widget.userId}')).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200 && mounted) {
          final spot = json.decode(res.body)['spot'];
          final st = (spot?['status'] ?? '').toString().toUpperCase();
          if (spot != null && (st == 'OCCUPIED' || st == 'LEAVING_SOON') && spot['latitude'] != null && spot['longitude'] != null) {
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
    _findCarPosSub?.cancel();
    widget.sensorEngine.removeListener(_onEngineUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double? distMeters = (_carPos != null && _userPos != null)
        ? Geolocator.distanceBetween(_userPos!.latitude, _userPos!.longitude, _carPos!.latitude, _carPos!.longitude)
        : widget.sensorEngine.distanceFromCarMeters;
    final bool showMins = widget.sensorEngine.isManualReleaseConfirmed;
    return Scaffold(
      appBar: AppBar(title: const Text('Trova la mia auto'), backgroundColor: Colors.indigo.shade800, foregroundColor: Colors.white),
      body: _loadingRemote
          ? const Center(child: CircularProgressIndicator())
          : _carPos == null
              ? const Center(child: Text('Nessun parcheggio attivo', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)))
              : Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(initialCenter: _carPos!, initialZoom: 17.5),
                      children: [
                        TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.parkadvisor_app'),
                        MarkerLayer(markers: [
                          if (_userPos != null) Marker(point: _userPos!, width: 36, height: 36, child: const Icon(Icons.my_location, color: Colors.blue, size: 26)),
                          Marker(point: _carPos!, width: 48, height: 48, child: buildMapSpotBadge(showMins ? Colors.orange : Colors.indigo, mins: showMins ? widget.sensorEngine.estimatedMinutesToRelease : null)),
                        ]),
                      ],
                    ),
                    Positioned(
                      left: 14, right: 14, bottom: MediaQuery.of(context).padding.bottom + 14,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(distMeters != null ? 'Distanza dall\'auto: ${distMeters.round()} metri' : 'Posizione auto registrata', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              const SizedBox(height: 10),
                              Row(children: [
                                Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.center_focus_strong, size: 18), label: const Text('Centra auto'), onPressed: () => _mapController.move(_carPos!, 18.0))),
                                const SizedBox(width: 8),
                                Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white), icon: const Icon(Icons.timer, size: 18), label: Text(showMins ? 'In rilascio' : 'Libera stallo'), onPressed: showMins ? null : () async => await widget.sensorEngine.confirmManualReleaseIntent())),
                              ]),
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
