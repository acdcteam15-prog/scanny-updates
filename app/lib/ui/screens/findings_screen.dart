import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../theme.dart';
import '../../state/prefs.dart';
import '../widgets/changes_card.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';
import '../widgets/today_card.dart';
import '../widgets/empty_explain.dart';
import 'finding_detail_screen.dart';

/// The list of findings for my groups. Also used for one system ([systemId]).
class FindingsScreen extends StatefulWidget {
  final String? systemId;
  final String? title;
  const FindingsScreen({super.key, this.systemId, this.title});
  @override
  State<FindingsScreen> createState() => _FindingsScreenState();
}

class _FindingsScreenState extends State<FindingsScreen> with WidgetsBindingObserver {
  FindingFilter _f = const FindingFilter();
  final _q = TextEditingController();
  DateTime? _since; // when the person last looked (from the previous visit)
  bool _defaulted = false; // the first look at the list: "open + assigned to me" if anything is assigned to me
  bool _changesDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final p = Provider.of<LocalPrefs>(context, listen: false);
    if (widget.systemId != null) return; // a system's own page is not "looking at the findings"
    _loadSince(p);
    p.setLastSeenMs(DateTime.now().millisecondsSinceEpoch);
  }

  /// A gap of less than 10 minutes is not "a while": no card.
  void _loadSince(LocalPrefs p) {
    final ms = p.lastSeenMs;
    final t = ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    _since = (t != null && DateTime.now().difference(t).inMinutes >= 10) ? t : null;
    _changesDismissed = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.systemId != null) return;
    final p = Provider.of<LocalPrefs>(context, listen: false);
    if (state == AppLifecycleState.paused) {
      p.setLastSeenMs(DateTime.now().millisecondsSinceEpoch);
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _loadSince(p));
      p.setLastSeenMs(DateTime.now().millisecondsSinceEpoch);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _q.dispose();
    super.dispose();
  }

  Future<void> _viewsAction(String v, LocalPrefs prefs, DataService d) async {
    final views = [for (final s in prefs.savedViews) SavedView.decode(s, myEmail: d.email)].whereType<SavedView>().toList();
    if (v == 'save') {
      final c = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save these filters'),
          content: TextField(controller: c, autofocus: true, maxLength: 30, decoration: const InputDecoration(hintText: 'Name, for example Exploited and overdue')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save'))],
        ),
      );
      if (name == null || name.isEmpty) return;
      final kept = views.where((x) => x.name != name).toList()..add(SavedView(name, _f.copyWith(query: _q.text)));
      await prefs.setSavedViews([for (final x in kept) x.encode()]);
      if (mounted) toast(context, 'Saved "$name"');
    } else if (v == 'manage') {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Saved views'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(shrinkWrap: true, children: [
                for (final x in views)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(x.name),
                    trailing: IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () async {
                        views.remove(x);
                        await prefs.setSavedViews([for (final y in views) y.encode()]);
                        setD(() {});
                      },
                    ),
                  ),
                if (views.isEmpty) const Text('No saved views.'),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
          ),
        ),
      );
    } else if (v.startsWith('v:')) {
      final i = int.tryParse(v.substring(2)) ?? -1;
      if (i < 0 || i >= views.length) return;
      setState(() {
        _f = views[i].filter;
        _q.text = _f.query;
      });
    }
  }

  static const _statusChoices = <String, Set<Status>>{
    'Open': {},
    'Solved': {Status.solved},
    'False positive': {Status.falsePositive},
    'Risk accepted': {Status.accepted},
    'Everything': {Status.ongoing, Status.acknowledged, Status.solved, Status.falsePositive, Status.accepted},
  };

  bool get _isDefaultFilter => _f.isDefault;

  String get _statusName {
    for (final e in _statusChoices.entries) {
      if (e.value.length == _f.statuses.length && e.value.containsAll(_f.statuses)) return e.key;
    }
    return 'Open';
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    var all = d.findings;
    if (widget.systemId != null) all = all.where((x) => x.sid == widget.systemId).toList();
    if (!_defaulted && widget.systemId == null && all.isNotEmpty) {
      _defaulted = true;
      if (all.any((x) => x.isOpen && !x.snoozed && x.assignee == d.email.toLowerCase())) _f = _f.copyWith(mine: d.email);
    }
    final shown = applyFilter(all, _f);
    final c = countOpen(all);
    final sig = '${_statusName}|${(_f.severities.map((e) => e.index).toList()..sort()).join(',')}|${_f.groupId}|${_f.mine}|${_f.exploited}|${_f.today}|${_f.overdueOnly}|${_f.snoozed}|${_f.sort}';
    final single = widget.systemId != null;

    // The dashboard and its cards scroll away with the list, so a small phone keeps room for findings.
    final header = Column(children: [
      if (!single && _since != null && !_changesDismissed)
        Builder(builder: (ctx) {
          final ch = changesSince(all, _since!, d.email);
          if (!ch.any) return const SizedBox.shrink();
          return ChangesCard(changes: ch, since: _since!, onDismiss: () => setState(() => _changesDismissed = true));
        }),
      if (all.isNotEmpty)
        DashboardHeader(
          counts: c,
          daily: dailyCounts(all),
          selected: _f.severities,
          online: d.online,
          trend: weekTrend(all),
          onToggle: (s) {
            final cur = {..._f.severities};
            cur.contains(s) ? cur.remove(s) : cur.add(s);
            setState(() => _f = _f.copyWith(severities: cur));
          },
        ),
      if (all.isNotEmpty && !single)
        TodayCard(
          items: todayList(all),
          onOpen: (f) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FindingDetailScreen(fid: f.fid))),
        ),
    ]);

    final body = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: TextField(
          controller: _q,
          decoration: InputDecoration(
            hintText: 'Search CVE, system or text',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _f.query.isEmpty ? null : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(() { _q.clear(); _f = _f.copyWith(query: ''); })),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _f = _f.copyWith(query: v)),
        ),
      ),
      SizedBox(
        height: 46,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14), children: [
          PopupMenuButton<String>(
            onSelected: (v) => setState(() => _f = _f.copyWith(statuses: _statusChoices[v])),
            itemBuilder: (c) => [for (final k in _statusChoices.keys) PopupMenuItem(value: k, child: Text(k))],
            child: Padding(padding: const EdgeInsets.only(right: 8), child: Chip(avatar: const Icon(Icons.filter_list_rounded), label: Text(_statusName))),
          ),
          if (!single && d.groups.length > 1)
            PopupMenuButton<String>(
              onSelected: (v) => setState(() => _f = _f.copyWith(groupId: v)),
              itemBuilder: (c) => [const PopupMenuItem(value: '', child: Text('All my groups')), for (final g in d.groups) PopupMenuItem(value: g.id, child: Text(g.name))],
              child: Padding(padding: const EdgeInsets.only(right: 8), child: Chip(avatar: const Icon(Icons.groups_rounded), label: Text(_f.groupId.isEmpty ? 'All groups' : d.groupName(_f.groupId)))),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(label: const Text('Assigned to me'), selected: _f.mine.isNotEmpty, onSelected: (v) => setState(() => _f = _f.copyWith(mine: v ? d.email : ''))),
          ),
          Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(label: const Text('Exploited'), selected: _f.exploited, onSelected: (v) => setState(() => _f = _f.copyWith(exploited: v)))),
          Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(label: const Text('New today'), selected: _f.today, onSelected: (v) => setState(() => _f = _f.copyWith(today: v)))),
          Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(label: const Text('Overdue'), selected: _f.overdueOnly, onSelected: (v) => setState(() => _f = _f.copyWith(overdueOnly: v)))),
          if (all.any((x) => x.isOpen && x.snoozed) || _f.snoozed)
            Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(avatar: const Icon(Icons.snooze_rounded, size: 16), label: Text('Snoozed (${all.where((x) => x.isOpen && x.snoozed).length})'), selected: _f.snoozed, onSelected: (v) => setState(() => _f = _f.copyWith(snoozed: v)))),
          PopupMenuButton<String>(
            onSelected: (v) => setState(() => _f = _f.copyWith(sort: v)),
            itemBuilder: (c) => const [PopupMenuItem(value: 'score', child: Text('Highest priority first')), PopupMenuItem(value: 'published', child: Text('Newest published first'))],
            child: Padding(padding: const EdgeInsets.only(right: 8), child: Chip(avatar: const Icon(Icons.sort_rounded, size: 18), label: Text(_f.sort == 'published' ? 'Newest published' : 'Highest priority'))),
          ),
          Builder(builder: (ctx) {
            final prefs = ctx.watch<LocalPrefs>();
            final views = [for (final s in prefs.savedViews) SavedView.decode(s, myEmail: d.email)].whereType<SavedView>().toList();
            return PopupMenuButton<String>(
              onSelected: (v) => _viewsAction(v, prefs, d),
              itemBuilder: (c) => [
                for (var i = 0; i < views.length; i++) PopupMenuItem(value: 'v:$i', child: Row(children: [const Icon(Icons.bookmark_rounded, size: 18), const SizedBox(width: 10), Flexible(child: Text(views[i].name, overflow: TextOverflow.ellipsis))])),
                if (views.isNotEmpty) const PopupMenuDivider(),
                if (!_f.isDefault || _q.text.isNotEmpty) const PopupMenuItem(value: 'save', child: Text('Save these filters…')),
                if (views.isNotEmpty) const PopupMenuItem(value: 'manage', child: Text('Delete a view…')),
                if (views.isEmpty && _f.isDefault && _q.text.isEmpty) const PopupMenuItem(enabled: false, child: Text('Choose filters, then save them here')),
              ],
              child: const Padding(padding: EdgeInsets.only(right: 8), child: Chip(avatar: Icon(Icons.bookmarks_rounded, size: 18), label: Text('Views'))),
            );
          }),
        ]),
      ),
      Expanded(
        child: all.isEmpty
            ? const EmptyExplain()
            : CustomScrollView(slivers: [
                SliverToBoxAdapter(child: header),
                if (shown.isEmpty)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 340,
                      child: _isDefaultFilter
                        ? const EmptyState(icon: Icons.verified_user_rounded, color: Color(0xFF4CD964), title: 'No open findings', body: 'Nothing needs you right now. New threats for your systems will show up here.')
                        : EmptyState(
                            icon: Icons.search_off_rounded,
                            title: 'Nothing matches these filters',
                            body: 'Try fewer filters.',
                            actionLabel: 'Clear filters',
                            onAction: () => setState(() {
                              _q.clear();
                              _f = const FindingFilter();
                            }),
                          ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
                    sliver: SliverList.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      // The key changes with the filters, so the cards slide in again when a filter is switched.
                      itemBuilder: (c, i) => Stagger(key: ValueKey('$sig|${shown[i].fid}'), index: i, child: _Tile(f: shown[i], d: d)),
                    ),
                  ),
              ]),
      ),
    ]);

    if (single) return Scaffold(appBar: AppBar(title: Text(widget.title ?? 'System')), body: body);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Row(children: [
          Text('Findings', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          if (d.isAdmin) const Pill('Admin', color: kTeal, icon: Icons.verified_user_rounded),
        ]),
      ),
      Expanded(child: body),
    ]);
  }
}

