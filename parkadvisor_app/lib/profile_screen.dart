import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const String _backendBaseUrl = 'https://parknow-api.onrender.com';
  static const String _userId = 'USER-001';

  bool _autoShare = true;
  bool _isBetaTester = false; // <-- Nuova variabile Beta Tester
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
      _isBetaTester = prefs.getBool('is_beta_tester') ?? false; // <-- Carica stato Beta Tester
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
      final res = await http.get(Uri.parse('$_backendBaseUrl/api/user/profile?userId=$_userId')).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        final remoteCredits = (data['credits_balance'] as num?)?.toInt();
        final remotePhone = data['phone_number'] as String?;
        final remoteBrand = data['car_brand'] as String?;
        final remoteModel = data['car_model'] as String?;
        final remoteColor = data['car_color'] as String?;
        final remoteAutoShare = data['auto_share_enabled'] as bool?;
        final remoteBetaTester = data['is_beta_tester'] as bool?; // <-- Predisposizione per Backend
        final remoteRadius = (data['search_radius_m'] as num?)?.toInt();
        final remoteWifi = data['home_wifi_ssid'] as String?;
        final remoteBt = data['car_bluetooth_mac'] as String?;
        String decodedPlate = '';
        final encPlate = data['car_plate_encrypted'] as String?;
        if (encPlate != null && encPlate.isNotEmpty) {
          try { decodedPlate = utf8.decode(base64Decode(encPlate)); } catch (_) {}
        }

        if (remoteCredits != null) await prefs.setInt('credits_balance', remoteCredits);
        if (remotePhone != null) await prefs.setString('user_phone', remotePhone);
        if (remoteBrand != null) await prefs.setString('car_brand', remoteBrand);
        if (remoteModel != null) await prefs.setString('car_model', remoteModel);
        if (remoteColor != null) await prefs.setString('car_color', remoteColor);
        if (decodedPlate.isNotEmpty) await prefs.setString('car_plate', decodedPlate);
        if (remoteAutoShare != null) await prefs.setBool('auto_share_enabled', remoteAutoShare);
        if (remoteBetaTester != null) await prefs.setBool('is_beta_tester', remoteBetaTester); // <-- Salva stato remoto Beta
        if (remoteRadius != null && _allowedRadii.contains(remoteRadius)) await prefs.setInt('search_radius_m', remoteRadius);
        if (remoteWifi != null) await prefs.setString('home_wifi_ssid', remoteWifi);
        if (remoteBt != null) await prefs.setString('car_bt_mac', remoteBt);

        setState(() {
          if (remoteCredits != null) _creditsBalance = remoteCredits;
          if (remotePhone != null) _phoneController.text = remotePhone;
          if (remoteBrand != null) _brandController.text = remoteBrand;
          if (remoteModel != null) _modelController.text = remoteModel;
          if (remoteColor != null) _colorController.text = remoteColor;
          if (decodedPlate.isNotEmpty) _plateController.text = decodedPlate;
          if (remoteAutoShare != null) _autoShare = remoteAutoShare;
          if (remoteBetaTester != null) _isBetaTester = remoteBetaTester; // <-- Aggiorna UI Beta
          if (remoteRadius != null && _allowedRadii.contains(remoteRadius)) _searchRadius = remoteRadius;
          if (remoteWifi != null) _wifiController.text = remoteWifi;
          if (remoteBt != null) _btController.text = remoteBt;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveProfile() async {
    setState(() => _isSaving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_share_enabled', _autoShare);
    await prefs.setBool('is_beta_tester', _isBetaTester); // <-- Salva stato Beta in locale
    await prefs.setInt('search_radius_m', _searchRadius);
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
          'phoneNumber': _phoneController.text.trim(),
          'carBrand': _brandController.text.trim(),
          'carModel': _modelController.text.trim(),
          'carColor': _colorController.text.trim(),
          'carPlate': _plateController.text.trim().toUpperCase(),
          'autoShareEnabled': _autoShare,
          'isBetaTester': _isBetaTester, // <-- Invia stato Beta al backend
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
                MaterialPageRoute(builder: (_) => const AdminScreen()),
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