import Testing
@testable import EQCore

struct JSFXExportTests {
    let preset = ParametricPreset(name: "dusk -> claude target", preampDB: -3.66, filters: [
        Filter(type: .lowShelf, frequency: 105, gainDB: 2.7, q: 0.7),
        Filter(type: .peaking, frequency: 1103.4, gainDB: -1.7, q: 1.6),
        Filter(type: .peaking, frequency: 5680.1, gainDB: -4.7, q: 2.03, isEnabled: false),
        Filter(type: .highShelf, frequency: 10_000, gainDB: -5, q: 0.7),
    ])

    @Test func namesTheEffectAfterThePreset() {
        // EffectDeck replaces an imported script with the same desc and author, so each preset needs its own desc.
        #expect(preset.jsfxScript.hasPrefix("desc:SystemEQ: dusk -> claude target\nauthor:SystemEQ\n"))
    }

    @Test func includesPreampAndOnlyEnabledFiltersWithExactValues() {
        let script = preset.jsfxScript
        #expect(script.contains("slider1:-3.66<-30,30,0.01>Preamp (dB)"))
        #expect(script.contains("bandCount = 3;"))
        #expect(script.contains("band(0, 1, 105, 2.7, 0.7);"))
        #expect(script.contains("band(1, 0, 1103.4, -1.7, 1.6);"))
        #expect(script.contains("band(2, 2, 10000, -5, 0.7);"))
        #expect(!script.contains("5680"))
    }
}
