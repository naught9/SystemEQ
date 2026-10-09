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
            Filter(type: .peaking, frequency: 5_500, gainDB: -5, q: 4),
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

        let result = AutoEQ.fit(source: source, target: target, name: "fit")

        #expect(result.equalization.max()! <= 6.0001)
        #expect(result.fitted.max()! < 6.5)
        #expect(abs(result.preset.preampDB + result.fitted.max()!) < 0.05)
    }

    @Test func alignsCurvesAtNormalizationFrequency() {
        let source = curve("s") { _ in 100 }
        let target = curve("t") { _ in 3 }

        let result = AutoEQ.fit(source: source, target: target, name: "fit")

        #expect(result.equalization.allSatisfy { abs($0) < 1e-9 })
        #expect(result.rmsErrorDB < 0.05)
    }
}
