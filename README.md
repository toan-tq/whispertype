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

## Build

```bash
git clone --recursive https://github.com/toan-tq/whispertype.git
cd whispertype
./build.sh
```

The build script compiles with Release optimizations for arm64. Output: `build-release/Whispertype.app`

### Dependencies

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — git submodule at `external/whisper.cpp`
- CMake 3.16+
- Xcode Command Line Tools

## Install

After building, copy the app to Applications:

```bash
cp -r build-release/Whispertype.app /Applications/
```

## Permissions

On first launch, macOS will ask for:

1. **Microphone access** — for recording your voice
2. **Accessibility access** — for typing into other apps and the global hotkey

## How It Works

1. Press `⌥ Space` — the menu bar icon changes to indicate recording
2. Speak naturally (Vietnamese or other languages)
3. Press `⌥ Space` again to stop (or wait 30s for auto-stop)
4. Groq transcribes your speech in the cloud
5. The transcribed text is typed into whatever app is focused

If Groq is rate-limited or returns a network error, the app automatically falls back to the local Whisper model (if enabled). Transcription requests are serialized so back-to-back recordings always type in the correct order.

## Architecture

Pure native macOS — no Electron, no Qt, no web views.

- **Language**: Objective-C++ (.mm)
- **Audio capture**: AVFoundation (`AVAudioRecorder`, 16kHz mono WAV)
- **Primary transcription**: Groq API (`whisper-large-v3`, cloud)
- **Fallback transcription**: whisper.cpp (local, on-device)
- **Text input**: CGEvent keyboard simulation
- **UI**: NSStatusItem (menu bar) with SF Symbols
- **Concurrency**: GCD (Grand Central Dispatch), serialized transcription queue
- **Local model**: `ggml-large-v3-turbo.bin` (~1.6 GB, auto-downloaded to `~/Library/Application Support/TQT/Whispertype/`)

## License

MIT
