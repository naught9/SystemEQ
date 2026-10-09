import EQCore
import Foundation
import Observation

/// Presets found in the user's chosen folders plus the app's own import folder.
/// Mutating methods don't rescan; call `reload()` (via `AppModel.reloadLibrary()`) afterwards.
@Observable @MainActor
final class PresetLibrary {
    struct Entry: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        /// Folder path relative to the library folder it was found in, for grouping.
        let group: String
        let preset: ParametricPreset

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.url == rhs.url }
        func hash(into hasher: inout Hasher) { hasher.combine(url) }
    }

    private(set) var entries: [Entry] = []
    private(set) var folders: [URL]
    /// Text files that weren't parametric presets, e.g. frequency response measurements.
    private(set) var skippedFileCount = 0

    static let importFolder = URL.applicationSupportDirectory
        .appending(path: "SystemEQ/Presets", directoryHint: .isDirectory)

    private static let foldersKey = "presetFolders"

    init() {
        folders = (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
        try? FileManager.default.createDirectory(at: Self.importFolder, withIntermediateDirectories: true)
        reload()
    }

    func entry(forPath path: String?) -> Entry? {
        entries.first { $0.id == path }
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
        saveFolders()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        saveFolders()
    }

    /// Copies preset files into the import folder. Returns the files that weren't valid presets.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [(URL, Error)] {
        var failures: [(URL, Error)] = []
        for url in urls {
            do {
                _ = try PresetParser.parse(contentsOf: url)
                let destination = Self.importFolder.appending(path: url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                failures.append((url, error))
            }
        }
        return failures
    }

    func reload() {
        var found: [Entry] = []
        var skipped = 0
        for root in [Self.importFolder] + folders {
            for url in Self.textFiles(in: root) {
                guard let preset = try? PresetParser.parse(contentsOf: url) else {
                    skipped += 1
                    continue
                }
                let relative = url.deletingLastPathComponent().path.dropFirst(root.path.count)
                let group = root == Self.importFolder ? "Imported" : root.lastPathComponent + relative
                found.append(Entry(url: url, group: group, preset: preset))
            }
        }
        entries = found.sorted {
            ($0.group, $0.preset.name.localizedLowercase) < ($1.group, $1.preset.name.localizedLowercase)
        }
        skippedFileCount = skipped
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.foldersKey)
    }

    private static func textFiles(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "txt" }
    }
}
