# GlassPlay

A native macOS music player built in Swift and SwiftUI, designed around the
macOS 26 "Liquid Glass" material. GlassPlay plays a local music library with
gapless and crossfaded playback, a 10-band EQ, EBU R128 loudness
normalization, and bit-perfect output — and it can also stream and download
from YouTube Music.

> GlassPlay requires **macOS 26 (Tahoe)** and runs on **Apple Silicon (arm64)**.

<!-- Drop screenshots here when you have them:
<p align="center">
  <img src="docs/screenshot-1.png" width="720" alt="GlassPlay Now Playing">
</p>
-->

## Features

**Playback**
- Gapless playback and adjustable crossfade via a dual `AVAudioPlayerNode` graph
- 10-band parametric EQ with presets (Rock, Pop, Hip-Hop, Jazz, Classical, …)
- EBU R128 / ITU-R BS.1770 loudness normalization (track or album mode),
  implemented from scratch in pure Swift
- Bit-perfect mode that drives the output DAC at the source file's native
  sample rate
- Shuffle and repeat (off / all / one)

**Library**
- Folder auto-import via FSEvents — drop files in and they appear
- Album grid with sort modes (name, artist, relevance, date added, most played)
- Artwork extraction, caching, and dominant-color extraction for theming
- Play counts and last-played tracking

**YouTube Music**
- Search YouTube Music (artists, albums, songs) and stream without downloading
- Browse artist profiles and albums
- Download tracks into your library
- Synced lyrics (YouTube Music, with an LRCLIB fallback)
- Optional per-song trivia via Wikipedia and a Genius token
- Auto-provisions its own tooling on first use (`yt-dlp`, `ffmpeg` via
  Homebrew; `ytmusicapi` in a private venv)

**System integration**
- Control Center / media-key Now Playing controls
- Floating always-on-top mini player
- Theme-aware Dock icon (dark/light)
- `glassplay://` URL scheme (`play`, `pause`, `next`, `previous`,
  `playlist?name=…`, `album?name=…`)
- Folder viewing for Documents, Downloads, Desktop, network & removable volumes

**Input**
- Keyboard shortcuts: `Space` play/pause, `←/→` prev/next (`Cmd` to seek),
  `↑/↓` volume (`Cmd` to jump to start/end), `M` mute, `L` loudness,
  `B` bit-perfect, `.` mini player, `Cmd+F` search, `Cmd+Shift+Z` zen mode
- Trackpad gestures on the Now Playing surface: two-finger swipe = prev/next,
  vertical = volume, pinch = artwork zoom
- Force-touch haptics

## Requirements

| | |
|---|---|
| OS | macOS 26 (Tahoe) |
| Arch | Apple Silicon (arm64) |
| Build | Swift 6 toolchain (`swiftc`) |

Optional (only needed for YouTube Music features — installed automatically on
first use if Homebrew is present):

```sh
brew install yt-dlp ffmpeg
```

## Build

There is no Xcode project or SwiftPM manifest — the whole app is compiled with
a single `swiftc` invocation and assembled into an `.app` bundle by
[`build.sh`](build.sh):

```sh
./build.sh
open GlassPlay.app
```

`build.sh` compiles `src/*.swift` with optimizations, stages the binary and
resources into `GlassPlay.app/Contents/`, and ad-hoc signs the bundle.

## Supported audio formats

MP3, M4A, M4B, M4R, AAC, ADTS, FLAC, ALAC, WAV, AIFF, AIFC, CAF, MP2, AU, SND,
AC3, EAC3, AMR, Opus, OGA, OGG, WMA, APE, WavPack, MKA, DSF — plus any UTType
conforming to `public.audio`.

## Architecture

GlassPlay is a single-target app with no third-party Swift dependencies. The
source lives in [`src/`](src):

| File | Responsibility |
|------|----------------|
| `App.swift` | `@main` entry point, `AppDelegate`, Dock icon theming |
| `Models.swift` | Data model — `Track`, `Playlist`, `Album`, `Library`; JSON persistence, artwork cache, loudness gains, dominant-color extraction |
| `Player.swift` | `AVAudioEngine` playback graph: gapless/crossfade, EQ, loudness, bit-perfect, streaming, queue |
| `YouTube.swift` | YouTube Music integration via `ytmusicapi` + `yt-dlp`/`ffmpeg`; search, stream, download, lyrics, trivia |
| `Settings.swift` | `UserDefaults`-backed settings: glass style, EQ, loudness, bit-perfect, sorts |
| `Views.swift` | The SwiftUI view layer |
| `NowPlaying.swift` | `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` bridge (media keys, Control Center) |
| `MiniPlayer.swift` | Floating, always-on-top `NSPanel` mini player |
| `Input.swift` | Global keyboard shortcuts and trackpad gestures |
| `FolderWatcher.swift` | FSEvents-based folder auto-import |
| `Metadata.swift` | Technical audio info (codec, sample rate, bit depth) and MPEG-4 tag writing |
| `Loudness.swift` | EBU R128 analyzer (K-weighting biquads) |
| `BitPerfect.swift` | CoreAudio DAC sample-rate control |
| `tools/gen_icon.swift` | Utility that generates the macOS 26-style app icon |

## Privacy

GlassPlay stores your library index as JSON, artwork files, and a Python venv
under `~/Library/Application Support/GlassPlay/`; settings live in
`UserDefaults`. `NSAppTransportSecurity` allows arbitrary loads because YouTube
streams are served over dynamically resolved hosts; no telemetry is collected.

## License

Licensed under the [Apache License 2.0](LICENSE).
