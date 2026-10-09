import EQCore
import SwiftUI

/// Curves the AutoEQ graph can show, in drawing order.
enum AutoEQCurve: String, CaseIterable {
    case target, source, error, correction, eq, equalized

    static let defaultSelection = encode([.target, .source, .eq, .equalized])

    var title: String {
        switch self {
        case .target: "Target"
        case .source: "Source"
        case .error: "Error"
        case .correction: "Correction"
        case .eq: "EQ"
        case .equalized: "Equalized"
        }
    }

    var help: String {
        switch self {
        case .target: "The target, with adjustments, aligned to the source"
        case .source: "The source measurement"
        case .error: "Source minus target: where the source is too loud (positive) or quiet (negative)"
        case .correction: "The ideal correction after smoothing, slope limiting and the max gain cap"
        case .eq: "What the fitted filters do, before preamp"
        case .equalized: "Predicted result: the source with the EQ applied"
        }
    }

    var color: Color {
        switch self {
        case .target: .green
        case .source: .primary
        case .error: .red
        case .correction: .orange
        case .eq: .purple
        case .equalized: .blue
        }
    }

    func values(in result: AutoEQResult, smoothed: Bool) -> [Double] {
        switch self {
        case .target: result.target
        case .source: smoothed ? result.sourceSmoothed : result.source
        case .error: smoothed ? result.errorSmoothed : result.error
        case .correction: result.equalization
        case .eq: result.fitted
        case .equalized: smoothed ? result.equalizedSourceSmoothed : result.equalizedSource
        }
    }

    static func encode(_ curves: Set<AutoEQCurve>) -> String {
        allCases.filter(curves.contains).map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ text: String) -> Set<AutoEQCurve> {
        Set(text.split(separator: ",").compactMap { AutoEQCurve(rawValue: String($0)) })
    }
}

/// Graph of the selected AutoEQ curves with a hover readout.
struct AutoEQPlot: View {
    let result: AutoEQResult?
    let curves: Set<AutoEQCurve>
    let smoothed: Bool
    @State private var hoverX: Double?

    private var shown: [AutoEQCurve] { AutoEQCurve.allCases.filter(curves.contains) }

    /// A dB range that fits the visible curves, in 5 dB steps, at least ±10 dB and at most ±40 dB.
    private var dbRange: ClosedRange<Double> {
        guard let result, !shown.isEmpty else { return -20...20 }
        let values = shown.flatMap { $0.values(in: result, smoothed: smoothed) }
        let low = max(((values.min() ?? -10) - 2) / 5, -8).rounded(.down) * 5
        let high = min(((values.max() ?? 10) + 2) / 5, 8).rounded(.up) * 5
        return min(low, -10)...max(high, 10)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = PlotScale(size: geometry.size, db: dbRange)
            Canvas { context, size in
                scale.drawGrid(in: context, dbStep: dbRange.upperBound - dbRange.lowerBound > 40 ? 10 : 5)
                guard let result else { return }

                for curve in shown {
                    let values = curve.values(in: result, smoothed: smoothed)
                    var path = Path()
                    for (index, frequency) in result.frequencies.enumerated() {
                        let point = scale.point(frequency, values[index])
                        index == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                    if curve == .target {
                        // A wide translucent band, as autoeq.app draws it, so curves on top stay readable.
                        context.stroke(path, with: .color(curve.color.opacity(0.3)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    } else {
                        context.stroke(path, with: .color(curve.color), lineWidth: curve == .eq || curve == .equalized ? 1.8 : 1.2)
                    }
                }

                if let hoverX {
                    var line = Path()
                    line.move(to: CGPoint(x: hoverX, y: 0))
                    line.addLine(to: CGPoint(x: hoverX, y: size.height))
                    context.stroke(line, with: .color(.secondary.opacity(0.6)), lineWidth: 0.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let hoverX, let result {
                    readout(at: scale.frequency(atX: hoverX), result: result)
                        .padding(8)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func readout(at frequency: Double, result: AutoEQResult) -> some View {
        let index = result.frequencies.indices.min { abs(result.frequencies[$0] - frequency) < abs(result.frequencies[$1] - frequency) }!
        return VStack(alignment: .trailing, spacing: 2) {
            Text(frequency >= 1_000 ? String(format: "%.2f kHz", result.frequencies[index] / 1_000) : String(format: "%.0f Hz", result.frequencies[index]))
                .fontWeight(.semibold)
            ForEach(shown, id: \.self) { curve in
                Text(String(format: "%@ %+.1f dB", curve.title, curve.values(in: result, smoothed: smoothed)[index]))
                    .foregroundStyle(curve.color)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
