import EQCore
import SwiftUI

/// Pulls post-EQ audio from the engine each frame and keeps the analysis state for display.
/// Deliberately not observable: the TimelineView redraws every frame anyway.
@MainActor
final class VisualizerModel {
    var fftSize = 8192
    var tiltDBPerOctave = 0.0

    private(set) var analyzer: SpectrumAnalyzer?
    private(set) var meter: LoudnessMeter?
    private(set) var peaks: (left: Double, right: Double) = (-.infinity, -.infinity)
    private(set) var peakHolds: (left: Double, right: Double) = (-.infinity, -.infinity)

    /// Display columns (one per two points of width) with smoothing and peak hold, in dB.
    private(set) var columns: [Double] = []
    private(set) var columnHolds: [Double] = []
    private var holdTimes: [Double] = []

    private var readPosition = 0
    private var history: [Float] = []
    private var scratch: [Float] = []
    private var lastUpdate: Date?
    private var lastPeakReset = Date.distantPast

    private let maxHistory = 1 << 16
    private let fallDBPerSecond = 40.0
    private let holdSeconds = 1.5

    func update(from engine: SystemAudioEQ, now: Date, columnCount: Int, scale: PlotScale) {
        guard lastUpdate != now else { return }
        let elapsed = min(lastUpdate.map { now.timeIntervalSince($0) } ?? 0, 0.25)
        lastUpdate = now

        if analyzer?.size != fftSize || analyzer?.sampleRate != engine.sampleRate {
            analyzer = SpectrumAnalyzer(size: fftSize, sampleRate: engine.sampleRate)
        }
        if meter == nil || meter?.sampleRate != engine.sampleRate {
            meter = LoudnessMeter(sampleRate: engine.sampleRate)
        }

        scratch.removeAll(keepingCapacity: true)
        engine.meterBuffer.read(from: &readPosition, into: &scratch)
        meter?.process(interleaved: scratch[...])
        for index in Swift.stride(from: 0, to: scratch.count - 1, by: 2) {
            history.append((scratch[index] + scratch[index + 1]) / 2)
        }
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }

        updatePeaks(now: now, elapsed: elapsed)
        guard let analyzer else { return }
        analyzer.analyze(history[...])
        updateColumns(analyzer: analyzer, count: columnCount, scale: scale, elapsed: elapsed, now: now.timeIntervalSinceReferenceDate)
    }

    func resetLoudness() {
        meter?.reset()
        peakHolds = (-.infinity, -.infinity)
    }

    private func updatePeaks(now: Date, elapsed: Double) {
        guard let meter else { return }
        let current = meter.takePeaks()
        peaks = (max(current.left, peaks.left - fallDBPerSecond * elapsed), max(current.right, peaks.right - fallDBPerSecond * elapsed))
        peakHolds = (max(peakHolds.left, current.left), max(peakHolds.right, current.right))
    }

    /// Reduces FFT bins to display columns: the loudest bin within each column, or interpolation
    /// between bins where columns are narrower than bins (in the bass). Columns fall at a fixed
    /// rate rather than jumping down, and remember their recent maximum.
    private func updateColumns(analyzer: SpectrumAnalyzer, count: Int, scale: PlotScale, elapsed: Double, now: Double) {
        if columns.count != count {
            columns = [Double](repeating: -200, count: count)
            columnHolds = columns
            holdTimes = [Double](repeating: 0, count: count)
        }
        let binWidth = analyzer.sampleRate / Double(analyzer.size)
        let magnitudes = analyzer.magnitudesDB
        let lastBin = magnitudes.count - 1

        for column in 0..<count {
            let lowFrequency = scale.frequency(atX: Double(column) / Double(count) * scale.size.width)
            let highFrequency = scale.frequency(atX: Double(column + 1) / Double(count) * scale.size.width)
            let lowBin = Int((lowFrequency / binWidth).rounded(.up))
            let highBin = min(Int(highFrequency / binWidth), lastBin)

            var value: Double
            if lowBin <= highBin {
                value = Double(magnitudes[lowBin...highBin].max()!)
            } else {
                let position = (lowFrequency + highFrequency) / 2 / binWidth
                let below = min(Int(position), lastBin - 1)
                let t = position - Double(below)
                value = Double(magnitudes[below]) * (1 - t) + Double(magnitudes[below + 1]) * t
            }
            value += tiltDBPerOctave * log2((lowFrequency + highFrequency) / 2 / 1_000)

            columns[column] = max(value, columns[column] - fallDBPerSecond * elapsed)
            if value >= columnHolds[column] {
                columnHolds[column] = value
                holdTimes[column] = now
            } else if now - holdTimes[column] > holdSeconds {
                columnHolds[column] = max(value, columnHolds[column] - fallDBPerSecond * elapsed)
            }
        }
    }
}

