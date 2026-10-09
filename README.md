# SystemEQ

A macOS menu bar app that applies a parametric EQ preset to all system audio, like a minimal SoundSource with a single system-wide EQ.

It loads the parametric EQ text files exported by [AutoEQ](https://autoeq.app), squig.link and Equalizer APO:

```
Preamp: -6.44 dB
Filter 1: ON LS Fc 105.0 Hz Gain 2.8 dB Q 0.70
Filter 2: ON PK Fc 78.5 Hz Gain 1.1 dB Q 4.44
```

Supported filter types: `PK`, `LS`/`LSC`, `HS`/`HSC`, `LP`, `HP`, `NO`, with `Q` or `BW Oct`. Raw frequency response measurements (two columns of numbers) aren't presets and are skipped.

## Requirements

- macOS 15 or later (uses Core Audio process taps, no audio driver to install)
- Swift 6 toolchain (Command Line Tools are enough; Xcode isn't needed)

## Build and run

```sh
scripts/build-app.sh --install   # builds, signs, copies to /Applications and launches
scripts/test.sh                  # runs the tests
```

On first enable, macOS asks for permission to capture system audio. If you denied it, re-enable SystemEQ under **System Settings → Privacy & Security → Screen & System Audio Recording**.

## Using it

1. Click the menu bar icon and choose **Add Folder…** to add a folder of presets (searched recursively), or **Import…** to copy individual files into the app's own preset folder.
2. Pick a preset and turn on the switch.

SystemEQ follows your default output device, so switching outputs or plugging in headphones moves the EQ to the new device. The preset's preamp is applied as well, so audio will sound quieter with EQ on, which prevents clipping.

## How it works

- A **global process tap** captures every app's audio except SystemEQ's own, and mutes the original.
- A **private aggregate device** built on the current output device receives the tap. Its audio callback runs the EQ and writes to the device.
- If SystemEQ quits or crashes, macOS removes the tap and audio plays directly again.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/EQCore` | Platform-independent preset parser, biquad filters and real-time `EQProcessor`. No macOS dependencies, so an iOS app can reuse it. |
| `Sources/SystemEQ/Audio` | Core Audio tap and aggregate device (macOS only). |
| `Sources/SystemEQ` | Menu bar app: preset library, settings and SwiftUI views. |
| `Tests/EQCoreTests` | Parser and DSP tests. |

iOS doesn't allow apps to process other apps' audio, so an iOS version could only EQ audio it plays itself, for example a built-in music player using `EQCore`.
