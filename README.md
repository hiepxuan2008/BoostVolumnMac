# BoostVolume

A tiny macOS menu bar app that makes system audio louder than the built-in 100% limit — up to 400%, with a limiter so loud audio doesn't clip.

It uses Core Audio process taps (macOS 14.4+): all system audio is captured and muted, boosted, and played to your output device. No audio driver to install.

## Requirements

- macOS 14.4 or later
- Xcode / Swift 6 toolchain to build

## Build & run

```bash
./scripts/build-app.sh
open build/BoostVolume.app
```

Run the tests with `swift test`.

## Using it

Click the speaker icon in the menu bar:

- **Boost** — turn boosting on/off.
- **Slider** — 100%–400%.
- **Output** — "System Default" follows your Mac's output (e.g. switches to headphones when plugged in), or pick a specific device.
- **Launch at login**.

The first time you turn Boost on, macOS asks for **System Audio Recording** permission. If you hear nothing while boosting, allow BoostVolume in System Settings › Privacy & Security › Screen & System Audio Recording (the menu has an "Open Settings" button).

## Signing

`build-app.sh` signs the app ad-hoc by default, which means macOS may ask for the audio permission again after every rebuild. To avoid that, sign with your own identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

## Notes

- Capture-and-replay adds roughly 10–20 ms of latency.
- If another audio enhancer (e.g. a virtual audio device) is your default output, BoostVolume boosts into that device; for the cleanest result pick your real speakers/headphones in the Output menu.
