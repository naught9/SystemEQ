import EQCore
import SwiftUI

/// A compact, read-only plot of a preset's combined frequency response.
struct ResponseCurveView: View {
    let preset: ParametricPreset

    var body: some View {
        Canvas { context, size in
            let scale = PlotScale(size: size, db: -15...15)
            scale.drawGrid(in: context, dbStep: 5, labelDB: false)
            context.stroke(scale.curve { preset.responseDB(at: $0) }, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Frequency response of \(preset.name)")
    }
}
