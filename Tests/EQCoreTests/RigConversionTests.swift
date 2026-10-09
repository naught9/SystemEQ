import Foundation
import Testing
@testable import EQCore

struct RigConversionTests {
    @Test func infersRigFromNamesAndFolders() {
        #expect(MeasurementRig.infer(from: "Targets (B&K 5128)/Harman 2025 MoA Average Target.txt") == .bk5128)
        #expect(MeasurementRig.infer(from: "Targets (IEC 711)/IEF 2023 Target.txt") == .iec711)
        #expect(MeasurementRig.infer(from: "IEC 60318-4 DF.txt") == .iec711)
        #expect(MeasurementRig.infer(from: "Moondrop x Crinacle Dusk [1].txt") == nil)
    }

    @Test func conversionHasTheMeasuredShapeAndIsReversible() {
        // A 5128 reads bass several dB lower and the 2-3 kHz region higher than a 711.
        #expect(RigConversion.offsetDB(at: 100, from: .iec711, to: .bk5128) < -2.5)
        #expect(RigConversion.offsetDB(at: 3_000, from: .iec711, to: .bk5128) > 1)
        for frequency in [30.0, 300, 3_000, 15_000] {
            let there = RigConversion.offsetDB(at: frequency, from: .iec711, to: .bk5128)
            let back = RigConversion.offsetDB(at: frequency, from: .bk5128, to: .iec711)
            #expect(there + back == 0)
            #expect(RigConversion.offsetDB(at: frequency, from: .bk5128, to: .bk5128) == 0)
        }
    }

    @Test func autoEQConvertsTheTargetToTheSourceRig() {
        let grid = FrequencyResponse.logGrid(pointsPerOctave: 48)
        let source = FrequencyResponse(name: "711 IEM", frequencies: grid, db: grid.map { 90 + 6 * exp(-pow(log2($0 / 3_000), 2)) })
        let target5128 = FrequencyResponse(name: "5128 target", frequencies: grid, db: grid.map { 8 * exp(-pow(log2($0 / 2_800), 2)) })

        var options = AutoEQOptions()
        options.sourceRig = .iec711
        options.targetRig = .bk5128
        let converted = AutoEQ.fit(source: source, target: target5128, name: "a", options: options)
        let manual = AutoEQ.fit(source: source, target: target5128.converted(from: .bk5128, to: .iec711), name: "a")
        let unconverted = AutoEQ.fit(source: source, target: target5128, name: "a")

        #expect(converted.equalization == manual.equalization)
        #expect(converted.equalization != unconverted.equalization)
    }
}
