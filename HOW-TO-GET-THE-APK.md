# Getting the APK without installing anything

> ### Read this first — fixing the "two apps" problem
>
> The build you installed showed up as a **separate app** instead of updating the
> original. That was a bug in the workflow: it set the package id to
> `com.aditya.workout_tracker`, while your locally built app is
> `com.example.workout_tracker`. Android treats a different package id as a
> different app entirely, no matter how it's signed — so it installed alongside
> rather than on top.
>
> It's fixed in this version. Follow the four steps in **Migrating your data**
> below and your history comes back without any exporting or importing.

### What's new in 2.4.0

- **Colour themes.** Settings → Appearance has eight: Ocean (the original),
  Lagoon, Forest, Sunset, Ember, Rose, Violet and Graphite. There's also a
  *Vivid colours* switch, and *Pure black dark mode* for OLED screens.
- **Tidier time entry.** A time like `8:88` is read as 9:28, and the box now
  shows `9:28` as soon as you leave it or tick the set.
- **Fixes**
  - Changing an exercise's type in the routine while that day's workout was
    open made its sets impossible to tick. Open workouts now follow the
    routine's current name and type.
  - Restored backups and CSV imports showed each workout's exercises
    interleaved in History (Row, Plank, Row, Plank…). They're grouped again.
  - Charts for an exercise whose tracking type changed only showed the old
    type's data.
  - A failed import left its button stuck with no message.
  - Export and Import in Settings gave no tap feedback.
  - Switching days while the app was reloading in the background could show
    the wrong day's workout.

### What's new in 2.3.0

- **Add an exercise for today only.** On the Today tab, *Add exercise for
  today* (below the last exercise) puts something like Bench Press into a
  Back day without changing your routine. It's tagged *Added today*, pre-fills
  from the last time you did it, and every set you tick counts towards its
  history and chart like any other exercise.
- **Times are min:sec.** Holds, cardio time, pace and the charts all read as
  `1:30` instead of `90` seconds. Type the digits and the colon fills itself
  in: 1, 3, 0 gives `1:30`.
- **Rest between sets.** Between two sets of the same exercise the app shows
  how long you rested — from ticking one set to ticking the next, whatever you
  did in between (supersets included). Until you tick the next set you see
  last time's rest, greyed like last time's weights.
- Your data upgrades in place on first launch; nothing to export or re-import.

### What's new in 2.2.0

- **Import history** (Settings → Import history). Restore a backup this app
  exported, or bring in older workouts from a CSV — useful for training you
  logged in a spreadsheet before you had the app. There's a copyable CSV
  template and an LLM prompt in there for converting a messy log.
- **Reps tracking type** (from 2.1.0) for bodyweight work — a single count box,
  no weight field. Its chart toggles between *Best set* and *Total*.
- The app still requests **zero Android permissions**. The file picker uses
  Android's document picker, which needs none, and the build explicitly strips
  any storage permission its dependencies try to add. The build log prints the
  final permission list so you can check.

---

## Migrating your data

You currently have two installs, both called "Workout Tracker". Do this in
order — it takes a couple of minutes and has a safety net at step 1.

**1. Export from the app that has your history.**
Open each one and look at the History tab. The one with your workouts in it is
the original. In that app: **Settings → Export history**, and share the file to
Google Drive or email it to yourself.

> This is your backup. If anything below goes sideways, you can install the new
> app fresh and pull everything back in with **Settings → Import history**.

**2. Uninstall the empty one.**
That's the other app — the one whose History tab is blank. Do this *now*, while
the two are still easy to tell apart. (Long-press its icon → App info →
Uninstall.) Nothing is lost; it never had any data.

**3. Install the new APK** built from this version, following *Getting your APK*
below. Because the package id and the signing key now both match your original
app, Android installs it **over** the original and the database stays exactly
where it is.

**4. Check the History tab.** Your workouts should all be there. If they aren't,
you still have the backup from step 1 — import it and nothing is lost.

---

GitHub builds the app for you on their machines and hands you the finished
`.apk`. You never install Flutter, Android Studio, or Java. Everything below
happens in a web browser.

**Time:** about 10 minutes the first time, then ~5 minutes of waiting per build.
**Cost:** free.

---

## One-time setup

### 1. Make a GitHub account

