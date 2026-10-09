import Foundation

/// Settings for `AutoEQ.fit`. The defaults match AutoEQ's standard 10-band parametric output:
/// a 105 Hz low shelf, eight peaking filters and a 10 kHz high shelf.
public struct AutoEQOptions: Sendable, Equatable {
    public var peakingFilterCount = 8
    /// Largest boost the equalization may ask for, in dB. Cuts are not limited.
    public var maxBoostDB = 6.0
    public var peakingFrequencyRange = 20.0...10_000.0
    public var qRange = 0.18...6.0
    public var lowShelf: (frequency: Double, q: Double)? = (105, 0.7)
    public var highShelf: (frequency: Double, q: Double)? = (10_000, 0.7)
    /// Source and target are aligned at this frequency.
    public var normalizationFrequency = 1_000.0
    /// Above this frequency, smoothing widens from 1/12 octave towards 1/2 octave,
    /// because treble measurements vary too much between fittings to correct finely.
    public var trebleSmoothingStart = 6_000.0
    public var trebleSmoothingEnd = 8_000.0
    public var sampleRate = 48_000.0
    public var iterations = 1_500

    // Adjustments to the target, like autoeq.app's sliders.
    /// Low shelf at 105 Hz, Q 0.7.
    public var bassBoostDB = 0.0
    /// High shelf at 10 kHz, Q 0.7.
    public var trebleDB = 0.0
    /// Constant slope pivoting at 1 kHz.
    public var tiltDBPerOctave = 0.0

    public init() {}

    public static func == (lhs: AutoEQOptions, rhs: AutoEQOptions) -> Bool {
        lhs.peakingFilterCount == rhs.peakingFilterCount && lhs.maxBoostDB == rhs.maxBoostDB
            && lhs.peakingFrequencyRange == rhs.peakingFrequencyRange && lhs.qRange == rhs.qRange
            && lhs.lowShelf?.frequency == rhs.lowShelf?.frequency && lhs.lowShelf?.q == rhs.lowShelf?.q
            && lhs.highShelf?.frequency == rhs.highShelf?.frequency && lhs.highShelf?.q == rhs.highShelf?.q
            && lhs.normalizationFrequency == rhs.normalizationFrequency && lhs.sampleRate == rhs.sampleRate
            && lhs.iterations == rhs.iterations && lhs.bassBoostDB == rhs.bassBoostDB
            && lhs.trebleDB == rhs.trebleDB && lhs.tiltDBPerOctave == rhs.tiltDBPerOctave
    }
}

public struct AutoEQResult: Sendable {
    public let preset: ParametricPreset
    public let frequencies: [Double]
    /// Source and target, offset so they meet at the normalization frequency.
    public let source: [Double]
    public let target: [Double]
    /// The smoothed, boost-limited correction the filters aim for.
    public let equalization: [Double]
    /// What the fitted filters actually do, excluding preamp.
    public let fitted: [Double]
    /// Weighted RMS difference between `fitted` and `equalization`, in dB.
    public let rmsErrorDB: Double
    /// Predicted result: source with the fitted EQ applied.
    public var equalizedSource: [Double] { zip(source, fitted).map(+) }
}

/// Generates a parametric EQ that makes a headphone's measured `source` response sound like `target`,
/// following the approach of AutoEQ (github.com/jaakkopasanen/AutoEq).
public enum AutoEQ {
    static let pointsPerOctave = 48.0

