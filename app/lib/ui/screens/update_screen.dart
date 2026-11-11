import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../logic/resume.dart';
import '../../state/native.dart';
import '../../state/updater.dart';
import '../widgets/common.dart';

String _mb(int bytes) => megabytes(bytes);

/// App updates without Google Play: what is new, size, download progress, install.
class UpdateScreen extends StatelessWidget {
  const UpdateScreen({super.key});

  String _errorText(String e) {
    if (e.startsWith('SocketException') || e.contains('Connection') || e.contains('TimeoutException')) return 'The connection was lost. What is downloaded is saved: press Resume to continue from there.';
    if (e == 'corrupt') return 'The downloaded file did not match its checksum, so it was not installed. Try again.';
    if (e.startsWith('HTTP 404')) return 'No update has been published yet. On the PC run Rebuild-APK.bat.';
    return 'The update check failed.\n$e';
  }

  @override
  Widget build(BuildContext context) {
    final u = context.watch<UpdateService>();
    final t = Theme.of(context);
    final info = u.latest;
    final name = u.installedName;
    String headline;
    IconData icon;
    Color? tint;
    if (u.status == UpdateStatus.checking) {
      headline = 'Checking for updates…';
      icon = Icons.sync_rounded;
    } else if (u.hasUpdate) {
      headline = u.status == UpdateStatus.ready
          ? 'Version ${info!.versionName} is ready to install'
          : u.status == UpdateStatus.paused
              ? 'Download paused'
              : 'Version ${info!.versionName} is available';
      icon = Icons.system_update_rounded;
      tint = t.colorScheme.primary;
    } else if (u.status == UpdateStatus.error) {
      headline = 'Could not check';
      icon = Icons.cloud_off_rounded;
      tint = t.colorScheme.error;
    } else if (info != null) {
      headline = 'Scanny ${name.isEmpty ? info.versionName : name} is up to date';
      icon = Icons.check_circle_rounded;
      tint = const Color(0xFF4CD964);
    } else {
      headline = 'Updates';
      icon = Icons.system_update_rounded;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Updates')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        Card(
          color: u.required ? t.colorScheme.errorContainer : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Icon(icon, size: 36, color: tint), const SizedBox(width: 12), Expanded(child: Text(headline, style: t.textTheme.titleLarge))]),
              const SizedBox(height: 8),
              Text('Installed: ${name.isEmpty ? '?' : '$name (${u.installedBuild})'}', style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
              if (u.required) Padding(padding: const EdgeInsets.only(top: 8), child: Text('This update is required.', style: TextStyle(color: t.colorScheme.error, fontWeight: FontWeight.w700))),
            ]),
          ),
        ),
        if (info != null && (u.hasUpdate || u.whatsNew != null)) ...[
          const SectionTitle("What's new"),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text([info.versionName, if (info.date.isNotEmpty) info.date, if (info.size > 0) '${_mb(info.size)} MB'].join(' · '), style: t.textTheme.labelLarge),
                if (info.notes.isNotEmpty) ...[const SizedBox(height: 8), SelectableText(info.notes)],
              ]),
            ),
          ),
        ],
        if (u.downloading || u.status == UpdateStatus.installing || u.status == UpdateStatus.paused) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(value: u.status == UpdateStatus.installing ? null : u.progress, minHeight: 8),
          const SizedBox(height: 6),
          Text(u.status == UpdateStatus.installing
              ? 'Opening the Android installer…'
              : u.status == UpdateStatus.paused
                  ? 'Paused at ${(u.progress * 100).round()}%. What is downloaded is saved on this phone.'
                  : u.status == UpdateStatus.waiting
                      ? u.waitNote
                      : 'Downloading ${(u.progress * 100).round()}%${u.totalBytes > 0 ? ' · ${_mb(u.gotBytes)} of ${_mb(u.totalBytes)} MB' : ''}${u.speedText.isEmpty ? '' : ' · ${u.speedText}'}'),
          if (u.downloading)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('You can turn the screen off or leave the app: the download goes on (see the notification) and continues from the last byte if the connection drops.',
                  style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 12.5)),
            ),
        ],
        if (u.status == UpdateStatus.ready && !u.needsPermission) ...[
          const SizedBox(height: 16),
          Row(children: [
            Icon(Icons.verified_rounded, color: const Color(0xFF4CD964), size: 20),
            const SizedBox(width: 8),
            const Expanded(child: Text('Downloaded and checked. Nothing is installed until you press Install.')),
          ]),
        ],
        if (u.needsPermission) ...[
          const SizedBox(height: 16),
          const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Android needs your permission once: allow Scanny to install apps in the screen that just opened, come back, and press Download again.'))),
        ],
        if (u.status == UpdateStatus.error && u.error != null) ...[const SizedBox(height: 16), Text(_errorText(u.error!), style: TextStyle(color: t.colorScheme.error))],
        if (u.batteryAsk) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Some phones cut downloads to save battery. Allow Scanny to run in the background (one question from Android) so updates finish with the screen off.'),
                const SizedBox(height: 8),
                OutlinedButton.icon(icon: const Icon(Icons.battery_saver_rounded), label: const Text('Allow background running'), onPressed: Native.requestBatteryExempt),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (u.status == UpdateStatus.ready) FilledButton.icon(icon: const Icon(Icons.system_update_rounded), label: const Text('Install now'), onPressed: u.install),
        if (u.status == UpdateStatus.paused) FilledButton.icon(icon: const Icon(Icons.play_arrow_rounded), label: const Text('Resume download'), onPressed: u.resume),
        if (u.status == UpdateStatus.error && u.hasUpdate) FilledButton.icon(icon: const Icon(Icons.refresh_rounded), label: Text(u.progress > 0 ? 'Resume download' : 'Try again'), onPressed: u.resume),
        if (u.downloading) FilledButton.tonalIcon(icon: const Icon(Icons.pause_rounded), label: const Text('Pause'), onPressed: u.pause),
        if (u.hasUpdate && (u.status == UpdateStatus.available)) ...[
          FilledButton.icon(icon: const Icon(Icons.download_rounded), label: const Text('Download and install'), onPressed: u.busy ? null : u.downloadAndInstall),
          const SizedBox(height: 8),
          OutlinedButton.icon(icon: const Icon(Icons.download_for_offline_rounded), label: const Text('Download only, install later'), onPressed: u.busy ? null : () => u.download()),
        ],
        if (u.hasUpdate && (u.downloading || u.status == UpdateStatus.paused || u.status == UpdateStatus.error) && u.progress > 0)
          TextButton.icon(icon: const Icon(Icons.close_rounded), label: const Text('Cancel and delete the download'), onPressed: u.cancel),
        if (!u.hasUpdate) OutlinedButton.icon(icon: const Icon(Icons.refresh_rounded), label: const Text('Check for updates'), onPressed: u.busy ? null : () => u.check()),
        if (u.whatsNew != null) TextButton(onPressed: u.dismissWhatsNew, child: const Text('Got it')),
      ]),
    );
  }
}
