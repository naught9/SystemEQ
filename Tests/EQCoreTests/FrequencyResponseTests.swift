import Foundation
import Testing
@testable import EQCore

struct PresetExportTests {
    @Test func exportedTextParsesBackToSamePreset() throws {
        let preset = ParametricPreset(name: "dusk -> harmon", preampDB: -4.58, filters: [
            Filter(type: .lowShelf, frequency: 105, gainDB: 2.4, q: 0.7),
            Filter(type: .peaking, frequency: 1643.1, gainDB: -1.3, q: 1.47, isEnabled: false),
            Filter(type: .highShelf, frequency: 10_000, gainDB: -7.2, q: 0.7),
            Filter(type: .highPass, frequency: 20, q: 0.71),
        ])
        let text = preset.equalizerAPOText

        #expect(text.hasPrefix("Preamp: -4.58 dB\nFilter 1: ON LS Fc 105.0 Hz Gain 2.4 dB Q 0.70\n"))
        #expect(try PresetParser.parse(text, name: preset.name) == preset)
    }
}

struct FrequencyResponseTests {
    @Test func parsesTabAndCommaSeparatedCurves() throws {
        let tabbed = (0..<12).map { "\(20 + $0 * 10)\t\(90.5 + Double($0))" }.joined(separator: "\n")
        let commas = "frequency,raw\n" + (0..<12).map { "\(20 + $0 * 10).000000, \($0)" }.joined(separator: "\n") + "\n20000.000000,\n"

        let measurement = try FrequencyResponse.parse(tabbed, name: "m")
        let target = try FrequencyResponse.parse(commas, name: "t")

        #expect(measurement.frequencies.count == 12)
        #expect(measurement.db.first == 90.5)
        #expect(target.frequencies.count == 12)
        #expect(target.frequencies.last == 130)
    }

    @Test func rejectsParametricPresets() {
        #expect(throws: FrequencyResponseParseError.notEnoughPoints) {
            try FrequencyResponse.parse("Preamp: -2 dB\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1", name: "p")
        }
    }

    @Test func interpolatesOnLogFrequencyAndHoldsEnds() {
        let curve = FrequencyResponse(name: "c", frequencies: [100, 1000, 10_000], db: [0, 10, 0])
        #expect(curve.value(at: 50) == 0)
        #expect(abs(curve.value(at: 316.227766) - 5) < 1e-6)
        #expect(curve.value(at: 1000) == 10)
        #expect(curve.value(at: 20_000) == 0)
    }

    @Test func logGridSpansRangeWithRequestedDensity() {
        let grid = FrequencyResponse.logGrid(from: 20, to: 20_000, pointsPerOctave: 48)
        #expect(abs(grid.first! - 20) < 1e-9)
        #expect(abs(grid.last! - 20_000) < 1e-6)
        #expect(grid.count == 479) // 9.97 octaves × 48 + 1
    }

    @Test func readsLatin1FilesFromREW() throws {
        // REW writes ISO-8859-1; "°" here is the single byte 0xB0, which isn't valid UTF-8.
        var bytes = Array("* Measurement data measured by REW, temp 21".utf8) + [0xB0] + Array("C\n* Freq(Hz) SPL(dB)\n".utf8)
        for i in 0..<12 { bytes += Array("\(20 + i * 10) \(90 + i)\n".utf8) }
        let url = FileManager.default.temporaryDirectory.appending(path: "latin1-\(UUID().uuidString).txt")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let response = try FrequencyResponse.parse(contentsOf: url)
        #expect(response.frequencies.count == 12)
        #expect(response.db.last == 101)
    }
}
