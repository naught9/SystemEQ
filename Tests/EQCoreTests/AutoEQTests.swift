import Foundation
import Testing
@testable import EQCore

struct AutoEQTests {
    private let grid = FrequencyResponse.logGrid(pointsPerOctave: 48)

    private func curve(_ name: String, _ value: (Double) -> Double) -> FrequencyResponse {
        FrequencyResponse(name: name, frequencies: grid, db: grid.map(value))
    }

    @Test func recoversAKnownEQ() {
        let known = ParametricPreset(name: "known", filters: [
            Filter(type: .lowShelf, frequency: 105, gainDB: 3, q: 0.7),
            Filter(type: .peaking, frequency: 300, gainDB: -2, q: 1.2),
            Filter(type: .peaking, frequency: 1_000, gainDB: -4, q: 2),
            Filter(type: .peaking, frequency: 3_000, gainDB: 3, q: 3),
            Filter(type: .peaking, frequency: 5_500, gainDB: -5, q: 2.5),
            Filter(type: .highShelf, frequency: 10_000, gainDB: -2, q: 0.7),
        ])
        // A flat headphone and a target that differs from it by exactly `known`.
        let source = curve("flat") { _ in 90 }
        let target = curve("target") { known.responseDB(at: $0) }

        let result = AutoEQ.fit(source: source, target: target, name: "fit")

        #expect(result.preset.filters.count == 10)
        #expect(result.preset.filters.first?.type == .lowShelf)
        #expect(result.preset.filters.last?.type == .highShelf)
        #expect(result.rmsErrorDB < 0.3)
    }

    @Test func limitsBoostsAndSetsPreampToAvoidClipping() {
        let source = curve("dip") { 90 - 12 * exp(-pow(log2($0 / 2_000), 2) * 8) }
        let target = curve("flat") { _ in 0 }

        var options = AutoEQOptions()
        options.maxBoostDB = 6
        let result = AutoEQ.fit(source: source, target: target, name: "fit", options: options)

        // AutoEq caps boosts before its final 1/5-octave smoothing, which can round a capped peak slightly higher.
        #expect(result.equalization.max()! <= 6.1)
        #expect(result.fitted.max()! < 6.5)
        // autoeq.app: preamp is the negated peak minus 0.1 dB.
        #expect(abs(result.preset.preampDB + result.fitted.max()! + 0.1) < 0.05)
    }

    @Test func alignsCurvesAtNormalizationFrequency() {
        let source = curve("s") { _ in 100 }
        let target = curve("t") { _ in 3 }

        let result = AutoEQ.fit(source: source, target: target, name: "fit")

        #expect(result.equalization.allSatisfy { abs($0) < 1e-9 })
        #expect(result.rmsErrorDB < 0.05)
    }

    /// Compares against the original Python AutoEq run on the same synthetic curves (optimizer run to
    /// convergence). Regenerate with scripts/autoeq-reference, as described in README.md.
    @Test(arguments: [
        ("autoeq-reference.json", nil),
        ("autoeq-reference-advanced.json", "advanced-settings.json"),
    ] as [(String, String?)])
    func matchesOriginalAutoEq(reference referenceFile: String, settings settingsFile: String?) throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let source = try FrequencyResponse.parse(contentsOf: fixtures.appending(path: "source.csv"))
        let target = try FrequencyResponse.parse(contentsOf: fixtures.appending(path: "target.csv"))
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appending(path: referenceFile))) as! [String: Any]
        let referenceEqualization = reference["equalization"] as! [Double]
        let referenceFilters = (reference["filters"] as! [[String: Any]]).map { filter in
            let type: FilterType = switch filter["type"] as! String {
            case "LowShelf": .lowShelf
            case "HighShelf": .highShelf
            default: .peaking
            }
            return Filter(type: type, frequency: filter["fc"] as! Double, gainDB: filter["gain"] as! Double, q: filter["q"] as! Double)
        }

        var options = AutoEQOptions()
        if let settingsFile {
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appending(path: settingsFile))) as! [String: Double]
            options.bassBoostDB = settings["bass_boost_gain"]!
            options.bassBoostFrequency = settings["bass_boost_fc"]!
            options.bassBoostQ = settings["bass_boost_q"]!
            options.trebleDB = settings["treble_boost_gain"]!
            options.trebleBoostFrequency = settings["treble_boost_fc"]!
            options.trebleBoostQ = settings["treble_boost_q"]!
            options.tiltDBPerOctave = settings["tilt"]!
            options.maxBoostDB = settings["max_gain"]!
            options.maxSlopeDBPerOctave = settings["max_slope"]!
            options.windowSize = settings["window_size"]!
            options.trebleWindowSize = settings["treble_window_size"]!
            options.trebleFrequencies = settings["treble_f_lower"]!...settings["treble_f_upper"]!
            options.trebleGainK = settings["treble_gain_k"]!
            options.optimizerFrequencyRange = settings["min_f"]!...settings["max_f"]!
        }
        let result = AutoEQ.fit(source: source, target: target, name: "fixture", options: options)

        // The equalization curve (smoothing, slope limiting, boost cap) is ported exactly.
        #expect(result.equalization.count == referenceEqualization.count)
        let maxDifference = zip(result.equalization, referenceEqualization).map { abs($0 - $1) }.max()!
        #expect(maxDifference < 1e-6)

        // The optimizer differs (Levenberg-Marquardt instead of SLSQP), so filters match closely, not exactly.
        let referencePreset = ParametricPreset(name: "", filters: referenceFilters)
        let difference = result.frequencies.indices.map { referencePreset.responseDB(at: result.frequencies[$0]) - result.fitted[$0] }
        let rms = sqrt(difference.map { $0 * $0 }.reduce(0, +) / Double(difference.count))
        #expect(rms < 0.25)
        #expect(abs(result.preset.preampDB - (reference["preamp"] as! Double)) < 0.6)
    }
}
