import AppKit
import EQCore
import SwiftUI

/// Parametric EQ editor for the working preset.
struct EditorView: View {
    @Bindable var model: AppModel
    @State private var selectedBand: Int?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            EQCurveEditor(model: model, selectedBand: $selectedBand)
                .frame(minHeight: 240)
            preampRow
            Divider()
            bandTable
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 620)
        .alert("Couldn't save preset", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.preset.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text(model.isEdited ? "Unsaved changes" : (model.loadedPresetPath == nil ? "Not in library" : "Saved in library"))
                    .font(.caption)
                    .foregroundStyle(model.isEdited ? .orange : .secondary)
            }
            Spacer()
            if model.isEdited && model.loadedPresetPath != nil {
                Button("Revert", action: model.revert)
            }
            Button("Reset to Flat") { model.edit { $0.preampDB = 0; $0.filters = [] } }
            Button("Save as Preset…", action: saveToLibrary)
            Button("Export…", action: export)
        }
    }

    private var preampRow: some View {
        let peak = model.preset.peakResponseDB
        return HStack(spacing: 10) {
            Text("Preamp").frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { model.preset.preampDB }, set: { value in model.edit { $0.preampDB = (value * 10).rounded() / 10 } }), in: -24...6)
                .frame(maxWidth: 260)
            TextField("", value: Binding(get: { model.preset.preampDB }, set: { value in model.edit { $0.preampDB = min(max(value, -48), 24) } }), format: .number.precision(.fractionLength(0...2)))
                .frame(width: 60)
            Text("dB")
            Button("Auto", action: model.autoPreamp)
                .help("Set the preamp so the loudest boost peaks at 0 dB")
            Spacer()
            if peak > 0.05 {
                Label(String(format: "Peaks at +%.1f dB, may clip", peak), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(String(format: "Peak %.1f dB", peak)).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var bandTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bands").font(.headline)
                Text("\(model.preset.filters.count) / \(AppModel.maxBands)").foregroundStyle(.secondary)
                Spacer()
                Text("Drag points on the curve to move bands. Hold ⌥ while dragging to change Q. Double-click to add a band.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add Band") {
                    model.addBand()
                    selectedBand = model.preset.filters.count - 1
                }
                .disabled(model.preset.filters.count >= AppModel.maxBands)
            }
            HStack(spacing: 8) {
                Text("#").frame(width: 22)
                Text("On").frame(width: 28)
                Text("Type").frame(width: 110, alignment: .leading)
                Text("Frequency").frame(width: 100, alignment: .leading)
                Text("Gain").frame(maxWidth: .infinity, alignment: .leading)
                Text("Q").frame(width: 60, alignment: .leading)
                Spacer().frame(width: 24)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.preset.filters.indices, id: \.self) { index in
                        BandRow(index: index, filter: band(index), isSelected: selectedBand == index) {
                            model.removeBand(at: index)
                            selectedBand = nil
                        }
                        .onTapGesture { selectedBand = index }
                    }
                }
            }
        }
    }

    /// A binding to one band that routes changes through `AppModel.edit` and keeps values in range.
    private func band(_ index: Int) -> Binding<Filter> {
        Binding(
            get: { model.preset.filters.indices.contains(index) ? model.preset.filters[index] : Filter(type: .peaking, frequency: 1000) },
            set: { filter in
                model.edit { preset in
                    guard preset.filters.indices.contains(index) else { return }
                    preset.filters[index] = filter.clamped()
                }
            }
        )
    }

    // MARK: Actions

    private func saveToLibrary() {
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "The preset is added to your library's Imported folder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = model.preset.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if PresetLibrary.importedPresetExists(named: name) {
            let confirm = NSAlert()
            confirm.messageText = "Replace “\(name)”?"
            confirm.informativeText = "A preset with this name is already in your library."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try model.saveToLibrary(named: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PresetLibrary.fileName(for: model.preset.name)
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.export(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BandRow: View {
    let index: Int
    @Binding var filter: Filter
    let isSelected: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .frame(width: 22)
            Toggle("", isOn: $filter.isEnabled).labelsHidden().frame(width: 28)
            Picker("", selection: $filter.type) {
                ForEach(FilterType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            HStack(spacing: 2) {
                TextField("", value: $filter.frequency, format: .number.precision(.fractionLength(0...1)))
                Text("Hz").foregroundStyle(.secondary)
            }
            .frame(width: 100)
            HStack(spacing: 6) {
                Slider(value: Binding(get: { filter.gainDB }, set: { filter.gainDB = ($0 * 10).rounded() / 10 }), in: -20...20)
                TextField("", value: $filter.gainDB, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 52)
                Text("dB").foregroundStyle(.secondary)
            }
            .disabled(!filter.type.usesGain)
            .frame(maxWidth: .infinity)
            TextField("", value: $filter.q, format: .number.precision(.fractionLength(0...3)))
                .frame(width: 60)
            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .frame(width: 24)
        }
        .controlSize(.small)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .opacity(filter.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}

/// The response curve with a draggable handle per band.
private struct EQCurveEditor: View {
    @Bindable var model: AppModel
    @Binding var selectedBand: Int?
    @State private var dragging: Int?
    @State private var dragStartQ = 1.0

    private let dbRange = -20.0...20.0

    var body: some View {
        GeometryReader { geometry in
            let scale = PlotScale(size: geometry.size, db: dbRange)
            Canvas { context, _ in
                scale.drawGrid(in: context, dbStep: 5)
                var zero = Path()
                zero.move(to: scale.point(20, 0))
                zero.addLine(to: scale.point(20_000, 0))
                context.stroke(zero, with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)

                for (index, filter) in model.preset.filters.enumerated() where filter.isEnabled {
                    let single = ParametricPreset(name: "", filters: [filter])
                    let color: Color = index == selectedBand ? .accentColor : .secondary
                    context.stroke(scale.curve { single.responseDB(at: $0) }, with: .color(color.opacity(index == selectedBand ? 0.6 : 0.25)), lineWidth: 1)
                }
                context.stroke(scale.curve { model.preset.responseDB(at: $0) }, with: .color(.accentColor), lineWidth: 2)

                for (index, filter) in model.preset.filters.enumerated() {
                    let center = handlePoint(filter, scale: scale)
                    let rect = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
                    let isSelected = index == selectedBand
                    context.fill(Path(ellipseIn: rect), with: .color(isSelected ? .accentColor : Color(nsColor: .controlBackgroundColor)))
                    context.stroke(Path(ellipseIn: rect), with: .color(filter.isEnabled ? .accentColor : .secondary), lineWidth: 1.5)
                    context.draw(
                        Text("\(index + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(isSelected ? .white : .primary),
                        at: center
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(scale: scale))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                addBand(at: value.location, scale: scale)
            })
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Bands without gain sit on the 0 dB line.
    private func handlePoint(_ filter: Filter, scale: PlotScale) -> CGPoint {
        scale.point(filter.frequency, filter.type.usesGain ? filter.gainDB : 0)
    }

    private func dragGesture(scale: PlotScale) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragging == nil {
                    dragging = nearestBand(to: value.startLocation, scale: scale)
                    selectedBand = dragging
                    if let dragging { dragStartQ = model.preset.filters[dragging].q }
                }
                guard let index = dragging else { return }
                let adjustingQ = NSEvent.modifierFlags.contains(.option)
                model.edit { preset in
                    guard preset.filters.indices.contains(index) else { return }
                    var filter = preset.filters[index]
                    if adjustingQ {
                        // Dragging up narrows the band; 100 points doubles or halves Q.
                        filter.q = dragStartQ * pow(2, -value.translation.height / 100)
                    } else {
                        filter.frequency = scale.frequency(atX: value.location.x).rounded()
                        if filter.type.usesGain { filter.gainDB = (scale.db(atY: value.location.y) * 10).rounded() / 10 }
                    }
                    preset.filters[index] = filter.clamped()
                }
            }
            .onEnded { _ in dragging = nil }
    }

    private func nearestBand(to point: CGPoint, scale: PlotScale) -> Int? {
        model.preset.filters.indices
            .map { ($0, hypot(handlePoint(model.preset.filters[$0], scale: scale).x - point.x, handlePoint(model.preset.filters[$0], scale: scale).y - point.y)) }
            .filter { $0.1 < 14 }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func addBand(at point: CGPoint, scale: PlotScale) {
        guard nearestBand(to: point, scale: scale) == nil, model.preset.filters.count < AppModel.maxBands else { return }
        model.edit { preset in
            preset.filters.append(Filter(
                type: .peaking,
                frequency: scale.frequency(atX: point.x).rounded(),
                gainDB: (scale.db(atY: point.y) * 10).rounded() / 10,
                q: 1
            ).clamped())
        }
        selectedBand = model.preset.filters.count - 1
    }
}

extension FilterType {
    var displayName: String {
        switch self {
        case .peaking: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .notch: "Notch"
        }
    }
}

extension Filter {
    /// Keeps edited values within ranges the filters can realise.
    func clamped() -> Filter {
        var filter = self
        filter.frequency = min(max(frequency, 10), 22_000)
        filter.gainDB = min(max(gainDB, -30), 30)
        filter.q = min(max(q, 0.1), 20)
        return filter
    }
}

extension ParametricPreset {
    /// The highest point of the combined response, preamp included, in dB.
    var peakResponseDB: Double {
        FrequencyResponse.logGrid(pointsPerOctave: 48).map { responseDB(at: $0) }.max() ?? preampDB
    }
}
