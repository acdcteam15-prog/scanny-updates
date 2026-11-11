import 'package:flutter/material.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Change the status. "Solved" asks for proof: the upgraded version, or the restrictive actions taken.
Future<bool> showStatusSheet(BuildContext context, DataService d, Finding f) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom), child: _StatusSheet(d: d, f: f)),
  );
  return r == true;
}

class _StatusSheet extends StatefulWidget {
  final DataService d;
  final Finding f;
  const _StatusSheet({required this.d, required this.f});
  @override
  State<_StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends State<_StatusSheet> {
  Status? _to;
  bool _upgrade = true;
  late final TextEditingController _version = TextEditingController(text: widget.f.fixed);
  final _actions = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _upgrade = widget.f.fixed.isNotEmpty;
  }

  @override
  void dispose() {
    _version.dispose();
    _actions.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final to = _to;
    if (to == null) return;
    Proof? proof;
    if (to == Status.solved) {
      final p = solvedProblem(upgrade: _upgrade, version: _version.text, actions: _actions.text);
      if (p != null) {
        setState(() => _problem = p);
        return;
      }
      proof = Proof(upgrade: _upgrade, version: _upgrade ? _version.text.trim() : '', actions: _upgrade ? '' : _actions.text.trim());
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.d.setStatus(widget.f, to, proof: proof);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _problem = '$e'.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final targets = allowedTargets(widget.f.status, isAdmin: widget.d.isAdmin);
    final t = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Change status', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Row(children: [const Text('Now: '), StatusChip(widget.f.status)]),
          const SizedBox(height: 12),
          if (targets.isEmpty)
            Text('A risk accepted for a period can only be changed by an admin, or in Scanny for Windows.', style: TextStyle(color: t.colorScheme.onSurfaceVariant))
          else
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in targets)
                ChoiceChip(
                  label: Text(kStatusLabel[s] ?? ''),
                  selected: _to == s,
                  selectedColor: statusColor(s).withValues(alpha: 0.28),
                  onSelected: (_) => setState(() {
                    _to = s;
                    _problem = null;
                  }),
                ),
            ]),
          if (_to == Status.solved) ...[
            const SizedBox(height: 16),
            Text('How was it fixed?', style: t.textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('Upgraded'), icon: Icon(Icons.system_update_alt_rounded)), ButtonSegment(value: false, label: Text('Restricted'), icon: Icon(Icons.shield_rounded))],
              selected: {_upgrade},
              onSelectionChanged: (s) => setState(() {
                _upgrade = s.first;
                _problem = null;
              }),
            ),
            const SizedBox(height: 12),
            if (_upgrade)
              TextField(controller: _version, decoration: const InputDecoration(labelText: 'Upgraded to version', hintText: 'for example 17.9.5'), textInputAction: TextInputAction.done)
            else
              TextField(controller: _actions, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Restrictive actions taken', hintText: 'For example: blocked TCP 443 from the guest VLAN, disabled the web admin page')),
          ],
          if (_to == Status.falsePositive) ...[
            const SizedBox(height: 12),
            Text('It leaves the open list. Add a comment afterwards to say why.', style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
          ],
          if (_problem != null) ...[const SizedBox(height: 12), Text(_problem!, style: TextStyle(color: t.colorScheme.error))],
          const SizedBox(height: 18),
          FilledButton(onPressed: (_to == null || _busy) ? null : _save, child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save')),
        ]),
      ),
    );
  }
}

Future<void> showAssignSheet(BuildContext context, DataService d, Finding f) async {
  final people = d.people;
  final pick = await showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Assign to', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
          if (f.assignee.isNotEmpty) ListTile(leading: const Icon(Icons.person_off_rounded), title: const Text('Nobody (remove assignment)'), onTap: () => Navigator.of(c).pop('none')),
          for (final p in people)
            ListTile(
              leading: CircleAvatar(child: Text(p.name.isEmpty ? '?' : p.name[0].toUpperCase())),
              title: Text(p.name),
              subtitle: Text(p.email),
              trailing: p.email == f.assignee ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(c).pop(p),
            ),
          if (people.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No people to choose from yet. Add members to your groups in Scanny for Windows.')),
        ]),
      ),
    ),
  );
  if (pick == null) return;
  try {
    await d.setAssignee(f, pick is Person ? pick : null);
  } catch (e) {
    if (context.mounted) toast(context, '$e'.replaceFirst('Bad state: ', ''));
  }
}
