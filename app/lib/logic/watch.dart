// Pure Dart: Zero-day watch filters and the reader view of an article. No Flutter, no Firebase, no packages.
import '../models/models.dart';

enum WatchMode { all, mine, unread }

enum ArticleOpen { reader, browser }

/// The setting each person makes for themselves: read an article inside Scanny, or send it to the phone's browser.
ArticleOpen articleOpenFrom(String? v) => v == 'browser' ? ArticleOpen.browser : ArticleOpen.reader;
String articleOpenName(ArticleOpen v) => v == ArticleOpen.browser ? 'browser' : 'reader';

/// The text that is shared for an article: its title, then the link on its own line (chat apps and mail turn it into a tappable link).
String shareText(WatchItem i) => '${i.title.trim()}\n${i.link.trim()}';

/// Does this article mention systems of this person's groups? (Admins: any system.)
bool mentionsMe(WatchItem i, Set<String> myGroups, bool isAdmin) => (i.mine && (isAdmin || i.groups.any(myGroups.contains))) || mentionedIds(i, myGroups, isAdmin).isNotEmpty;

/// Ids of the systems this person may see that the article mentions (admins: all groups).
List<String> mentionedIds(WatchItem i, Set<String> myGroups, bool isAdmin) {
  final out = <String>{};
  i.mentions.forEach((g, ids) {
    if (isAdmin || myGroups.contains(g)) out.addAll(ids.where((x) => x.trim().isNotEmpty));
  });
  return out.toList()..sort();
}

/// The red label: one system by name, several as a count, none known (older data) in general words. [nameOf] turns a system id into its name ('' if unknown).
String mentionLabel(List<String> ids, String Function(String) nameOf) {
  if (ids.isEmpty) return 'Mentions your systems';
  if (ids.length > 1) return 'Mentions ${ids.length} systems';
  final n = nameOf(ids.first).trim();
  return n.isEmpty ? 'Mentions 1 system' : 'Mentions $n';
}

List<WatchItem> filterWatch(List<WatchItem> items, {required WatchMode mode, required Set<String> myGroups, required bool isAdmin, required Set<String> read, String feed = ''}) {
  final out = items.where((i) {
    if (feed.isNotEmpty && i.feed != feed) return false;
    if (mode == WatchMode.mine && !mentionsMe(i, myGroups, isAdmin)) return false;
    if (mode == WatchMode.unread && read.contains(i.id)) return false;
    return true;
  }).toList();
  out.sort((a, b) => b.when.compareTo(a.when));
  return out;
}

// ------------------------------------------------------------------------------------------------ reader view
class ArticleBlock {
  /// h (heading), p (paragraph), li (list item), q (quote), pre (code)
  final String kind;
  final String text;
  const ArticleBlock(this.kind, this.text);
}

class Article {
  final String title;
  final List<ArticleBlock> blocks;
  const Article(this.title, this.blocks);
  bool get readable => blocks.length >= 2;
}

final RegExp _skip = RegExp(r'<(script|style|noscript|svg|nav|footer|aside|header|form|iframe|template|figure|picture|button|select)\b[^>]*>.*?</\1\s*>', caseSensitive: false, dotAll: true);
final RegExp _comment = RegExp(r'<!--.*?-->', dotAll: true);
final RegExp _block = RegExp(r'<(h[1-4]|p|li|blockquote|pre)\b[^>]*>(.*?)</\1\s*>', caseSensitive: false, dotAll: true);
final RegExp _tag = RegExp(r'<[^>]+>');

const Map<String, String> _named = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'mdash': '-', 'ndash': '-', 'hellip': '...', 'rsquo': "'", 'lsquo': "'", 'ldquo': '"', 'rdquo': '"', 'copy': '(c)',
};

String decodeEntities(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
      final e = m.group(1)!;
      if (e.startsWith('#x') || e.startsWith('#X')) {
        final c = int.tryParse(e.substring(2), radix: 16);
        return c == null || c > 0x10FFFF ? '' : String.fromCharCode(c);
      }
      if (e.startsWith('#')) {
        final c = int.tryParse(e.substring(1));
        return c == null || c > 0x10FFFF ? '' : String.fromCharCode(c);
      }
      return _named[e.toLowerCase()] ?? m.group(0)!;
    });

String _text(String html) => decodeEntities(html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ').replaceAll(_tag, ' ')).replaceAll(RegExp(r'\s+'), ' ').trim();

/// Keeps the headings and paragraphs of the article and drops menus, scripts, footers and ads.
Article extractArticle(String html, {int maxBlocks = 90, int maxChars = 20000}) {
  var h = html.replaceAll(_comment, ' ');
  String title = '';
  final og = RegExp(r'''<meta[^>]+property=["']og:title["'][^>]*content=["']([^"']+)["']''', caseSensitive: false).firstMatch(h) ??
      RegExp(r'''<meta[^>]+content=["']([^"']+)["'][^>]*property=["']og:title["']''', caseSensitive: false).firstMatch(h);
  if (og != null) title = _text(og.group(1)!);
  if (title.isEmpty) {
    final t = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(h);
    if (t != null) title = _text(t.group(1)!);
  }
  h = h.replaceAll(_skip, ' ');
  String? pick(String tag) {
    String? best;
    for (final m in RegExp('<$tag\\b[^>]*>(.*?)</$tag\\s*>', caseSensitive: false, dotAll: true).allMatches(h)) {
      final inner = m.group(1)!;
      if (best == null || inner.length > best.length) best = inner;
    }
    return best;
  }

  final scoped = pick('article') ?? pick('main');
  final src = scoped ?? h;
  final out = <ArticleBlock>[];
  var last = '', total = 0;
  for (final m in _block.allMatches(src)) {
    final tag = m.group(1)!.toLowerCase();
    final kind = tag.startsWith('h') ? 'h' : (tag == 'li' ? 'li' : (tag == 'blockquote' ? 'q' : tag));
    final text = _text(m.group(2)!);
    if (text.isEmpty || text == last) continue;
    if (kind == 'li' && text.length < 3) continue;
    if (scoped == null && kind != 'h' && text.length < 60) continue;
    last = text;
    total += text.length;
    out.add(ArticleBlock(kind, text.length > 3000 ? text.substring(0, 3000) : text));
    if (out.length >= maxBlocks || total > maxChars) break;
  }
  return Article(title.length > 300 ? title.substring(0, 300) : title, out);
}
