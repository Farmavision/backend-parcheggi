import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  static const String _baseUrl = 'https://parknow-api.onrender.com';
  final TextEditingController _pinCtrl = TextEditingController();
  bool _unlocked = false;
  bool _loading = false;
  bool _saving = false;
  String _pin = '';
  bool _geofenceEnabled = false;
  bool _selfBookingBlock = false;
  List<Map<String, dynamic>> _zones = [];

  final Map<String, TextEditingController> _controllers = {
    'initial_credits': TextEditingController(text: '50'),
    'search_fee': TextEditingController(text: '5'),
    'release_reward': TextEditingController(text: '4'),
    'cancellation_penalty': TextEditingController(text: '2'),
    'release_delta_minutes': TextEditingController(text: '5'),
    'reservation_hold_minutes': TextEditingController(text: '10'),
    'free_spot_ttl_minutes': TextEditingController(text: '15'),
    'polling_interval_seconds': TextEditingController(text: '5'),
    'search_radius_meters': TextEditingController(text: '500'),
    'arrival_verification_meters': TextEditingController(text: '25'),
  };

  @override
  void dispose() {
    _pinCtrl.dispose();
    for (final c in _controllers.values) c.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _apiCall(String method, String path, {Map<String, dynamic>? body, String? pin}) async {
    final HttpClient client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('$_baseUrl$path'));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      if (pin != null && pin.isNotEmpty) req.headers.set('x-admin-pin', pin);
      if (body != null) req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final decoded = text.isNotEmpty ? jsonDecode(text) : <String, dynamic>{};
      return {'status': res.statusCode, 'data': decoded is Map<String, dynamic> ? decoded : <String, dynamic>{}};
    } finally {
      client.close();
    }
  }

  Future<void> _verifyPin() async {
    final entered = _pinCtrl.text.trim();
    if (entered.isEmpty) return;
    setState(() => _loading = true);
    try {
      final r = await _apiCall('POST', '/api/admin/verify-pin', body: {'pin': entered});
      if (r['status'] == 200) {
        _pin = entered;
        await _loadConfig();
        if (mounted) setState(() => _unlocked = true);
      } else {
        _showSnack('PIN errato', isError: true);
      }
    } catch (_) {
      _showSnack('Errore connessione server', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadConfig() async {
    final r = await _apiCall('GET', '/api/admin/config');
    if (r['status'] == 200) {
      final data = r['data'] as Map<String, dynamic>;
      final params = (data['params'] as Map<String, dynamic>?) ?? {};
      final rawZones = (data['zones'] as List?) ?? [];
      for (final entry in _controllers.entries) {
        if (params[entry.key] != null) entry.value.text = params[entry.key].toString();
      }
      if (!mounted) return;
      setState(() {
        _geofenceEnabled = (params['geofence_enabled'] ?? 0) == 1;
        _selfBookingBlock = (params['self_booking_block_enabled'] ?? 0) == 1;
        _zones = rawZones.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      final params = <String, num>{
        'geofence_enabled': _geofenceEnabled ? 1 : 0,
        'self_booking_block_enabled': _selfBookingBlock ? 1 : 0,
      };
      for (final entry in _controllers.entries) {
        final parsed = num.tryParse(entry.value.text.trim().replaceAll(',', '.'));
        if (parsed != null) params[entry.key] = parsed;
      }
      final r = await _apiCall('POST', '/api/admin/config', body: {'params': params, 'zones': _zones}, pin: _pin);
      if (r['status'] == 200) {
        _showSnack('Salvato su cloud!');
      } else {
        _showSnack('Errore (${r['status']})', isError: true);
      }
    } catch (_) {
      _showSnack('Errore connessione server', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openAddZoneDialog() async {
    final nameCtrl = TextEditingController();
    final latCtrl = TextEditingController();
    final lonCtrl = TextEditingController();
    final radCtrl = TextEditingController(text: '1.5');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuova Zona'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nome Zona (es. Centro)')),
              Row(children: [
                Expanded(child: TextField(controller: latCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitudine'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: lonCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitudine'))),
              ]),
              TextField(controller: radCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Raggio (km)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final lat = double.tryParse(latCtrl.text.trim().replaceAll(',', '.'));
              final lon = double.tryParse(lonCtrl.text.trim().replaceAll(',', '.'));
              final rad = double.tryParse(radCtrl.text.trim().replaceAll(',', '.')) ?? 1.5;
              if (name.isEmpty || lat == null || lon == null) return _showSnack('Dati non validi', isError: true);
              setState(() {
                _zones.add({'id': 'z_${DateTime.now().millisecondsSinceEpoch}', 'name': name, 'lat': lat, 'lon': lon, 'radius_km': rad, 'active': true});
              });
              Navigator.pop(ctx);
            },
            child: const Text('Aggiungi'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700));
  }

  Widget _numField(String key, String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(controller: _controllers[key], keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon), border: const OutlineInputBorder(), isDense: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pannello Amministratore'), backgroundColor: Colors.blueGrey.shade900, foregroundColor: Colors.white),
      body: !_unlocked
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.admin_panel_settings, size: 64, color: Colors.blueGrey.shade800),
                  const SizedBox(height: 16),
                  TextField(controller: _pinCtrl, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'PIN Amministratore', border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock)), onSubmitted: (_) => _verifyPin()),
                  const SizedBox(height: 16),
                  SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _loading ? null : _verifyPin, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade900, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)), child: Text(_loading ? 'Verifica...' : 'Sblocca Pannello'))),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [const Icon(Icons.public, color: Colors.teal), const SizedBox(width: 8), const Expanded(child: Text('Zone Geografiche (Geofencing)', style: TextStyle(fontWeight: FontWeight.bold))), Switch(value: _geofenceEnabled, onChanged: (v) => setState(() => _geofenceEnabled = v))]),
                        const Divider(),
                        ..._zones.asMap().entries.map((e) => ListTile(contentPadding: EdgeInsets.zero, leading: Switch(value: e.value['active'] == true, onChanged: (v) => setState(() => _zones[e.key]['active'] = v)), title: Text(e.value['name'].toString()), subtitle: Text('${e.value['radius_km']} km'), trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => setState(() => _zones.removeAt(e.key))))),
                        OutlinedButton.icon(onPressed: _openAddZoneDialog, icon: const Icon(Icons.add), label: const Text('Aggiungi Zona')),
                      ],
                    ),
                  ),
                ),
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Economia & Crediti', style: TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 12), _numField('initial_credits', 'Crediti iniziali', Icons.card_giftcard), _numField('search_fee', 'Costo prenotazione', Icons.toll), _numField('release_reward', 'Premio rilascio', Icons.emoji_events), _numField('cancellation_penalty', 'Penale', Icons.warning)]))),
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Tempi & Scadenze', style: TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 12), _numField('release_delta_minutes', 'Preavviso (min)', Icons.timer), _numField('reservation_hold_minutes', 'Attesa max (min)', Icons.hourglass_bottom), _numField('free_spot_ttl_minutes', 'Durata libero (min)', Icons.update), _numField('polling_interval_seconds', 'Polling (sec)', Icons.sync)]))),
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Distanze & Regole', style: TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 12), _numField('search_radius_meters', 'Raggio (m)', Icons.radar), _numField('arrival_verification_meters', 'Tolleranza GPS (m)', Icons.gps_fixed), SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Blocca auto-prenotazione'), value: _selfBookingBlock, onChanged: (v) => setState(() => _selfBookingBlock = v))]))),
                const SizedBox(height: 18),
                SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saving ? null : _saveConfig, style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade800, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)), child: Text(_saving ? 'Salvataggio...' : 'Salva Configurazione'))),
              ],
            ),
    );
  }
}
