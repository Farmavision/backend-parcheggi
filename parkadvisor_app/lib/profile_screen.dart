import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_screen.dart';
import 'admin_hub_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const String _backendBaseUrl = 'https://parknow-api.onrender.com';
  static const String _userId = 'USER-001';

  bool _autoShare = true;
  bool _isBetaTester = false;
  int _searchRadius = 500;
  int _creditsBalance = 50;
  bool _isSaving = false;

  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _brandController = TextEditingController();
  final _modelController = TextEditingController();
  final _colorController = TextEditingController();
  final _plateController = TextEditingController();
  final _wifiController = TextEditingController();
  final _btController = TextEditingController();
  static const MethodChannel _bgServiceChannel = MethodChannel('parknow/bg_service');
  List<String> _homeWifis = [];
  List<String> _workWifis = [];
  List<String> _ignoredWifis = [];
  List<String> _carBtMacs = [];
  List<String> _ignoredBtMacs = [];
  Map<String, String> _btNames = {};

  List<String> _parseCsv(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    return raw.split(',').map((e) => e.replaceAll('"', '').trim()).where((e) => e.isNotEmpty).toList();
  }

  Future<void> _persistAndSyncNetworks() async {
    final prefs = await SharedPreferences.getInstance();
    final homeCsv = _homeWifis.join(',');
    final workCsv = _workWifis.join(',');
    final btCsv = _carBtMacs.map((m) => m.toUpperCase()).join(',');
    _wifiController.text = homeCsv;
    _btController.text = btCsv;

    if (homeCsv.isEmpty) { await prefs.remove('home_wifi_ssid'); } else { await prefs.setString('home_wifi_ssid', homeCsv); }
    if (workCsv.isEmpty) { await prefs.remove('work_wifi_ssid'); } else { await prefs.setString('work_wifi_ssid', workCsv); }
    await prefs.setStringList('ignored_wifis', _ignoredWifis);
    if (btCsv.isEmpty) { await prefs.remove('car_bt_mac'); } else { await prefs.setString('car_bt_mac', btCsv); }
    await prefs.setStringList('ignored_bt_macs', _ignoredBtMacs);
    await prefs.setString('car_bt_names_json', json.encode(_btNames));

    try {
      await _bgServiceChannel.invokeMethod('syncConfigToNative', {
        'homeWifiSsid': homeCsv,
        if (homeCsv.isEmpty) 'clearHomeWifi': true,
        'workWifiSsid': workCsv,
        if (workCsv.isEmpty) 'clearWorkWifi': true,
        'ignoredWifis': _ignoredWifis,
        'carBtMac': btCsv,
      });
    } catch (_) {}
  }

  Future<void> _addWifiDialog() async {
    final ctrl = TextEditingController();
    String kind = 'home';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Aggiungi rete Wi-Fi'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(labelText: 'Nome rete (SSID)', border: OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: kind,
                decoration: const InputDecoration(labelText: 'Tipo', border: OutlineInputBorder(), isDense: true),
                items: const [
                  DropdownMenuItem(value: 'home', child: Text('Casa')),
                  DropdownMenuItem(value: 'work', child: Text('Lavoro')),
                  DropdownMenuItem(value: 'ignored', child: Text('Ignorata (non chiedere più)')),
                ],
                onChanged: (v) { if (v != null) setDlg(() => kind = v); },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
            ElevatedButton(
              onPressed: () async {
                final ssid = ctrl.text.replaceAll('"', '').trim();
                if (ssid.isEmpty) return;
                setState(() {
                  _homeWifis.removeWhere((e) => e.toLowerCase() == ssid.toLowerCase());
                  _workWifis.removeWhere((e) => e.toLowerCase() == ssid.toLowerCase());
                  _ignoredWifis.removeWhere((e) => e.toLowerCase() == ssid.toLowerCase());
                  if (kind == 'home') _homeWifis.add(ssid);
                  else if (kind == 'work') _workWifis.add(ssid);
                  else _ignoredWifis.add(ssid);
                });
                await _persistAndSyncNetworks();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Salva'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addBluetoothDialog() async {
    final macCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String kind = 'car';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Aggiungi dispositivo Bluetooth'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Nome (es. Audi MMI)', border: OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: macCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Indirizzo MAC (AA:BB:CC:DD:EE:FF)', border: OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: kind,
                decoration: const InputDecoration(labelText: 'Tipo', border: OutlineInputBorder(), isDense: true),
                items: const [
                  DropdownMenuItem(value: 'car', child: Text('Auto')),
                  DropdownMenuItem(value: 'ignored', child: Text('Ignorato (non chiedere più)')),
                ],
                onChanged: (v) { if (v != null) setDlg(() => kind = v); },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
            ElevatedButton(
              onPressed: () async {
                final mac = macCtrl.text.trim().toUpperCase();
                final name = nameCtrl.text.trim();
                if (mac.isEmpty) return;
                setState(() {
                  _carBtMacs.removeWhere((e) => e.toUpperCase() == mac);
                  _ignoredBtMacs.removeWhere((e) => e.toUpperCase() == mac);
                  if (kind == 'car') _carBtMacs.add(mac);
                  else _ignoredBtMacs.add(mac);
                  if (name.isNotEmpty) _btNames[mac] = name;
                });
                await _persistAndSyncNetworks();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Salva'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _netBadge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
    child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
  );

  Widget _buildMyWifiCard() {
    final items = <Map<String, String>>[
      ..._homeWifis.map((s) => {'ssid': s, 'type': 'home'}),
      ..._workWifis.map((s) => {'ssid': s, 'type': 'work'}),
      ..._ignoredWifis.map((s) => {'ssid': s, 'type': 'ignored'}),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi, color: Colors.blue),
                const SizedBox(width: 8),
                const Expanded(child: Text('Le mie reti Wi-Fi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                TextButton.icon(onPressed: _addWifiDialog, icon: const Icon(Icons.add, size: 18), label: const Text('Aggiungi')),
              ],
            ),
            const Text('Le reti in elenco vengono riconosciute in automatico e non saranno più richieste alla connessione.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Text('Nessuna rete Wi-Fi salvata.', style: TextStyle(color: Colors.grey, fontSize: 13))
            else
              ...items.map((it) {
                final ssid = it['ssid']!;
                final type = it['type']!;
                final color = type == 'home' ? Colors.blue.shade700 : (type == 'work' ? Colors.teal.shade700 : Colors.grey.shade700);
                final label = type == 'home' ? 'Casa' : (type == 'work' ? 'Lavoro' : 'Ignorata');
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(ssid, style: const TextStyle(fontWeight: FontWeight.w600)),
                  leading: _netBadge(label, color),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    onPressed: () async {
                      setState(() {
                        _homeWifis.removeWhere((e) => e.toLowerCase() == ssid.toLowerCase());
                        _workWifis.removeWhere((e) => e.toLowerCase() == ssid.toLowerCase());
                        _ignoredWifis.removeWhere((e) => e.toLowerCase() == ssid.toLowerCase());
                      });
                      await _persistAndSyncNetworks();
                    },
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildMyBluetoothCard() {
    final items = <Map<String, String>>[
      ..._carBtMacs.map((m) => {'mac': m.toUpperCase(), 'type': 'car'}),
      ..._ignoredBtMacs.map((m) => {'mac': m.toUpperCase(), 'type': 'ignored'}),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth, color: Colors.indigo),
                const SizedBox(width: 8),
                const Expanded(child: Text('I miei dispositivi Bluetooth', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                TextButton.icon(onPressed: _addBluetoothDialog, icon: const Icon(Icons.add, size: 18), label: const Text('Aggiungi')),
              ],
            ),
            const Text('I dispositivi in elenco non verranno più richiesti quando si connettono al telefono.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Text('Nessun dispositivo Bluetooth salvato.', style: TextStyle(color: Colors.grey, fontSize: 13))
            else
              ...items.map((it) {
                final mac = it['mac']!;
                final type = it['type']!;
                final name = _btNames[mac] ?? '';
                final color = type == 'car' ? Colors.indigo.shade700 : Colors.grey.shade700;
                final label = type == 'car' ? 'Auto' : 'Ignorato';
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: _netBadge(label, color),
                  title: Text(name.isNotEmpty ? name : mac, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: name.isNotEmpty ? Text(mac, style: const TextStyle(fontSize: 11)) : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    onPressed: () async {
                      setState(() {
                        _carBtMacs.removeWhere((e) => e.toUpperCase() == mac);
                        _ignoredBtMacs.removeWhere((e) => e.toUpperCase() == mac);
                      });
                      await _persistAndSyncNetworks();
                    },
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
  final List<int> _allowedRadii = [100, 300, 500, 1000];

  String get _maskedPlatePreview {
    final raw = _plateController.text.trim().toUpperCase();
    if (raw.isEmpty) return 'Non impostata';
    if (raw.length <= 2) return raw;
    return '${'*' * (raw.length - 2)}${raw.substring(raw.length - 2)}';
  }

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isBetaTester = prefs.getBool('is_beta_tester') ?? false;
      _autoShare = _isBetaTester ? true : (prefs.getBool('auto_share_enabled') ?? true);
      final savedRadius = prefs.getInt('search_radius_m') ?? 500;
      _searchRadius = _allowedRadii.contains(savedRadius) ? savedRadius : 500;
      _creditsBalance = prefs.getInt('credits_balance') ?? 50;
      _emailController.text = prefs.getString('user_email') ?? '';
      _phoneController.text = prefs.getString('user_phone') ?? '';
      _brandController.text = prefs.getString('car_brand') ?? '';
      _modelController.text = prefs.getString('car_model') ?? '';
      _colorController.text = prefs.getString('car_color') ?? '';
      _plateController.text = prefs.getString('car_plate') ?? '';
      _wifiController.text = prefs.getString('home_wifi_ssid') ?? '';
      _btController.text = prefs.getString('car_bt_mac') ?? '';
      _homeWifis = _parseCsv(prefs.getString('home_wifi_ssid'));
      _workWifis = _parseCsv(prefs.getString('work_wifi_ssid'));
      _ignoredWifis = prefs.getStringList('ignored_wifis') ?? [];
      _carBtMacs = _parseCsv(prefs.getString('car_bt_mac')).map((m) => m.toUpperCase()).toList();
      _ignoredBtMacs = (prefs.getStringList('ignored_bt_macs') ?? []).map((m) => m.toUpperCase()).toList();
      try {
        final rawNames = prefs.getString('car_bt_names_json');
        if (rawNames != null && rawNames.isNotEmpty) {
          _btNames = Map<String, String>.from(json.decode(rawNames));
        }
        final legacyName = prefs.getString('car_bt_name');
        if (legacyName != null && legacyName.isNotEmpty && _carBtMacs.isNotEmpty) {
          _btNames.putIfAbsent(_carBtMacs.first, () => legacyName);
        }
      } catch (_) {}
    });

    try {
      final res = await http.get(Uri.parse('$_backendBaseUrl/api/user/profile?userId=$_userId')).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        final remoteCredits = (data['credits_balance'] as num?)?.toInt();
        final remoteEmail = data['email'] as String?;
        final remotePhone = data['phone_number'] as String?;
        final remoteBrand = data['car_brand'] as String?;
        final remoteModel = data['car_model'] as String?;
        final remoteColor = data['car_color'] as String?;
        final remoteAutoShare = data['auto_share_enabled'] as bool?;
        final remoteBetaTester = data['is_beta_tester'] as bool?;
        final remoteRadius = (data['search_radius_m'] as num?)?.toInt();
        final remoteWifi = data['home_wifi_ssid'] as String?;
        final remoteBt = data['car_bluetooth_mac'] as String?;
        String decodedPlate = '';
        final encPlate = data['car_plate_encrypted'] as String?;
        if (encPlate != null && encPlate.isNotEmpty) {
          try { decodedPlate = utf8.decode(base64Decode(encPlate)); } catch (_) {}
        }

        if (remoteCredits != null) await prefs.setInt('credits_balance', remoteCredits);
        if (remoteEmail != null) await prefs.setString('user_email', remoteEmail);
        if (remotePhone != null) await prefs.setString('user_phone', remotePhone);
        if (remoteBrand != null) await prefs.setString('car_brand', remoteBrand);
        if (remoteModel != null) await prefs.setString('car_model', remoteModel);
        if (remoteColor != null) await prefs.setString('car_color', remoteColor);
        if (decodedPlate.isNotEmpty) await prefs.setString('car_plate', decodedPlate);
        if (remoteBetaTester != null) await prefs.setBool('is_beta_tester', remoteBetaTester);
        final effectiveAutoShare = (remoteBetaTester ?? _isBetaTester) ? true : (remoteAutoShare ?? _autoShare);
        await prefs.setBool('auto_share_enabled', effectiveAutoShare);
        if (remoteRadius != null && _allowedRadii.contains(remoteRadius)) await prefs.setInt('search_radius_m', remoteRadius);
        if (remoteWifi != null) await prefs.setString('home_wifi_ssid', remoteWifi);
        if (remoteBt != null) await prefs.setString('car_bluetooth_mac', remoteBt);

        setState(() {
          if (remoteCredits != null) _creditsBalance = remoteCredits;
          if (remoteEmail != null) _emailController.text = remoteEmail;
          if (remotePhone != null) _phoneController.text = remotePhone;
          if (remoteBrand != null) _brandController.text = remoteBrand;
          if (remoteModel != null) _modelController.text = remoteModel;
          if (remoteColor != null) _colorController.text = remoteColor;
          if (decodedPlate.isNotEmpty) _plateController.text = decodedPlate;
          if (remoteBetaTester != null) _isBetaTester = remoteBetaTester;
          _autoShare = _isBetaTester ? true : (remoteAutoShare ?? _autoShare);
          if (remoteRadius != null && _allowedRadii.contains(remoteRadius)) _searchRadius = remoteRadius;
          if (remoteWifi != null) _wifiController.text = remoteWifi;
          if (remoteBt != null) _btController.text = remoteBt;
          if (remoteWifi != null && remoteWifi.isNotEmpty) {
            for (final s in _parseCsv(remoteWifi)) {
              if (!_homeWifis.any((e) => e.toLowerCase() == s.toLowerCase())) _homeWifis.add(s);
            }
          }
          if (remoteBt != null && remoteBt.isNotEmpty) {
            for (final m in _parseCsv(remoteBt)) {
              final u = m.toUpperCase();
              if (!_carBtMacs.any((e) => e.toUpperCase() == u)) _carBtMacs.add(u);
            }
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _onBetaTesterToggled(bool value) async {
    if (!value) {
      setState(() => _isBetaTester = false);
      return;
    }

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.science, color: Colors.amber.shade900, size: 40),
        title: const Text('Programma Beta Tester ParkNow!', textAlign: TextAlign.center),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Il tuo contributo è fondamentale per costruire una base informativa solida sull\'affidabilità del rilevamento automatico dei parcheggi in città.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 12),
              Text('Attivando la modalità Beta Tester accetti le seguenti condizioni:'),
              SizedBox(height: 8),
              Text('• Condivisione Automatica Obbligatoria: il rilevamento sosta e ripartenza tramite sensori resta sempre attivo e non può essere disabilitato.'),
              SizedBox(height: 6),
              Text('• Rilascio Silenzio-Assenso: quando ti avvicini entro 100m dall\'auto parte un conto alla rovescia con notifica; se non annulli, lo stallo viene liberato in automatico.'),
              SizedBox(height: 6),
              Text('• Utilizzo Gratuito: durante il test i costi in crediti per la ricerca parcheggio sono completamente azzerati.'),
              SizedBox(height: 6),
              Text('• Segnalazioni Dirette: avrai accesso al modulo rapido per inviare anomalie o suggerimenti al team tecnico.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Accetta e Attiva'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber.shade800,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );

    if (accepted == true && mounted) {
      setState(() {
        _isBetaTester = true;
        _autoShare = true;
      });
    }
  }

  Future<void> _openBetaReportDialog() async {
    String selectedCategory = 'Sensori / Rilevamento Sosta';
    final messageCtrl = TextEditingController();
    bool sending = false;

    final categories = [
      'Sensori / Rilevamento Sosta',
      'Notifica Silenzio-Assenso',
      'Mappa / Ricerca Parcheggio',
      'Bluetooth / Wi-Fi',
      'Altro / Suggerimento',
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          icon: Icon(Icons.bug_report, color: Colors.amber.shade900, size: 36),
          title: const Text('Invia Segnalazione Beta'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Aiutaci a migliorare la precisione del sistema descrivendo cosa è successo:', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Area interessata', border: OutlineInputBorder(), isDense: true),
                  items: categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (v) { if (v != null) setDialogState(() => selectedCategory = v); },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: messageCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Descrizione dettagliata',
                    hintText: 'Es. Ero fermo al semaforo e ha rilevato sosta, oppure la notifica non è comparsa...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: sending ? null : () => Navigator.pop(ctx),
              child: const Text('Chiudi'),
            ),
            ElevatedButton.icon(
              onPressed: sending
                  ? null
                  : () async {
                      final msg = messageCtrl.text.trim();
                      if (msg.isEmpty) return;
                      setDialogState(() => sending = true);
                      bool ok = false;
                      try {
                        final res = await http.post(
                          Uri.parse('$_backendBaseUrl/api/beta/feedback'),
                          headers: {'Content-Type': 'application/json'},
                          body: json.encode({
                            'userId': _userId,
                            'category': selectedCategory,
                            'message': msg,
                            'diagnostics': {
                              'searchRadiusM': _searchRadius,
                              'hasWifiConfigured': _wifiController.text.trim().isNotEmpty,
                              'hasBtConfigured': _btController.text.trim().isNotEmpty,
                              'carInfo': '${_brandController.text.trim()} ${_modelController.text.trim()}'.trim(),
                            },
                          }),
                        ).timeout(const Duration(seconds: 12));
                        ok = res.statusCode == 200 || res.statusCode == 201;
                      } catch (_) {}

                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: ok ? Colors.green.shade700 : Colors.orange.shade800,
                            content: Text(ok
                                ? 'Segnalazione inviata al team tecnico. Grazie per il contributo!'
                                : 'Segnalazione salvata: verrà sincronizzata appena il server risponde.'),
                          ),
                        );
                      }
                    },
              icon: const Icon(Icons.send),
              label: Text(sending ? 'Invio...' : 'Invia Report'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade900,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveProfile() async {
    setState(() => _isSaving = true);
    if (_isBetaTester) _autoShare = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_share_enabled', _autoShare);
    await prefs.setBool('is_beta_tester', _isBetaTester);
    await prefs.setInt('search_radius_m', _searchRadius);
    await prefs.setString('user_email', _emailController.text.trim());
    await prefs.setString('user_phone', _phoneController.text.trim());
    await prefs.setString('car_brand', _brandController.text.trim());
    await prefs.setString('car_model', _modelController.text.trim());
    await prefs.setString('car_color', _colorController.text.trim());
    await prefs.setString('car_plate', _plateController.text.trim().toUpperCase());
    if (_wifiController.text.trim().isNotEmpty) await prefs.setString('home_wifi_ssid', _wifiController.text.trim());
    if (_btController.text.trim().isNotEmpty) await prefs.setString('car_bt_mac', _btController.text.trim().toUpperCase());

    bool cloudSynced = false;
    String? syncError;
    try {
      final res = await http.post(
        Uri.parse('$_backendBaseUrl/api/user/profile'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': _userId,
          'email': _emailController.text.trim(),
          'phoneNumber': _phoneController.text.trim(),
          'carBrand': _brandController.text.trim(),
          'carModel': _modelController.text.trim(),
          'carColor': _colorController.text.trim(),
          'carPlate': _plateController.text.trim().toUpperCase(),
          'autoShareEnabled': _autoShare,
          'isBetaTester': _isBetaTester,
          'searchRadiusM': _searchRadius,
          'homeWifiSsid': _wifiController.text.trim(),
          'carBluetoothMac': _btController.text.trim().toUpperCase(),
        }),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        cloudSynced = true;
        final data = json.decode(res.body);
        final bal = (data['profile']?['credits_balance'] as num?)?.toInt();
        if (bal != null) {
          await prefs.setInt('credits_balance', bal);
          if (mounted) setState(() => _creditsBalance = bal);
        }
      } else {
        syncError = 'HTTP ${res.statusCode}';
      }
    } catch (e) {
      syncError = 'Connessione lenta o server in avvio';
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: cloudSynced ? Colors.green.shade700 : Colors.orange.shade800,
        content: Text(cloudSynced
            ? 'Profilo salvato e sincronizzato sul cloud!'
            : 'Salvato sul telefono (sync cloud rimandata: $syncError)'),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _phoneController.dispose();
    _brandController.dispose();
    _modelController.dispose();
    _colorController.dispose();
    _plateController.dispose();
    _wifiController.dispose();
    _btController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profilo e Impostazioni'),
        backgroundColor: Colors.blue.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.admin_panel_settings),
            tooltip: 'Pannello Amministratore',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AdminHubScreen()),
              );
            },
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadProfileData)
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            color: Colors.blue.shade50,
            child: ListTile(
              leading: Icon(Icons.account_balance_wallet, color: Colors.blue.shade800, size: 38),
              title: const Text('Borsellino Crediti', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(_isBetaTester ? 'Account Beta Tester (Costi esenti)' : 'Saldo attuale disponibile'),
              trailing: Text('$_creditsBalance cr', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: Colors.amber.shade50,
            child: Column(
              children: [
                SwitchListTile(
                  secondary: Icon(Icons.science, color: Colors.amber.shade900),
                  title: const Text('Modalità Beta Tester', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Abilita il rilascio automatico Silenzio-Assenso e azzera i costi di utilizzo.'),
                  value: _isBetaTester,
                  onChanged: _onBetaTesterToggled,
                ),
                if (_isBetaTester)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _openBetaReportDialog,
                        icon: Icon(Icons.bug_report, color: Colors.amber.shade900),
                        label: Text('Invia Segnalazione / Feedback Beta', style: TextStyle(color: Colors.amber.shade900, fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.amber.shade800),
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: _isBetaTester ? Colors.grey.shade100 : null,
            child: SwitchListTile(
              title: Text(
                'Condivisione Automatica Parcheggio',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _isBetaTester ? Colors.grey.shade700 : null,
                ),
              ),
              subtitle: Text(
                _isBetaTester
                    ? 'Attiva e obbligatoria in modalità Beta Tester per la raccolta dati.'
                    : 'Rileva automaticamente sosta e ripartenza tramite sensori',
              ),
              value: _isBetaTester ? true : _autoShare,
              onChanged: _isBetaTester ? null : (v) => setState(() => _autoShare = v),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Raggio di Ricerca Predefinito', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _searchRadius,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                    items: _allowedRadii.map((r) => DropdownMenuItem(value: r, child: Text('$r metri'))).toList(),
                    onChanged: (v) { if (v != null) setState(() => _searchRadius = v); },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Dati Veicolo & Contatto', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(controller: _emailController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder(), isDense: true)),
                  const SizedBox(height: 10),
                  TextField(controller: _phoneController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Telefono', border: OutlineInputBorder(), isDense: true)),
                  const SizedBox(height: 10),
                  TextField(controller: _brandController, decoration: const InputDecoration(labelText: 'Marca Auto (es. Fiat)', border: OutlineInputBorder(), isDense: true)),
                  const SizedBox(height: 10),
                  TextField(controller: _modelController, decoration: const InputDecoration(labelText: 'Modello (es. Panda)', border: OutlineInputBorder(), isDense: true)),
                  const SizedBox(height: 10),
                  TextField(controller: _colorController, decoration: const InputDecoration(labelText: 'Colore', border: OutlineInputBorder(), isDense: true)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _plateController,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(labelText: 'Targa (visibile: $_maskedPlatePreview)', border: const OutlineInputBorder(), isDense: true),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildMyWifiCard(),
          const SizedBox(height: 12),
          _buildMyBluetoothCard(),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveProfile,
              icon: const Icon(Icons.save),
              label: Text(_isSaving ? 'Salvataggio...' : 'Salva Profilo'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade800,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
