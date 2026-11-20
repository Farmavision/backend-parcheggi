import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  static const String _backendBaseUrl = 'https://parknow-api.onrender.com';
  final _pinCtrl = TextEditingController();
  bool _unlocked = false;
  bool _loading = false;
  String _adminPin = '';

  final List<Map<String, dynamic>> _zones = [];
  final _rewardCtrl = TextEditingController(text: '10');
  final _feeCtrl = TextEditingController(text: '5');
  final _penaltyCtrl = TextEditingController(text: '15');
  final _xtRitNotSecCtrl = TextEditingController(text: '15');
  final _xtGpsAttivoSecCtrl = TextEditingController(text: '10');
  final _xtGpsMaxAttivoMinCtrl = TextEditingController(text: '5');
  final _xtGpsDisattivoSecCtrl = TextEditingController(text: '15');
  final _deltaCtrl = TextEditingController(text: '5');
  final _autoReleaseDelayCtrl = TextEditingController(text: '60');

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700),
    );
  }

  Future<Map<String, dynamic>> _apiCall(String method, String path, {Map<String, dynamic>? body, String? pin}) async {
    final uri = Uri.parse('$_backendBaseUrl$path');
    final headers = {'Content-Type': 'application/json', 'x-admin-pin': pin ?? _adminPin};
    http.Response res;
    if (method == 'POST') {
      res = await http.post(uri, headers: headers, body: json.encode(body ?? {})).timeout(const Duration(seconds: 12));
    } else if (method == 'DELETE') {
      res = await http.delete(uri, headers: headers).timeout(const Duration(seconds: 12));
    } else {
      res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 12));
    }
    Map<String, dynamic> decoded = {};
    try { decoded = json.decode(res.body); } catch (_) {}
    return {'status': res.statusCode, 'data': decoded};
  }

  Future<void> _verifyPin() async {
    final entered = _pinCtrl.text.trim();
    if (entered.isEmpty) return;
    setState(() => _loading = true);
    try {
      final r = await _apiCall('GET', '/api/admin/settings', pin: entered);
      if (r['status'] == 200) {
        _adminPin = entered;
        _unlocked = true;
        await _loadConfig();
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
    try {
      final r = await _apiCall('GET', '/api/admin/settings');
      if (r['status'] == 200) {
        final data = r['data'] as Map<String, dynamic>;
        final prefs = await SharedPreferences.getInstance();
        setState(() {
          if (data['reward_release'] != null) _rewardCtrl.text = data['reward_release'].toString();
          if (data['fee_search'] != null) _feeCtrl.text = data['fee_search'].toString();
final ritNot = int.tryParse(_xtRitNotSecCtrl.text) ?? 15;
    final gpsAtt = int.tryParse(_xtGpsAttivoSecCtrl.text) ?? 10;
    final gpsMax = int.tryParse(_xtGpsMaxAttivoMinCtrl.text) ?? 5;
    final gpsDis = int.tryParse(_xtGpsDisattivoSecCtrl.text) ?? 15;
    final spSave = await SharedPreferences.getInstance();
    await spSave.setInt('xt_rit_not_sec', ritNot);
    await spSave.setInt('xt_gps_attivo_sec', gpsAtt);
    await spSave.setInt('xt_gps_max_attivo_min', gpsMax);
    await spSave.setInt('xt_gps_disattivo_sec', gpsDis);
          if (data['penalty_false_release'] != null) _penaltyCtrl.text = data['penalty_false_release'].toString();
          if (data['release_delta_minutes'] != null) _deltaCtrl.text = data['release_delta_minutes'].toString();
      final spLoad = await SharedPreferences.getInstance();
        _xtRitNotSecCtrl.text = (data['xt_rit_not_sec'] ?? spLoad.getInt('xt_rit_not_sec') ?? 15).toString();
        _xtGpsAttivoSecCtrl.text = (data['xt_gps_attivo_sec'] ?? spLoad.getInt('xt_gps_attivo_sec') ?? 10).toString();
        _xtGpsMaxAttivoMinCtrl.text = (data['xt_gps_max_attivo_min'] ?? spLoad.getInt('xt_gps_max_attivo_min') ?? 5).toString();
        _xtGpsDisattivoSecCtrl.text = (data['xt_gps_disattivo_sec'] ?? spLoad.getInt('xt_gps_disattivo_sec') ?? 15).toString();
          if (data['auto_release_delay_s'] != null) {
            _autoReleaseDelayCtrl.text = data['auto_release_delay_s'].toString();
            final val = int.tryParse(_autoReleaseDelayCtrl.text);
            if (val != null) prefs.setInt('auto_release_delay_s', val);
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    setState(() => _loading = true);
    try {
      final delayVal = int.tryParse(_autoReleaseDelayCtrl.text) ?? 60;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('auto_release_delay_s', delayVal);

      final r = await _apiCall('POST', '/api/admin/settings', body: {
        'reward_release': int.tryParse(_rewardCtrl.text) ?? 10,
        'fee_search': int.tryParse(_feeCtrl.text) ?? 5,
        'penalty_false_release': int.tryParse(_penaltyCtrl.text) ?? 15,
        'wifi_exit_timeout_sec': int.tryParse(_xtRitNotSecCtrl.text) ?? 15,
      'gps_idle_timeout_min': int.tryParse(_xtGpsMaxAttivoMinCtrl.text) ?? 5,
      'xt_rit_not_sec': int.tryParse(_xtRitNotSecCtrl.text) ?? 15,
      'xt_gps_attivo_sec': int.tryParse(_xtGpsAttivoSecCtrl.text) ?? 10,
      'xt_gps_max_attivo_min': int.tryParse(_xtGpsMaxAttivoMinCtrl.text) ?? 5,
      'xt_gps_disattivo_sec': int.tryParse(_xtGpsDisattivoSecCtrl.text) ?? 15,
      'release_delta_minutes': int.tryParse(_deltaCtrl.text) ?? 5,
        'auto_release_delay_s': delayVal,
      });
      if (r['status'] == 200) {
        _showSnack('Salvato su cloud!');
      } else {
        _showSnack('Errore (${r['status']})', isError: true);
      }
    } catch (_) {
      _showSnack('Errore connessione server', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openAddZoneDialog() async {
    final nameCtrl = TextEditingController();
    final latCtrl = TextEditingController();
    final lonCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuova Zona Tariffata'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nome Zona (es. Centro Storico)')),
              TextField(controller: latCtrl, decoration: const InputDecoration(labelText: 'Latitudine'), keyboardType: TextInputType.number),
              TextField(controller: lonCtrl, decoration: const InputDecoration(labelText: 'Longitudine'), keyboardType: TextInputType.number),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty) {
                setState(() => _zones.add({'name': nameCtrl.text, 'lat': latCtrl.text, 'lon': lonCtrl.text}));
              }
              Navigator.pop(ctx);
            },
            child: const Text('Aggiungi'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    _rewardCtrl.dispose();
    _feeCtrl.dispose();
    _penaltyCtrl.dispose();
    _deltaCtrl.dispose();
    _autoReleaseDelayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pannello Amministratore'),
        backgroundColor: Colors.blueGrey.shade900,
        foregroundColor: Colors.white,
        actions: _unlocked ? [IconButton(icon: const Icon(Icons.add_location_alt), onPressed: _openAddZoneDialog)] : null,
      ),
      body: !_unlocked
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline, size: 64, color: Colors.blueGrey),
                  const SizedBox(height: 16),
                  const Text('Area Riservata Amministratore', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Inserisci PIN Admin', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _verifyPin,
                      child: Text(_loading ? 'Verifica in corso...' : 'Sblocca Pannello'),
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('Parametri Economici & Temporizzatori', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: _rewardCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Ricompensa Rilascio Stallo (crediti)',
                    helperText: 'Crediti accreditati all\'utente quando libera correttamente un posto.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _feeCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Costo Ricerca Parcheggio (crediti)',
                    helperText: 'Crediti scalati per la ricerca (gratuito per i Beta Tester).',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _penaltyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Penalità Falso Rilascio (crediti)',
                    helperText: 'Crediti detratti se l\'auto non lascia lo stallo entro il tempo limite.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _deltaCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Finestra Verifica Rilascio (minuti)',
                    helperText: 'Tempo massimo concesso per liberare lo stallo dopo la conferma.',
                    border: OutlineInputBorder(),

                  ),
                ),
            const SizedBox(height: 12),
            TextField(
          controller: _xtRitNotSecCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Xt.rit.not — Ritardo notifica disconnessione Wi-Fi (sec)',
            helperText: 'Default: 15s. Verifica che il Wi-Fi resti scollegato prima della push.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _xtGpsAttivoSecCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Xt.gps.attivo — Attesa prima di attivare GPS alta precisione (sec)',
            helperText: 'Default: 10s (0-10s). Tempo per confermare/rifiutare la notifica.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _xtGpsMaxAttivoMinCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Xt.gps.max_attivo — Timeout massimo GPS alta precisione (min)',
            helperText: 'Default: 5 min. Limite massimo di sicurezza per analisi uscita.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _xtGpsDisattivoSecCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Xt.gps.disattivo — Ritardo rientro GPS risparmio energetico (sec)',
            helperText: 'Default: 15s. Stabilizzazione prima di riportare il GPS standard.',
            border: OutlineInputBorder(),
          ),
        ),
                const SizedBox(height: 14),
                TextField(
                  controller: _autoReleaseDelayCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Timer Silenzio-Assenso (sec)',
                    helperText: 'Secondi di attesa dopo la notifica entro 100m prima del rilascio automatico.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _loading ? null : _saveConfig,
                  icon: const Icon(Icons.cloud_upload),
                  label: Text(_loading ? 'Salvataggio...' : 'Salva Configurazione'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade900,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ],
            ),
    );
  }
}
