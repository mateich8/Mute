# Mute

A native macOS music player built in Swift and SwiftUI, designed around the
macOS 26 "Liquid Glass" material. Mute plays a local music library with
gapless and crossfaded playback, a 10-band EQ, EBU R128 loudness
normalization, and bit-perfect output — and it can also stream and download
from YouTube Music.

> Mute requires **macOS 26 (Tahoe)** and runs on **Apple Silicon (arm64)**.

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
- `mute://` URL scheme (`play`, `pause`, `next`, `previous`,
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
| Build | Swift 6 toolchain (`swiftc`) — Command Line Tools with the macOS 26.5 SDK, or Xcode |

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
open Mute.app
```

`build.sh` compiles `src/*.swift` with optimizations, stages the binary and
resources into `Mute.app/Contents/`, and ad-hoc signs the bundle.

Prefer a prebuilt copy? Grab `Mute.app.zip` from the
[latest release](../../releases/latest) — every release is built fresh by CI
on an Apple-Silicon macOS 26 runner.

## Screenshots

Screenshots live in `docs/`. To capture one, use the included helper — it
captures the frontmost window and drops it into `docs/`:

```sh
./tools/capture-screenshots.sh --open   # launch Mute, then capture a window
./tools/capture-screenshots.sh --screen # capture the whole screen instead
```

## Supported audio formats

MP3, M4A, M4B, M4R, AAC, ADTS, FLAC, ALAC, WAV, AIFF, AIFC, CAF, MP2, AU, SND,
AC3, EAC3, AMR, Opus, OGA, OGG, WMA, APE, WavPack, MKA, DSF — plus any UTType
conforming to `public.audio`.

## Architecture

Mute is a single-target app with no third-party Swift dependencies. The
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

Mute stores your library index as JSON, artwork files, and a Python venv
under `~/Library/Application Support/Mute/`; settings live in
`UserDefaults`. `NSAppTransportSecurity` allows arbitrary loads because YouTube
streams are served over dynamically resolved hosts; no telemetry is collected.

## Continuous integration & releases

- **[Build workflow](.github/workflows/build.yml)** — compiles the app with
  `./build.sh` on every push and PR (on an Apple-Silicon `macos-26` runner) and
  uploads the bundle as a CI artifact.
- **[Release workflow](.github/workflows/release.yml)** — builds and publishes a
  GitHub Release with `Mute.app.zip` whenever you push a `v*` tag:

  ```sh
  git tag v1.0
  git push origin v1.0
  ```

## License

Licensed under the [Apache License 2.0](LICENSE).
