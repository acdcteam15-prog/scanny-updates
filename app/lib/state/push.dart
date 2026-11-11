import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'native.dart';
import 'update_notify.dart';

/// Every tap on a notification: the update notifications as before, and an alert or activity notification opens its finding.
@pragma('vm:entry-point')
void scannyPushResponse(NotificationResponse r) {
  final p = r.payload ?? '';
  if (p.startsWith('{')) {
    try {
      final m = jsonDecode(p);
      if (m is Map) PushService.emitOpen({for (final e in m.entries) '${e.key}': '${e.value}'});
    } catch (_) {}
    return;
  }
  scannyNotificationResponse(r);
}

/// Push alerts. Scanny for Windows sends them (free Firebase Cloud Messaging) to the phones of the right group.
/// This service asks for permission, registers this phone in Firestore (devices/{id}) and shows alerts that arrive while the app is open.
class PushService {
  final FlutterLocalNotificationsPlugin _n = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  String? _token;
  String _email = '';

  /// A tap on an alert or an activity notification: the finding to open (fid), the activity item (aid), the CVE. The home screen listens.
  static final StreamController<Map<String, String>> opens = StreamController<Map<String, String>>.broadcast();

  /// A tap that arrived before the home screen was there (the app was closed): it is handed over once.
  static Map<String, String>? _pending;
  static Map<String, String>? takePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  static void emitOpen(Map<String, String> data) {
    if ((data['fid'] ?? '').isEmpty && (data['cve'] ?? '').isEmpty) return;
    if (opens.hasListener) {
      opens.add(data);
    } else {
      _pending = data;
    }
  }

  /// Notifications for what other people do on findings in my groups (Scanny for Windows reads it from this phone's devices/{id} record).
  bool activityPush = true;

  /// off / all / mine / critical. Scanny for Windows reads it from this phone's devices/{id} record to decide which new articles to push.
  String watchPush = 'mine';

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'scanny_alerts',
    'Scanny alerts',
    description: 'New critical and high findings for your groups, and daily summaries',
    importance: Importance.high,
  );

  Future<void> init() async {
    try {
      await _n.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_stat_scanny')),
        onDidReceiveNotificationResponse: scannyPushResponse,
        onDidReceiveBackgroundNotificationResponse: scannyPushResponse,
      );
      await _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(_channel);
      _ready = true;
      FirebaseMessaging.onMessage.listen(_show);
      FirebaseMessaging.onMessageOpenedApp.listen((m) => emitOpen({for (final e in m.data.entries) e.key: '${e.value}'}));
      final first = await FirebaseMessaging.instance.getInitialMessage();
      if (first != null) emitOpen({for (final e in first.data.entries) e.key: '${e.value}'});
      FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        _token = t;
        _store();
      });
    } catch (e) {
      debugPrint('push init: $e');
    }
  }

  Future<void> _show(RemoteMessage m) async {
    if (!_ready) return;
    final n = m.notification;
    if (n == null) return;
    try {
      await _n.show(
        m.hashCode & 0x7fffffff,
        n.title,
        n.body,
        const NotificationDetails(
          android: AndroidNotificationDetails('scanny_alerts', 'Scanny alerts', importance: Importance.high, priority: Priority.high, icon: '@drawable/ic_stat_scanny'),
        ),
        payload: jsonEncode(m.data),
      );
    } catch (e) {
      debugPrint('push show: $e');
    }
  }

  /// Called after a successful sign-in of an allowed member.
  Future<void> register(String email) async {
    _email = email.toLowerCase();
    try {
      await FirebaseMessaging.instance.requestPermission();
      _token = await FirebaseMessaging.instance.getToken();
      await _store();
    } catch (e) {
      debugPrint('push register: $e');
    }
  }

  String get _id => sha1.convert(utf8.encode(_token ?? '')).toString();

  Future<void> _store() async {
    final t = _token;
    if (t == null || t.isEmpty || _email.isEmpty) return;
    try {
      final b = await Native.buildInfo();
      await FirebaseFirestore.instance.collection('devices').doc(_id).set({
        'email': _email,
        'token': t,
        'platform': 'android',
        'watchPush': watchPush,
        'activityPush': activityPush,
        'app': b.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('push store: $e');
    }
  }

  /// The person changed what the Zero-day watch may push to this phone.
  Future<void> setWatchPush(String mode) async {
    watchPush = mode;
    try {
      if (_token == null || _token!.isEmpty || _email.isEmpty) return;
      await FirebaseFirestore.instance.collection('devices').doc(_id).set({'watchPush': mode}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('push watch mode: $e');
    }
  }

  /// The person switched the activity notifications of this phone on or off.
  Future<void> setActivityPush(bool on) async {
    activityPush = on;
    try {
      if (_token == null || _token!.isEmpty || _email.isEmpty) return;
      await FirebaseFirestore.instance.collection('devices').doc(_id).set({'activityPush': on}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('push activity mode: $e');
    }
  }

  /// On sign-out: this phone no longer receives this person's alerts.
  Future<void> unregister() async {
    try {
      if (_token != null && _token!.isNotEmpty) await FirebaseFirestore.instance.collection('devices').doc(_id).delete();
    } catch (e) {
      debugPrint('push unregister: $e');
    }
    _email = '';
  }
}
