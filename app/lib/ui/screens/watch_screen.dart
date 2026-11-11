import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../logic/rules.dart';
import '../../logic/watch.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../../state/prefs.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'reader_screen.dart';

/// Zero-day watch: vendor advisories, research blogs and news that Scanny for Windows collects. Items that mention your groups' systems glow red.
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key});
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  WatchMode _mode = WatchMode.all;
  String _feed = '';
  String _query = '';
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    final prefs = context.watch<LocalPrefs>();
    final t = Theme.of(context);
    final myGroups = d.groups.map((g) => g.id).toSet();
    final read = prefs.watchRead;
    final sysName = {for (final x in d.systemDocs) x.id: x.name};
    final feeds = {for (final i in d.watchItems) i.feed}.where((f) => f.isNotEmpty).toList()..sort();
    final list = filterWatch(d.watchItems, mode: _mode, myGroups: myGroups, isAdmin: d.isAdmin, read: read, feed: _feed, query: _query);
    Widget chip(String label, bool on, VoidCallback tap) => Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => tap()));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        child: Align(alignment: Alignment.centerLeft, child: Text('Zero-day watch', style: t.textTheme.headlineSmall)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Align(alignment: Alignment.centerLeft, child: Text('Advisories, research and news. Items that mention your systems glow red.', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12.5))),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          controller: _q,
          onChanged: (v) => setState(() => _query = v.trim()),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search the title or the text inside articles',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _query.isEmpty ? null : IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Clear', onPressed: () => setState(() {
                  _q.clear();
                  _query = '';
                })),
            isDense: true,
          ),
        ),
      ),
      SizedBox(
        height: 46,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          chip('Everything', _mode == WatchMode.all && _feed.isEmpty, () => setState(() {
                _mode = WatchMode.all;
                _feed = '';
              })),
          chip('Mentions my systems', _mode == WatchMode.mine, () => setState(() => _mode = _mode == WatchMode.mine ? WatchMode.all : WatchMode.mine)),
          chip('Unread', _mode == WatchMode.unread, () => setState(() => _mode = _mode == WatchMode.unread ? WatchMode.all : WatchMode.unread)),
          for (final f in feeds) chip(f, _feed == f, () => setState(() => _feed = _feed == f ? '' : f)),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? (d.watchItems.isEmpty
                ? const EmptyState(icon: Icons.rss_feed_rounded, color: kTeal, title: 'No articles yet', body: 'Scanny for Windows sends the newest ones every few minutes.')
                : EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Nothing matches this filter',
                    actionLabel: 'Clear filters',
                    onAction: () => setState(() {
                      _mode = WatchMode.all;
                      _feed = '';
                      _q.clear();
                      _query = '';
                    }),
                  ))
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: ListView.builder(
                  key: ValueKey('$_mode|$_feed'),
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                  itemCount: list.length,
                  itemBuilder: (c, n) => Stagger(index: n, child: _card(context, t, list[n], mentionsMe(list[n], myGroups, d.isAdmin), !read.contains(list[n].id), mentionLabel(mentionedIds(list[n], myGroups, d.isAdmin), (id) => sysName[id] ?? ''))),
                ),
              ),
      ),
    ]);
  }

  /// Shares the article as plain text (title and link). The apps that receive it make the link tappable.
  Future<void> _share(BuildContext context, WatchItem i) async {
    try {
      await SharePlus.instance.share(ShareParams(text: shareText(i), subject: i.title));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sharing is not available right now.')));
    }
  }

  Widget _card(BuildContext context, ThemeData t, WatchItem i, bool mine, bool unread, String mentionText) {
    const red = Color(0xFFE5484D);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PressScale(
        child: GlowCard(
          stripe: mine ? red : kTeal,
          glow: mine,
          child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => openArticle(context, i),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                if (unread) Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 8), decoration: const BoxDecoration(color: kTeal, shape: BoxShape.circle)),
                Flexible(child: Pill(i.feed, color: kTeal, wrap: true)),
                const SizedBox(width: 10),
                Text(ago(i.when), style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12)),
              ]),
              if (mine) Padding(padding: const EdgeInsets.only(top: 8), child: Pill(mentionText, color: red, icon: Icons.warning_amber_rounded, wrap: true)),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Padding(padding: const EdgeInsets.only(top: 6), child: Text(i.title, style: TextStyle(fontWeight: unread ? FontWeight.w700 : FontWeight.w500, fontSize: 15, height: 1.3)))),
                if (i.link.isNotEmpty)
                  IconButton(
                    tooltip: 'Share link',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.share_rounded, size: 20, color: t.colorScheme.onSurfaceVariant),
                    onPressed: () => _share(context, i),
                  ),
              ]),
              if (i.summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(i.summary, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 13, height: 1.4)),
              ],
              if (watchSnippet(i, _query).isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(watchSnippet(i, _query), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.colorScheme.primary, fontSize: 12.5, height: 1.4)),
              ],
              if (i.cves.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 4, children: [for (final c in i.cves.take(4)) Pill(c, color: const Color(0xFFF08C2B))]),
              ],
            ]),
          ),
        ),
        ),
      ),
    );
  }
}
