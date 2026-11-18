import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'notification_service.dart'; // Importazione delle notifiche integrata

class AutoReleaseManager {
  static final AutoReleaseManager _instance = AutoReleaseManager._internal();
  factory AutoReleaseManager() => _instance;
  AutoReleaseManager._internal();

  Timer? _timer;
  bool _isActive = false;

  Future<void> checkDistance(double distanceMeters, String spotId) async {
    // 1. Innesco: Distanza inferiore a 100m
    if (distanceMeters <= 100 && !_isActive) {
      final prefs = await SharedPreferences.getInstance();
      
      // Controlla se è Beta Tester o se ha il rilascio automatico attivo
      if (prefs.getBool('is_beta_tester') == true || prefs.getBool('auto_share_enabled') == true) {
        _startSilenzioAssenso(spotId, prefs);
      }
    }
  }

  void _startSilenzioAssenso(String spotId, SharedPreferences prefs) {
    _isActive = true;
    
    // 2. Legge il parametro amministrativo (di default 60 sec)
    int timerSeconds = prefs.getInt('auto_release_delay_s') ?? 60;
    print("Avviato timer Silenzio-Assenso di $timerSeconds sec per lo stallo $spotId");
    
    // 3. Mostra la notifica interattiva con pulsante "Annulla"
    NotificationService().showAutoReleaseNotification(timerSeconds);
    
    // 4. Avvia il countdown dinamico
    _timer = Timer(Duration(seconds: timerSeconds), () {
      _executeRelease(spotId);
    });
  }

  void abortRelease() {
    _timer?.cancel();
    _isActive = false;
    print("Rilascio automatico annullato dall'utente.");
    // Nasconde la notifica se l'utente preme annulla
    NotificationService().cancelNotification();
  }

  Future<void> _executeRelease(String spotId) async {
    _isActive = false;
    try {
      // Chiamata API per mettere il parcheggio in "fase di rilascio"
      final res = await http.post(Uri.parse('https://parknow-api.onrender.com/api/parking/release/$spotId'));
      if (res.statusCode == 200) {
        print("Stallo $spotId rilasciato automaticamente (Silenzio-Assenso).");
      }
    } catch (e) {
      print("Errore rilascio automatico: $e");
    }
  }
}