// Pure Dart: the rules for resuming an interrupted update download. No Flutter, no Firebase, no packages.
import 'dart:convert';
import 'dart:math';

/// What was being downloaded into the partial file. If it differs from the update now offered, the partial file is thrown away.
class PartMeta {
  final String key;
  final String url;
  final int total;
  const PartMeta({required this.key, required this.url, required this.total});

  String toJson() => jsonEncode({'key': key, 'url': url, 'total': total});

  static PartMeta? tryParse(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      final m = jsonDecode(text);
      if (m is! Map) return null;
      return PartMeta(key: '${m['key'] ?? ''}', url: '${m['url'] ?? ''}', total: (m['total'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }
}

/// Byte to continue from. 0 = start again (nothing saved, another version or address, or a file that cannot be right).
int resumeFrom({required PartMeta? meta, required String key, required String url, required int partLength, required int total}) {
  if (meta == null || meta.key != key || meta.url != url) return 0;
  if (partLength <= 0) return 0;
  if (total > 0 && partLength > total) return 0;
  return partLength;
}

/// Value for the HTTP Range header, or null when the whole file is wanted.
String? rangeHeader(int start) => start > 0 ? 'bytes=$start-' : null;

/// Size of the whole file from a "Content-Range: bytes 100-999/1000" answer (null when unknown).
int? totalFromContentRange(String? h) {
  if (h == null) return null;
  final m = RegExp(r'/(\d+)\s*$').firstMatch(h.trim());
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Seconds to wait before the next try after a lost connection: 2, 4, 8, 16, 30, 30...
int retrySeconds(int attempt) => min(30, 2 << min(attempt, 4));

/// Errors that a new try can fix (lost connection, slow server). Others (404, corrupt file, not https) are final.
bool isRetryable(Object e) {
  final t = e.toString();
  if (t == 'corrupt' || t.startsWith('The update address')) return false;
  final m = RegExp(r'^HTTP (\d+)').firstMatch(t);
  if (m != null) {
    final code = int.parse(m.group(1)!);
    return code == 408 || code == 429 || code >= 500;
  }
  return true;
}

String megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(bytes > 20 * 1024 * 1024 ? 0 : 1);