class _Tile extends StatelessWidget {
  final Finding f;
  final DataService d;
  const _Tile({required this.f, required this.d});

  Widget _swipeBg(Color c, IconData icon, String label, AlignmentGeometry a) => Container(
        alignment: a,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: c), const SizedBox(width: 8), Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w600))]),
      );

  /// Swipe right: acknowledge. Swipe left: assign to me. Both can be undone from the snackbar. The tile always springs back; the list updates from the live data.
  Future<bool> _swipe(BuildContext context, DismissDirection dir) async {
    final m = ScaffoldMessenger.of(context);
    void say(String text, {VoidCallback? undo}) => m
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: undo == null ? null : SnackBarAction(label: 'Undo', onPressed: undo)));
    try {
      if (dir == DismissDirection.startToEnd) {
        if (f.status != Status.ongoing) {
          say('${f.cve} is already ${(kStatusLabel[f.status] ?? '').toLowerCase()}.');
          return false;
        }
        final before = f.status;
        await d.setStatus(f, Status.acknowledged);
        HapticFeedback.lightImpact();
        say('${f.cve} acknowledged', undo: () async {
          final cur = d.finding(f.fid);
          if (cur == null) return;
          try {
            await d.setStatus(cur, before);
          } catch (e) {
            say('$e'.replaceFirst('Bad state: ', ''));
          }
        });
      } else {
        if (f.assignee == d.email) {
          say('${f.cve} is already assigned to you.');
          return false;
        }
        final before = f.assignee.isEmpty ? null : Person(email: f.assignee, name: f.assigneeName.isEmpty ? f.assignee : f.assigneeName);
        await d.setAssignee(f, Person(email: d.email, name: d.displayName));
        HapticFeedback.lightImpact();
        say('${f.cve} assigned to you', undo: () async {
          final cur = d.finding(f.fid);
          if (cur == null) return;
          try {
            await d.setAssignee(cur, before);
          } catch (e) {
            say('$e'.replaceFirst('Bad state: ', ''));
          }
        });
      }
    } catch (e) {
      say('$e'.replaceFirst('Bad state: ', ''));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final canSwipe = d.online && f.isOpen;
    return Dismissible(
      key: ValueKey('swipe-${f.fid}'),
      direction: canSwipe ? DismissDirection.horizontal : DismissDirection.none,
      confirmDismiss: (dir) => _swipe(context, dir),
      background: _swipeBg(kAccent, Icons.done_all_rounded, 'Acknowledge', AlignmentDirectional.centerStart),
      secondaryBackground: _swipeBg(kTeal, Icons.person_add_alt_1_rounded, 'Assign to me', AlignmentDirectional.centerEnd),
      child: _card(context),
    );
  }

  Widget _card(BuildContext context) {
    final t = Theme.of(context);
    return PressScale(
      child: GlowCard(
        stripe: severityColor(f.severity),
        child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FindingDetailScreen(fid: f.fid))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Hero(tag: 'sev-${f.fid}', child: Material(type: MaterialType.transparency, child: SeverityRing(severity: f.severity, score: f.score))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(f.cve, style: t.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
                  if (f.kev) const Padding(padding: EdgeInsets.only(left: 6), child: Pill('Exploited', color: Color(0xFFFF5C6C))),
                  if (f.advisory != null) const Padding(padding: EdgeInsets.only(left: 6), child: Pill('Advisory', color: kAccent, icon: Icons.campaign_rounded)),
                ]),
                const SizedBox(height: 2),
                Text(f.headline.isNotEmpty ? f.headline : f.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 13)),
                const SizedBox(height: 6),
                Text('${f.system} ${f.sysVersion}'.trim(), style: const TextStyle(fontSize: 12.5)),
                if (f.published.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text('Published ${f.published}', style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant))),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  StatusChip(f.status),
                  if (f.snoozed) Pill('Snoozed until ${f.snoozeUntil!.year}-${f.snoozeUntil!.month.toString().padLeft(2, '0')}-${f.snoozeUntil!.day.toString().padLeft(2, '0')}', color: const Color(0xFF8F98B7), icon: Icons.snooze_rounded),
                  if (f.overdue) const Pill('Overdue', color: Color(0xFFFF5C6C), icon: Icons.schedule_rounded) else if (f.due.isNotEmpty && f.isOpen) Pill('Due ${f.due}', icon: Icons.schedule_rounded),
                  if (f.assigneeName.isNotEmpty || f.assignee.isNotEmpty) Pill(f.assigneeName.isNotEmpty ? f.assigneeName : f.assignee, icon: Icons.person_rounded),
                  if (f.alsoBy.isNotEmpty) Pill(alsoText(f.alsoBy), color: kTeal),
                  if (d.groups.length > 1) for (final g in f.groups) GroupDot(group: d.group(g), fallback: g),
                ]),
              ]),
            ),
          ]),
        ),
        ),
      ),
    );
  }
}
