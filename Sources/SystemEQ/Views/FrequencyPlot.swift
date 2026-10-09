import SwiftUI

/// Maps frequency (log scale) and dB to points in a plot of a given size.
struct PlotScale {
    var size: CGSize
    var frequencies: ClosedRange<Double> = 20...20_000
    var db: ClosedRange<Double>

    func x(_ frequency: Double) -> Double {
        log(frequency / frequencies.lowerBound) / log(frequencies.upperBound / frequencies.lowerBound) * size.width
    }

    func y(_ value: Double) -> Double {
        (1 - (min(max(value, db.lowerBound), db.upperBound) - db.lowerBound) / (db.upperBound - db.lowerBound)) * size.height
    }

    func frequency(atX x: Double) -> Double {
        frequencies.lowerBound * pow(frequencies.upperBound / frequencies.lowerBound, min(max(x / size.width, 0), 1))
    }

    func db(atY y: Double) -> Double {
        db.upperBound - min(max(y / size.height, 0), 1) * (db.upperBound - db.lowerBound)
    }

    func point(_ frequency: Double, _ value: Double) -> CGPoint {
        CGPoint(x: x(frequency), y: y(value))
    }

    /// A path through `value(frequency)` sampled once per horizontal point.
    func curve(_ value: (Double) -> Double) -> Path {
        var path = Path()
        let steps = max(Int(size.width), 2)
        for step in 0...steps {
            let frequency = self.frequency(atX: Double(step) / Double(steps) * size.width)
            let point = point(frequency, value(frequency))
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    /// Frequency and dB grid lines with labels.
    func drawGrid(in context: GraphicsContext, dbStep: Double, labelDB: Bool = true) {
        var grid = Path()
        let decades = [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
        for frequency in decades where frequencies.contains(frequency) {
            grid.move(to: CGPoint(x: x(frequency), y: 0))
            grid.addLine(to: CGPoint(x: x(frequency), y: size.height))
        }
        var value = (db.lowerBound / dbStep).rounded(.up) * dbStep
        while value <= db.upperBound {
            grid.move(to: CGPoint(x: 0, y: y(value)))
            grid.addLine(to: CGPoint(x: size.width, y: y(value)))
            if labelDB {
                context.draw(
                    Text("\(Int(value))").font(.system(size: 9)).foregroundStyle(.secondary),
                    at: CGPoint(x: 3, y: y(value) - 1), anchor: .bottomLeading
                )
            }
            value += dbStep
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)

        for frequency in decades where frequencies.contains(frequency) && frequency < frequencies.upperBound {
            let label = frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
            context.draw(
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                at: CGPoint(x: x(frequency) + 3, y: size.height - 2), anchor: .bottomLeading
            )
        }
    }
}
