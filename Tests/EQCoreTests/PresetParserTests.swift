import Testing
@testable import EQCore

struct PresetParserTests {
    @Test func parsesAutoEQExport() throws {
        let text = """
        Preamp: -6.44 dB
        Filter 1: ON LS Fc 105.0 Hz Gain 2.8 dB Q 0.70
        Filter 2: ON PK Fc 78.5 Hz Gain 1.1 dB Q 4.44
        Filter 10: ON HS Fc 10000.0 Hz Gain 6.4 dB Q 0.70
        """
        let preset = try PresetParser.parse(text, name: "pods -> dusk")

        #expect(preset.name == "pods -> dusk")
        #expect(preset.preampDB == -6.44)
        #expect(preset.filters == [
            Filter(type: .lowShelf, frequency: 105, gainDB: 2.8, q: 0.7),
            Filter(type: .peaking, frequency: 78.5, gainDB: 1.1, q: 4.44),
            Filter(type: .highShelf, frequency: 10_000, gainDB: 6.4, q: 0.7),
        ])
    }

    @Test func parsesSquigLinkExportWithIntegerValues() throws {
        let text = """
        Preamp: -3.305 dB
        Filter 1: ON PK Fc 21 Hz Gain -0.7 dB Q 4
        Filter 6: ON PK Fc 6000 Hz Gain -4 dB Q 6.6
        """
        let preset = try PresetParser.parse(text, name: "squig")

        #expect(preset.preampDB == -3.305)
        #expect(preset.filters.map(\.frequency) == [21, 6000])
        #expect(preset.filters.map(\.gainDB) == [-0.7, -4])
    }

    @Test func handlesEqualizerAPOVariants() throws {
        let text = """
        # comment
        Device: all
        Preamp: -2 dB
        Filter: ON LSC Fc 100 Hz Gain 3 dB Q 0.7
        Filter 2: OFF PK Fc 1000 Hz Gain -3 dB Q 1
        Filter 3: ON PK Fc 2000 Hz Gain 2 dB BW Oct 1
        Filter 4: ON HP Fc 20 Hz
        Filter 5: ON None
        """
        let preset = try PresetParser.parse(text, name: "apo")

        #expect(preset.filters.count == 4)
        #expect(preset.filters[0].type == .lowShelf)
        #expect(preset.filters[1].isEnabled == false)
        #expect(abs(preset.filters[2].q - 1.4142) < 0.001)
        #expect(preset.filters[3] == Filter(type: .highPass, frequency: 20))
    }

    @Test func rejectsFrequencyResponseMeasurements() {
        let text = """
        20\t94.957533
        20.290906698750476\t94.95717712295226
        """
        #expect(throws: PresetParseError.notParametricEQ) {
            try PresetParser.parse(text, name: "Dusk [2] H")
        }
    }

    @Test func rejectsFilterWithoutFrequency() {
        #expect(throws: PresetParseError.invalidLine(number: 1, text: "Filter 1: ON PK Gain 2 dB Q 1")) {
            try PresetParser.parse("Filter 1: ON PK Gain 2 dB Q 1", name: "bad")
        }
    }
}
