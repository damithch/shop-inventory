import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// The phone's push notification address, which the server sends low-stock
/// alerts to. See [FirebasePush] for the real one.
abstract class PushService {
  /// Asks to show notifications (Android 13+) and returns this phone's token,
  /// or null if there is none.
  Future<String?> getToken();

  /// New tokens, when Firebase replaces the old one.
  Stream<String> get onTokenRefresh;
}

/// Firebase Cloud Messaging. Alerts arriving while the app is closed or in the
/// background are shown by Android itself; [onAlert] covers the app being open.
class FirebasePush implements PushService {
  FirebasePush._();

  /// Starts Firebase, or returns null when the app was built without
  /// google-services.json, in which case the app works without push.
  static Future<FirebasePush?> start() async {
    try {
      await Firebase.initializeApp();
      return FirebasePush._();
    } catch (e) {
      debugPrint('Push notifications are off: $e');
      return null;
    }
  }

  @override
  Future<String?> getToken() async {
    try {
      await FirebaseMessaging.instance.requestPermission();
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      // No Google Play services, or no network yet.
      debugPrint('Could not get a push token: $e');
      return null;
    }
  }

  @override
  Stream<String> get onTokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  /// Title and text of each alert received while the app is open.
  Stream<String> get onAlert => FirebaseMessaging.onMessage
      .where((m) => m.notification != null)
      .map((m) => [m.notification!.title, m.notification!.body].whereType<String>().join('\n'));
}
