import 'package:flutter/material.dart';

import '../../state/auth_service.dart';
import '../widgets/common.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  AuthFailure? _error;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.signInGoogle();
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(28), children: [
          const SizedBox(height: 56),
          Center(child: ClipRRect(borderRadius: BorderRadius.circular(28), child: Image.asset('assets/logo.png', width: 108, height: 108))),
          const SizedBox(height: 16),
          Text('Scanny', textAlign: TextAlign.center, style: t.textTheme.headlineLarge),
          const SizedBox(height: 6),
          Text('Vulnerability alerts for your team', textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 40),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 56)),
            icon: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.g_mobiledata_rounded, size: 32),
            label: const Text('Continue with Google'),
            onPressed: _busy ? null : _go,
          ),
          if (_error != null) ...[const SizedBox(height: 14), ErrorBox(code: _error!.code, meaning: _error!.meaning)],
          const SizedBox(height: 22),
          Text('Only Google addresses that your admin added in Scanny for Windows (Team > Members) can enter.', textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 13)),
        ]),
      ),
    );
  }
}