struct VisualizerView: View {
    let engine: SystemAudioEQ
    @State private var model = VisualizerModel()
    @State private var fftSize = 8192
    @State private var tilt = 0.0
    @State private var floorDB = -100.0

    private static let fftSizes = [4096, 8192, 16384, 32768]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            TimelineView(.animation) { timeline in
                VStack(spacing: 12) {
                    GeometryReader { geometry in
                        let scale = PlotScale(size: geometry.size, db: floorDB...0)
                        let _ = model.update(from: engine, now: timeline.date, columnCount: max(Int(geometry.size.width / 2), 2), scale: scale)
                        SpectrumCanvas(model: model, scale: scale)
                    }
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    LoudnessPanel(model: model)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .onChange(of: fftSize, initial: true) { model.fftSize = fftSize }
        .onChange(of: tilt, initial: true) { model.tiltDBPerOctave = tilt }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Resolution", selection: $fftSize) {
                ForEach(Self.fftSizes, id: \.self) { size in
                    Text("\(size / 1024)k · \(String(format: "%.1f", engine.sampleRate / Double(size))) Hz").tag(size)
                }
            }
            .frame(width: 220)
            .help("FFT size. Larger sizes resolve bass detail better but respond more slowly.")
            Picker("Tilt", selection: $tilt) {
                Text("None").tag(0.0)
                Text("3 dB/oct").tag(3.0)
                Text("4.5 dB/oct").tag(4.5)
            }
            .frame(width: 170)
            .help("Tilts the display so music, which has less energy in the treble, looks flatter")
            Picker("Floor", selection: $floorDB) {
                Text("-80 dB").tag(-80.0)
                Text("-100 dB").tag(-100.0)
                Text("-120 dB").tag(-120.0)
            }
            .frame(width: 140)
            Spacer()
            Text("After EQ").foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }
}

private struct SpectrumCanvas: View {
    let model: VisualizerModel
    let scale: PlotScale

    var body: some View {
        Canvas { context, size in
            scale.drawGrid(in: context, dbStep: 20)
            let columns = model.columns
            guard columns.count > 1 else { return }
            let step = size.width / Double(columns.count)

            var fill = Path()
            var line = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in columns.enumerated() {
                let point = CGPoint(x: (Double(index) + 0.5) * step, y: scale.y(value))
                fill.addLine(to: point)
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [.cyan.opacity(0.55), .blue.opacity(0.1)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(.cyan), lineWidth: 1.2)

            var holds = Path()
            for (index, value) in model.columnHolds.enumerated() {
                let point = CGPoint(x: (Double(index) + 0.5) * step, y: scale.y(value))
                index == 0 ? holds.move(to: point) : holds.addLine(to: point)
            }
            context.stroke(holds, with: .color(.white.opacity(0.45)), lineWidth: 0.8)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct LoudnessPanel: View {
    let model: VisualizerModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            reading("Momentary", model.meter?.momentaryLUFS)
            reading("Short-term", model.meter?.shortTermLUFS)
            reading("Integrated", model.meter?.integratedLUFS)
            VStack(alignment: .leading, spacing: 6) {
                PeakBar(label: "L", value: model.peaks.left, hold: model.peakHolds.left)
                PeakBar(label: "R", value: model.peaks.right, hold: model.peakHolds.right)
            }
            .frame(maxWidth: .infinity)
            Button("Reset", action: model.resetLoudness)
                .controlSize(.small)
                .help("Restart integrated loudness and peak hold")
        }
        .frame(height: 64)
    }

    private func reading(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(formatted(value))
                .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
            Text("LUFS").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 100, alignment: .leading)
    }

    private func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite, value > -70 else { return "–" }
        return String(format: "%.1f", value)
    }
}

/// Horizontal sample peak meter from -60 to 0 dBFS with a numeric peak hold.
private struct PeakBar: View {
    let label: String
    let value: Double
    let hold: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let fraction = { (db: Double) in min(max((db + 60) / 60, 0), 1) }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * fraction(value))
                        }
                    Rectangle()
                        .fill(hold > -0.1 ? .red : .primary)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * fraction(hold) - 1)
                        .opacity(hold.isFinite ? 1 : 0)
                }
            }
            .frame(height: 10)
            Text(hold.isFinite ? String(format: "%.1f", hold) : "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(hold > -0.1 ? .red : .secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
