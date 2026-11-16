import 'package:flutter/material.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _autoShare = true;
  int _searchRadius = 500;
  int _creditsBalance = 150;

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
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // 1. Borsellino Crediti
          Card(
            elevation: 2,
            color: Colors.blue.shade50,
            child: ListTile(
              leading: Icon(Icons.account_balance_wallet, color: Colors.blue.shade800, size: 38),
              title: const Text('Borsellino Crediti', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Guadagni crediti quando liberi uno stallo'),
              trailing: Text(
                '$_creditsBalance',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green.shade700),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 2. Account e Verifica Cellulare
          const Text('ACCOUNT', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Numero di Cellulare',
              hintText: '+39 333 1234567',
              prefixIcon: Icon(Icons.phone_android),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),

          // 3. Dati Veicolo e Targa Mascherata
          const Text('IL TUO VEICOLO', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _brandController,
                  decoration: const InputDecoration(labelText: 'Marca', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _modelController,
                  decoration: const InputDecoration(labelText: 'Modello', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _colorController,
                  decoration: const InputDecoration(labelText: 'Colore', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _plateController,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Targa', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Visibilità pubblica targa (ultime 2 cifre): $_maskedPlatePreview',
              style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 20),

          // 4. Modalità di Rilascio Parcheggio
          const Text('RILASCIO PARCHEGGIO', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Condivisione Automatica'),
            subtitle: Text(
              _autoShare
                  ? 'Attiva: segnala lo stallo libero automaticamente alla ripartenza'
                  : 'Manuale: chiede conferma con un pop-up quando liberi il posto',
            ),
            value: _autoShare,
            onChanged: (bool value) => setState(() => _autoShare = value),
          ),
          const SizedBox(height: 16),

          // 5. Raggio di Ricerca
          Text(
            'RAGGIO DI RICERCA: $_searchRadius metri',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          Slider(
            value: _allowedRadii.indexOf(_searchRadius).toDouble(),
            min: 0,
            max: (_allowedRadii.length - 1).toDouble(),
            divisions: _allowedRadii.length - 1,
            label: '$_searchRadius m',
            onChanged: (double value) {
              setState(() => _searchRadius = _allowedRadii[value.toInt()]);
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _allowedRadii.map((r) => Text('${r}m', style: const TextStyle(fontSize: 12, color: Colors.grey))).toList(),
          ),
          const SizedBox(height: 16),

          // 6. Sensori Opzionali (Wi-Fi e Bluetooth)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Sensori Smart (Opzionale)', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Wi-Fi casa e Bluetooth auto per automatismi avanzati'),
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _wifiController,
                decoration: const InputDecoration(
                  labelText: 'Nome Wi-Fi Casa/Ufficio',
                  prefixIcon: Icon(Icons.wifi),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _btController,
                decoration: const InputDecoration(
                  labelText: 'Dispositivo Bluetooth Auto',
                  prefixIcon: Icon(Icons.bluetooth_connected),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
          const SizedBox(height: 24),

          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade800,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            icon: const Icon(Icons.save),
            label: const Text('SALVA PROFILO', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Preferenze profilo salvate!')),
              );
            },
          ),
        ],
      ),
    );
  }
}
