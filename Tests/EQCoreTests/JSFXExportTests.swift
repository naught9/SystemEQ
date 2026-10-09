import Testing
@testable import EQCore

struct JSFXExportTests {
    let claude = ParametricPreset(name: "dusk -> claude target", preampDB: -3.66, filters: [
        Filter(type: .lowShelf, frequency: 105, gainDB: 2.7, q: 0.7),
        Filter(type: .peaking, frequency: 1103.4, gainDB: -1.7, q: 1.6),
        Filter(type: .peaking, frequency: 5680.1, gainDB: -4.7, q: 2.03, isEnabled: false),
        Filter(type: .highShelf, frequency: 10_000, gainDB: -5, q: 0.7),
    ])
    let harman = ParametricPreset(name: "dusk -> harman, 2019 <v2>", preampDB: -5.29, filters: [
        Filter(type: .peaking, frequency: 3_000, gainDB: 2, q: 1),
    ])

    @Test func singlePresetScriptIsNamedAfterItAndHidesTheSelector() {
        // EffectDeck replaces an imported script with the same desc and author, so the desc is the preset's name.
        let script = claude.jsfxScript
        #expect(script.hasPrefix("desc:SystemEQ: dusk -> claude target\nauthor:SystemEQ\n"))
        #expect(script.contains("slider1:0<0,0,1{dusk → claude target}>-Preset"))
    }

    @Test func storesPreampAndOnlyEnabledFiltersWithExactValues() {
        let script = claude.jsfxScript
        #expect(script.contains("preset(0, 3, -3.66);"))
        #expect(script.contains("band(0, 0, 1, 105, 2.7, 0.7);"))
        #expect(script.contains("band(0, 1, 0, 1103.4, -1.7, 1.6);"))
        #expect(script.contains("band(0, 2, 2, 10000, -5, 0.7);"))
        #expect(!script.contains("5680"))
    }

    @Test func combinedScriptHasASelectorWithSafeLabels() {
        let script = JSFXExport.script(presets: [claude, harman], title: "Presets")
        #expect(script.hasPrefix("desc:SystemEQ: Presets\n"))
        // Commas separate menu entries and angle brackets delimit the slider, so they're replaced.
        #expect(script.contains("slider1:0<0,1,1{dusk → claude target,dusk → harman; 2019 (v2)}>Preset"))
        #expect(script.contains("preset(1, 1, -5.29);"))
        #expect(script.contains("band(1, 0, 0, 3000, 2, 1);"))
    }

    @Test func isAlwaysOnWithoutItsOwnBypass() {
        // Hosts bypass the whole effect, so the script has only the preset menu and preamp adjustment.
        let script = JSFXExport.script(presets: [claude, harman], title: "Presets")
        #expect(script.contains("slider2:0<-30,30,0.01>Preamp adjust (dB)"))
        #expect(!script.contains("slider3"))
        #expect(!script.contains("Bypassed"))
    }
}
