// Pure Dart: why is the app empty, in plain words. No Flutter and no Firebase imports.

class Explanation {
  final String title;
  final String body;
  final List<String> steps;
  const Explanation(this.title, this.body, this.steps);
}

/// What the phone knows about itself. The same numbers are shown on the "Connection details" sheet.
class Situation {
  final String email;
  final bool isAdmin;
  final int groups;
  final int findings;
  final int systems;
  final bool online;
  final Map<String, String> errors;
  final String project;
  const Situation({required this.email, required this.isAdmin, required this.groups, required this.findings, required this.systems, required this.online, this.errors = const {}, this.project = ''});
}

/// The most likely reason nothing is on screen, with what to do about it. Null when there is data.
Explanation? explainEmpty(Situation s) {
  if (s.findings > 0) return null;
  if (s.errors.values.any((e) => e.contains('permission-denied'))) {
    return Explanation('The database refused this account', 'Google answered "permission-denied" when the app asked for your data.', [
      'Make sure ${s.email} is listed under Team > Members in Scanny for Windows.',
      'In Scanny for Windows press Team > Phones and sync > Deploy security rules (new versions come with new rules).',
      'Close the app and open it again.',
    ]);
  }
  if (!s.online && s.findings == 0) {
    return const Explanation('No connection yet', 'The phone has no saved copy of your data and cannot reach the internet.', ['Connect to Wi-Fi or mobile data and open the app again.']);
  }
  if (!s.isAdmin && s.groups == 0) {
    return Explanation('No group is assigned to you', 'You are signed in as ${s.email}, a member without a group. Members only see the systems and findings of their own groups.', [
      'Ask an admin to open Scanny for Windows > Team > Members, tick a group for ${s.email} and press Save.',
      'Or ask them to make you an admin: admins see every group.',
      'The phone picks the change up by itself within a minute. If not, press Reload my access.',
    ]);
  }
  if (s.isAdmin && s.groups == 0) {
    return Explanation('Scanny for Windows has not sent anything yet', 'You are an admin, but no group exists in the database. This usually means the Windows app is not running, is linked to another Firebase project, or has not synced.', [
      'On the PC open Scanny for Windows > Team and look at "Linked to ..." and the Connection doctor.',
      'The project must be the same one this phone was built for${s.project.isEmpty ? '' : ' (${s.project})'}.',
      'Press Sync now on the Team page and wait a minute.',
    ]);
  }
  if (s.systems == 0) {
    return Explanation('Your groups have no systems yet', 'The groups exist, but no system is tagged to them, so there is nothing to show.', [
      'In Scanny for Windows > Team tag your systems with a group.',
      'Make sure Scanny for Windows is running, then press Sync now on the Team page.',
    ]);
  }
  return const Explanation('No open findings', 'Your systems are there, and nothing open affects them right now. Scanny for Windows adds findings after its next scan.', []);
}
