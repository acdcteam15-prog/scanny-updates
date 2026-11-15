import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../logic/notify.dart';
import '../../logic/rules.dart';
import '../../logic/watch.dart';
import '../../models/models.dart';
import '../../state/auth_service.dart';
import '../../state/data_service.dart';
import '../../state/export.dart';
import '../../state/lock.dart';
import '../../state/native.dart';
import '../../state/prefs.dart';
import '../../state/push.dart';
import '../../state/updater.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/empty_explain.dart';
import 'notify_screen.dart';
import 'update_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  String _exportGroup = '';
  bool _everything = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Native.buildInfo().then((b) {
      if (mounted) setState(() => _version = b.name.isEmpty ? '' : '${b.name} (${b.build})');
    });
  }

  Future<void> _setPin() async {
    final lock = Provider.of<LockService>(context, listen: false);
    final c = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose a PIN'),
        content: TextField(controller: c, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, autofocus: true, decoration: const InputDecoration(hintText: '4 to 6 digits')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save'))],
      ),
    );
    final p = hashPinText((pin ?? '').trim());
    if (p.length >= 4 && RegExp(r'^\d+$').hasMatch(p)) {
      await lock.enable(p);
      if (mounted) toast(context, 'Lock is on. Fingerprint or face works too when your phone has it.');
    } else if (pin != null && mounted) {
      toast(context, 'The PIN needs 4 to 6 digits.');
    }
  }

  Future<void> _export(DataService d, bool pdf) async {
    final gid = _exportGroup;
    final items = applyFilter(
      d.findings.where((f) => gid.isEmpty || f.groups.contains(gid)),
      FindingFilter(statuses: _everything ? Status.values.toSet() : const {}),
    );
    if (items.isEmpty) {
      toast(context, 'There is nothing to export for this choice.');
      return;
    }
    setState(() => _busy = true);
    try {
      final title = gid.isEmpty ? 'All my groups' : d.groupName(gid);
      if (pdf) {
        await Exporter.sharePdf(title, items, d.groupName);
      } else {
        await Exporter.shareCsv(title, items, d.groupName);
      }
    } catch (e) {
      if (mounted) toast(context, 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    final prefs = context.watch<LocalPrefs>();
    final u = context.watch<UpdateService>();
    final t = Theme.of(context);
    final me = d.me;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 32), children: [
      Text('Settings', style: t.textTheme.headlineSmall),
      const SectionTitle('Account', icon: Icons.person_rounded),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(radius: 24, child: Text((me?.name ?? '?').isEmpty ? '?' : (me?.name ?? '?')[0].toUpperCase(), style: const TextStyle(fontSize: 20))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(me?.name ?? '', style: t.textTheme.titleMedium), Text(d.email, style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 13))])),
              if (d.isAdmin) const Pill('Admin', color: kTeal, icon: Icons.verified_user_rounded),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final g in d.groups) GroupDot(group: g), if (d.groups.isEmpty) const Text('No groups yet')]),
            const SizedBox(height: 4),
            Text(d.isAdmin ? 'You see every group.' : 'You see the systems and alerts of your groups.', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12.5)),
          ]),
        ),
      ),
      const SectionTitle('Security', icon: Icons.lock_rounded),
      Card(
        child: Column(children: [
          SwitchListTile(
            title: const Text('Lock the app'),
            subtitle: const Text('Fingerprint or face, with a PIN as backup. Hides Scanny in recent apps.'),
            value: prefs.lockEnabled,
            onChanged: (v) => v ? _setPin() : Provider.of<LockService>(context, listen: false).disable(),
          ),
        ]),
      ),
      const SectionTitle('Notifications', icon: Icons.notifications_rounded),
      Card(
        child: SwitchListTile(
          title: const Text('Push alerts on this phone'),
          subtitle: const Text('Turn push alerts on or off for this phone. Below you choose what you are told.'),
          value: prefs.pushEnabled,
          onChanged: (v) async {
            await prefs.setPushEnabled(v);
            final push = Provider.of<PushService>(context, listen: false);
            if (v) {
              await push.register(d.email);
            } else {
              await push.unregister();
            }
          },
        ),
      ),
      if (prefs.pushEnabled)
        Card(
          child: ListTile(
            leading: const Icon(Icons.send_rounded),
            title: const Text('Send me a test'),
            subtitle: const Text('Scanny for Windows sends a real message to each of your phones and says which got it.'),
            onTap: () async {
              final m = ScaffoldMessenger.of(context);
              m.showSnackBar(const SnackBar(content: Text('Asking Scanny for Windows to send a test…')));
              try {
                final r = await PushService.requestTest(d.email);
                m.showSnackBar(SnackBar(content: Text(r)));
              } catch (e) {
                m.showSnackBar(SnackBar(content: Text('$e')));
              }
            },
          ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.tune_rounded),
          title: const Text('What you are told'),
          subtitle: Text('${NotifyPrefs.fromJson(prefs.notifyJson, watch: prefs.watchPush, activity: prefs.activityPush).summary(canWatch: d.canWatch)}${prefs.notifyJson == null ? ' (default)' : ''}'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NotifyScreen())),
        ),
      ),
      const SectionTitle('Appearance', icon: Icons.palette_outlined),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Theme'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)), visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 'dark', label: Text('Dark', maxLines: 1, softWrap: false)),
                  ButtonSegment(value: 'light', label: Text('Light', maxLines: 1, softWrap: false)),
                  ButtonSegment(value: 'black', label: Text('Black', maxLines: 1, softWrap: false)),
                  ButtonSegment(value: 'system', label: Text('Auto', maxLines: 1, softWrap: false)),
                ],
                selected: {prefs.themeMode},
                onSelectionChanged: (v) => prefs.setThemeMode(v.first),
              ),
            ),
            const SizedBox(height: 6),
            Text('Only for this phone. Black saves battery on OLED screens. Auto follows the phone: dark when the phone is in dark mode, light otherwise.', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12.5)),
          ]),
        ),
      ),
      if (d.canWatch) ...[
        const SectionTitle('Zero-day watch', icon: Icons.rss_feed_rounded),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Open articles'),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ArticleOpen>(
                  segments: const [
                    ButtonSegment(value: ArticleOpen.reader, label: Text('In Scanny'), icon: Icon(Icons.chrome_reader_mode_rounded)),
                    ButtonSegment(value: ArticleOpen.browser, label: Text('In the browser'), icon: Icon(Icons.open_in_browser_rounded)),
                  ],
                  selected: {articleOpenFrom(prefs.articleOpenRaw)},
                  onSelectionChanged: (v) => prefs.setArticleOpen(articleOpenName(v.first)),
                ),
              ),
              const SizedBox(height: 6),
              Text('Your own choice, only for this phone. "In Scanny" shows a clean reader page with a button to open the original.', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12.5)),
            ]),
          ),
        ),
      ],
      const SectionTitle('Export a group', icon: Icons.ios_share_rounded),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              initialValue: _exportGroup,
              decoration: const InputDecoration(labelText: 'Group'),
              items: [const DropdownMenuItem(value: '', child: Text('All my groups')), for (final g in d.groups) DropdownMenuItem(value: g.id, child: Text(g.name))],
              onChanged: (v) => setState(() => _exportGroup = v ?? ''),
            ),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Include solved, false positives and accepted risks'), value: _everything, onChanged: (v) => setState(() => _everything = v)),
            Row(children: [
              Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.table_chart_rounded), label: const Text('CSV'), onPressed: _busy ? null : () => _export(d, false))),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('PDF'), onPressed: _busy ? null : () => _export(d, true))),
            ]),
          ]),
        ),
      ),
      const SectionTitle('About', icon: Icons.info_outline_rounded),
      Card(
        child: Column(children: [
          ListTile(leading: const Icon(Icons.wifi_tethering_rounded), title: const Text('Connection details'), subtitle: const Text('Who you are signed in as, your groups, and what this phone received'), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => showConnectionDetails(context)),
          ListTile(
            leading: Icon(u.hasUpdate ? Icons.system_update_rounded : Icons.info_outline_rounded),
            title: Text(u.hasUpdate ? 'Update available: ${u.latest?.versionName}' : 'Scanny $_version'),
            subtitle: Text(u.hasUpdate ? 'Tap to download and install' : 'Check for updates'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              u.check();
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UpdateScreen()));
            },
          ),
          SwitchListTile(title: const Text('Check for updates automatically'), value: prefs.autoUpdateCheck, onChanged: prefs.setAutoUpdateCheck),
          SwitchListTile(
            title: const Text('Download new versions in the background'),
            subtitle: const Text('A notification tells you when it is ready. Nothing is installed until you tap.'),
            value: prefs.autoDownload,
            onChanged: prefs.setAutoDownload,
          ),
          if (prefs.autoDownload)
            SwitchListTile(
              title: const Text('Only on Wi-Fi'),
              subtitle: const Text('The Download button always works on any connection.'),
              value: prefs.autoDownloadWifiOnly,
              onChanged: prefs.setAutoDownloadWifiOnly,
            ),
        ]),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        icon: const Icon(Icons.logout_rounded),
        label: const Text('Sign out'),
        onPressed: () async {
          final push = Provider.of<PushService>(context, listen: false);
          final data = Provider.of<DataService>(context, listen: false);
          final nav = Navigator.of(context);
          await push.unregister();
          data.detach(notify: false);
          await AuthService.signOut();
          nav.popUntil((r) => r.isFirst);
        },
      ),
    ]);
  }
}
