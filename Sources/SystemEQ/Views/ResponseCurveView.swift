import EQCore
import SwiftUI

/// Plots a preset's combined frequency response from 20 Hz to 20 kHz on a log axis.
struct ResponseCurveView: View {
    let preset: ParametricPreset

    private let minFrequency = 20.0
    private let maxFrequency = 20_000.0
    private let rangeDB = 15.0

    var body: some View {
        Canvas { context, size in
            func x(_ frequency: Double) -> Double {
                log10(frequency / minFrequency) / log10(maxFrequency / minFrequency) * size.width
            }
            func y(_ db: Double) -> Double {
                (1 - (min(max(db, -rangeDB), rangeDB) + rangeDB) / (2 * rangeDB)) * size.height
            }

            var grid = Path()
            for frequency in [100.0, 1_000, 10_000] {
                grid.move(to: CGPoint(x: x(frequency), y: 0))
                grid.addLine(to: CGPoint(x: x(frequency), y: size.height))
            }
            for db in [-10.0, -5, 5, 10] {
                grid.move(to: CGPoint(x: 0, y: y(db)))
                grid.addLine(to: CGPoint(x: size.width, y: y(db)))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            context.stroke(zero, with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)

            for (frequency, label) in [(100.0, "100"), (1_000, "1k"), (10_000, "10k")] {
                context.draw(
                    Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                    at: CGPoint(x: x(frequency) + 3, y: size.height - 2),
                    anchor: .bottomLeading
                )
            }

            var curve = Path()
            let steps = Int(size.width)
            for step in 0...steps {
                let frequency = minFrequency * pow(maxFrequency / minFrequency, Double(step) / Double(steps))
                let point = CGPoint(x: x(frequency), y: y(preset.responseDB(at: frequency)))
                step == 0 ? curve.move(to: point) : curve.addLine(to: point)
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Frequency response of \(preset.name)")
    }
}
