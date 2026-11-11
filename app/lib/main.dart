import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'state/data_service.dart';
import 'state/lock.dart';
import 'state/prefs.dart';
import 'state/push.dart';
import 'state/updater.dart';
import 'state/widget_sync.dart';
import 'ui/screens/auth_gate.dart';
import 'ui/screens/lock_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  // Any startup problem shows a readable error screen instead of closing the app.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      // Saved copy on the phone: the findings stay readable without a connection.
      FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true, cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED);
    } catch (e, st) {
      runApp(StartupErrorApp(error: 'Firebase could not start.\n\n$e\n\n$st'));
      return;
    }
    final prefs = await LocalPrefs.load();
    final push = PushService()
      ..watchPush = prefs.watchPush
      ..activityPush = prefs.activityPush;
    await push.init();
    runApp(MultiProvider(
      providers: [
        ChangeNotifierProvider<LocalPrefs>.value(value: prefs),
        Provider<PushService>.value(value: push),
        ChangeNotifierProvider<LockService>(create: (_) => LockService(prefs)),
        ChangeNotifierProvider<DataService>(create: (_) => DataService()),
        ChangeNotifierProvider<UpdateService>(lazy: false, create: (c) => UpdateService(c.read<LocalPrefs>())),
      ],
      child: const ScannyApp(),
    ));
  }, (error, stack) => debugPrint('Uncaught: $error\n$stack'));
}

/// Shown when the app cannot start (for example a Firebase config problem), with the real error.
class StartupErrorApp extends StatelessWidget {
  final String error;
  const StartupErrorApp({super.key, required this.error});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Scaffold(
        appBar: AppBar(title: const Text('Scanny - startup error')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Scanny could not start. Please send this text.'),
          const SizedBox(height: 12),
          FilledButton.icon(icon: const Icon(Icons.copy_rounded), label: const Text('Copy'), onPressed: () => Clipboard.setData(ClipboardData(text: error))),
          const SizedBox(height: 12),
          SelectableText(error, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ]),
      ),
    );
  }
}

class ScannyApp extends StatefulWidget {
  const ScannyApp({super.key});
  @override
  State<ScannyApp> createState() => _ScannyAppState();
}

class _ScannyAppState extends State<ScannyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Whenever the findings change: refresh the home-screen widgets.
    Provider.of<DataService>(context, listen: false).onFindingsChanged = () {
      final d = Provider.of<DataService>(context, listen: false);
      WidgetSync.push(d.findings);
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final lock = Provider.of<LockService>(context, listen: false);
    if (s == AppLifecycleState.paused) lock.paused();
    if (s == AppLifecycleState.resumed) lock.resumed();
  }

  @override
  Widget build(BuildContext context) {
    final locked = context.watch<LockService>().locked;
    return MaterialApp(
      title: 'Scanny',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      builder: (c, child) => Stack(children: [child ?? const SizedBox.shrink(), if (locked) const Positioned.fill(child: LockScreen())]),
      home: const AuthGate(),
    );
  }
}
