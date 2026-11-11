import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_service.dart';
import '../../state/data_service.dart';
import '../../state/push.dart';
import '../widgets/common.dart';
import 'home_shell.dart';
import 'sign_in_screen.dart';

/// Signed out -> sign-in. Signed in -> check the members list -> the app (or an explanation).
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (c, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const Splash();
        final u = snap.data;
        if (u == null) {
          Provider.of<DataService>(context, listen: false).detach(notify: false);
          return const SignInScreen();
        }
        return _AccessGate(user: u);
      },
    );
  }
}

class _AccessGate extends StatefulWidget {
  final User user;
  const _AccessGate({required this.user});
  @override
  State<_AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<_AccessGate> {
  bool _registered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attach());
  }

  void _attach() {
    if (!mounted) return;
    Provider.of<DataService>(context, listen: false).attach(widget.user);
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    Widget child;
    switch (d.access) {
      case Access.loading:
        child = const Splash();
      case Access.ok:
        if (!_registered) {
          _registered = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => Provider.of<PushService>(context, listen: false).register(d.email));
        }
        child = const HomeShell();
      case Access.denied:
        child = _NotAllowed(email: (widget.user.email ?? '').toLowerCase(), onRetry: _attach);
      case Access.error:
        child = Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ErrorBox(code: 'load', meaning: '${d.error ?? 'Could not load your data.'}\n\nIf this says permission-denied, ask the admin to press "Deploy security rules" in Scanny for Windows (Team > Phones and sync).'),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _attach, child: const Text('Try again')),
                  TextButton(onPressed: AuthService.signOut, child: const Text('Use another account')),
                ]),
              ),
            ),
          ),
        );
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: child);
  }
}

class _NotAllowed extends StatelessWidget {
  final String email;
  final VoidCallback onRetry;
  const _NotAllowed({required this.email, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_person_rounded, size: 64, color: t.colorScheme.primary),
              const SizedBox(height: 16),
              Text('This account is not on the list', style: t.textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              SelectableText(email, style: TextStyle(color: t.colorScheme.primary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text('Ask your admin to add this address in Scanny for Windows: Team > Members, then Sync now. Then press Try again.', textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
              TextButton(onPressed: AuthService.signOut, child: const Text('Use another Google account')),
            ]),
          ),
        ),
      ),
    );
  }
}