<https://github.com/signup> — free, email and password.

### 2. Create a private repository

1. Go to <https://github.com/new>
2. **Repository name:** `workout-tracker`
3. Select **Private**. This matters: the app signing key lives in the repo, and
   a private repo is what keeps it yours.
4. Leave everything else alone, click **Create repository**.

### 3. Upload the project

On the empty repo page, click **uploading an existing file**.

Unzip the folder I sent you, then **drag all of its contents** into the browser
window — the `lib` folder, the `.github` folder, the `signing` folder, the
`assets` folder, `pubspec.yaml`, and the rest. Drag the *contents*, not the
folder itself.

> If the `.github` folder doesn't appear in your file explorer, it's hidden.
> In Windows Explorer: **View → Show → Hidden items**.

**One thing to add first:** copy your app icon from
`C:\dev\workout_tracker\assets\icon\icon.png` into the `assets\icon\`
folder of the unzipped project, replacing the placeholder text file in there.
I couldn't include it because it wasn't in what you sent. Without it the build
still works — the app just gets Flutter's default icon back.

Scroll down, click **Commit changes**.

### 4. That's it — the build starts on its own

Uploading counts as a push, so the build kicks off immediately.

---

## Getting your APK

1. Click the **Actions** tab at the top of your repo.
2. Click the run at the top of the list. A yellow dot means it's still going, a
   green tick means it's done. It takes about 5 minutes.
3. When it's green, scroll to the bottom of that page to **Artifacts**.
4. Click **workout-tracker-apk** to download it.

You get a `.zip`. Unzip it and you'll find `workout-tracker-<date>.apk` inside.

### Installing it on your phone

Easiest route: download the zip on your PC, unzip, then copy the `.apk` to your
phone over USB (or email it to yourself / drop it in Google Drive). Open the
file on the phone and tap install.

The first time, Android will warn about installing from an unknown source — tap
through to allow it for whichever app you opened the file with. Play Protect may
also want a "Install anyway" confirmation. Both are expected for an app that
isn't from the Play Store.

---

## Updating a repo you already made

If the repo exists from last time, you don't need a new one. Go to the repo →
**Add file → Upload files** and drag the whole unzipped folder's contents in
again. Same-named files are replaced, new ones are added, and nothing needs
deleting. Commit, and the build starts by itself.

Note that `.github/workflows/build-apk.yml` changed in this version — that file
is where the package-id fix lives, so it has to be re-uploaded too, not just
`lib/`.

## Making changes later

Edit any file directly on GitHub (click the file → the pencil icon → **Commit
changes**), or ask me for an updated `lib` folder and re-upload it. Every change
triggers a fresh build automatically; grab the new APK from the Actions tab.

**Your workout data survives updates.** Every APK built here is signed with the
same debug key and carries the same package id as the app on your phone, so
Android accepts each build as a genuine update and installs it over the top
without touching the database.

**Uninstalling is still the one thing that deletes your history** — so don't do
it to "start clean". If you ever have to, export first (Settings → Export
history) and pull it back in afterwards with Settings → Import history. Worth
exporting every month or so regardless; it's the only backup that exists.

---

## Notes

- **Keep the repo private.** `signing/debug.keystore` is the Android debug key
  copied from your PC — the same one that signed the APK already on your phone,
  which is what lets builds from here install as updates rather than forcing an
  uninstall. It's a development key with a standard, publicly known password
  (`android`), not a credential to any account, so a private repo is a fine
  home for it. If you ever publish to the Play Store you'd generate a proper
  release key instead and keep that one out of the repo.
- **Only `lib/` and `pubspec.yaml` are the app.** The `android/` folder is
  generated fresh on every build, which is why it isn't in the repo — it can
  never drift out of sync with the Flutter version building it.
- **Don't change `--org com.example` in the workflow.** That string is the
  package id, and it has to keep matching the app on your phone. Changing it is
  what caused the second app to appear.
- **The build log is the receipt.** Near the end of a run, the *Report package id
  and permissions* step prints the package it built (should be
  `com.example.workout_tracker`) and every permission in the finished APK
  (should be none). Worth a glance on the first run.
- **Build failed (red X)?** Click the run, then the failed step, and send me the
  red error text. That output is exactly what I need to fix it.
