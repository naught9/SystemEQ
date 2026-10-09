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
    @AppStorage("autoEQShowAdvanced") private var showAdvanced = false
    @AppStorage("autoEQSmoothed") private var showSmoothed = true
    @AppStorage("autoEQCurves") private var storedCurves = AutoEQCurve.defaultSelection
    @AppStorage("autoEQOptions") private var storedOptions = Data()

    private var visibleCurves: Set<AutoEQCurve> {
        get { AutoEQCurve.decode(storedCurves) }
        nonmutating set { storedCurves = AutoEQCurve.encode(newValue) }
    }

    private struct Inputs: Equatable {
        var sourceID: String?
        var targetID: String?
        var options: AutoEQOptions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            settings.frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                plot
                summary
            }
        }
        .padding(16)
        .frame(minWidth: 960, minHeight: 680)
        .task(id: Inputs(sourceID: sourceID, targetID: targetID, options: fitOptions)) { await refit() }
        .onAppear {
            if let saved = try? JSONDecoder().decode(AutoEQOptions.self, from: storedOptions) { options = saved }
        }
        .onChange(of: options) {
            storedOptions = (try? JSONEncoder().encode(options)) ?? Data()
        }
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
                if let source { rigPicker(for: source) }
                measurementPicker("Target", selection: $targetID)
                if let target { rigPicker(for: target) }
                if source != nil && target != nil {
                    rigStatus
                }
                if model.library.measurements.isEmpty {
                    Text("Add a folder containing frequency response measurements (two columns: frequency and dB) from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Make the source sound like the target")
            }

            Section("Target") {
                slider("Bass", $options.bassBoostDB, -20...20, step: 0.5, format: "%+.1f dB",
                       help: "Raises (positive) or lowers (negative) the target's bass")
                slider("Bass below", $options.bassBoostFrequency, 40...200, step: 5, format: "%.0f Hz",
                       help: "Corner frequency of the bass shelf: the bass gain applies below it")
                slider("Treble", $options.trebleDB, -15...15, step: 0.5, format: "%+.1f dB",
                       help: "Raises (positive) or lowers (negative) the target's treble")
                slider("Treble above", $options.trebleBoostFrequency, 1_000...20_000, step: 500, format: "%.0f Hz",
                       help: "Corner frequency of the treble shelf: the treble gain applies above it")
                slider("Tilt", $options.tiltDBPerOctave, -1.5...1.5, step: 0.1, format: "%+.1f dB/oct")
                slider("Max gain", $options.maxBoostDB, 0...36, step: 1, format: "%.0f dB",
                       help: "Largest boost the EQ may apply")
            }

            Section("Filters") {
                Stepper(value: $options.peakingFilterCount, in: 1...(AppModel.maxBands - 2)) {
                    Text("Peaking filters: \(options.peakingFilterCount)")
                }
                Text("Plus a 105 Hz low shelf and a 10 kHz high shelf, as AutoEQ uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    advancedSettings
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var advancedSettings: some View {
        slider("Bass Q", $options.bassBoostQ, 0.3...0.8, step: 0.05, format: "%.2f",
               help: "Steepness of the bass shelf's transition")
        slider("Treble Q", $options.trebleBoostQ, 0.3...0.8, step: 0.05, format: "%.2f",
               help: "Steepness of the treble shelf's transition")
        slider("Max slope", $options.maxSlopeDBPerOctave, 6...36, step: 3, format: "%.0f dB/oct",
               help: "Steepest slope the correction curve may have")
        slider("Smoothing", $options.windowSize, 0...1, step: 0.01, format: "%.2f oct",
               help: "Smoothing for the smoothed source and error curves. As in AutoEq, the correction always uses 1/12 octave.")
        slider("Treble smoothing", $options.trebleWindowSize, 0...3, step: 0.1, format: "%.1f oct",
               help: "Smoothing above the transition region for the smoothed curves. As in AutoEq, the correction always uses 2 octaves.")
        slider("Treble gain multiplier", $options.trebleGainK, 0...1, step: 0.05, format: "%.2f",
               help: "Scales the correction above the transition region; 1 applies it fully")
        rangeSliders("Transition region", $options.trebleFrequencies, 1_000...20_000, step: 100, gap: 100,
                     help: "Where treble smoothing and the treble gain multiplier take over")
        rangeSliders("Optimizer range", $options.optimizerFrequencyRange, 20...20_000, step: 10, gap: 500,
                     help: "Frequencies the filters are fitted over")
        Button("Reset to autoeq.app defaults") {
            options = AutoEQOptions()
        }
    }

    /// Options for fitting, including the rigs of the chosen source and target.
    private var fitOptions: AutoEQOptions {
        var options = options
        options.sourceRig = source.flatMap(model.library.rig(for:))
        options.targetRig = target.flatMap(model.library.rig(for:))
        return options
    }

    private func rigPicker(for measurement: PresetLibrary.Measurement) -> some View {
        Picker("Measured on", selection: Binding(
            get: { model.library.rig(for: measurement) },
            set: { model.library.setRig($0, for: measurement) }
        )) {
            Text("Unknown").tag(MeasurementRig?.none)
            ForEach(MeasurementRig.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }
        .font(.caption)
        .help("The rig this curve was measured on. Guessed from \"711\" or \"5128\" in the file or folder name.")
    }

    private var rigStatus: some View {
        let sourceRig = fitOptions.sourceRig, targetRig = fitOptions.targetRig
        let (message, icon, color): (String, String, Color) = switch (sourceRig, targetRig) {
        case let (source?, target?) where source != target:
            ("Target converted from \(target.rawValue) to \(source.rawValue)", "arrow.triangle.2.circlepath", .secondary)
        case (_?, _?):
            ("Source and target are from the same rig", "checkmark.circle", .secondary)
        default:
            ("Set both rigs so a target from a different rig can be converted", "exclamationmark.triangle", .orange)
        }
        return Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
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

    private func slider(
        _ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
        step: Double, format: String, help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
        .help(help ?? "")
    }

    /// Two sliders editing the bounds of a frequency range, kept at least `gap` apart.
    private func rangeSliders(
        _ title: String, _ range: Binding<ClosedRange<Double>>, _ limits: ClosedRange<Double>,
        step: Double, gap: Double, help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f–%.0f Hz", range.wrappedValue.lowerBound, range.wrappedValue.upperBound))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { range.wrappedValue.lowerBound },
                set: { range.wrappedValue = min($0, range.wrappedValue.upperBound - gap)...range.wrappedValue.upperBound }
            ), in: limits, step: step)
            Slider(value: Binding(
                get: { range.wrappedValue.upperBound },
                set: { range.wrappedValue = range.wrappedValue.lowerBound...max($0, range.wrappedValue.lowerBound + gap) }
            ), in: limits, step: step)
        }
        .help(help)
    }

    // MARK: Results

    private var plot: some View {
        VStack(alignment: .leading, spacing: 6) {
            AutoEQPlot(result: result, curves: visibleCurves, smoothed: showSmoothed)
                .overlay {
                    if isFitting { ProgressView().controlSize(.small).padding(8) }
                }
                .overlay {
                    if result == nil && !isFitting {
                        Text("Choose a source and a target").foregroundStyle(.secondary)
                    }
                }

            HStack(spacing: 12) {
                ForEach(AutoEQCurve.allCases, id: \.self) { curve in
                    Toggle(isOn: Binding(
                        get: { visibleCurves.contains(curve) },
                        set: { isOn in
                            if isOn { visibleCurves.insert(curve) } else { visibleCurves.remove(curve) }
                        }
                    )) {
                        Text(curve.title).foregroundStyle(curve.color)
                    }
                    .toggleStyle(.checkbox)
                    .help(curve.help)
                }
                Spacer()
                Toggle("Smoothed", isOn: $showSmoothed)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Show the source, error and equalized curves smoothed")
            }
            .font(.caption)
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
        let options = fitOptions
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
