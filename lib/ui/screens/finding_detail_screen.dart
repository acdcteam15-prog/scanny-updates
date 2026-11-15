import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../logic/find_ui.dart';
import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../theme.dart';
import '../widgets/ask_ai_sheet.dart';
import '../widgets/common.dart';
import '../widgets/detail_widgets.dart';
import 'reader_screen.dart';
import 'status_sheet.dart';

class FindingDetailScreen extends StatefulWidget {
  final String fid;
  const FindingDetailScreen({super.key, required this.fid});
  @override
  State<FindingDetailScreen> createState() => _FindingDetailScreenState();
}

class _FindingDetailScreenState extends State<FindingDetailScreen> {
  final _comment = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _comment.addListener(() => setState(() {})); // the @ suggestions follow what is typed
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String _date(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  Future<void> _snooze(DataService d, Finding f) async {
    final days = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Snooze ${f.cve}', style: Theme.of(ctx).textTheme.titleMedium)),
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('It leaves the open list and the counts, for everyone, and comes back by itself.', style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant, fontSize: 13))),
          for (final n in const [7, 30, 90]) ListTile(leading: const Icon(Icons.snooze_rounded), title: Text('$n days'), onTap: () => Navigator.pop(ctx, n)),
          if (f.snoozed) ListTile(leading: const Icon(Icons.notifications_active_outlined), title: const Text('Remove the snooze'), onTap: () => Navigator.pop(ctx, 0)),
        ]),
      ),
    );
    if (days == null) return;
    try {
      await d.snooze(f, days);
      if (mounted) toast(context, days == 0 ? 'Snooze removed' : 'Snoozed for $days days');
    } catch (e) {
      if (mounted) toast(context, '$e'.replaceFirst('Bad state: ', ''));
    }
  }

  void _mention(Person p) {
    final t = _comment.text;
    final sel = _comment.selection;
    final at = sel.isValid && sel.start >= 0 && sel.start <= t.length ? sel.start : t.length;
    final ins = '@${p.name} ';
    _comment.value = TextEditingValue(text: t.substring(0, at) + ins + t.substring(at), selection: TextSelection.collapsed(offset: at + ins.length));
  }

  Future<void> _share(Finding f) async {
    try {
      await SharePlus.instance.share(ShareParams(text: findingShareText(f), subject: f.cve));
    } catch (e) {
      if (mounted) toast(context, 'Sharing is not available right now.');
    }
  }

  Future<void> _post(DataService d, Finding f) async {
    setState(() => _posting = true);
    try {
      await d.addComment(f, _comment.text);
      _comment.clear();
      FocusManager.instance.primaryFocus?.unfocus();
    } catch (e) {
      if (mounted) toast(context, '$e'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    final f = d.finding(widget.fid);
    final t = Theme.of(context);
    if (f == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('This finding is no longer available. It was fixed and removed, or it left your groups.', textAlign: TextAlign.center))));
    }
    final canEdit = d.online;
    final me = d.email;
    final mine = f.assignee == me;
    return Scaffold(
      // 1.25.0: the common actions stay at the bottom, without scrolling past the details
      bottomNavigationBar: !canEdit
          ? null
          : SafeArea(
              child: Container(
                margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(18), border: Border.all(color: t.colorScheme.outlineVariant)),
                child: Row(children: [
                  _BarButton(icon: Icons.flag_rounded, label: kStatusLabel[f.status] ?? 'Status', onTap: () async {
                    HapticFeedback.lightImpact();
                    await showStatusSheet(context, d, f);
                  }),
                  _BarButton(icon: Icons.person_add_alt_1_rounded, label: mine ? 'Mine' : 'Assign me', onTap: mine ? null : () async {
                    HapticFeedback.lightImpact();
                    try {
                      await d.setAssignee(f, Person(email: me, name: d.displayName));
                      if (context.mounted) toast(context, 'Assigned to you');
                    } catch (e) {
                      if (context.mounted) toast(context, '$e'.replaceFirst('Bad state: ', ''));
                    }
                  }),
                  if (f.isOpen) _BarButton(icon: Icons.snooze_rounded, label: 'Snooze', onTap: () => _snooze(d, f)),
                  _BarButton(icon: Icons.auto_awesome_rounded, label: 'Ask AI', onTap: () => showAskAi(context, d, f)),
                ]),
              ),
            ),
      appBar: AppBar(title: Text(f.cve), actions: [
        IconButton(icon: const Icon(Icons.copy_rounded), tooltip: 'Copy CVE', onPressed: () { Clipboard.setData(ClipboardData(text: f.cve)); HapticFeedback.selectionClick(); toast(context, 'Copied ${f.cve}'); }),
        IconButton(icon: const Icon(Icons.share_rounded), tooltip: 'Share', onPressed: () => _share(f)),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Hero(tag: 'sev-${f.fid}', child: Material(type: MaterialType.transparency, child: SeverityRing(severity: f.severity, score: f.score, size: 56))),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(severityLabel(f.severity), style: TextStyle(color: severityColor(f.severity), fontWeight: FontWeight.w700, fontSize: 16)),
                  Text('${f.system} ${f.sysVersion}'.trim(), style: t.textTheme.titleSmall),
                ])),
              ]),
              const SizedBox(height: 10),
              if (f.headline.isNotEmpty) Text(f.headline, style: t.textTheme.titleSmall),
              if (f.title.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(f.title, style: TextStyle(color: t.colorScheme.onSurfaceVariant))),
              const SizedBox(height: 10),
              if (f.cvss != null || f.epss != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    if (f.cvss != null) CvssGauge(score: f.cvss!),
                    if (f.cvss != null && f.epss != null) const SizedBox(width: 14),
                    if (f.epss != null) Expanded(child: EpssBar(value: f.epss!)),
                  ]),
                ),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (f.kev) const Pill('Actively exploited', color: Color(0xFFFF5C6C), icon: Icons.bolt_rounded),
                if (f.poc) const Pill('Public exploit', color: Color(0xFFFF9F43), icon: Icons.code_rounded),
                if (f.fixed.isNotEmpty) Pill('Patch available: ${f.fixed}', color: const Color(0xFF4CD964), icon: Icons.check_rounded),
                if (f.overdue) const Pill('Overdue', color: Color(0xFFFF5C6C), icon: Icons.schedule_rounded),
                if (d.systemDocs.any((x) => x.id == f.sid && x.exposed)) const Pill('Internet', color: Color(0xFF8796FF), icon: Icons.public_rounded),
                for (final nv in {for (final x in d.systemDocs) if (x.id == f.sid && x.newer.isNotEmpty) x.newer}) Pill('New version: $nv', color: const Color(0xFF3AD6C4), icon: Icons.system_update_alt_rounded),
                if (f.snoozed) Pill('Snoozed until ${_date(f.snoozeUntil!)}', color: const Color(0xFF8F98B7), icon: Icons.snooze_rounded),
                for (final g in f.groups) GroupDot(group: d.group(g), fallback: g),
                if (f.firstSeen != null) Pill('Found ${ago(f.firstSeen)}', icon: Icons.schedule_rounded),
              ]),
              if (f.source.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text('Record from ${f.source}${f.alsoBy.isNotEmpty ? '. Also reported by ${f.alsoBy.join(', ')}. Shown once.' : '.'}', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12.5)),
                ),
            ]),
          ),
        ),
        const SectionTitle('Status'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                StatusChip(f.status),
                const Spacer(),
                if (f.statusBy.isNotEmpty) Flexible(child: Text('${f.statusByName.isEmpty ? f.statusBy : f.statusByName} · ${ago(f.statusAt)}', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12), overflow: TextOverflow.ellipsis)),
              ]),
              if (f.solved != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(f.solved!.text, style: const TextStyle(color: Color(0xFF4CD964)))),
              if (f.accepted != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text('Accepted until ${f.accepted!.until}: ${f.accepted!.reason}', style: const TextStyle(color: Color(0xFFF2C94C)))),
              if (f.due.isNotEmpty && f.isOpen) Padding(padding: const EdgeInsets.only(top: 10), child: Text(f.overdue ? 'Overdue since ${f.due}' : 'Fix by ${f.due}', style: TextStyle(color: f.overdue ? const Color(0xFFFF5C6C) : null))),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: FilledButton.icon(style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)), visualDensity: VisualDensity.compact), icon: const Icon(Icons.flag_rounded, size: 18), label: const Text('Change status', maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis), onPressed: canEdit ? () => showStatusSheet(context, d, f) : null)),
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton.icon(style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)), visualDensity: VisualDensity.compact), icon: const Icon(Icons.person_add_alt_1_rounded, size: 18), label: Text(f.assigneeName.isNotEmpty ? f.assigneeName : (f.assignee.isNotEmpty ? f.assignee : 'Assign'), maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis), onPressed: canEdit ? () => showAssignSheet(context, d, f) : null)),
              ]),
              if (f.isOpen) Padding(padding: const EdgeInsets.only(top: 10), child: SizedBox(width: double.infinity, child: OutlinedButton.icon(icon: const Icon(Icons.snooze_rounded), label: Text(f.snoozed ? 'Snoozed until ${_date(f.snoozeUntil!)} · change' : 'Snooze'), onPressed: canEdit ? () => _snooze(d, f) : null))),
              if (!canEdit) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Offline: changes are switched off.', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12))),
            ]),
          ),
        ),
        if (f.steps.isNotEmpty) ...[
          const SectionTitle('What to do'),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < f.steps.length; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${i + 1}.  ', style: const TextStyle(fontWeight: FontWeight.w700)), Expanded(child: SelectableText(f.steps[i]))]))]))),
        ],
        if (f.workaround.isNotEmpty) ...[
          const SectionTitle('If you cannot patch yet'),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final w in f.workaround) Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  '), Expanded(child: SelectableText(w))]))]))),
        ],
        if (f.advisory != null) ...[
          const SectionTitle('Advisory', icon: Icons.campaign_rounded),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('This advisory lists ${f.system} ${f.sysVersion} as affected.'.replaceAll('  ', ' '), style: const TextStyle(fontWeight: FontWeight.w600)),
                for (final x in f.advisory!.affected) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $x', style: const TextStyle(fontSize: 13))),
                if (f.advisory!.cves.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('${f.advisory!.cves.length} CVEs in this advisory', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final c in f.advisory!.cves.take(60)) ActionChip(label: Text(c, style: const TextStyle(fontSize: 12)), onPressed: () => openReference(context, RefLink('https://nvd.nist.gov/vuln/detail/$c', const ['CVE']))),
                  ]),
                  if (f.advisory!.cves.length > 60) Padding(padding: const EdgeInsets.only(top: 6), child: Text('and ${f.advisory!.cves.length - 60} more', style: const TextStyle(fontSize: 12))),
                ],
              ]),
            ),
          ),
        ],
        if (f.refs.isNotEmpty) ...[
          const SectionTitle('References', icon: Icons.link_rounded),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final r in f.refs)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => openReference(context, r),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(refLabel(r.url), style: const TextStyle(color: kAccent, fontSize: 14)),
                        for (final tag in r.tags) Pill(tag),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ],
        const SectionTitle('Comments'),
        StreamBuilder<List<Comment>>(
          stream: d.comments(f),
          builder: (c, s) {
            final list = s.data ?? const <Comment>[];
            if (list.isEmpty) return Text('No comments yet. Use them for ticket numbers, maintenance windows and hand-offs.', style: TextStyle(color: t.colorScheme.onSurfaceVariant));
            return Column(children: [
              for (final cm in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [Text(cm.byName, style: t.textTheme.titleSmall), const Spacer(), Text(ago(cm.at), style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12))]),
                    const SizedBox(height: 4),
                    SelectableText(cm.text),
                  ]))),
                ),
            ]);
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Builder(builder: (ctx) {
            final seen = <String>{};
            final people = <Person>[
              for (final g in f.groups)
                for (final p in (d.group(g)?.people ?? const <Person>[]))
                  if (p.email != d.email && seen.add(p.email)) p,
            ];
            if (people.isEmpty) return const SizedBox.shrink();
            return PopupMenuButton<Person>(
              tooltip: 'Mention someone',
              enabled: canEdit,
              icon: const Icon(Icons.alternate_email_rounded),
              onSelected: _mention,
              itemBuilder: (c) => [for (final p in people) PopupMenuItem(value: p, child: Text(p.name))],
            );
          }),
          Expanded(child: TextField(controller: _comment, enabled: canEdit, minLines: 1, maxLines: 4, maxLength: 2000, decoration: const InputDecoration(hintText: 'Write a comment, @ to mention', counterText: ''))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: (!canEdit || _posting) ? null : () => _post(d, f), icon: _posting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_rounded)),
        ]),
        // 1.25.0: typing @ suggests the people who can see this finding
        Builder(builder: (c) {
          final mq = mentionQuery(_comment.text, _comment.selection.baseOffset);
          if (mq == null) return const SizedBox.shrink();
          final seen = <String>{};
          final ppl = mentionMatches([
            for (final g in f.groups)
              for (final p in (d.group(g)?.people ?? const <Person>[]))
                if (p.email != d.email && seen.add(p.email)) p,
          ], mq.q);
          if (ppl.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in ppl)
                ActionChip(
                  avatar: const Icon(Icons.alternate_email_rounded, size: 16),
                  label: Text(p.name),
                  onPressed: () {
                    final r = insertMention(_comment.text, _comment.selection.baseOffset, mq.start, p.name);
                    _comment.value = TextEditingValue(text: r.text, selection: TextSelection.collapsed(offset: r.caret));
                    HapticFeedback.selectionClick();
                  },
                ),
            ]),
          );
        }),
        const SectionTitle('History'),
        StreamBuilder<List<AuditEntry>>(
          stream: d.history(f),
          builder: (c, s) {
            final list = s.data ?? const <AuditEntry>[];
            final events = <TimelineEvent>[
              for (final e in list)
                TimelineEvent(
                  icon: e.action == 'comment' ? Icons.chat_bubble_outline_rounded : (e.action == 'assign' ? Icons.person_outline_rounded : Icons.flag_rounded),
                  text: e.text,
                  sub: '${e.byName} · ${ago(e.at)}',
                  color: e.action == 'status' ? kAccent : null,
                ),
              if (f.firstSeen != null) TimelineEvent(icon: Icons.radar_rounded, text: 'Found by Scanny', sub: ago(f.firstSeen), color: kTeal),
            ];
            if (events.isEmpty) return Text('Nothing has changed yet.', style: TextStyle(color: t.colorScheme.onSurfaceVariant));
            return Timeline(events: events);
          },
        ),
      ]),
    );
  }
}


/// One button of the action bar at the bottom of a finding.
class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _BarButton({required this.icon, required this.label, this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 21, color: c.onSurface),
              const SizedBox(height: 2),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
    );
  }
}
