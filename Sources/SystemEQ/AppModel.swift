import EQCore
import Foundation
import Observation
import ServiceManagement

/// Ties the preset library to the audio engine and remembers the user's choices between launches.
@Observable @MainActor
final class AppModel {
    let library = PresetLibrary()
    let engine = SystemAudioEQ()

    var selectedPresetPath: String? {
        didSet {
            UserDefaults.standard.set(selectedPresetPath, forKey: Keys.selectedPreset)
            applySelectedPreset()
        }
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? engine.start() : engine.stop()
        }
    }

    var selectedEntry: PresetLibrary.Entry? {
        library.entry(forPath: selectedPresetPath)
    }

    var launchesAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            try? launchesAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private enum Keys {
        static let selectedPreset = "selectedPresetPath"
        static let enabled = "enabled"
    }

    init() {
        selectedPresetPath = UserDefaults.standard.string(forKey: Keys.selectedPreset)
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        applySelectedPreset()
        if isEnabled { engine.start() }
    }

    func reloadLibrary() {
        library.reload()
        applySelectedPreset()
    }

    private func applySelectedPreset() {
        engine.processor.setPreset(selectedEntry?.preset ?? .flat)
    }
}
