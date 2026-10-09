import EQCore
import Foundation
import Observation
import ServiceManagement

/// Ties the preset library, the editable working preset and the audio engine together,
/// and remembers the user's choices between launches.
@Observable @MainActor
final class AppModel {
    static let maxBands = 20

    let library = PresetLibrary()
    let engine = SystemAudioEQ()

    /// The preset being heard and edited. Loading a library preset copies it here;
    /// edits never touch the original file.
    private(set) var preset: ParametricPreset = .flat {
        didSet {
            engine.processor.setPreset(preset)
            savePresetState()
        }
    }

    /// Library file the working preset was loaded from, or nil for flat / unsaved presets.
    private(set) var loadedPresetPath: String?

    /// True once the working preset differs from the file it was loaded from.
    private(set) var isEdited = false

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? engine.start() : engine.stop()
        }
    }

    var launchesAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            try? launchesAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private enum Keys {
        static let enabled = "enabled"
        static let loadedPreset = "selectedPresetPath"
        static let workingPreset = "workingPreset"
        static let isEdited = "isEdited"
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        loadedPresetPath = defaults.string(forKey: Keys.loadedPreset)
        isEdited = defaults.bool(forKey: Keys.isEdited)

        if !isEdited, let entry = library.entry(forPath: loadedPresetPath) {
            preset = entry.preset
        } else if let data = defaults.data(forKey: Keys.workingPreset),
                  let saved = try? JSONDecoder().decode(ParametricPreset.self, from: data) {
            preset = saved
        }
        engine.processor.setPreset(preset)
        if isEnabled { engine.start() }
    }

    // MARK: Loading and saving

    func load(_ entry: PresetLibrary.Entry?) {
        loadedPresetPath = entry?.id
        isEdited = false
        preset = entry?.preset ?? .flat
    }

    func reloadLibrary() {
        library.reload()
        // Pick up changes to the file the working preset came from, unless the user has edited it.
        if !isEdited, let entry = library.entry(forPath: loadedPresetPath) {
            preset = entry.preset
        }
    }

    /// Writes the working preset into the library's import folder under `name` and makes it the loaded preset.
    func saveToLibrary(named name: String) throws {
        var saved = preset
        saved.name = name
        let url = PresetLibrary.importFolder.appending(path: PresetLibrary.fileName(for: name))
        try saved.equalizerAPOText.write(to: url, atomically: true, encoding: .utf8)
        library.reload()
        loadedPresetPath = url.path
        isEdited = false
        preset = saved
    }

    func export(to url: URL) throws {
        try preset.equalizerAPOText.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Makes a generated preset the working preset, as an unsaved preset.
    func useUnsaved(_ newPreset: ParametricPreset) {
        loadedPresetPath = nil
        isEdited = true
        preset = newPreset
    }

    /// Discards edits and returns to the loaded preset.
    func revert() {
        load(library.entry(forPath: loadedPresetPath))
    }

    // MARK: Editing

    /// Applies an edit to the working preset. The first edit turns it into a new, unsaved preset.
    func edit(_ change: (inout ParametricPreset) -> Void) {
        var updated = preset
        change(&updated)
        guard updated != preset else { return }
        if !isEdited {
            isEdited = true
            if loadedPresetPath != nil { updated.name += " (edited)" } else if updated.name == ParametricPreset.flat.name { updated.name = "Custom" }
        }
        preset = updated
    }

    func addBand() {
        edit { preset in
            guard preset.filters.count < Self.maxBands else { return }
            preset.filters.append(Filter(type: .peaking, frequency: 1000, gainDB: 0, q: 1))
        }
    }

    func removeBand(at index: Int) {
        edit { preset in
            guard preset.filters.indices.contains(index) else { return }
            preset.filters.remove(at: index)
        }
    }

    /// Sets the preamp so the loudest boost peaks at 0 dB, which avoids clipping.
    func autoPreamp() {
        edit { preset in
            var filtersOnly = preset
            filtersOnly.preampDB = 0
            preset.preampDB = (-max(0, filtersOnly.peakResponseDB) * 100).rounded() / 100
        }
    }

    private func savePresetState() {
        let defaults = UserDefaults.standard
        defaults.set(loadedPresetPath, forKey: Keys.loadedPreset)
        defaults.set(isEdited, forKey: Keys.isEdited)
        defaults.set(try? JSONEncoder().encode(preset), forKey: Keys.workingPreset)
    }
}
