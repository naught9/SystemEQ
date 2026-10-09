import AppKit
import EQCore
import SwiftUI

/// Builds a parametric preset that makes one measured headphone (source) match another
/// headphone or a target curve, like autoeq.app.
struct AutoEQView: View {
    @Bindable var model: AppModel
    @AppStorage("autoEQSource") private var sourceID: String?
    @AppStorage("autoEQTarget") private var targetID: String?
    @State private var options = AutoEQOptions()
    @State private var result: AutoEQResult?
    @State private var isFitting = false
    @State private var name = ""
    @State private var errorMessage: String?

    private struct Inputs: Equatable {
        var sourceID: String?
        var targetID: String?
        var options: AutoEQOptions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            settings.frame(width: 280)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                plot
                summary
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 620)
        .task(id: Inputs(sourceID: sourceID, targetID: targetID, options: options)) { await refit() }
        .alert("Couldn't save preset", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var source: PresetLibrary.Measurement? { model.library.measurements.first { $0.id == sourceID } }
    private var target: PresetLibrary.Measurement? { model.library.measurements.first { $0.id == targetID } }

    // MARK: Settings

    private var settings: some View {
        Form {
            Section {
                measurementPicker("Source", selection: $sourceID)
                measurementPicker("Target", selection: $targetID)
                if model.library.measurements.isEmpty {
                    Text("Add a folder containing frequency response measurements (two columns: frequency and dB) from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Make the source sound like the target")
            }

            Section("Target adjustments") {
                slider("Bass boost", value: $options.bassBoostDB, range: -10...10, unit: "dB")
                slider("Treble", value: $options.trebleDB, range: -10...10, unit: "dB")
                slider("Tilt", value: $options.tiltDBPerOctave, range: -2...2, step: 0.1, unit: "dB/oct")
            }

            Section("Filters") {
                slider("Max boost", value: $options.maxBoostDB, range: 0...12, unit: "dB")
                Stepper(value: $options.peakingFilterCount, in: 1...(AppModel.maxBands - 2)) {
                    Text("Peaking filters: \(options.peakingFilterCount)")
                }
                Text("Plus a 105 Hz low shelf and a 10 kHz high shelf, as AutoEQ uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func measurementPicker(_ title: String, selection: Binding<String?>) -> some View {
        let groups = Dictionary(grouping: model.library.measurements, by: \.group)
        return Picker(title, selection: selection) {
            Text("None").tag(String?.none)
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? []) { measurement in
                        Text(measurement.response.name).tag(Optional(measurement.id))
                    }
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0.5, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%+.1f %@", value.wrappedValue, unit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: Results

    private var plot: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                let scale = PlotScale(size: size, db: -20...20)
                scale.drawGrid(in: context, dbStep: 5)
                guard let result else { return }

                func path(_ values: [Double]) -> Path {
                    var path = Path()
                    for (index, frequency) in result.frequencies.enumerated() {
                        let point = scale.point(frequency, values[index])
                        index == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                    return path
                }
                context.stroke(path(result.source), with: .color(.secondary), lineWidth: 1.2)
                context.stroke(path(result.target), with: .color(.green), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                context.stroke(path(result.equalizedSource), with: .color(.blue), lineWidth: 1.5)
                context.stroke(path(result.equalization), with: .color(.orange.opacity(0.7)), lineWidth: 1)
                context.stroke(path(result.fitted), with: .color(.accentColor), lineWidth: 2)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isFitting { ProgressView().controlSize(.small).padding(8) }
            }
            .overlay {
                if result == nil && !isFitting {
                    Text("Choose a source and a target").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                legend("Source", .secondary)
                legend("Target", .green, dashed: true)
                legend("Source with EQ", .blue)
                legend("Correction needed", .orange)
                legend("Fitted EQ", .accentColor)
            }
            .font(.caption)
        }
    }

    private func legend(_ title: String, _ color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 16, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 2] : []))
            .frame(width: 16, height: 8)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result {
                HStack(spacing: 16) {
                    Text(String(format: "Fit error %.2f dB RMS", result.rmsErrorDB))
                    Text(String(format: "Preamp %.2f dB", result.preset.preampDB))
                    Text("\(result.preset.filters.count) filters")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                ScrollView {
                    Text(result.preset.equalizerAPOText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(6)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                TextField("Preset name", text: $name)
                    .frame(maxWidth: 320)
                Spacer()
                Button("Use Now") { if let preset = namedPreset { model.useUnsaved(preset) } }
                    .help("Listen to this preset now. You can then fine-tune it in the Equalizer window.")
                Button("Save as Preset", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(result == nil)
        }
    }

    private var namedPreset: ParametricPreset? {
        guard var preset = result?.preset else { return nil }
        preset.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? preset.name : name
        return preset
    }

    // MARK: Actions

    private func refit() async {
        guard let source, let target else {
            result = nil
            return
        }
        // Wait briefly so dragging a slider doesn't start a fit for every intermediate value.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        isFitting = true
        defer { isFitting = false }
        let defaultName = "\(source.response.name) -> \(target.response.name)"
        let options = options
        let fitted = await Task.detached(priority: .userInitiated) {
            AutoEQ.fit(source: source.response, target: target.response, name: defaultName, options: options)
        }.value
        guard !Task.isCancelled else { return }
        if result == nil || name.isEmpty || name == result?.preset.name { name = defaultName }
        result = fitted
    }

    private func save() {
        guard let preset = namedPreset else { return }
        if PresetLibrary.importedPresetExists(named: preset.name) {
            let confirm = NSAlert()
            confirm.messageText = "Replace “\(preset.name)”?"
            confirm.informativeText = "A preset with this name is already in your library."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            model.useUnsaved(preset)
            try model.saveToLibrary(named: preset.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
