import 'dart:convert';
import 'dart:typed_data';

/// A tiny PDF writer for one kind of document: a title and a table of text. Pure Dart, no packages.
/// Uses the built-in Helvetica font, so only Latin characters are drawn; anything else becomes "?".
/// (The `pdf` package was removed: it pulls in `image` and `archive`, whose versions clash with Flutter's pinned ones.)
const double _pageW = 842; // A4 landscape, in points
const double _pageH = 595;
const double _margin = 28;
const double _font = 8;
const double _lineH = 10.5;

String _latin(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x0A || r == 0x0D || r == 0x09) {
      b.write(' ');
    } else if (r >= 32 && r < 127 || (r >= 160 && r < 256)) {
      b.writeCharCode(r);
    } else {
      b.write('?');
    }
  }
  return b.toString();
}

/// Escapes a string for a PDF literal. Characters 128-255 are written as octal, so the file itself stays plain ASCII.
String _lit(String s) {
  final b = StringBuffer('(');
  for (final u in _latin(s).codeUnits) {
    if (u == 0x28 || u == 0x29 || u == 0x5C) {
      b.write('\\${String.fromCharCode(u)}');
    } else if (u > 126) {
      b.write('\\${u.toRadixString(8).padLeft(3, '0')}');
    } else {
      b.writeCharCode(u);
    }
  }
  b.write(')');
  return b.toString();
}

/// Splits [text] into at most [maxLines] lines of about [maxChars] characters (the last line is cut with "..").
List<String> wrapText(String text, int maxChars, int maxLines) {
  final words = _latin(text).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final lines = <String>[];
  var cur = '';
  for (var w in words) {
    while (w.length > maxChars) {
      if (cur.isNotEmpty) {
        lines.add(cur);
        cur = '';
      }
      lines.add(w.substring(0, maxChars));
      w = w.substring(maxChars);
    }
    if (cur.isEmpty) {
      cur = w;
    } else if (cur.length + 1 + w.length <= maxChars) {
      cur = '$cur $w';
    } else {
      lines.add(cur);
      cur = w;
    }
  }
  if (cur.isNotEmpty) lines.add(cur);
  if (lines.isEmpty) lines.add('');
  if (lines.length > maxLines) {
    final cut = lines.sublist(0, maxLines);
    final last = cut.last;
    cut[maxLines - 1] = (last.length > maxChars - 2 ? last.substring(0, maxChars - 2) : last) + '..';
    return cut;
  }
  return lines;
}

/// [widths] are relative column widths. Returns the bytes of a complete PDF file.
Uint8List buildTablePdf({required String title, required String subtitle, required List<String> head, required List<List<String>> rows, required List<double> widths}) {
  final usable = _pageW - 2 * _margin;
  final total = widths.fold<double>(0, (a, b) => a + b);
  final colW = [for (final w in widths) usable * w / total];
  final maxChars = [for (final w in colW) ((w - 6) / (_font * 0.52)).floor().clamp(4, 200)];

  // Lay the rows out onto pages.
  final pages = <StringBuffer>[];
  late StringBuffer cur;
  var y = 0.0;
  late void Function() newPage;

  void drawRow(List<String> cells, {bool bold = false, bool fill = false}) {
    final wrapped = [for (var i = 0; i < colW.length; i++) wrapText(i < cells.length ? cells[i] : '', maxChars[i], 3)];
    final lines = wrapped.map((l) => l.length).reduce((a, b) => a > b ? a : b);
    final h = lines * _lineH + 4;
    if (y - h < _margin) {
      newPage();
    }
    if (fill) cur.write('0.85 g ${_margin} ${y - h} $usable $h re f 0 g\n');
    var x = _margin;
    for (var i = 0; i < colW.length; i++) {
      for (var j = 0; j < wrapped[i].length; j++) {
        cur.write('BT /${bold ? 'F2' : 'F1'} $_font Tf ${(x + 3).toStringAsFixed(1)} ${(y - 9 - j * _lineH).toStringAsFixed(1)} Td ${_lit(wrapped[i][j])} Tj ET\n');
      }
      x += colW[i];
    }
    y -= h;
    cur.write('0.7 G 0.4 w ${_margin} $y m ${_margin + usable} $y l S 0 G\n');
  }

  newPage = () {
    cur = StringBuffer();
    pages.add(cur);
    y = _pageH - _margin;
    if (pages.length == 1) {
      cur.write('BT /F2 15 Tf $_margin ${y - 12} Td ${_lit(title)} Tj ET\n');
      y -= 20;
      cur.write('BT /F1 9 Tf $_margin ${y - 9} Td ${_lit(subtitle)} Tj ET\n');
      y -= 20;
    }
    drawRow(head, bold: true, fill: true);
  };

  newPage();
  for (final r in rows) {
    drawRow(r);
  }
  if (rows.isEmpty) drawRow(['No findings for this choice.']);

  // Objects: 1 catalog, 2 pages, 3 Helvetica, 4 Helvetica-Bold, then (content, page) per page.
  final objs = <String>[];
  final kids = <String>[];
  for (var i = 0; i < pages.length; i++) {
    final c = 5 + i * 2;
    final p = c + 1;
    final stream = '${pages[i]}BT /F1 7 Tf ${_pageW - _margin - 60} 14 Td ${_lit('Page ${i + 1} of ${pages.length}')} Tj ET\n';
    objs.add('<< /Length ${stream.length} >>\nstream\n${stream}endstream');
    objs.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $_pageW $_pageH] /Contents $c 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> >>');
    kids.add('$p 0 R');
  }
  final all = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${pages.length} >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>',
    ...objs,
  ];
  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));
  put('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < all.length; i++) {
    offsets.add(out.length);
    put('${i + 1} 0 obj\n${all[i]}\nendobj\n');
  }
  final xref = out.length;
  put('xref\n0 ${all.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    put('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  put('trailer\n<< /Size ${all.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.toBytes();
}
