# TNxLive — 24/7 Loop Live Streaming (Phone-Only)

TNxLive is a phone-only live streaming app: pick one or more videos, add your
stream keys, press **START LIVE** — the playlist loops forever and streams
simultaneously to YouTube, Facebook and any custom RTMP destination
(including TikTok) straight from your Android phone.

- Package: `com.tnxlive.app`
- Stack: Flutter + FFmpegKit (GPL build with libx264) + foreground service
- No account, no Firebase, no server. Stream keys are stored **only on your
  device** (SharedPreferences) and are never sent anywhere except the
  streaming platforms themselves.

## Features

- **Playlist loop** — add multiple videos; they play back-to-back in an
  endless loop (`ffmpeg -stream_loop -1` with a concat list).
- **Multistream** — YouTube + Facebook + Custom RTMP at the same time
  (FFmpeg `tee` muxer, `onfail=ignore` so one bad destination doesn't kill
  the others).
- **Destinations**
  - YouTube: preset server `rtmp://a.rtmp.youtube.com/live2/` + stream key
  - Facebook: preset server `rtmp://live-api-s.facebook.com:443/rtmp/` + stream key
  - TikTok / Custom: paste the full combined RTMP URL
- **Quality** — 480p (~1200 kbps), 720p (~2500 kbps, recommended),
  1080p (~4500 kbps).
- **Modes** — *Re-encode* (libx264, works with any source video) or
  *Copy / Fast* (no re-encode, low CPU/battery, source must already be
  H.264 + AAC).
- **Foreground service + wakelock** — stream keeps running with the screen
  off; persistent notification shows LIVE duration. Battery-optimisation
  exemption is requested on first start.
- **Live log + stats** — scrolling FFmpeg log (last ~100 lines), running
  duration timer, bitrate / FPS / speed / data-sent readouts.
- **In-app guide** — where to find each platform's stream key (in Banglish).

## New in v1.1

- **Profiles (up to 5)** — save a full setup per channel: YouTube / Facebook /
  TikTok keys + on/off toggles + quality + mode. Switch profiles from the
  chips above *Destinations*; editing any field auto-saves back into the
  active profile. Profiles are stored as JSON in SharedPreferences on the
  device only, and keys are never written to the Live Log. v1.0's saved keys
  migrate automatically into "Profile 1".
- **Schedule — Auto Live** — set a daily start and stop time; the app starts
  the stream by itself and stops it at the stop time. Overnight windows
  (e.g. 22:00 → 06:00) work, and arming the schedule while already inside
  the window starts the stream immediately. Mechanism: while armed, the
  foreground service stays running in "Schedule ON" mode and an in-app
  timer checks the clock every ~20 seconds; the notification shows the
  next start/stop times. If a scheduled stream fails 3 times in the same
  window, the schedule turns itself off and sends an alert instead of
  retry-looping. Manually stopping a schedule-started stream suppresses
  auto-start for the rest of that window. **Caveat: if you force-stop the
  app (or the system kills it despite the notification), the schedule
  cannot fire** — Android gives no reliable way to wake a force-stopped app
  to run FFmpeg; reopening the app re-arms a saved schedule automatically.
- **Battery guard** — while LIVE, the battery is checked every 30 seconds
  (`battery_plus`). If it falls to the chosen threshold (10% / 15% / 20%,
  default 15%) while not charging, you get **one** notification
  (`flutter_local_notifications`), a Live Log entry and an on-screen banner
  per crossing — no spam. The guard re-arms after charging back above
  threshold + 5, or on the next live session. Starting a live session
  already below the threshold warns immediately.

## New in v1.3

