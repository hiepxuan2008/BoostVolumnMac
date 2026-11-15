# Volume Booster — Design

Date: 2026-11-15
Status: Approved

## Intent

A simple native macOS app that makes system audio louder than the built-in 100% volume limit — a stripped-down take on Boom 3D, keeping only the volume boost.

## Goals

- Boost all system audio from 100% up to 400% (≈ +12 dB) with a single slider.
- Sound clean when boosted: a limiter prevents harsh digital clipping.
- No driver install, no admin password — only the macOS "System Audio Recording" permission.
- Stay out of the way: menu bar only, no Dock icon.

## Non-goals

EQ, balance, stereo width, night mode, per-app volume, a virtual audio driver, App Store distribution. All can come later.

## Anti-goals

- Audible distortion or crackling at high boost (the limiter and glitch-free audio thread are core, not polish).
- Audio dropping out or being left muted when the app quits, crashes, or the output device changes.

## Constraints

- macOS 14.4+ (Core Audio process taps). Developer machine: macOS 26.5, Xcode 26.3.
- Swift + SwiftUI.
- Capture-and-replay adds ~10–20 ms of latency; accepted.

## Approaches considered

1. **Core Audio process tap (chosen).** Tap all system audio with `CATapDescription` (excluding our own process), mute the original (`mutedWhenTapped`), wrap tap + real output in a private aggregate device, apply gain + limiter in an IOProc, write to the output. No install; one permission prompt. Requires macOS 14.4+.
2. **Virtual audio driver (Boom / eqMac style).** An AudioServerPlugIn set as the default output; app reads from it and plays to real hardware. Works on older macOS, but needs an admin install of a system-level driver. Rejected: more friction and moving parts than needed on this machine.
3. **Per-app capture (ScreenCaptureKit audio).** Can capture audio but cannot mute the originals, so you'd hear both. Rejected.

Picked: approach 1 — user chose it explicitly.

## Design (as agreed)

**UI** — `MenuBarExtra` popover:

```
┌─────────────────────────────┐
│ Boost              [ ON ●]  │
│ ───────●──────────  250%    │
│ Output: MacBook Speakers ▾  │
│ ☐ Launch at login           │
│ Quit                        │
└─────────────────────────────┘
```

- Boost on/off toggle.
- Boost slider 100%–400%, with live percentage.
- Output device picker (defaults to the current system output).
- Launch at login (`SMAppService`).
- Quit.
- `LSUIElement` = YES (no Dock icon). `NSAudioCaptureUsageDescription` in Info.plist.

**Behavior**

- Boost ON: create the tap + aggregate device and start audio; Boost OFF: tear down, original audio un-mutes.
- Follows default output device changes (headphones plugged in, etc.) by rebuilding the tap/aggregate on the new device.
- Remembers boost level, on/off state, and launch-at-login across launches.
- First time Boost is turned on, macOS shows the System Audio Recording permission prompt; if denied, the UI says so and points to System Settings.

## Left to the builder

- Limiter algorithm (e.g. look-ahead-free peak limiter or soft-knee/tanh saturation) — must be real-time safe (no allocations/locks on the audio thread) and transparent at 100%.
- Gain smoothing so slider moves don't click.
- Project setup (Xcode project vs. generator), code signing for local use, app name/icon.
- Exact handling of sample-rate / channel-count mismatches between tap and output.
- Test strategy: unit-test the DSP (gain, limiter) and settings; audio-device plumbing verified manually.
