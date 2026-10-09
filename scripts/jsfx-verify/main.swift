// Checks that generated JSFX scripts process audio exactly like SystemEQ. See README.md.
// Usage: verify <ysfx host binary> <scratch directory> <preset.txt>...
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

var worstExact = 0.0, worstApp = 0.0
for file in presetFiles {
    let preset = try PresetParser.parse(contentsOf: file)
    let name = preset.name
    let script = "\(scratch)/\(name).jsfx"
    try preset.jsfxScript.write(toFile: script, atomically: true, encoding: .utf8)
    var line = name.padding(toLength: 38, withPad: " ", startingAt: 0)
    for rate in [44_100.0, 48_000.0, 96_000.0] {
        let out = "\(scratch)/out.bin"
        let host = Process()
        host.executableURL = URL(filePath: hostPath)
        host.arguments = [script, String(Int(rate)), String(frames), out]
        try host.run(); host.waitUntilExit()
        guard host.terminationStatus == 0 else { print("host failed for \(name)"); exit(1) }
        let data = try Data(contentsOf: URL(filePath: out))
        let jsfx = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }

        // 64-bit reference with SystemEQ's coefficient code.
        let coefficients = preset.filters.filter(\.isEnabled).map { BiquadCoefficients(filter: $0, sampleRate: rate) }
        let gain = pow(10, preset.preampDB / 20)
        // SystemEQ's real processor (32-bit samples in and out, 64-bit inside).
        let processor = EQProcessor(preset: preset, sampleRate: rate)
        processor.beginCycle()

        var exactDiff = 0.0, appDiff = 0.0
        for ch in 0..<2 {
            var s = [Double](repeating: 0, count: coefficients.count * 2)
            var floats = input[ch].map { Float($0) }
            floats.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frames: frames, stride: 1, channel: ch) }
            for i in 0..<frames {
                var x = input[ch][i] * gain
                for (k, c) in coefficients.enumerated() {
                    let y = c.b0 * x + s[2 * k]
                    s[2 * k] = c.b1 * x - c.a1 * y + s[2 * k + 1]
                    s[2 * k + 1] = c.b2 * x - c.a2 * y
                    x = y
                }
                let j = jsfx[ch * frames + i]
                exactDiff = max(exactDiff, abs(j - x))
                appDiff = max(appDiff, abs(j - Double(floats[i])))
            }
        }
        worstExact = max(worstExact, exactDiff); worstApp = max(worstApp, appDiff)
        line += String(format: "  %5.1fk: %.1e / %.1e", rate / 1000, exactDiff, appDiff)
    }
    print(line)
}
print(String(format: "worst: vs 64-bit reference %.2e (%.0f dB), vs SystemEQ app processor %.2e (%.0f dB)", worstExact, 20 * log10(max(worstExact, 1e-300)), worstApp, 20 * log10(worstApp)))
