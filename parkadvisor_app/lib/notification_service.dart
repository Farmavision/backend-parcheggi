import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  Function()? onCancelReleaseAction;

  Future<void> init({Function()? onCancelAction}) async {
    onCancelReleaseAction = onCancelAction;
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    await flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (response.actionId == 'CANCEL_RELEASE') {
          onCancelReleaseAction?.call();
        }
      },
    );
  }

  Future<void> showAutoReleaseNotification({required int delaySeconds}) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'auto_release_channel',
      'Rilascio Automatico Parcheggio',
      channelDescription: 'Avvisi di conto alla rovescia per rilascio stallo',
      importance: Importance.max,
      priority: Priority.high,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'CANCEL_RELEASE',
          'Non sto partendo (Annulla)',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );
    const NotificationDetails details = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(
      id: 1001,
      title: 'Rilascio parcheggio tra ${delaySeconds}s',
      body: 'Ti stai avvicinando all\'auto. Tocca Annulla se non stai ripartendo.',
      notificationDetails: details,
    );
  }

  Future<void> cancelAutoReleaseNotification() async {
    await flutterLocalNotificationsPlugin.cancel(id: 1001);
  }
}
