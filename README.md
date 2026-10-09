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

1. Click the menu bar icon and choose **Add Folder…** to add a folder of presets and measurements (searched recursively), or **Import…** to copy individual presets into the app's own preset folder.
2. Pick a preset and turn on the switch.

From the menu bar you can also open:

- **Equalizer**: edit the current preset with up to 20 parametric bands. Drag points on the curve (hold ⌥ to change Q) or type values. Editing a library preset turns it into a new unsaved preset; **Save as Preset…** adds it to the library and **Export…** writes an Equalizer APO / AutoEQ `.txt` file.
- **Visualizer**: post-EQ spectrum (4k–32k point FFT with peak hold and optional tilt) and BS.1770 / EBU R 128 loudness (momentary, short-term, integrated LUFS) with sample peak meters.
- **AutoEQ**: generate a preset that makes a measured headphone (source) sound like another headphone or a target curve. This is a Swift port of [AutoEq](https://github.com/jaakkopasanen/AutoEq)'s pipeline with autoeq.app's defaults (8 peaking filters with 105 Hz / 10 kHz shelves, +12 dB max boost, 18 dB/oct slope limit, 0.08 / 2 octave smoothing, mean-error normalisation). Bass boost, treble boost, tilt and max gain adjust the target like autoeq.app's sliders, and an Advanced section exposes its other parameters (shelf frequencies and Q, max slope, smoothing, treble gain multiplier, transition region, optimizer range). The graph's curves (source, target, error, correction, EQ, equalized) can be toggled, shown smoothed, and read by hovering. Measurements are two-column text files (frequency, dB) as exported by squig.link or AutoEQ.

SystemEQ follows your default output device, so switching outputs or plugging in headphones moves the EQ to the new device. The preset's preamp is applied as well, so audio will sound quieter with EQ on, which prevents clipping.

## How it works

- A **global process tap** captures every app's audio except SystemEQ's own, and mutes the original.
- A **private aggregate device** built on the current output device receives the tap. Its audio callback runs the EQ and writes to the device.
- If SystemEQ quits or crashes, macOS removes the tap and audio plays directly again.

## Rig conversion

IEM measurements and targets come from different rigs, mainly the IEC 711 coupler used by most squig.link databases and the B&K 5128 used for newer targets such as Harman 2025 MoA. In the AutoEQ window, each source and target has a "Measured on" setting, guessed from "711" or "5128" in its file or folder name. When the rigs differ, the target is converted to the source's rig before fitting, using the median 5128 − 711 difference over 93 IEMs measured on both. It's accurate to about a decibel up to 4 kHz; above 8 kHz only the smoothed average applies, as individual IEMs vary by several dB there. See `scripts/rig-conversion`.

## AutoEq port

`Sources/EQCore/AutoEQ.swift` ports AutoEq's `process` (interpolation, centring, compensation, Savitzky-Golay smoothing, slope limiting) and `optimize_parametric_eq` (filter initialisation, loss with sharpness penalty). The equalization curve matches the original exactly. SciPy's SLSQP optimizer is replaced by Levenberg-Marquardt on the same loss, run to convergence instead of autoeq.app's 0.5 s limit, so filters typically differ from autoeq.app's by under 0.15 dB RMS and the preamp by a few tenths of a dB.

`Tests/EQCoreTests/AutoEQTests.swift` checks this against output from the original Python code stored in `Tests/EQCoreTests/Fixtures`. To regenerate it, install AutoEq's dependencies (numpy, scipy, matplotlib, tabulate, pillow) in a virtual environment and run:

```sh
python scripts/autoeq-reference/make_fixture.py Tests/EQCoreTests/Fixtures
python scripts/autoeq-reference/run.py <AutoEq checkout> Tests/EQCoreTests/Fixtures/source.csv Tests/EQCoreTests/Fixtures/target.csv none > Tests/EQCoreTests/Fixtures/autoeq-reference.json
```

AutoEq is MIT licensed, copyright (c) 2018-2022 Jaakko Pasanen; the notice is included in `AutoEQ.swift`.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/EQCore` | Platform-independent preset parsing and export, biquad filters, real-time `EQProcessor`, measurement parsing, AutoEQ-style fitter, spectrum analyzer and loudness meter. No macOS dependencies, so an iOS app can reuse it. |
| `Sources/SystemEQ/Audio` | Core Audio tap and aggregate device (macOS only). |
| `Sources/SystemEQ` | Menu bar app: preset library, settings and SwiftUI views. |
| `Tests/EQCoreTests` | Parser, DSP, metering and fitter tests. |

iOS doesn't allow apps to process other apps' audio, so an iOS version could only EQ audio it plays itself, for example a built-in music player using `EQCore`.

## License

MIT, see [LICENSE](LICENSE). `Sources/EQCore/AutoEQ.swift` is a port of AutoEq, also MIT licensed (c) 2018-2022 Jaakko Pasanen.
