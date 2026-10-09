import AppKit
import EQCore
import SwiftUI

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var importMessage: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ResponseCurveView(preset: model.preset)
                .frame(height: 110)
            presetSummary
            Divider()
            TextField("Search presets", text: $search)
                .textFieldStyle(.roundedBorder)
            presetList
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SystemEQ").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $model.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                switch model.engine.state {
                case .stopped:
                    Text("Off")
                case let .running(device):
                    Text("Output: \(device)")
                case let .failed(message):
                    Text(message).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var presetSummary: some View {
        HStack {
            Text(model.preset.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.isEdited {
                Text("edited").foregroundStyle(.orange)
            }
            Spacer()
            Text("\(model.preset.filters.count(where: \.isEnabled)) bands · preamp \(model.preset.preampDB, specifier: "%.1f") dB")
                .foregroundStyle(.secondary)
            Button("Edit…") { open(WindowID.editor) }
                .controlSize(.small)
        }
        .font(.caption)
    }

    private var filteredEntries: [PresetLibrary.Entry] {
        guard !search.isEmpty else { return model.library.entries }
        return model.library.entries.filter {
            $0.preset.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search)
        }
    }

    private var presetList: some View {
        let groups = Dictionary(grouping: filteredEntries, by: \.group)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.library.entries.isEmpty {
                    Text("Add a folder of AutoEQ / squig.link parametric EQ .txt files to get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                presetRow(name: "Flat (no EQ)", entry: nil)
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    Text(group)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    ForEach(groups[group] ?? []) { entry in
                        presetRow(name: entry.preset.name, entry: entry)
                    }
                }
            }
        }
        .frame(height: 240)
    }

    private func presetRow(name: String, entry: PresetLibrary.Entry?) -> some View {
        let isCurrent = !model.isEdited && model.loadedPresetPath == entry?.id
        return Button {
            model.load(entry)
        } label: {
            HStack {
                Image(systemName: "checkmark")
                    .opacity(isCurrent ? 1 : 0)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let importMessage {
                Text(importMessage).font(.caption).foregroundStyle(.orange)
            } else if model.library.skippedFileCount > 0 {
                Text("\(model.library.skippedFileCount) .txt files skipped (not parametric EQ, e.g. measurements)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Equalizer…") { open(WindowID.editor) }
                Button("Visualizer…") { open(WindowID.visualizer) }
            }
            HStack {
                Button("Add Folder…", action: addFolder)
                Button("Import…", action: importFiles)
                Menu("Folders") {
                    ForEach(model.library.folders, id: \.self) { folder in
                        Button("Remove \(folder.lastPathComponent)") {
                            model.library.removeFolder(folder)
                            model.reloadLibrary()
                        }
                    }
                    if !model.library.folders.isEmpty { Divider() }
                    Button("Show Imported Presets") { NSWorkspace.shared.open(PresetLibrary.importFolder) }
                    Button("Reload") { model.reloadLibrary() }
                }
                .fixedSize()
            }
            HStack {
                Toggle("Launch at login", isOn: $model.launchesAtLogin)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .controlSize(.small)
    }

    // MARK: Actions

    private func open(_ window: String) {
        openWindow(id: window)
        NSApp.activate()
    }

    private func addFolder() {
        guard let urls = runOpenPanel(directories: true) else { return }
        urls.forEach(model.library.addFolder)
        model.reloadLibrary()
    }

    private func importFiles() {
        guard let urls = runOpenPanel(directories: false) else { return }
        let failures = model.library.importFiles(urls)
        importMessage = failures.isEmpty ? nil : "Skipped \(failures.map(\.0.lastPathComponent).joined(separator: ", ")): not a parametric EQ preset"
        model.reloadLibrary()
    }

    private func runOpenPanel(directories: Bool) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = true
        if !directories { panel.allowedContentTypes = [.plainText] }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
