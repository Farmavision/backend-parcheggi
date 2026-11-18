import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'auto_release_manager.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) {
  // Questa funzione viene chiamata anche se l'app è in background o chiusa
  if (notificationResponse.actionId == 'cancel_release') {
    AutoReleaseManager().abortRelease();
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    // Configurazione per Android (usa l'icona di default dell'app)
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Intercetta il tap se l'app è in primo piano (foreground)
        if (response.actionId == 'cancel_release') {
          AutoReleaseManager().abortRelease();
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
  }

  Future<void> showAutoReleaseNotification(int seconds) async {
    AndroidNotificationDetails androidDetails = const AndroidNotificationDetails(
      'auto_release_channel',
      'Rilascio Automatico',
      channelDescription: 'Notifiche per il rilascio automatico del parcheggio',
      importance: Importance.max,
      priority: Priority.high,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'cancel_release',
          'Non sto partendo (Annulla)',
          cancelNotification: true,
          showsUserInterface: true,
        ),
      ],
    );
    NotificationDetails platformDetails = NotificationDetails(android: androidDetails);
    
    await flutterLocalNotificationsPlugin.show(
      1001,
      'Sei vicino all\'auto',
      'Il parcheggio verrà rilasciato tra $seconds secondi.',
      platformDetails,
    );
  }
  
  Future<void> cancelNotification() async {
    await flutterLocalNotificationsPlugin.cancel(1001);
  }
}