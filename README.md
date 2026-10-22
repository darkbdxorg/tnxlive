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
