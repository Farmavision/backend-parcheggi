import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

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
  List> _zones = [];

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
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _verifyPin() async {
    final entered = _pinCtrl.text.trim();
    if (entered.isEmpty) return;
    setState(() => _loading = true);
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/api/admin/verify-pin'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pin': entered}),
      );
      if (res.statusCode == 200) {
        _pin = entered;
        await _loadConfig();
        if (mounted) setState(() => _unlocked = true);
      } else {
        _showSnack('PIN Amministratore errato', isError: true);
      }
    } catch (_) {
      _showSnack('Errore di connessione al server', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadConfig() async {
    final res = await http.get(Uri.parse('$_baseUrl/api/admin/config'));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final params = (data['params'] as Map<String, dynamic>?) ?? {};
      final rawZones = (data['zones'] as List?) ?? [];

      for (final entry in _controllers.entries) {
        if (params[entry.key] != null) {
          entry.value.text = params[entry.key].toString();
        }
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

      final res = await http.post(
        Uri.parse('$_baseUrl/api/admin/config'),
        headers: {
          'Content-Type': 'application/json',
          'x-admin-pin': _pin,
        },
        body: jsonEncode({'params': params, 'zones': _zones}),
      );
      if (res.statusCode == 200) {
        _showSnack('Parametri e zone salvati su cloud!');
      } else {
        _showSnack('Errore salvataggio (${res.statusCode})', isError: true);
      }
    } catch (_) {
      _showSnack('Impossibile contattare il server', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openAddZoneDialog() async {
    final nameCtrl = TextEditingController();
    final latCtrl = TextEditingController();
    final lonCtrl = TextEditingController();
    final radCtrl = TextEditingController(text: '1.5');
    bool fetchingGps = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Nuova Zona Attiva'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nome Zona / Quartiere',
                    hintText: 'Es. Roma - Appio Claudio',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: fetchingGps
                      ? null
                      : () async {
                          setDlgState(() => fetchingGps = true);
                          try {
                            final pos = await Geolocator.getCurrentPosition();
                            latCtrl.text = pos.latitude.toStringAsFixed(6);
                            lonCtrl.text = pos.longitude.toStringAsFixed(6);
                          } catch (_) {
                            _showSnack('GPS non disponibile', isError: true);
                          } finally {
                            setDlgState(() => fetchingGps = false);
                          }
                        },
                  icon: const Icon(Icons.my_location),
                  label: Text(fetchingGps ? 'Rilevamento GPS...' : 'Usa posizione GPS attuale'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: latCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'Latitudine'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: lonCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'Longitudine'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: radCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Raggio di copertura (km)'),
                ),
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
                if (name.isEmpty || lat == null || lon == null) {
                  _showSnack('Inserisci nome e coordinate valide', isError: true);
                  return;
                }
                setState(() {
                  _zones.add({
                    'id': 'zone_${DateTime.now().millisecondsSinceEpoch}',
                    'name': name,
                    'lat': lat,
                    'lon': lon,
                    'radius_km': rad,
                    'active': true,
                  });
                });
                Navigator.pop(ctx);
              },
              child: const Text('Aggiungi'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
      ),
    );
  }

  Widget _numField(String key, String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controllers[key],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pannello Amministratore'),
        backgroundColor: Colors.blueGrey.shade900,
        foregroundColor: Colors.white,
      ),
      body: !_unlocked
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.admin_panel_settings, size: 64, color: Colors.blueGrey.shade800),
                  const SizedBox(height: 16),
                  const Text(
                    'Area Riservata Amministratore',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Inserisci il PIN per configurare tariffe, tempi e zone attive.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _pinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'PIN Amministratore',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock),
                    ),
                    onSubmitted: (_) => _verifyPin(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _verifyPin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade900,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(_loading ? 'Verifica...' : 'Sblocca Pannello'),
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.public, color: Colors.teal),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Limitazione Zone Geografiche',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                            ),
                            Switch(
                              value: _geofenceEnabled,
                              onChanged: (v) => setState(() => _geofenceEnabled = v),
                            ),
                          ],
                        ),
                        Text(
                          _geofenceEnabled
                              ? 'ATTIVO: l\'app funziona solo all\'interno delle zone abilitate qui sotto.'
                              : 'DISATTIVO: l\'app è utilizzabile ovunque senza limiti di zona.',
                          style: TextStyle(
                            fontSize: 12,
                            color: _geofenceEnabled ? Colors.teal.shade800 : Colors.black54,
                          ),
                        ),
                        const Divider(height: 20),
                        if (_zones.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text('Nessuna zona configurata.', style: TextStyle(color: Colors.black54)),
                          ),
                        ..._zones.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final z = entry.value;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Switch(
                              value: z['active'] == true,
                              onChanged: (v) => setState(() => _zones[idx]['active'] = v),
                            ),
                            title: Text(z['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('Raggio ${z['radius_km']} km · (${z['lat']}, ${z['lon']})'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              onPressed: () => setState(() => _zones.removeAt(idx)),
                            ),
                          );
                        }),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _openAddZoneDialog,
                          icon: const Icon(Icons.add_location_alt),
                          label: const Text('Aggiungi Zona Attiva'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Economia & Crediti', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        _numField('initial_credits', 'Crediti iniziali nuovi utenti', Icons.card_giftcard),
                        _numField('search_fee', 'Costo prenotazione stallo (crediti)', Icons.toll),
                        _numField('release_reward', 'Premio cessione stallo (crediti)', Icons.emoji_events),
                        _numField('cancellation_penalty', 'Penale annullamento / mancato rilascio', Icons.warning_amber),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Tempi & Scadenze', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        _numField('release_delta_minutes', 'Preavviso uscita standard (minuti)', Icons.timer),
                        _numField('reservation_hold_minutes', 'Tempo max arrivo prenotazione (minuti)', Icons.hourglass_bottom),
                        _numField('free_spot_ttl_minutes', 'Durata visibilità stallo libero (minuti)', Icons.update),
                        _numField('polling_interval_seconds', 'Frequenza aggiornamento stato (secondi)', Icons.sync),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Distanze & Regole Operative', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        _numField('search_radius_meters', 'Raggio ricerca stalli vicini (metri)', Icons.radar),
                        _numField('arrival_verification_meters', 'Tolleranza GPS verifica arrivo/uscita (metri)', Icons.gps_fixed),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Blocca auto-prenotazione stesso utente'),
                          subtitle: const Text('Attiva in produzione; disattiva per test con un solo telefono'),
                          value: _selfBookingBlock,
                          onChanged: (v) => setState(() => _selfBookingBlock = v),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _saveConfig,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    icon: const Icon(Icons.cloud_upload),
                    label: Text(
                      _saving ? 'Salvataggio in corso...' : 'Salva Configurazione Amministratore',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
