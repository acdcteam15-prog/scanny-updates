# Scanny high availability (several PCs, one main)

Run Scanny on up to **three PCs** (different sites are fine: they only need the internet). One PC is the **main**: it scans, sends the alerts, syncs with the phones and answers Ask AI. The others are **standbys**: they keep an exact, encrypted copy of everything and stay silent. When the main cannot serve the phones, the best standby takes over by itself.

## How it decides
* The PCs share your Firebase project. A **lease** document says who the main is. The main renews it every minute (it writes with the server's own clock, so the clocks of the PCs do not matter).
* **Takeover:** if the lease is not renewed for **5 minutes** (the main lost the internet, crashed, was switched off), the **best-priority standby that is alive** takes over. Priority 1 is the preferred PC. PC 3 does not take over while PC 2 is alive.
* **A main without internet steps back by itself** after about 4 minutes, so it can never act as a second main when its internet returns.
* **Failback:** when the preferred PC is back and has been **healthy for 30 minutes**, the current main makes a last copy of the data, hands the job over, and becomes a standby again. Nothing is lost.
* The five and thirty minutes can be changed in Settings > High availability.

## What is copied (and what is not)
Systems, findings, comments, history, alert log, the audit log and your settings (including the AI keys, SMTP, Telegram...) are copied through Firebase, **encrypted on the PC with a cluster key** that never goes to Firebase in readable form. Not copied, because they belong to one PC: the WhatsApp link and its message queue, the proxy, backup settings, the update key, the master password, and each PC's own health state.

## Alerts after a failover
Telegram, e-mail, desktop notifications and the phone push work from whichever PC is the main. **WhatsApp stays on the PC where it is linked** and is only sent while that PC is the main (the official WhatsApp Cloud API method works from any PC because it needs no link).

## Set it up
1. **PC 1** (your current Scanny): Settings > High availability > give it a name > **Turn on high availability**. It becomes the main and starts copying.
2. On PC 1 press **Make a join file for another PC**, choose a passphrase (8 characters or more) and save the file. It contains the Firebase key, protected by the passphrase. Copy it to the other PC (USB, e-mail...).
3. **PC 2 and PC 3:** install Scanny (`Scanny-Windows_1.13.0.zip`, then `START-SCANNY-WINDOWS.bat`), create its master password as usual, sign in, open Settings > High availability > **Join an existing cluster**, choose the file, type the passphrase, give the PC a name and its priority (2 or 3). It copies everything and becomes a standby.
4. Check Settings > High availability on any PC: it lists the PCs, who is the main and how long each has been healthy. A pill in the top bar shows **Main** or **Standby**.

## Good to know
* A **standby is read-only**: its window shows a banner and refuses changes (make them on the main). It can still be updated, restarted, and WhatsApp can still be linked on it.
* **Changes made on a PC after it lost the main role are discarded** when it copies the main's data (they were refused anyway).
* After a takeover the new main runs a **first scan**; its CVE cache may be cold, so the first scan can take longer. Findings, statuses and the phones' data are already there.
* A main that loses **only** the connection to Firebase (but not the rest of the internet) also steps back: serving the phones needs Firebase.
* Up to a minute can pass between a lease change and the old main noticing; in that minute both may send an alert.
* **Firebase free quota:** each PC reads about 7,000 times a day for this (the free plan has 50,000 reads a day for everything). Writes: about 3,000 a day on the main.
* Keep the PCs' clocks on automatic time anyway; Windows time sync is on by default.
* **Leave the cluster** turns it off on one PC (it keeps its data and works alone again). If it was the main, it steps down first and the next PC takes over. If it was the **last PC**, the cluster is deleted from Firebase too, so nothing is left behind.
* **A PC that is off or lost** (for example a dead main) can be taken out by another PC: its row on Settings > High availability shows **Remove** once it has been off for 5 minutes. If it was the main, the job is free at once. If that PC ever starts again it sees that it was removed and works on its own. A PC that is online cannot be removed from elsewhere: press Leave on it.
* **Delete the cluster** (any PC, and also from a PC that is not in the cluster, to clear a leftover): type DELETE. The other PCs are told first and drop out by themselves, then the lease, the list of PCs and the encrypted copy of the data are removed from Firebase (about two minutes). Every PC keeps its own data and works on its own. The phones are not affected. Nobody can join while a cluster is being deleted.
* **Copy a report** puts the state of the cluster (PCs, roles, health, last copies, problems; no keys or passwords) on the clipboard, for support.
* If Settings > High availability shows "There is already a cluster in this Firebase project", the PCs of an older cluster went away without cleaning up. Join it with a join file, or delete it there.

## Buttons
**Remove** (a PC that is off), **Delete the cluster**, **Copy a report**, **Make this PC the main now** (a deliberate switch, even while the main is fine), **Step down** (maintenance: the next best PC takes over; this PC does not take the job back for 3 minutes), **Make a join file**, **Check now**, **Leave the cluster**.
