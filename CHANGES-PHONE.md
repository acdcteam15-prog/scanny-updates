# Changes

## 1.3.2 - no more strange groups on the admin's Settings page
- Groups such as "rt-a-eu4kzp" or "rt-b-qf6pew" were leftovers of the setup wizard's security self-test, not your groups. The phone now hides them, the wizard deletes its test data twice (also its sub-documents), and Scanny for Windows 1.10.11 removes the leftovers from Firebase.

## 1.3.1 (setup) - the iPhone web app stays on the update site
- "Publish update" replaces the whole Firebase Hosting site each time. It now keeps the iPhone web app (published by START-SCANNY-IPHONE.bat in the Scanny-iPhone folder) so publishing an Android update never removes it.

## 1.3.1 - Zero-day watch cards fixed, red "Mentions ..." label
- **No more overlap:** a long source name (for example "Trellix Security Bulletins") wraps onto a second line inside its chip and the time stays beside it.
- **Mentions your systems, like Windows:** an article that mentions something you run gets the red glow and a red label: "Mentions wordpress" for one system, "Mentions 3 systems" for several. You see only systems of your own groups (admins see all). Needs Scanny for Windows 1.10.10 or newer (it sends opaque system ids; the phone looks the names up among systems you may already read, so no group learns another group's system names). Older data shows "Mentions your systems".

## 1.3.0 - updates that survive a sleeping phone
- **The bug:** the update was downloaded into the phone's cache by a plain download that Android stops when the screen goes off, and the next try deleted what was saved and started from 0.
- **Foreground download:** while an update downloads, Scanny runs as an Android foreground service (a progress notification, Android's own rule for long transfers) and keeps the CPU and Wi-Fi awake. The screen can be off or the app in the background.
- **Resume from the last byte:** the download is saved in Scanny's own storage (not the cache) as it comes. After a lost connection it waits 2, 4, 8, up to 30 seconds and continues by itself (up to 12 tries); after a pause, a restart of the app or of the phone, **Resume** continues from the byte where it stopped. A partial file of another version or address is dropped. The finished file is checked (SHA-256) and kept until installed or until the app is up to date, then deleted.
- **Notification buttons:** Pause, Resume and Cancel in the progress notification, and in the Updates screen. Cancel deletes the saved part.
- **Background download:** when a new version is found, Scanny downloads it quietly (Settings > About: on by default, **Only on Wi-Fi** on by default) and a notification says "Update x is ready". Nothing is installed until you tap Install. The Download button always works on any connection. **Download only, install later** is also there.
- **Updates screen:** speed and time left, "Downloaded and checked", a saved download is shown again after restarting the app, and a one-tap "Allow background running" (battery saving) when a download was cut.
- The wizard adds the foreground-service permission and service, the battery-saving question, and the native wake lock. Run **START-SCANNY-PHONE.bat** once so they are in the app, then Publish-Update.
- Limit: swiping Scanny away from the recent apps stops the download (Android closes the app); what was saved stays, and Resume continues.

## 1.2.4 - share an article, and a push for every new Zero-day watch article
- **Share button** on every article in the Watch tab, on the right of the title. It shares the title and the link as plain text; in chat apps, mail and SMS the link is tappable and opens the site. Articles without a link have no button.
- **Push for new articles** (Settings > Zero-day watch): one notification per new article. Each person picks: Off, All, My systems (articles that mention systems of your groups; default) or Critical (exploited or zero-day). The choice is saved on this phone's record in Firebase, so Scanny for Windows (1.10.4 or newer) knows what to send. It follows the existing "Push alerts on this phone" switch.
- Needs the matching Scanny for Windows 1.10.4: it sends the notifications (max 8 per scan, then one "N more").

## 1.2.3 - groups changed while the app is open now show up, and clean systems are listed
- **Bug fixed:** the phone loaded your groups once, when it signed in. If the admin assigned you to groups afterwards (while the app stayed open), the Watch tab appeared but the findings and systems of those groups never did, until you signed out and in again. Now the phone watches your own member record: when your groups or your role change it reloads the groups and their data by itself, within a minute.
- **Reload my access** button on the empty screens (and the same on a fresh sign-in): reads your member record again and restarts the group data.
- **Systems list:** it showed only systems that have findings. It now shows every system Scanny for Windows sent to your groups, with "No open findings" for the clean ones. No extra reads.

## 1.2.2 - push to GitHub only
- **Menu option 10 / `Push-To-GitHub.bat`:** uploads the last APK (the newest one in Output) to your GitHub releases and nothing else: no rebuild, no Firebase. Use it when the build worked but GitHub was blocked on that network, or to push from another PC or network. Safe to repeat: an APK that is already on GitHub is reused, never uploaded twice. It writes `Output\GitHub-release.txt` with the download address. When the phones should see "Update available", run `Publish-Update.bat` afterwards; it reuses the GitHub upload.
- **A blocked network no longer wipes your GitHub token.** The saved repository and token are cleared only when GitHub itself says they are wrong (401/403/404). A blocked or unreachable GitHub just says so, and tells you the APK is saved and how to push it later.

## 1.2.1 - an empty screen now explains itself
- Instead of a blank list the Findings and Systems screens say why nothing is shown and what to do: no group assigned to you, no system tagged to your groups, Scanny for Windows has not sent anything (wrong project or not running), the database refused the account (rules need deploying), or no connection yet.
- **Settings > Connection details** (also reachable from the empty screen): who you are signed in as, your role and groups, how many findings and systems this phone received, online or offline, the Firebase project, and any error. A Copy button sends it to your admin.

## 1.2.0 - Zero-day watch on the phone
- New **Watch** tab (only for people the admin switched on under Team > Members in Scanny for Windows; admins always): the newest advisories and news, filters (Everything, Mentions my systems, Unread, by feed), red glow for items that mention your groups' systems.
- **Each person chooses how articles open** (Settings > Zero-day watch): in Scanny (a reader page that downloads the article on the phone and shows headings, paragraphs, lists and code, with a button for the browser) or straight in the phone's browser. The reader page has a menu entry to switch to "always the browser".
- The admin can switch Zero-day watch on or off for you while the app is open.
- The setup wizard now tests the new rules (switch on, switch off, admin, and that a phone can never write an article) and teaches the phone's native bridge to open a browser.

## 1.1.5 - no more name clashes with the Windows folder
- `START-HERE.bat` is now **`START-SCANNY-PHONE.bat`** and the documents are `README-PHONE.md`, `CHANGES-PHONE.md`, `TESTING-PHONE.md`, `DISTRIBUTION-PHONE.md`. Scanny for Windows uses `START-SCANNY-WINDOWS.bat` and `README-WINDOWS.md`. Both folders can be pasted into one folder.
- Windows can now switch its Firebase account and project by itself (Scanny for Windows > Settings > Phone sync). The phone app only shows data of the project it was built for, so choose the project that has the Scanny phone app (the list marks it).

## 1.1.4 - the build works: no more `pdf` / `image` / `archive` packages
- The first release build stopped with `The method 'decodeLazy' isn't defined for the type 'ZLibDecoder'`. Cause: the `pdf` package pulled in `image 4.11`, which needs a newer `archive` than the one Flutter's own pinned packages allow. The PDF export now uses a small built-in PDF writer (`lib/logic/pdf_lite.dart`), so those packages are gone. Checked with an independent PDF reader: valid file, correct page count, text extracts, brackets and backslashes escaped.
- PDF text uses the built-in Helvetica font: Latin characters only (Arabic names print as `?` in the PDF; the CSV export keeps them).
- Includes the 1.1.3 fix for the sample test (`MyApp`).

## 1.1.3 - the code check passes
- `flutter create` writes a sample test that refers to a class called `MyApp`, which made the wizard's code check report one error ("The name 'MyApp' isn't a class"). The app now ships its own `test/widget_test.dart`, and the wizard removes the sample test if it is still there. The rest of the code passed the real `flutter analyze` with no errors, so answering "y" to "Build anyway?" was safe.

## 1.1.2 - choose the Google account, and the one-click Authentication step
- **Google refuses to start Authentication from a program on the free plan** (error BILLING_NOT_ENABLED), so that single click stays in the browser. The wizard now says so once and opens the right page for you.
- **Choose the Google account:** a new step asks which Google account to use (Enter = keep, C = change; a browser opens to sign in). At every browser step type **A** to sign in with another Google account; the page then opens again for that account.
- **One browser visit instead of two:** "Start Authentication + turn on Google" now comes first (it includes the "Get started" click). The Email/Password provider, used only by the self-test, then switches on by itself.
- If the saved project belongs to another account, type **N** to create a NEW project with the account you are signed in with (the old one is listed as retired).

## 1.1.1 - Europe instead of Dammam, and the wizard presses "Get started" itself
- **New Firebase project in the EU (eur3).** The database region is no longer Dammam. A project saved by an older wizard is never used again: START-SCANNY-PHONE option 1 retires it (it only prints where to delete it), creates a new project and re-links everything. Your signing key, build number and member list are kept, so phones update over the old install. For the United States set `SCANNY_FIRESTORE_REGION=nam5` before running.
- **Authentication "Get started" is done for you** through Google's API, so the Email/Password and Google steps no longer stop with "Authentication has not been started yet". If Google refuses, the wizard falls back to asking you to click it once.

## 1.1.0 - one CVE, shown once
- A CVE that several sources report is shown **once**. Scanny for Windows keeps the record of the source you rank highest (Settings > Sources) and sends this phone the other sources as a small tag: "also: CISA KEV, Exploit news +1". The finding page says which source the record comes from and lists the others.

## 1.0.0 - first release
- **Sign in with Google.** Only the addresses listed under Members in Scanny for Windows can enter; anyone else sees an explanation.
- **Groups.** Each member sees the systems and findings of their own groups. Admins see every group. The list comes live from Firebase (free plan) and stays readable offline.
- **Findings.** Severity ring, exploited flag, due date, search, filters (open / solved / false positive / risk accepted), "assigned to me".
- **Status with proof.** On-going, Acknowledged, Solved, False positive. **Solved asks for the upgraded version, or the restrictive actions taken**; empty answers are refused (here, in Windows and in the Firebase security rules).
- **Assign** a finding to a member, **comments**, and the **history** of every change. Changes made here show up in Scanny for Windows within a minute.
- **Push alerts** from Scanny for Windows, with a level per group (critical only by default), and a daily or weekly summary.
- **Fingerprint / face lock** with a PIN backup, hidden in recent apps.
- **Offline:** the saved copy stays readable; changes are switched off until the connection is back.
- **Export** a group as CSV or PDF and share it.
- **Home-screen widgets:** alert counter and top findings.
- **Updates without Google Play** (Firebase Hosting + GitHub Releases), same as Dishy.
- **Setup wizard** (START-SCANNY-PHONE.bat): installs the tools, creates the free Firebase project, deploys the security rules, links Scanny for Windows automatically, builds the APK, and installs it on your phone with every permission granted.
