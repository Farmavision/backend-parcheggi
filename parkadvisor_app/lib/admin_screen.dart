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
  List> _zones = [];

  // Aggiunto 'auto_release_delay_s' alla mappa dei controller
  final Map<String, TextEditingController> _controllers = {
    'initial_credits': TextEditingController(text: '50'),
    'search_fee': TextEditingController(text: '5'),
    'release_reward': TextEditingController(text: '4'),
    'cancellation_penalty': TextEditingController(text: '2'),
    'release_delta_minutes': TextEditingController(text: '5'),
    'reservation_hold_minutes': TextEditingController(text: '10'),
    'free_spot_ttl_minutes': TextEditingController(text: '15'),
    'polling_interval_seconds': TextEditingController(text: '5'),
    'auto_release_delay_s': TextEditingController(text: '60'), // <-- Nuovo parametro Timer
    'search_radius_meters': TextEditingController(text: '500'),
    'arrival_verification_meters': TextEditingController(text: '25'),
  };

  @override
  void dispose() {
    _pinCtrl.dispose();
    for (final c in _controllers.values) c.dispose();
    super.dispose();
  }

  Future> _apiCall(String method, String path, {Map<String, dynamic>? body, String? pin}) async {
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
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nome Zona (es.