import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

class AutoReleaseManager {
  final Future<void> Function() onTriggerAutoRelease;
  Timer? _countdownTimer;

  AutoReleaseManager({required this.onTriggerAutoRelease});

  Future<void> startCountdownIfBetaTester() async {
    final prefs = await SharedPreferences.getInstance();
    final isBeta = prefs.getBool('is_beta_tester') ?? false;
    if (!isBeta) return;

    final delaySeconds = prefs.getInt('auto_release_delay_s') ?? 60;
    cancelCountdown();

    await NotificationService().showAutoReleaseNotification(delaySeconds: delaySeconds);

    _countdownTimer = Timer(Duration(seconds: delaySeconds), () async {
      await NotificationService().cancelAutoReleaseNotification();
      await onTriggerAutoRelease();
    });
  }

  void cancelCountdown() {
    if (_countdownTimer != null && _countdownTimer!.isActive) {
      _countdownTimer!.cancel();
    }
    _countdownTimer = null;
    NotificationService().cancelAutoReleaseNotification();
  }

  void dispose() {
    cancelCountdown();
  }
}
