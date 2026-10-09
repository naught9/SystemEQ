// Checks that generated JSFX scripts process audio exactly like SystemEQ. See README.md.
// Usage: verify <ysfx host binary> <scratch directory> <preset.txt>...
// Checks each preset alone, then all of them combined in one script with a preset selector.
import Foundation
let arguments = CommandLine.arguments
guard arguments.count >= 4 else { print("usage: verify <host> <scratch dir> <preset.txt>..."); exit(2) }
let hostPath = arguments[1], scratch = arguments[2]
let presetFiles = arguments.dropFirst(3).map { URL(filePath: $0) }
let frames = 48_000 * 2

// Same input as host.cpp: an impulse, then xorshift noise, both channels interleaved per frame, in float precision.
var input: [[Double]] = [[], []]
var state: UInt64 = 0x9E3779B97F4A7C15
for i in 0..<frames {
    for ch in 0..<2 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        var v = Double(state >> 11) / 9007199254740992.0 - 0.5
        if i == 0 { v = 0.9 }
        input[ch].append(Double(Float(v)))
    }
}

let presets = try presetFiles.map { try PresetParser.parse(contentsOf: $0) }
let combined = "\(scratch)/combined.jsfx"
try JSFXExport.script(presets: presets, title: "Presets").write(toFile: combined, atomically: true, encoding: .utf8)

/// Runs `script` in the host with the selector at `index` and returns its output, left then right.
func runHost(_ script: String, rate: Double, index: Int, list: Bool = false) throws -> [Double] {
    let out = "\(scratch)/out.bin"
    let host = Process()
    host.executableURL = URL(filePath: hostPath)
    host.arguments = [script, String(Int(rate)), String(frames), out, String(index)] + (list ? ["--list"] : [])
    try host.run(); host.waitUntilExit()
    guard host.terminationStatus == 0 else { print("host failed for \(script)"); exit(1) }
    let data = try Data(contentsOf: URL(filePath: out))
    return data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
}

_ = try runHost(combined, rate: 48_000, index: 0, list: true)
print("columns: single-preset script, then combined script with that preset selected (vs 64-bit reference / vs EQProcessor)")

var worstExact = 0.0, worstApp = 0.0
for (index, preset) in presets.enumerated() {
    let single = "\(scratch)/\(preset.name).jsfx"
    try preset.jsfxScript.write(toFile: single, atomically: true, encoding: .utf8)
    var line = preset.name.padding(toLength: 38, withPad: " ", startingAt: 0)
    for rate in [44_100.0, 48_000.0, 96_000.0] {
        // 64-bit reference with SystemEQ's coefficient code.
        let coefficients = preset.filters.filter(\.isEnabled).map { BiquadCoefficients(filter: $0, sampleRate: rate) }
        let gain = pow(10, preset.preampDB / 20)
        var reference: [[Double]] = [[], []]
        // SystemEQ's real processor (32-bit samples in and out, 64-bit inside).
        let processor = EQProcessor(preset: preset, sampleRate: rate)
        processor.beginCycle()
        var app: [[Float]] = [[], []]
        for ch in 0..<2 {
            var s = [Double](repeating: 0, count: coefficients.count * 2)
            for i in 0..<frames {
                var x = input[ch][i] * gain
                for (k, c) in coefficients.enumerated() {
                    let y = c.b0 * x + s[2 * k]
                    s[2 * k] = c.b1 * x - c.a1 * y + s[2 * k + 1]
                    s[2 * k + 1] = c.b2 * x - c.a2 * y
                    x = y
                }
                reference[ch].append(x)
            }
            var floats = input[ch].map { Float($0) }
            floats.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frames: frames, stride: 1, channel: ch) }
            app[ch] = floats
        }

        line += String(format: "  %5.1fk:", rate / 1000)
        for (script, selector) in [(single, 0), (combined, index)] {
            let jsfx = try runHost(script, rate: rate, index: selector)
            var exactDiff = 0.0, appDiff = 0.0
            for ch in 0..<2 {
                for i in 0..<frames {
                    let j = jsfx[ch * frames + i]
                    exactDiff = max(exactDiff, abs(j - reference[ch][i]))
                    appDiff = max(appDiff, abs(j - Double(app[ch][i])))
                }
            }
            worstExact = max(worstExact, exactDiff); worstApp = max(worstApp, appDiff)
            line += String(format: " %.0e/%.0e", exactDiff, appDiff)
        }
    }
    print(line)
}
print(String(format: "worst: vs 64-bit reference %.2e (%.0f dB), vs SystemEQ app processor %.2e (%.0f dB)", worstExact, 20 * log10(max(worstExact, 1e-300)), worstApp, 20 * log10(worstApp)))
