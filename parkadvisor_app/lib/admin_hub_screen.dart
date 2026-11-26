import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'admin_screen.dart';

const String _kAdminBackendUrl = 'https://parknow-api.onrender.com';

Future<Map<String, dynamic>> _adminReq(
  String method,
  String path,
  String pin, {
  Map<String, dynamic>? body,
}) async {
  final uri = Uri.parse('$_kAdminBackendUrl$path');
  final headers = {'Content-Type': 'application/json', 'x-admin-pin': pin};
  http.Response res;
  if (method == 'POST') {
    res = await http.post(uri, headers: headers, body: json.encode(body ?? {})).timeout(const Duration(seconds: 12));
  } else {
    res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 12));
  }
  Map<String, dynamic> data = {};
  try {
    final decoded = json.decode(res.body);
    if (decoded is Map<String, dynamic>) data = decoded;
  } catch (_) {}
  return {'status': res.statusCode, 'data': data};
}

String _fmtTs(dynamic raw) {
  if (raw == null) return '—';
  final s = raw.toString();
  final dt = DateTime.tryParse(s)?.toLocal();
  if (dt == null) return s.length > 16 ? s.substring(0, 16) : s;
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(dt.day)}/${p(dt.month)} ${p(dt.hour)}:${p(dt.minute)}';
}

class AdminHubScreen extends StatefulWidget {
  const AdminHubScreen({super.key});
  @override
  State<AdminHubScreen> createState() => _AdminHubScreenState();
}

class _AdminHubScreenState extends State<AdminHubScreen> {
  final _pinCtrl = TextEditingController();
  bool _unlocked = false;
  bool _verifying = false;
  String _adminPin = '';

  Timer? _liveTimer;
  bool _loadingSpots = false;
  int _totalSpots = 0;
  int _occupiedSpots = 0;
  int _leavingSpots = 0;
  int _freeSpots = 0;
  String _lastUpdated = '';
  List<dynamic> _liveSpots = [];