    public static func fit(source: FrequencyResponse, target: FrequencyResponse, name: String, options: AutoEQOptions = AutoEQOptions()) -> AutoEQResult {
        let grid = FrequencyResponse.logGrid(from: 20, to: 20_000, pointsPerOctave: pointsPerOctave)
        var sourceDB = source.resampled(to: grid)
        let adjustments = ParametricPreset(name: "", filters: [
            Filter(type: .lowShelf, frequency: 105, gainDB: options.bassBoostDB, q: 0.7),
            Filter(type: .highShelf, frequency: 10_000, gainDB: options.trebleDB, q: 0.7),
        ])
        var targetDB = zip(target.resampled(to: grid), grid).map { value, frequency in
            value + adjustments.responseDB(at: frequency, sampleRate: options.sampleRate) + options.tiltDBPerOctave * log2(frequency / 1_000)
        }

        // Align both curves at the normalization frequency, using a 1-octave average to ignore narrow features.
        let octaveAverage = { (values: [Double]) in
            smoothed(values, grid: grid, pointsPerOctave: pointsPerOctave) { _ in 1 }
        }
        let normIndex = grid.indices.min { abs(log2(grid[$0] / options.normalizationFrequency)) < abs(log2(grid[$1] / options.normalizationFrequency)) }!
        let sourceOffset = octaveAverage(sourceDB)[normIndex], targetOffset = octaveAverage(targetDB)[normIndex]
        sourceDB = sourceDB.map { $0 - sourceOffset }
        targetDB = targetDB.map { $0 - targetOffset }

        let difference = zip(targetDB, sourceDB).map(-)
        let equalization = smoothed(difference, grid: grid, pointsPerOctave: pointsPerOctave) { frequency in
            let t = min(max(log(frequency / options.trebleSmoothingStart) / log(options.trebleSmoothingEnd / options.trebleSmoothingStart), 0), 1)
            return 1.0 / 12 + t * (0.5 - 1.0 / 12)
        }
        .map { min($0, options.maxBoostDB) }

        // Treble above 10 kHz counts for less: it's the least reliable part of any measurement.
        let weights = grid.map { $0 <= 10_000 ? 1.0 : 0.3 }

        var fitter = Fitter(grid: grid, desired: equalization, weights: weights, options: options)
        fitter.initialize()
        fitter.optimize()
        let filters = fitter.roundedFilters()

        let fittedPreset = ParametricPreset(name: name, filters: filters)
        let fitted = grid.map { fittedPreset.responseDB(at: $0, sampleRate: options.sampleRate) }
        var preset = fittedPreset
        preset.preampDB = (-max(0, fitted.max() ?? 0) * 100).rounded(.down) / 100

        let weightedError = zip(zip(fitted, equalization), weights).map { pair, weight in weight * pow(pair.0 - pair.1, 2) }
        let rms = sqrt(weightedError.reduce(0, +) / weights.reduce(0, +))

        return AutoEQResult(
            preset: preset, frequencies: grid, source: sourceDB, target: targetDB,
            equalization: equalization, fitted: fitted, rmsErrorDB: rms
        )
    }
}

/// Least-squares fit of filter parameters to a desired response, by Adam gradient descent
/// on log-frequency, gain and log-Q with numerical gradients.
private struct Fitter {
    struct Band {
        var type: FilterType
        var log2Frequency: Double
        var gain: Double
        var log2Q: Double
        /// Shelves keep their frequency and Q fixed, as AutoEQ does.
        var isFixed: Bool

        var filter: Filter {
            Filter(type: type, frequency: pow(2, log2Frequency), gainDB: gain, q: pow(2, log2Q))
        }
    }

    let grid: [Double]
    let desired: [Double]
    let weights: [Double]
    let options: AutoEQOptions
    private let totalWeight: Double
    // cos/sin of ω and 2ω at each grid frequency, which never change during fitting.
    private let cos1: [Double], sin1: [Double], cos2: [Double], sin2: [Double]

    private(set) var bands: [Band] = []
    private var responses: [[Double]] = []
    private var total: [Double]

    init(grid: [Double], desired: [Double], weights: [Double], options: AutoEQOptions) {
        self.grid = grid
        self.desired = desired
        self.weights = weights
        self.options = options
        totalWeight = weights.reduce(0, +)
        let omega = grid.map { 2 * Double.pi * $0 / options.sampleRate }
        cos1 = omega.map(cos)
        sin1 = omega.map(sin)
        cos2 = omega.map { cos(2 * $0) }
        sin2 = omega.map { sin(2 * $0) }
        total = [Double](repeating: 0, count: grid.count)
    }

    // MARK: Initial guess

    /// Sets shelves from the average correction at the extremes, then places each peaking filter
    /// at the largest remaining error with a width matching that error's half-height width.
    mutating func initialize() {
        var residual = desired
        func average(_ range: ClosedRange<Double>) -> Double {
            let values = grid.indices.filter { range.contains(grid[$0]) }.map { residual[$0] }
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }

        if let shelf = options.lowShelf {
            add(Band(type: .lowShelf, log2Frequency: log2(shelf.frequency), gain: clampGain(average(20...shelf.frequency / 2)), log2Q: log2(shelf.q), isFixed: true), to: &residual)
        }
        if let shelf = options.highShelf {
            add(Band(type: .highShelf, log2Frequency: log2(shelf.frequency), gain: clampGain(average(shelf.frequency * 1.2...20_000)), log2Q: log2(shelf.q), isFixed: true), to: &residual)
        }

        let candidates = grid.indices.filter { options.peakingFrequencyRange.contains(grid[$0]) }
        for _ in 0..<options.peakingFilterCount {
            guard let peak = candidates.max(by: { abs(residual[$0]) * weights[$0] < abs(residual[$1]) * weights[$1] }) else { break }
            let height = residual[peak]
            var lower = peak, upper = peak
            while lower > 0, residual[lower - 1] * height > 0, abs(residual[lower - 1]) > abs(height) / 2 { lower -= 1 }
            while upper < grid.count - 1, residual[upper + 1] * height > 0, abs(residual[upper + 1]) > abs(height) / 2 { upper += 1 }
            let bandwidth = max(log2(grid[upper] / grid[lower]), 1 / 24)
            let q = sqrt(pow(2, bandwidth)) / (pow(2, bandwidth) - 1)

            add(Band(type: .peaking, log2Frequency: log2(grid[peak]), gain: clampGain(height), log2Q: log2(clampQ(q)), isFixed: false), to: &residual)
        }
    }

