# Whispertype

A native macOS menu bar app that transcribes your voice and types it into any focused application. Powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — all processing happens locally on your Mac, no data leaves your device.

## Features

- **Menu bar app** — runs quietly in your menu bar, no dock icon
- **Global hotkey** — press `Cmd+Shift+V` to start/stop recording from anywhere
- **Local transcription** — uses whisper.cpp with the `large-v3-turbo` model, no internet required after initial download
- **Multilingual** — auto-detects language (Vietnamese, English, etc.)
- **Types into any app** — simulates keyboard input into whatever app is focused
- **Apple Silicon optimized** — Metal GPU, Accelerate (AMX), native ARM features
- **Voice commands**:
  - `enter` — press Return key
  - `xuống dòng` — press Option+Return (new line without sending, e.g. in chat apps)
  - `tab` — press Tab key
  - `xoá` — delete the text typed since last command

## Requirements

- macOS 12.0+
- Apple Silicon (M1/M2/M3/M4)
- ~1.6 GB disk space for the Whisper model (downloaded automatically on first launch)

## Build

```bash
git clone --recursive https://github.com/user/whispertype.git
cd whispertype
./build.sh
```

The build script compiles with Release optimizations for arm64. Output: `build-release/Whispertype.app`

### Dependencies

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — included as a subdirectory (expected at `../VisionGuardAI/external/whisper.cpp`)
- CMake 3.16+
- Xcode Command Line Tools

## Install

After building, copy the app to Applications:

```bash
cp -r build-release/Whispertype.app /Applications/
```

Or simply double-click `Whispertype.app` to run from any location.

## Permissions

On first launch, macOS will ask for:

1. **Microphone access** — for recording your voice
2. **Accessibility access** — for typing into other apps and the global hotkey

## How It Works

1. Press `Cmd+Shift+V` — the menu bar icon changes to indicate recording
2. Speak naturally in any language
3. Press `Cmd+Shift+V` again to stop (or wait 30s for auto-stop)
4. Whisper transcribes your speech locally
5. The transcribed text is typed into whatever app is focused

## Architecture

Pure native macOS — no Electron, no Qt, no web views.

- **Language**: Objective-C++ (.mm)
- **Audio capture**: AVFoundation (AVAudioRecorder)
- **Transcription**: whisper.cpp (local, on-device)
- **Text input**: CGEvent keyboard simulation
- **UI**: NSStatusItem (menu bar) with SF Symbols
- **Concurrency**: GCD (Grand Central Dispatch)
- **Model**: `ggml-large-v3-turbo.bin` (~1.6 GB, auto-downloaded to `~/Library/Application Support/TQT/Whispertype/`)

## License

MIT
