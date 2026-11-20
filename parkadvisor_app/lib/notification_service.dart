import 'dart:typed_data';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  Function()? onCancelReleaseAction;
  Function()? onConfirmReleaseAction;
  Function()? onDenyReleaseAction;

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
        if (response.actionId == 'CONFIRM_RELEASE_NOW') { onConfirmReleaseAction?.call(); } else if (response.actionId == 'DENY_RELEASE') { onDenyReleaseAction?.call(); } else if (response.actionId == 'CANCEL_RELEASE') {
          onCancelReleaseAction?.call();
        }
      },
    );
  }

  Future<void> showAutoReleaseNotification({required int delaySeconds}) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'parknow_urgent_release_v2',
      'Avvisi Urgenti Rilascio Parcheggio',
      channelDescription: 'Avvisi di conto alla rovescia per rilascio stallo',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'CONFIRM_RELEASE_NOW',
          'Conferma Rilascio Ora',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'DENY_RELEASE',
          'Rifiuta / Non parto',
          showsUserInterface: false,
          cancelNotification: true,
        ),
        
      ],
    );
    final NotificationDetails details = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(
      id: 1001,
      title: 'Stai lasciando il parcheggio?',
      body: 'Conferma per liberare lo stallo oppure rifiuta.',
      notificationDetails: details,
    );
  }

  Future<void> cancelAutoReleaseNotification() async {
    await flutterLocalNotificationsPlugin.cancel(id: 1001);
  }
}
