# Whispertype

A native macOS menu bar app that transcribes your voice and types it into any focused application. Uses the [Groq API](https://groq.com) for fast cloud transcription, with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) as a local fallback.

## Features

- **Menu bar app** — runs quietly in your menu bar, no dock icon
- **Global hotkey** — press `⌥ Space` (Option+Space) to start/stop recording from anywhere
- **Groq cloud transcription** — fast, accurate transcription via Groq's Whisper API
- **Local fallback** — optional whisper.cpp fallback when Groq is rate-limited or unavailable
- **Vietnamese-first** — tuned for Vietnamese (`vi`), works with other languages too
- **Types into any app** — simulates keyboard input into whatever app is focused
- **Apple Silicon optimized** — Metal GPU, Accelerate (AMX), native ARM features
- **Visible progress** — the menu shows "Uploading 43% · 12s" / "Waiting for Groq · 3s" instead of a silent wait
- **Nothing lost** — a recording that could not be transcribed is kept under `failed/` (see menu → Show Failed Recordings)
- **Voice commands**:
  - `enter` — press Return key
  - `xuống dòng` / `new line` — press Option+Return (new line without sending, e.g. in chat apps)
  - `tab` — press Tab key
  - `xoá` / `delete` — delete the text typed since last command

## Requirements

- macOS 12.0+
- Apple Silicon (M1/M2/M3/M4)
- A [Groq API key](https://console.groq.com) (free tier available)
- ~1.6 GB disk space if using local model (downloaded automatically on first launch)

## Setup

### 1. Set your Groq API key

```bash
defaults write com.tqt.whispertype GroqAPIKey "gsk_YOUR_KEY_HERE"
```

The app reads this key from `NSUserDefaults` on launch. Without it, the app stays in "Initializing" state and you'll see "Set Groq API key first" when pressing the hotkey.

### 2. (Optional) Enable local model fallback

```bash
defaults write com.tqt.whispertype LocalModelEnabled -bool true
```

Or toggle it in the menu bar menu. When enabled, the app downloads `ggml-large-v3-turbo.bin` (~1.6 GB) to `~/Library/Application Support/TQT/Whispertype/` on first use.

### 3. (Optional) Tune recording

```bash
# Auto-stop cap in seconds (default 30, range 5–600)
defaults write com.tqt.whispertype MaxRecordingSeconds -int 60

# Recording format sent to Groq: wav (default, best transcript quality), flac or aac
# (smaller uploads, but both measured worse on Vietnamese; opt-in only)
defaults write com.tqt.whispertype RecordingFormat -string wav
```

## Build

```bash
git clone --recursive https://github.com/toan-tq/whispertype.git
cd whispertype
./build.sh
```

The build script compiles with Release optimizations for arm64 in `build-release/`, then installs the app (see below). `./build.sh --no-install` only builds and leaves `build-release/Whispertype.app` in place.

### Dependencies

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — git submodule at `external/whisper.cpp`
- CMake 3.16+
- Xcode Command Line Tools

## Install

`./build.sh` installs by default: it quits the running Whispertype, replaces
`/Applications/Whispertype.app` with the freshly built bundle (moved, not copied, so no
second copy is left in `build-release/`), registers it with LaunchServices and relaunches it.

Keeping a single copy matters: two bundles with the id `com.tqt.whispertype` both show up
in Spotlight, and LaunchServices may start the build copy, whose ad-hoc signature does not
match the permissions granted to the installed one. Don't install with `cp -r` over an
existing bundle either — it overwrites the signed binary in place and leaves stale files.

### Permissions survive rebuilds only with a stable signing identity

The default build is ad-hoc signed (`codesign --sign -`). macOS ties the Accessibility
and Microphone grants to the exact code hash, so **every rebuild is a new app** to the
system: the grants stop applying silently and the hotkey never registers. After a
rebuild, reset and re-grant:

```bash
tccutil reset Accessibility com.tqt.whispertype
tccutil reset Microphone com.tqt.whispertype
open /Applications/Whispertype.app   # then allow in System Settings → Privacy & Security
```

To keep grants across builds, sign with a certificate that does not change, e.g. a
self-signed "Code Signing" certificate created in Keychain Access:

```bash
CODESIGN_IDENTITY="Whispertype Dev" ./build.sh
```

## Permissions

On first launch, macOS will ask for:

1. **Microphone access** — for recording your voice
2. **Accessibility access** — for typing into other apps and the global hotkey

## How It Works

1. Press `⌥ Space` — the menu bar icon changes to indicate recording
2. Speak naturally (Vietnamese or other languages)
3. Press `⌥ Space` again to stop (or wait for the auto-stop cap, 30 s by default)
4. The recording (WAV, 16 kHz mono) is uploaded to Groq; the menu shows upload
   progress and elapsed time
5. The transcribed text is typed into whatever app is focused

Each Groq request is bounded: 20 s without any progress or 45 s in total counts as a
failure, and the request is retried once after 2 s. If it still fails and the local
model is enabled, the app falls back to it; otherwise the audio is moved to
`~/Library/Caches/com.tqt.whispertype/failed/`, the menu shows "Last error: …", and
the app beeps. Failed recordings are purged after 7 days.

Transcription requests are serialized so back-to-back recordings always type in the
correct order.

## Architecture

Pure native macOS — no Electron, no Qt, no web views.

- **Language**: Objective-C++ (.mm)
- **Audio capture**: AVFoundation (`AVAudioRecorder`, 16 kHz mono WAV by default)
- **Primary transcription**: Groq API (`whisper-large-v3`, cloud) with upload progress,
  explicit timeouts and one retry
- **Fallback transcription**: whisper.cpp (local, on-device)
- **Text input**: CGEvent keyboard simulation
- **UI**: NSStatusItem (menu bar) with SF Symbols
- **Concurrency**: GCD (Grand Central Dispatch), serialized transcription queue
- **Local model**: `ggml-large-v3-turbo.bin` (~1.6 GB, auto-downloaded to `~/Library/Application Support/TQT/Whispertype/`)

## License

MIT
