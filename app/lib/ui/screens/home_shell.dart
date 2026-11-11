import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../../state/prefs.dart';
import '../../state/push.dart';
import '../../state/updater.dart';
import '../widgets/common.dart';
import '../widgets/pill_nav_bar.dart';
import 'activity_screen.dart';
import 'finding_detail_screen.dart';
import 'findings_screen.dart';
import 'settings_screen.dart';
import 'systems_screen.dart';
import 'update_screen.dart';
import 'watch_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  StreamSubscription<Map<String, String>>? _openSub;
  StreamSubscription<List<AuditEntry>>? _actSub;
  int _actGroups = -1;
  List<AuditEntry> _activity = const [];

  @override
  void initState() {
    super.initState();
    final prefs = Provider.of<LocalPrefs>(context, listen: false);
    if (prefs.activityBaseMs == 0) prefs.setActivityBaseMs(DateTime.now().millisecondsSinceEpoch); // only what happens from now on counts as new
    _openSub = PushService.opens.stream.listen(_openFromPush);
    final p = PushService.takePending();
    if (p != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openFromPush(p));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = Provider.of<DataService>(context);
    if (d.groups.length != _actGroups) {
      _actGroups = d.groups.length;
      _actSub?.cancel();
      _actSub = d.activity().listen((l) {
        if (!mounted) return;
        setState(() => _activity = l);
        if (_tab == _activityIndex(d.canWatch)) Provider.of<LocalPrefs>(context, listen: false).setActivitySeenMs(DateTime.now().millisecondsSinceEpoch);
      });
    }
  }

  @override
  void dispose() {
    _openSub?.cancel();
    _actSub?.cancel();
    super.dispose();
  }

  int _activityIndex(bool watch) => watch ? 3 : 2;

  /// A tap on an alert or an activity notification: the finding opens (it may still be loading, so wait a little).
  void _openFromPush(Map<String, String> m) {
    final aid = m['aid'] ?? '';
    if (aid.isNotEmpty) Provider.of<LocalPrefs>(context, listen: false).markActivityRead(aid);
    final fid = m['fid'] ?? '';
    if (fid.isEmpty) return;
    final ds = Provider.of<DataService>(context, listen: false);
    var tries = 0;
    void go() {
      if (!mounted) return;
      if (ds.finding(fid) != null) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FindingDetailScreen(fid: fid)));
      } else if (tries++ < 30) {
        Timer(const Duration(milliseconds: 500), go);
      }
    }

    go();
  }

  @override
  Widget build(BuildContext context) {
    final u = context.watch<UpdateService>();
    final data = context.watch<DataService>();
    final prefs = context.watch<LocalPrefs>();
    final watch = data.canWatch;
    final pages = <Widget>[const FindingsScreen(), const SystemsScreen(), if (watch) const WatchScreen(), const ActivityScreen(), const SettingsScreen()];
    final tab = _tab >= pages.length ? pages.length - 1 : _tab;
    final dot = tab != _activityIndex(watch) &&
        activityDot(_activity, data.email, DateTime.fromMillisecondsSinceEpoch(prefs.activityBaseMs), prefs.activityRead, DateTime.fromMillisecondsSinceEpoch(prefs.activitySeenMs));
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const OfflineBanner(),
          if (u.hasUpdate)
            Material(
              color: u.required ? Theme.of(context).colorScheme.errorContainer : const Color(0xFF1E2A66),
              child: InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UpdateScreen())),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    const Icon(Icons.system_update_rounded, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(u.required ? 'Update required: version ${u.latest?.versionName}' : 'Update available: version ${u.latest?.versionName}', style: const TextStyle(fontWeight: FontWeight.w600))),
                    const Icon(Icons.chevron_right_rounded),
                  ]),
                ),
              ),
            ),
          Expanded(child: IndexedStack(index: tab, children: pages)),
        ]),
      ),
      bottomNavigationBar: PillNavBar(
        index: tab,
        onTap: (i) {
          setState(() => _tab = i);
          if (i == _activityIndex(watch)) prefs.setActivitySeenMs(DateTime.now().millisecondsSinceEpoch); // opening the tab clears its dot, not the dots of the items
        },
        items: [
          const NavItem(Icons.shield_outlined, Icons.shield_rounded, 'Findings'),
          const NavItem(Icons.dns_outlined, Icons.dns_rounded, 'Systems'),
          if (watch) const NavItem(Icons.rss_feed_rounded, Icons.rss_feed_rounded, 'Watch'),
          NavItem(Icons.history_rounded, Icons.history_rounded, 'Activity', dot: dot),
          const NavItem(Icons.tune_outlined, Icons.tune_rounded, 'Settings'),
        ],
      ),
    );
  }
}