  @override
  void dispose() {
    _liveTimer?.cancel();
    _pinCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: err ? Colors.red.shade700 : Colors.green.shade700),
    );
  }

  Future<void> _unlock() async {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty) return;
    setState(() => _verifying = true);
    try {
      final r = await _adminReq('POST', '/api/admin/verify-pin', pin, body: {'pin': pin});
      if (r['status'] == 200 && r['data']['ok'] == true) {
        _adminPin = pin;
        setState(() => _unlocked = true);
        await _fetchSpotsSummary();
        _liveTimer?.cancel();
        _liveTimer = Timer.periodic(const Duration(seconds: 12), (_) => _fetchSpotsSummary(silent: true));
      } else {
        _snack('PIN amministratore errato', err: true);
      }
    } catch (_) {
      _snack('Errore connessione al server', err: true);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _fetchSpotsSummary({bool silent = false}) async {
    if (!_unlocked) return;
    if (!silent && mounted) setState(() => _loadingSpots = true);
    try {
      final r = await _adminReq('GET', '/api/admin/spots-summary', _adminPin);
      if (r['status'] == 200 && mounted) {
        final d = r['data'] as Map<String, dynamic>;
        final c = (d['counts'] as Map<String, dynamic>?) ?? {};
        setState(() {
          _totalSpots = (c['total'] as num?)?.toInt() ?? 0;
          _occupiedSpots = (c['occupied'] as num?)?.toInt() ?? 0;
          _leavingSpots = (c['leavingSoon'] as num?)?.toInt() ?? 0;
          _freeSpots = (c['free'] as num?)?.toInt() ?? 0;
          _liveSpots = (d['spots'] as List<dynamic>?) ?? [];
          _lastUpdated = _fmtTs(d['timestamp']);
        });
      }
    } catch (_) {
    } finally {
      if (!silent && mounted) setState(() => _loadingSpots = false);
    }
  }

  Widget _kpiBox(String label, int value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Column(
          children: [
            Text('$value', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildProportionalBar() {
    final tot = _totalSpots <= 0 ? 1 : _totalSpots;
    final occFlex = (_occupiedSpots * 100 / tot).round();
    final leavFlex = (_leavingSpots * 100 / tot).round();
    final freeFlex = (_freeSpots * 100 / tot).round();
    if (_totalSpots == 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(height: 10, color: Colors.grey.shade200),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 10,
        child: Row(
          children: [
            if (occFlex > 0) Expanded(flex: occFlex, child: Container(color: Colors.red.shade600)),
            if (leavFlex > 0) Expanded(flex: leavFlex, child: Container(color: Colors.amber.shade700)),
            if (freeFlex > 0) Expanded(flex: freeFlex, child: Container(color: Colors.green.shade600)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hub Amministratore'),
        backgroundColor: Colors.blueGrey.shade900,
        foregroundColor: Colors.white,
        actions: [
          if (_unlocked)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Aggiorna stalli live',
              onPressed: () => _fetchSpotsSummary(),
            ),
        ],
      ),
      body: !_unlocked ? _buildPinGate() : _buildHubBody(),
    );
  }

  Widget _buildPinGate() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.admin_panel_settings, size: 48, color: Colors.blueGrey.shade800),
                const SizedBox(height: 10),
                const Text('Accesso Backoffice ParkNow!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                TextField(
                  controller: _pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _unlock(),
                  decoration: const InputDecoration(
                    labelText: 'PIN Amministratore',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _verifying ? null : _unlock,
                    icon: const Icon(Icons.login),
                    label: Text(_verifying ? 'Verifica in corso...' : 'Accedi'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey.shade900,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHubBody() {
    return RefreshIndicator(
      onRefresh: () => _fetchSpotsSummary(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // CARD 1: Cruscotto Real-Time Stalli
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AdminSpotsLiveScreen(adminPin: _adminPin, initialSpots: _liveSpots),
                  ),
                );
                _fetchSpotsSummary(silent: true);
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.sensors, color: Colors.teal.shade700),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('Stalli Parcheggio Real-Time', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                        if (_loadingSpots)
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          Text(_lastUpdated.isEmpty ? 'Live' : 'Agg. $_lastUpdated', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _kpiBox('Totale', _totalSpots, Colors.blueGrey.shade800),
                        const SizedBox(width: 6),
                        _kpiBox('Occupati', _occupiedSpots, Colors.red.shade700),
                        const SizedBox(width: 6),
                        _kpiBox('In Rilascio', _leavingSpots, Colors.amber.shade800),
                        const SizedBox(width: 6),
                        _kpiBox('Liberi', _freeSpots, Colors.green.shade700),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildProportionalBar(),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text('Tocca per lista live e sblocco forzato', style: TextStyle(fontSize: 12, color: Colors.teal.shade800, fontWeight: FontWeight.w600)),
                        Icon(Icons.chevron_right, size: 18, color: Colors.teal.shade800),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // CARD 2: Log & Gestione Utenti
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              leading: CircleAvatar(
                backgroundColor: Colors.indigo.shade50,
                child: Icon(Icons.manage_accounts, color: Colors.indigo.shade800),
              ),
              title: const Text('Log & Gestione Utenti', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: const Text('Anagrafica, Email, contestazioni crediti (Ledger), Audit Log eventi e sblocco stalli'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AdminUsersScreen(adminPin: _adminPin)),
                );
                _fetchSpotsSummary(silent: true);
              },
            ),
          ),
          const SizedBox(height: 14),

          // CARD 3: Parametri Algoritmo & Geofence
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              leading: CircleAvatar(
                backgroundColor: Colors.orange.shade50,
                child: Icon(Icons.tune, color: Colors.orange.shade900),
              ),
              title: const Text('Parametri Algoritmo & Geofence', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: const Text('Npassi, T0passi, Rgeofence, DeltaGps, Tgps_senzapasso, Silenzio-Assenso e crediti'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AdminScreen(initialPin: _adminPin)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class AdminSpotsLiveScreen extends StatefulWidget {
  final String adminPin;
  final List<dynamic> initialSpots;
  const AdminSpotsLiveScreen({super.key, required this.adminPin, required this.initialSpots});
  @override
  State<AdminSpotsLiveScreen> createState() => _AdminSpotsLiveScreenState();
}

class _AdminSpotsLiveScreenState extends State<AdminSpotsLiveScreen> {
  List<dynamic> _spots = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _spots = List<dynamic>.from(widget.initialSpots);
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final r = await _adminReq('GET', '/api/admin/spots-summary', widget.adminPin);
      if (r['status'] == 200 && mounted) {
        setState(() => _spots = (r['data']['spots'] as List<dynamic>?) ?? []);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forceRelease(Map<String, dynamic> spot, {bool remove = false}) async {
    final r = await _adminReq('POST', '/api/admin/spots/force-release', widget.adminPin, body: {
      'spotId': spot['id'],
      'userId': spot['user_id'],
      'removeSpot': remove,
    });
    if (!mounted) return;
    if (r['status'] == 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.green.shade700, content: Text(remove ? 'Stallo rimosso' : 'Stallo forzato su FREE')),
      );
      _reload();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.red.shade700, content: Text(r['data']['error']?.toString() ?? 'Errore operazione')),
      );
    }
  }

  Color _statusColor(String st) {
    if (st == 'OCCUPIED') return Colors.red.shade700;
    if (st == 'LEAVING_SOON') return Colors.amber.shade800;
    return Colors.green.shade700;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Stalli Live (${_spots.length})'),
        backgroundColor: Colors.teal.shade800,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)],
      ),
      body: _loading && _spots.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _spots.isEmpty
              ? const Center(child: Text('Nessuno stallo presente al momento.'))
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _spots.length,
                    itemBuilder: (_, i) {
                      final s = _spots[i] as Map<String, dynamic>;
                      final st = (s['status'] ?? '').toString().toUpperCase();
                      final c = _statusColor(st);
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: c.withOpacity(0.15),
                            child: Icon(Icons.local_parking, color: c),
                          ),
                          title: Text('${s['user_id'] ?? 'N/D'}  •  $st', style: TextStyle(fontWeight: FontWeight.bold, color: c)),
                          subtitle: Text(
                            'ID: ${s['id']}\nCoord: ${s['latitude']}, ${s['longitude']}\nAgg: ${_fmtTs(s['updated_at'])}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          isThreeLine: true,
                          trailing: st == 'FREE'
                              ? IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                                  tooltip: 'Rimuovi stallo libero',
                                  onPressed: () => _forceRelease(s, remove: true),
                                )
                              : ElevatedButton(
                                  onPressed: () => _forceRelease(s, remove: false),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white),
                                  child: const Text('Libera', style: TextStyle(fontSize: 12)),
                                ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class AdminUsersScreen extends StatefulWidget {
  final String adminPin;
  const AdminUsersScreen({super.key, required this.adminPin});
  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _searchCtrl = TextEditingController();
  List<dynamic> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    setState(() => _loading = true);
    try {
      final q = Uri.encodeQueryComponent(_searchCtrl.text.trim());
      final r = await _adminReq('GET', '/api/admin/users?q=$q', widget.adminPin);
      if (r['status'] == 200 && mounted) {
        setState(() => _users = (r['data']['users'] as List<dynamic>?) ?? []);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log & Gestione Utenti'),
        backgroundColor: Colors.indigo.shade900,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadUsers)],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              onSubmitted: (_) => _loadUsers(),
              decoration: InputDecoration(
                hintText: 'Cerca per ID utente, email, telefono o targa...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _loadUsers),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _users.isEmpty
                    ? const Center(child: Text('Nessun utente trovato.'))
                    : RefreshIndicator(
                        onRefresh: _loadUsers,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                          itemCount: _users.length,
                          itemBuilder: (_, i) {
                            final u = _users[i] as Map<String, dynamic>;
                            final uid = (u['external_user_id'] ?? '').toString();
                            final email = (u['email'] ?? '').toString();
                            final bal = (u['credits_balance'] as num?)?.toInt() ?? 0;
                            final isBeta = u['is_beta_tester'] == true;
                            final isSusp = u['is_suspended'] == true;
                            final spot = u['active_spot'] as Map<String, dynamic>?;
                            final spotStatus = spot != null ? (spot['status'] ?? '').toString().toUpperCase() : '';
                            return Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isSusp ? Colors.red.shade100 : Colors.indigo.shade50,
                                  child: Icon(
                                    isSusp ? Icons.block : Icons.person,
                                    color: isSusp ? Colors.red.shade800 : Colors.indigo.shade800,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Expanded(child: Text(uid, style: const TextStyle(fontWeight: FontWeight.bold))),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(12)),
                                      child: Text('$bal cr', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade900, fontSize: 12)),
                                    ),
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(email.isNotEmpty ? email : 'Email non impostata', style: TextStyle(fontSize: 12, color: email.isNotEmpty ? Colors.black87 : Colors.grey.shade600)),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        if (spotStatus.isNotEmpty)
                                          _chip(spotStatus, spotStatus == 'OCCUPIED' ? Colors.red.shade700 : Colors.amber.shade800),
                                        if (isBeta) _chip('BETA', Colors.amber.shade900),
                                        if (isSusp) _chip('SOSPESO', Colors.red.shade900),
                                        _chip('Agg: ${_fmtTs(u['updated_at'])}', Colors.blueGrey.shade600),
                                      ],
                                    ),
                                  ],
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => AdminUserDetailScreen(adminPin: widget.adminPin, externalUserId: uid),
                                    ),
                                  );
                                  _loadUsers();
                                },
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

class AdminUserDetailScreen extends StatefulWidget {
  final String adminPin;
  final String externalUserId;
  const AdminUserDetailScreen({super.key, required this.adminPin, required this.externalUserId});
  @override
  State<AdminUserDetailScreen> createState() => _AdminUserDetailScreenState();
}

class _AdminUserDetailScreenState extends State<AdminUserDetailScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _loading = true;
  bool _saving = false;
  bool _schemaReady = true;

  Map<String, dynamic>? _user;
  Map<String, dynamic>? _activeSpot;
  List<dynamic> _ledger = [];
  List<dynamic> _auditLogs = [];

  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  bool _isBeta = false;
  bool _isSuspended = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _loadDetail();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: err ? Colors.red.shade700 : Colors.green.shade700),
    );
  }

  Future<void> _loadDetail() async {
    setState(() => _loading = true);
    try {
      final uid = Uri.encodeComponent(widget.externalUserId);
      final r = await _adminReq('GET', '/api/admin/users/$uid/detail', widget.adminPin);
      if (r['status'] == 200 && mounted) {
        final d = r['data'] as Map<String, dynamic>;
        final u = d['user'] as Map<String, dynamic>?;
        setState(() {
          _user = u;
          _activeSpot = d['activeSpot'] as Map<String, dynamic>?;
          _ledger = (d['ledger'] as List<dynamic>?) ?? [];
          _auditLogs = (d['auditLogs'] as List<dynamic>?) ?? [];
          _schemaReady = d['schemaReady'] != false;
          _emailCtrl.text = (u?['email'] ?? '').toString();
          _phoneCtrl.text = (u?['phone_number'] ?? '').toString();
          _isBeta = u?['is_beta_tester'] == true;
          _isSuspended = u?['is_suspended'] == true;
        });
      }
    } catch (_) {
      _snack('Errore caricamento dettaglio utente', err: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveUser() async {
    setState(() => _saving = true);
    try {
      final uid = Uri.encodeComponent(widget.externalUserId);
      final r = await _adminReq('POST', '/api/admin/users/$uid/update', widget.adminPin, body: {
        'email': _emailCtrl.text.trim(),
        'phoneNumber': _phoneCtrl.text.trim(),
        'isBetaTester': _isBeta,
        'isSuspended': _isSuspended,
      });
      if (r['status'] == 200) {
        final warn = r['data']['schemaWarning']?.toString();
        _snack(warn ?? 'Impostazioni utente aggiornate!');
        await _loadDetail();
      } else {
        _snack(r['data']['error']?.toString() ?? 'Errore salvataggio', err: true);
      }
    } catch (_) {
      _snack('Errore connessione server', err: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openAdjustCreditsDialog() async {
    final deltaCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String reason = 'CONTESTATION_REFUND';
    bool busy = false;
    final reasons = {
      'CONTESTATION_REFUND': 'Rimborso Contestazione',
      'ADMIN_BONUS': 'Bonus / Accredito Manuale',
      'ADMIN_PENALTY': 'Addebito / Penale Manuale',
      'ADMIN_ADJUSTMENT': 'Rettifica Generica',
    };

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Rettifica Crediti Utente'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: deltaCtrl,
                  keyboardType: const TextInputType.numberWithOptions(signed: true),
                  decoration: const InputDecoration(
                    labelText: 'Variazione crediti (es. 10 oppure -5)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: reason,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Causale', border: OutlineInputBorder(), isDense: true),
                  items: reasons.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) { if (v != null) setDlg(() => reason = v); },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: noteCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Motivazione / Nota (obbligatoria)',
                    hintText: 'Es. Rimborso per GPS impreciso in garage',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Annulla')),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      final delta = int.tryParse(deltaCtrl.text.trim());
                      final note = noteCtrl.text.trim();
                      if (delta == null || delta == 0 || note.length < 3) {
                        _snack('Inserisci un importo valido e una motivazione', err: true);
                        return;
                      }
                      setDlg(() => busy = true);
                      final uid = Uri.encodeComponent(widget.externalUserId);
                      final r = await _adminReq('POST', '/api/admin/users/$uid/adjust-credits', widget.adminPin, body: {
                        'delta': delta,
                        'reasonCode': reason,
                        'note': note,
                      });
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (r['status'] == 200) {
                        _snack('Saldo aggiornato: ${r['data']['newBalance']} cr');
                        _loadDetail();
                      } else {
                        _snack(r['data']['error']?.toString() ?? 'Errore rettifica', err: true);
                      }
                    },
              child: Text(busy ? 'Salvo...' : 'Applica'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _forceReleaseActiveSpot() async {
    if (_activeSpot == null) return;
    final r = await _adminReq('POST', '/api/admin/spots/force-release', widget.adminPin, body: {
      'spotId': _activeSpot!['id'],
      'userId': widget.externalUserId,
    });
    if (r['status'] == 200) {
      _snack('Stallo liberato forzatamente');
      _loadDetail();
    } else {
      _snack(r['data']['error']?.toString() ?? 'Errore sblocco stallo', err: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bal = (_user?['credits_balance'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.externalUserId),
        backgroundColor: Colors.indigo.shade900,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadDetail)],
        bottom: TabBar(
          controller: _tabCtrl,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.amber,
          tabs: [
            const Tab(icon: Icon(Icons.person_outline), text: 'Backoffice'),
            Tab(icon: const Icon(Icons.receipt_long), text: 'Ledger (${_ledger.length})'),
            Tab(icon: const Icon(Icons.history), text: 'Eventi (${_auditLogs.length})'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabCtrl,
              children: [
                _buildBackofficeTab(bal),
                _buildLedgerTab(),
                _buildAuditTab(),
              ],
            ),
    );
  }

  Widget _buildBackofficeTab(int bal) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!_schemaReady)
          Card(
            color: Colors.amber.shade50,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Nota: esegui lo script SQL su Supabase per creare user_credit_ledger, user_audit_logs e le colonne email/is_suspended.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        Card(
          color: Colors.blue.shade50,
          child: ListTile(
            leading: Icon(Icons.account_balance_wallet, color: Colors.blue.shade800, size: 34),
            title: Text('Saldo attuale: $bal cr', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            subtitle: Text(_activeSpot != null ? 'Stallo attivo: ${_activeSpot!['status']}' : 'Nessuno stallo attivo'),
            trailing: ElevatedButton.icon(
              onPressed: _openAdjustCreditsDialog,
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('Rettifica'),
            ),
          ),
        ),
        if (_activeSpot != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _forceReleaseActiveSpot,
              icon: const Icon(Icons.lock_open, color: Colors.orange),
              label: Text('Forza Liberazione Stallo (${_activeSpot!['id']})'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Anagrafica & Flag Backoffice', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email Utente', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Telefono', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Modalità Beta Tester'),
                  subtitle: const Text('Esente da costi ricerca e Silenzio-Assenso attivo'),
                  value: _isBeta,
                  onChanged: (v) => setState(() => _isBeta = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Account Sospeso', style: TextStyle(color: Colors.red)),
                  subtitle: const Text('Segnala account sospeso per abusi/contestazioni'),
                  value: _isSuspended,
                  onChanged: (v) => setState(() => _isSuspended = v),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _saveUser,
                    icon: const Icon(Icons.save),
                    label: Text(_saving ? 'Salvataggio...' : 'Salva Modifiche Utente'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade900, foregroundColor: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLedgerTab() {
    if (_ledger.isEmpty) return const Center(child: Text('Nessun movimento crediti registrato.'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _ledger.length,
      itemBuilder: (_, i) {
        final row = _ledger[i] as Map<String, dynamic>;
        final delta = (row['delta'] as num?)?.toInt() ?? 0;
        final isPos = delta >= 0;
        final balAfter = row['balance_after'];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: isPos ? Colors.green.shade50 : Colors.red.shade50,
              child: Text(
                '${isPos ? '+' : ''}$delta',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isPos ? Colors.green.shade800 : Colors.red.shade800),
              ),
            ),
            title: Text('${row['reason_code'] ?? 'MOVIMENTO'}  ${balAfter != null ? '→ $balAfter cr' : ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            subtitle: Text(
              '${_fmtTs(row['created_at'])} • ${row['actor'] ?? 'SYSTEM'}${row['note'] != null && row['note'].toString().isNotEmpty ? '\nNota: ${row['note']}' : ''}${row['spot_id'] != null ? '\nStallo: ${row['spot_id']}' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAuditTab() {
    if (_auditLogs.isEmpty) return const Center(child: Text('Nessun evento parcheggio/audit registrato.'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _auditLogs.length,
      itemBuilder: (_, i) {
        final ev = _auditLogs[i] as Map<String, dynamic>;
        final dist = ev['distance_m'];
        final acc = ev['accuracy_m'];
        final meta = ev['meta'];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.event_note, color: Colors.blueGrey),
            title: Text('${ev['event_type'] ?? 'EVENT'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            subtitle: Text(
              '${_fmtTs(ev['created_at'])} • Sorgente: ${ev['trigger_source'] ?? 'N/D'}'
              '${dist != null ? '\nDist: ${dist}m (acc ${acc ?? '?'}m)' : ''}'
              '${ev['spot_id'] != null ? '\nStallo: ${ev['spot_id']}' : ''}'
              '${meta != null && meta.toString() != '{}' ? '\nDettagli: ${json.encode(meta)}' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      },
    );
  }
}