- **Auto-reconnect** — a "live intent" model: while the app is supposed to
  be live, an FFmpeg session that ends or fails *unexpectedly* (network
  drop, encoder error) is restarted automatically with exponential backoff —
  10s, 20s, 40s, then capped at 60s between attempts. The status card shows
  "RECONNECTING — Reconnecting in Xs (attempt N)" and the Live Log records
  the drop, the countdown and the outcome. A deliberate stop (in-app STOP,
  the notification Stop button, or the schedule window end) clears the
  intent and never reconnects. A schedule-started stream that drops
  mid-window reconnects like any other, still stops at the window end, and
  its failed attempts count toward the v1.1 rule: 3 consecutive failures in
  one window disarm the schedule with an alert. Toggle it in *Stream
  Settings → Auto-reconnect* (default ON; persisted). **Note:** a reconnect
  starts a brand-new FFmpeg session, so **the playlist restarts from the
  beginning**. The on-screen duration keeps counting from the original
  session start (including reconnect gaps), while Sent / Bitrate / FPS /
  Speed are per-attempt and restart from zero, because they are read from
  the current FFmpeg session.
- **Stream-down alert** — an unexpected drop fires **one** loud notification
  per incident on a dedicated max-importance channel (`⚠ Live theme geche!`,
  sound + vibration): the body says auto-reconnect is trying, or that the
  stream has stopped (reconnect OFF), or that the schedule gave up. When a
  reconnect succeeds, a quiet follow-up (`Live abar chalu hoiche`, normal
  importance) fires once. Every alert is also written to the Live Log.
- **Notification controls** — the persistent foreground-service notification
  now carries action buttons: **Stop** while LIVE (stops exactly like the
  in-app STOP — clears intent, no reconnect) and **Cancel** while the
  schedule is armed but not live (disarms the schedule). Tapping the
  notification body still opens the app. Implemented with
  flutter_foreground_task `NotificationButton`s; the task handler forwards
  presses to the main isolate (`sendDataToMain` → `addTaskDataCallback`),
  which runs the normal stop/disarm code paths. The battery-guard
  notifications are unchanged.

## New in v1.2

- **Bottom navigation** — the old single long scrolling screen is split into
  four tabs: **Live** (status/stats, playlist, destinations, stream settings,
  START/STOP, live log), **Profiles** (profile management), **Auto**
  (schedule + battery guard) and **Guide**. Tab state is kept alive
  (`IndexedStack`), so a running stream, the log and all timers survive tab
  switches; a red dot on the Live tab shows when a stream is running.

## How to get stream keys

- **YouTube**: YouTube Studio → Create → Go Live → Stream → copy the stream
  key. Your channel must have live streaming enabled (first-time activation
  can take ~24 hours). The key is persistent and reusable.
- **Facebook**: From your Page's Live dashboard choose "Use stream key" and
  enable **Persistent stream key** so it doesn't change every session.
- **TikTok**: You need 1000+ followers and to be 18+. TikTok gives a **new
  server URL + key for every session** (via LIVE Studio / "Stream to PC") —
  paste the full combined RTMP URL into the Custom field right before going
  live. Old keys will not work.

## Honest limits

- This is **phone-only**: the phone must stay **on, charging and online**
  for the whole stream. If the phone dies, loses network, or the app is
  swiped away from Recents, the stream stops. True server-side 24/7
  (phone off) needs a VPS — a different setup.
- 1080p re-encoding is heavy for a phone CPU; the phone may get warm.
  720p is the sweet spot.
- Stream only content you own the rights to. Looping movies, songs or TV
  content will get copyright strikes from YouTube/Facebook.
- Streaming pushes a lot of data (~1.1 GB/hour at 720p per destination
  set — multistreaming from the phone sends one combined feed). Watch your
  data plan; Wi-Fi is strongly recommended.

## Build

```bash
cd app
flutter pub get
flutter build apk --release
```

Or push to GitHub and let the included workflow
(`.github/workflows/build-apk.yml`, Flutter 3.35.6, JDK 17) build the APK.

## License note

The FFmpeg build used (`ffmpeg_kit_flutter_new_gpl`) includes GPL
components (x264 etc.), so TNxLive is distributed under GPL-compatible
terms. FFmpeg and its libraries keep their own licenses.
