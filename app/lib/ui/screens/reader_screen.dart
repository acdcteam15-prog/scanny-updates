import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../logic/rules.dart';
import '../../logic/watch.dart';
import '../../models/models.dart';
import '../../state/native.dart';
import '../../state/prefs.dart';
import '../../state/reader_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Opens an article the way this person chose in Settings: inside Scanny (reader view) or in the phone's browser.
Future<void> openArticle(BuildContext context, WatchItem item) async {
  final prefs = Provider.of<LocalPrefs>(context, listen: false);
  await prefs.markWatchRead(item.id);
  if (!context.mounted) return;
  if (articleOpenFrom(prefs.articleOpenRaw) == ArticleOpen.browser) {
    await openInBrowser(context, item.link);
  } else {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(item: item)));
  }
}

/// Opens a reference link of a CVE: in Scanny's reader, or in the browser if this person chose that for articles.
Future<void> openReference(BuildContext context, RefLink r) async {
  final prefs = Provider.of<LocalPrefs>(context, listen: false);
  if (articleOpenFrom(prefs.articleOpenRaw) == ArticleOpen.browser) {
    await openInBrowser(context, r.url);
    return;
  }
  final item = WatchItem(id: 'ref-${r.url.hashCode}', title: refLabel(r.url), feed: r.tags.isEmpty ? 'Reference' : r.tags.first, link: r.url, summary: '', published: '', t: 0, cves: const [], groups: const [], mine: false);
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(item: item)));
}

Future<void> openInBrowser(BuildContext context, String link) async {
  final ok = link.isNotEmpty && await Native.openUrl(link);
  if (!ok && context.mounted) {
    await Clipboard.setData(ClipboardData(text: link));
    if (context.mounted) toast(context, 'No browser could open it. The address was copied.');
  }
}

/// A plain reader view: the text of the article without menus and ads, with the summary shown at once.
class ReaderScreen extends StatefulWidget {
  final WatchItem item;
  const ReaderScreen({super.key, required this.item});
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final Future<Article> _article = ReaderService.fetch(widget.item.link);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final i = widget.item;
    final prefs = context.watch<LocalPrefs>();
    return Scaffold(
      appBar: AppBar(
        title: Text(i.feed, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Open in the browser', icon: const Icon(Icons.open_in_browser_rounded), onPressed: () => openInBrowser(context, i.link)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'copy') {
                await Clipboard.setData(ClipboardData(text: i.link));
                if (context.mounted) toast(context, 'Link copied');
              } else {
                await prefs.setArticleOpen(v);
                if (context.mounted) toast(context, v == 'browser' ? 'Articles will open in the browser from now on. Change it in Settings.' : 'Articles will open here from now on.');
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: Text('Copy link')),
              if (articleOpenFrom(prefs.articleOpenRaw) == ArticleOpen.reader) const PopupMenuItem(value: 'browser', child: Text('Always open in the browser')),
            ],
          ),
        ],
      ),
      body: FutureBuilder<Article>(
        future: _article,
        builder: (c, s) {
          final loading = s.connectionState != ConnectionState.done;
          final a = s.data;
          final ok = a != null && a.readable;
          final title = (a != null && a.title.isNotEmpty) ? a.title : i.title;
          return ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 40), children: [
            Text(i.title.isNotEmpty ? i.title : title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.25)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Pill(i.feed, color: kTeal),
              Text(ago(i.when), style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12.5)),
              for (final c in i.cves.take(6)) Pill(c, color: const Color(0xFFE5484D)),
            ]),
            const SizedBox(height: 14),
            if (loading) ...[
              if (i.summary.isNotEmpty) Text(i.summary, style: t.textTheme.bodyLarge?.copyWith(height: 1.5)),
              const SizedBox(height: 18),
              const Row(children: [SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 10), Text('Loading the full article…')]),
            ] else if (ok)
              ..._blocks(t, a)
            else ...[
              if (i.summary.isNotEmpty) Text(i.summary, style: t.textTheme.bodyLarge?.copyWith(height: 1.5)),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    s.hasError ? 'The full article could not be loaded here (${_why(s.error)}). Open the original in the browser.' : 'This page has little readable text (it may need JavaScript or a login). Open the original in the browser.',
                    style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.tonalIcon(icon: const Icon(Icons.open_in_browser_rounded), label: const Text('Open the original in the browser'), onPressed: () => openInBrowser(context, i.link)),
          ]);
        },
      ),
    );
  }

  String _why(Object? e) {
    final s = '$e'.replaceAll('Exception: ', '').replaceAll('FormatException: ', '');
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  List<Widget> _blocks(ThemeData t, Article a) => [
        for (final b in a.blocks)
          switch (b.kind) {
            'h' => Padding(padding: const EdgeInsets.only(top: 18, bottom: 6), child: Text(b.text, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            'li' => Padding(padding: const EdgeInsets.only(left: 6, bottom: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  ', style: TextStyle(color: kTeal)), Expanded(child: Text(b.text, style: t.textTheme.bodyLarge?.copyWith(height: 1.5)))])),
            'q' => Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.only(left: 12), decoration: const BoxDecoration(border: Border(left: BorderSide(color: kTeal, width: 3))), child: Text(b.text, style: t.textTheme.bodyLarge?.copyWith(height: 1.5, color: t.colorScheme.onSurfaceVariant))),
            'pre' => Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)), child: Text(b.text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5))),
            _ => Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(b.text, style: t.textTheme.bodyLarge?.copyWith(height: 1.55))),
          },
      ];
}
