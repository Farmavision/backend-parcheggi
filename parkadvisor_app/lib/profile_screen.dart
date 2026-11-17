import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const String _backendBaseUrl = 'https://parknow-api.onrender.com';
  static const String _userId = 'USER-001';

  bool _autoShare = true;
  int _searchRadius = 500;
  int _creditsBalance = 50;
  bool _isSaving = false;

  final _phoneController = TextEditingController();
  final _brandController = TextEditingController();
  final _modelController = TextEditingController();
  final _colorController = TextEditingController();
  final _plateController = TextEditingController();
  final _wifiController = TextEditingController();
  final _btController = TextEditingController();
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
      _autoShare = prefs.getBool('auto_share_enabled') ?? true;
      final savedRadius = prefs.getInt('search_radius_m') ?? 500;
      _searchRadius = _allowedRadii.contains(savedRadius) ? savedRadius : 500;
      _creditsBalance = prefs.getInt('credits_balance') ?? 50;
      _phoneController.text = prefs.getString('user_phone') ?? '';
      _brandController.text = prefs.getString('car_brand') ?? '';
      _modelController.text = prefs.getString('car_model') ?? '';
      _colorController.text = prefs.getString('car_color') ?? '';
      _plateController.text = prefs.getString('car_plate') ?? '';
      _wifiController.text = prefs.getString('home_wifi_ssid') ?? '';
      _btController.text = prefs.getString('car_bt_mac') ?? '';
    });

    try {
      final res = await http.get(Uri.parse('$_backendBaseUrl/api/user/profile?userId=$_userId')).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        final remoteCredits = (data['credits_balance'] as num?)?.toInt();
        if (remoteCredits != null) {
          await prefs.setInt('credits_balance', remoteCredits);
          setState(() => _creditsBalance = remoteCredits);
        }
      }
    } catch (_) {}
  }

  Future<void> _saveProfile() async {
    setState(() => _isSaving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_share_enabled', _autoShare);
    await prefs.setInt('search_radius_m', _searchRadius);
    await prefs.setString('user_phone', _phoneController.text.trim());
    await prefs.setString('car_brand', _brandController.text.trim());
    await prefs.setString('car_model', _modelController.text.trim());
    await prefs.setString('car_color', _colorController.text.trim());
    await prefs.setString('car_plate', _plateController.text.trim().toUpperCase());
    if (_wifiController.text.trim().isNotEmpty) await prefs.setString('home_wifi_ssid', _wifiController.text.trim());
    if (_btController.text.trim().isNotEmpty) await prefs.setString('car_bt_mac', _btController.text.trim().toUpperCase());

    try {
      final res = await http.post(
        Uri.parse('$_backendBaseUrl/api/user/profile'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': _userId,
          'phoneNumber': _phoneController.text.trim(),
          'carBrand': _brandController.text.trim(),
          'carModel': _modelController.text.trim(),
          'carColor': _colorController.text.trim(),
          'carPlate': _plateController.text.trim().toUpperCase(),
          'autoShareEnabled': _autoShare,
          'searchRadiusM': _searchRadius,
          'homeWifiSsid': _wifiController.text.trim(),
          'carBluetoothMac': _btController.text.trim().toUpperCase(),
        }),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final bal = (data['profile']?['credits_balance'] as num?)?.toInt();
        if (bal != null) {
          await prefs.setInt('credits_balance', bal);
          if (mounted) setState(() => _creditsBalance = bal);
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() => _isSaving = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profilo e preferenze salvati!')));
  }

  @override
  void dispose() {
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
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadProfileData)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            color: Colors.blue.shade50,
            child: ListTile(
              leading: Icon(Icons.account_balance_wallet, color: Colors.blue.shade800, size: 38),
              title: const Text('Borsellino Crediti', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Crediti maturati con rilascio verificato'),
              trailing: Text('$_creditsBalance', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green.shade700)),
            ),
          ),
          const SizedBox(height: 18),
          const Text('ACCOUNT', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Numero di Cellulare', prefixIcon: Icon(Icons.phone_android), border: OutlineInputBorder()),
          ),
          const SizedBox(height: 18),
          const Text('IL TUO VEICOLO', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _brandController, decoration: const InputDecoration(labelText: 'Marca', border: OutlineInputBorder()))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _modelController, decoration: const InputDecoration(labelText: 'Modello', border: OutlineInputBorder()))),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: _colorController, decoration: const InputDecoration(labelText: 'Colore', border: OutlineInputBorder()))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _plateController, textCapitalization: TextCapitalization.characters, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Targa', border: OutlineInputBorder()))),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text('Visibilità pubblica targa (ultime 2 cifre): $_maskedPlatePreview', style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700)),
          ),
          const SizedBox(height: 18),
          const Text('RILASCIO PARCHEGGIO', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notifica / Condivisione Automatica'),
            subtitle: Text(_autoShare
                ? 'Attiva: se ignori il pop-up <100m, libera in automatico all\'aggancio BT/GPS/Giroscopio'
                : 'Manuale: libera lo stallo solo su conferma esplicita del pop-up'),
            value: _autoShare,
            onChanged: (v) => setState(() => _autoShare = v),
          ),
          const SizedBox(height: 14),
          Text('RAGGIO DI RICERCA: $_searchRadius metri', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          Slider(
            value: _allowedRadii.indexOf(_searchRadius).toDouble(),
            min: 0,
            max: (_allowedRadii.length - 1).toDouble(),
            divisions: _allowedRadii.length - 1,
            label: '$_searchRadius m',
            onChanged: (v) => setState(() => _searchRadius = _allowedRadii[v.toInt()]),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _allowedRadii.map((r) => Text('${r}m', style: const TextStyle(fontSize: 12, color: Colors.grey))).toList(),
          ),
          const SizedBox(height: 14),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Sensori Smart (Opzionale)', style: TextStyle(fontWeight: FontWeight.w600)),
            children: [
              const SizedBox(height: 8),
              TextField(controller: _wifiController, decoration: const InputDecoration(labelText: 'Wi-Fi Casa/Ufficio', prefixIcon: Icon(Icons.wifi), border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: _btController, decoration: const InputDecoration(labelText: 'MAC Bluetooth Auto', prefixIcon: Icon(Icons.bluetooth_connected), border: OutlineInputBorder())),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade800,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              icon: const Icon(Icons.save),
              label: Text(_isSaving ? 'SALVATAGGIO...' : 'SALVA PROFILO', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              onPressed: _isSaving ? null : _saveProfile,
            ),
          ),
        ),
      ),
    );
  }
}
