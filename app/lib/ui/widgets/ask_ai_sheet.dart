import 'dart:async';

import 'package:flutter/material.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../theme.dart';

class _Turn {
  final String q;
  String status = 'pending';
  String answer = '';
  String error = '';
  String provider = '';
  bool sent = false; // the question is in Firebase
  final DateTime t0 = DateTime.now();
  int secs = 0;
  String trying = ''; // the AI service Scanny for Windows is asking right now
  int attempt = 0;
  int total = 0;
  List<String> failed = []; // services that did not answer, and why
  StreamSubscription<Map<String, dynamic>>? sub;
  Timer? timer;
  _Turn(this.q);
  bool get waiting => answer.isEmpty && error.isEmpty;
}

/// Ask AI about one finding. The question goes through Firebase and Scanny for Windows answers it with its own AI keys,
/// trying one provider after the other until one answers. The keys never reach the phone.
Future<void> showAskAi(BuildContext context, DataService d, Finding f) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom), child: _AskAiSheet(d: d, f: f)),
    );

class _AskAiSheet extends StatefulWidget {
  final DataService d;
  final Finding f;
  const _AskAiSheet({required this.d, required this.f});
  @override
  State<_AskAiSheet> createState() => _AskAiSheetState();
}

class _AskAiSheetState extends State<_AskAiSheet> {
  static const _quick = ['How do I fix this?', 'Is it urgent for me?', 'Explain it in simple words'];
  final _c = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <_Turn>[];
  Timer? _clock; // redraws every second while a question waits, so the seconds count up

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  void _finish(_Turn t) {
    t.timer?.cancel();
    t.sub?.cancel();
  }

  void _ask(String text) {
    final q = text.trim();
    if (q.isEmpty) return;
    final t = _Turn(q);
    final history = aiHistory([for (final x in _turns) (x.q, x.answer)]);
    setState(() => _turns.add(t));
    _c.clear();
    _toEnd();
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_turns.any((x) => x.waiting)) {
        _clock?.cancel();
        _clock = null;
      }
      setState(() {});
    });
    t.sub = widget.d.askAi(widget.f, q, history).listen((m) {
      if (!mounted) return;
      setState(() {
        t.status = '${m['status'] ?? 'pending'}';
        if (m['_sent'] == true || t.status != 'pending') t.sent = true;
        if ('${m['trying'] ?? ''}'.isNotEmpty) {
          t.trying = '${m['trying']}';
          t.attempt = (m['attempt'] is num) ? (m['attempt'] as num).toInt() : 0;
          t.total = (m['total'] is num) ? (m['total'] as num).toInt() : 0;
        }
        if (m['failed'] is List) t.failed = [for (final x in m['failed'] as List) '$x'];
        if (t.status == 'done') {
          t.answer = '${m['answer'] ?? ''}';
          t.provider = '${m['provider'] ?? ''}';
          t.secs = DateTime.now().difference(t.t0).inSeconds;
          _finish(t);
        } else if (t.status == 'error') {
          t.error = '${m['error'] ?? 'No answer.'}';
          _finish(t);
        }
      });
      _toEnd();
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        t.error = '$e'.replaceFirst('Bad state: ', '');
        _finish(t);
      });
    });
    t.timer = Timer(const Duration(seconds: 120), () {
      if (mounted && t.waiting) {
        setState(() {
          t.error = 'No answer yet. Is Scanny for Windows running and online?';
          _finish(t);
        });
      }
    });
  }

  @override
  void dispose() {
    for (final t in _turns) {
      _finish(t);
    }
    _clock?.cancel();
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _step(ThemeData t, String state, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (state == 'ok')
            const Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF4CD964))
          else if (state == 'now')
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(Icons.radio_button_unchecked_rounded, size: 16, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Flexible(child: Text(text, style: TextStyle(color: state == 'todo' ? t.colorScheme.onSurfaceVariant : null))),
        ]),
      );

  /// The steps of one question: sent, picked up by Scanny for Windows, which AI service is being asked (and which did not answer), and the seconds.
  Widget _progress(ThemeData t, _Turn x) {
    final secs = DateTime.now().difference(x.t0).inSeconds;
    final working = x.status == 'working';
    final asking = working ? (x.trying.isEmpty ? 'Thinking…' : 'Asking ${x.trying}${x.total > 1 ? ' (${x.attempt} of ${x.total})' : ''}…') : 'Asking the AI';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      _step(t, x.sent ? 'ok' : 'now', x.sent ? 'Sent to Firebase' : 'Sending…'),
      _step(t, working ? 'ok' : (x.sent ? 'now' : 'todo'), working ? 'Scanny for Windows picked it up' : 'Waiting for Scanny for Windows…'),
      _step(t, working ? 'now' : 'todo', asking),
      for (final f in x.failed) Padding(padding: const EdgeInsets.only(left: 26, top: 1), child: Text('✕ $f', style: TextStyle(fontSize: 12.5, color: t.colorScheme.error))),
      Padding(padding: const EdgeInsets.only(left: 26, top: 4), child: Text('$secs s', style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant))),
      if (!working && x.sent && secs >= 25) Padding(padding: const EdgeInsets.only(left: 26, top: 2), child: Text('Taking longer than usual. Scanny for Windows must be on and online to answer.', style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome_rounded, color: kAccent, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text('Ask AI · ${widget.f.cve}', style: t.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(controller: _scroll, shrinkWrap: true, children: [
              if (_turns.isEmpty) Text('Pick a question or write your own. Scanny for Windows answers with its own AI keys (the PC must be on). If one AI service does not answer, it tries the next.', style: TextStyle(color: t.colorScheme.onSurfaceVariant, height: 1.4)),
              for (final x in _turns) ...[
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Container(
                    margin: const EdgeInsets.only(top: 8, left: 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(16)),
                    child: Text(x.q),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    margin: const EdgeInsets.only(top: 8, right: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(16)),
                    child: x.error.isNotEmpty
                        ? Text(x.error, style: TextStyle(color: t.colorScheme.error))
                        : x.answer.isNotEmpty
                            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                SelectableText(x.answer, style: const TextStyle(height: 1.45)),
                                const SizedBox(height: 6),
                                Text('Answered by ${x.provider.isEmpty ? 'AI' : x.provider} · ${x.secs} s', style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
                              ])
                            : _progress(t, x),
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [for (final q in _quick) ActionChip(label: Text(q), onPressed: () => _ask(q))]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: TextField(controller: _c, maxLength: 1000, minLines: 1, maxLines: 3, textInputAction: TextInputAction.send, onSubmitted: _ask, decoration: const InputDecoration(hintText: 'Ask your own question', counterText: '', isDense: true))),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: () => _ask(_c.text), icon: const Icon(Icons.send_rounded)),
          ]),
        ]),
      ),
    );
  }
}