    private mutating func add(_ band: Band, to residual: inout [Double]) {
        let response = self.response(of: band)
        for i in residual.indices { residual[i] -= response[i] }
        bands.append(band)
        responses.append(response)
        for i in total.indices { total[i] += response[i] }
    }

    // MARK: Optimization

    mutating func optimize() {
        // Parameter layout: for each band, [log2 frequency, gain, log2 Q]; fixed bands only use gain.
        let learningRates = [0.02, 0.1, 0.03]
        var m = [[Double]](repeating: [0, 0, 0], count: bands.count)
        var v = m
        // A large epsilon keeps near-zero (noise-level) gradients from taking full-size Adam steps.
        let beta1 = 0.9, beta2 = 0.999, epsilon = 1e-3, h = 1e-4

        for iteration in 1...max(options.iterations, 1) {
            let decay = 1 - 0.9 * Double(iteration) / Double(options.iterations)
            for index in bands.indices {
                let parameters = bands[index].isFixed ? [1] : [0, 1, 2]
                var gradient = [0.0, 0.0, 0.0]
                for p in parameters {
                    var plus = bands[index], minus = bands[index]
                    plus[p] += h
                    minus[p] -= h
                    gradient[p] = (loss(replacing: index, with: plus) - loss(replacing: index, with: minus)) / (2 * h)
                }

                var band = bands[index]
                for p in parameters {
                    m[index][p] = beta1 * m[index][p] + (1 - beta1) * gradient[p]
                    v[index][p] = beta2 * v[index][p] + (1 - beta2) * gradient[p] * gradient[p]
                    let mHat = m[index][p] / (1 - pow(beta1, Double(iteration)))
                    let vHat = v[index][p] / (1 - pow(beta2, Double(iteration)))
                    band[p] -= learningRates[p] * decay * mHat / (sqrt(vHat) + epsilon)
                }
                replace(index, with: clamped(band))
            }
        }
    }

    /// Filters in AutoEQ's order (low shelf, peaks by frequency, high shelf), rounded as AutoEQ prints them.
    func roundedFilters() -> [Filter] {
        let order: (Band) -> Int = { $0.type == .lowShelf ? 0 : $0.type == .highShelf ? 2 : 1 }
        return bands
            .sorted { (order($0), $0.log2Frequency) < (order($1), $1.log2Frequency) }
            .map { band in
                var filter = band.filter
                filter.frequency = (filter.frequency * 10).rounded() / 10
                filter.gainDB = (filter.gainDB * 10).rounded() / 10
                filter.q = (filter.q * 100).rounded() / 100
                return filter
            }
    }

    private func loss(replacing index: Int, with band: Band) -> Double {
        let candidate = response(of: band)
        let previous = responses[index]
        var sum = 0.0
        for i in grid.indices {
            let error = total[i] - previous[i] + candidate[i] - desired[i]
            sum += weights[i] * error * error
        }
        return sum / totalWeight
    }

    private mutating func replace(_ index: Int, with band: Band) {
        let response = self.response(of: band)
        for i in total.indices { total[i] += response[i] - responses[index][i] }
        bands[index] = band
        responses[index] = response
    }

    private func response(of band: Band) -> [Double] {
        let c = BiquadCoefficients(filter: band.filter, sampleRate: options.sampleRate)
        return grid.indices.map { i in
            let numeratorReal = c.b0 + c.b1 * cos1[i] + c.b2 * cos2[i]
            let numeratorImag = c.b1 * sin1[i] + c.b2 * sin2[i]
            let denominatorReal = 1 + c.a1 * cos1[i] + c.a2 * cos2[i]
            let denominatorImag = c.a1 * sin1[i] + c.a2 * sin2[i]
            return 10 * log10(
                (numeratorReal * numeratorReal + numeratorImag * numeratorImag)
                    / (denominatorReal * denominatorReal + denominatorImag * denominatorImag)
            )
        }
    }

    private func clamped(_ band: Band) -> Band {
        var band = band
        band.gain = clampGain(band.gain)
        if !band.isFixed {
            band.log2Frequency = min(max(band.log2Frequency, log2(options.peakingFrequencyRange.lowerBound)), log2(options.peakingFrequencyRange.upperBound))
            band.log2Q = min(max(band.log2Q, log2(options.qRange.lowerBound)), log2(options.qRange.upperBound))
        }
        return band
    }

    private func clampGain(_ gain: Double) -> Double { min(max(gain, -20), 20) }
    private func clampQ(_ q: Double) -> Double { min(max(q, options.qRange.lowerBound), options.qRange.upperBound) }
}

private extension Fitter.Band {
    subscript(parameter: Int) -> Double {
        get { [log2Frequency, gain, log2Q][parameter] }
        set {
            switch parameter {
            case 0: log2Frequency = newValue
            case 1: gain = newValue
            default: log2Q = newValue
            }
        }
    }
}
