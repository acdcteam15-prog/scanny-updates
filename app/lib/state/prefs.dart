import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/rules.dart';

/// Settings of this phone only.
class LocalPrefs extends ChangeNotifier {
  final SharedPreferences _sp;
  LocalPrefs._(this._sp);

  static Future<LocalPrefs> load() async => LocalPrefs._(await SharedPreferences.getInstance());

  // ---- app lock (fingerprint / face with a PIN fallback)
  bool get lockEnabled => _sp.getBool('lockEnabled') ?? false;
  String get pinHash => _sp.getString('pinHash') ?? '';
  Future<void> setLock(bool on, String hash) async {
    await _sp.setString('pinHash', hash);
    await _set(_sp.setBool('lockEnabled', on));
  }

  // ---- what the findings list shows
  bool get showClosed => _sp.getBool('showClosed') ?? false;
  Future<void> setShowClosed(bool v) => _set(_sp.setBool('showClosed', v));
  String get lastGroup => _sp.getString('lastGroup') ?? '';
  Future<void> setLastGroup(String v) => _set(_sp.setString('lastGroup', v));

  // ---- activity: red dots (the tab, and each item until it is opened) and the notifications
  int get activityBaseMs => _sp.getInt('activityBaseMs') ?? 0;
  Future<void> setActivityBaseMs(int v) => _sp.setInt('activityBaseMs', v);
  int get activitySeenMs => _sp.getInt('activitySeenMs') ?? 0;
  Future<void> setActivitySeenMs(int v) => _set(_sp.setInt('activitySeenMs', v));
  Set<String> get activityRead => (_sp.getStringList('activityRead') ?? const <String>[]).toSet();
  Future<void> markActivityRead(String id) => _set(_sp.setStringList('activityRead', addRead(_sp.getStringList('activityRead') ?? const <String>[], id)));
  bool get activityPush => _sp.getBool('activityPush') ?? true;
  Future<void> setActivityPush(bool v) => _set(_sp.setBool('activityPush', v));

  // ---- saved filters (named views of the findings list) and when the person last looked
  List<String> get savedViews => _sp.getStringList('savedViews') ?? const [];
  Future<void> setSavedViews(List<String> v) => _set(_sp.setStringList('savedViews', v));
  int get lastSeenMs => _sp.getInt('lastSeenMs') ?? 0;
  Future<void> setLastSeenMs(int v) => _sp.setInt('lastSeenMs', v);

  // ---- push + widget
  bool get pushEnabled => _sp.getBool('pushEnabled') ?? true;
  Future<void> setPushEnabled(bool v) => _set(_sp.setBool('pushEnabled', v));

  // ---- app updates (Firebase Hosting + GitHub Releases, same as Dishy)
  bool get autoUpdateCheck => _sp.getBool('autoUpdateCheck') ?? true;
  int get updateLastCheck => _sp.getInt('updateLastCheck') ?? 0;
  String get whatsNewSeen => _sp.getString('whatsNewSeen') ?? '';
  /// Download a new version in the background as soon as it is found; installing always waits for a tap.
  bool get autoDownload => _sp.getBool('autoDownload') ?? true;
  Future<void> setAutoDownload(bool v) => _set(_sp.setBool('autoDownload', v));
  /// The quiet background download waits for Wi-Fi (the Download button always works on any connection).
  bool get autoDownloadWifiOnly => _sp.getBool('autoDownloadWifiOnly') ?? true;
  Future<void> setAutoDownloadWifiOnly(bool v) => _set(_sp.setBool('autoDownloadWifiOnly', v));
  Future<void> setAutoUpdateCheck(bool v) => _set(_sp.setBool('autoUpdateCheck', v));
  Future<void> setUpdateLastCheck(int ms) => _sp.setInt('updateLastCheck', ms);
  Future<void> setWhatsNewSeen(String v) => _sp.setString('whatsNewSeen', v);

  // ---- Zero-day watch: read an article inside Scanny or in the browser (each person chooses), and which ones this phone has opened
  String get articleOpenRaw => _sp.getString('articleOpen') ?? 'reader';
  Future<void> setArticleOpen(String v) => _set(_sp.setString('articleOpen', v));
  /// Which new Zero-day watch articles this person wants a push for: off, all, mine (mention my groups' systems) or critical (exploited / zero-day).
  String get watchPush {
    final v = _sp.getString('watchPush') ?? 'mine';
    return const ['off', 'all', 'mine', 'critical'].contains(v) ? v : 'mine';
  }

  Future<void> setWatchPush(String v) => _set(_sp.setString('watchPush', v));
  Set<String> get watchRead => (_sp.getStringList('watchRead') ?? const <String>[]).toSet();
  Future<void> markWatchRead(String id) async {
    final cur = (_sp.getStringList('watchRead') ?? <String>[]).toList();
    if (cur.contains(id)) return;
    cur.add(id);
    await _set(_sp.setStringList('watchRead', cur.length > 300 ? cur.sublist(cur.length - 300) : cur));
  }

  Future<void> _set(Future<bool> f) async {
    await f;
    notifyListeners();
  }
}
