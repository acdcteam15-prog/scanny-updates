import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/lock.dart';

/// Shown over the whole app while it is locked.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  bool _wrong = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
  }

  Future<void> _bio() async {
    final lock = Provider.of<LockService>(context, listen: false);
    if (await lock.canUseBiometrics() && mounted) {
      await lock.unlockWithBiometrics('Unlock Scanny');
    }
  }

  void _tap(String d) {
    final lock = Provider.of<LockService>(context, listen: false);
    setState(() {
      _wrong = false;
      if (d == '<') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
        return;
      }
      if (_pin.length < 6) _pin += d;
    });
    if (_pin.length >= 4 && lock.checkPin(_pin)) {
      HapticFeedback.selectionClick();
      lock.unlock();
    } else if (_pin.length == 6) {
      setState(() {
        _wrong = true;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    Widget key(String d, {IconData? icon}) => Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 72,
            height: 72,
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
              onPressed: () => d == 'bio' ? _bio() : _tap(d),
              child: icon != null ? Icon(icon) : Text(d, style: const TextStyle(fontSize: 26)),
            ),
          ),
        );
    return Material(
      color: s.surface,
      child: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_rounded, size: 56, color: s.primary),
            const SizedBox(height: 12),
            Text('Enter your PIN', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 6; i++)
                Container(margin: const EdgeInsets.all(6), width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, color: i < _pin.length ? s.primary : s.outlineVariant)),
            ]),
            SizedBox(height: 28, child: _wrong ? Text('Wrong PIN', style: TextStyle(color: s.error)) : null),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d)]),
            Row(mainAxisSize: MainAxisSize.min, children: [key('bio', icon: Icons.fingerprint_rounded), key('0'), key('<', icon: Icons.backspace_outlined)]),
          ]),
        ),
      ),
    );
  }
}
