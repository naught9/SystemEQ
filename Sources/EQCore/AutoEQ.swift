// Swift port of the equalization pipeline and parametric EQ optimizer from AutoEq
// (https://github.com/jaakkopasanen/AutoEq): autoeq/frequency_response.py, autoeq/peq.py,
// autoeq/utils.py and autoeq/constants.py, with the defaults used by autoeq.app.
//
// MIT License
//
// Copyright (c) 2018-2022 Jaakko Pasanen
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Differences from AutoEq: SciPy's SLSQP optimizer is replaced by a bounded Levenberg-Marquardt
// solver minimising the same loss from the same initial filters, run to convergence rather than
// stopped after 0.5 s, so filter values can differ slightly from autoeq.app's.

import Foundation

/// Settings for `AutoEQ.fit`. Defaults match autoeq.app with the "8 peaking with shelves" configuration.
public struct AutoEQOptions: Sendable, Equatable {
    /// Low shelf added to the target at 105 Hz, Q 0.7.
    public var bassBoostDB = 0.0
    /// High shelf added to the target at 10 kHz, Q 0.7.
    public var trebleDB = 0.0
    /// Slope added to the target, pivoting at 632 Hz (the log-centre of 20 Hz–20 kHz).
    public var tiltDBPerOctave = 0.0
    /// Largest boost the equalization may apply.
    public var maxBoostDB = 12.0
    /// Steepest slope the equalization curve may have, in dB per octave.
    public var maxSlopeDBPerOctave = 18.0
    /// Smoothing window below `trebleFrequencies`, in octaves.
    public var windowSize = 0.08
    /// Smoothing window above `trebleFrequencies`, in octaves.
    public var trebleWindowSize = 2.0
    /// Region where smoothing (and treble gain scaling) cross over from normal to treble.
    public var trebleFrequencies = 6_000.0...8_000.0
    /// Scales the equalization above `trebleFrequencies`; 1 leaves it unchanged.
    public var trebleGainK = 1.0
    /// Shift the error so its mean is zero between 100 Hz and 10 kHz, instead of aligning at 1 kHz only.
    /// autoeq.app always does this.
    public var minimizeMeanError = true
    public var peakingFilterCount = 8
    public var sampleRate = 48_000.0

    public init() {}
}

public struct AutoEQResult: Sendable {
    public let preset: ParametricPreset
    public let frequencies: [Double]
    /// Source, centred at 1 kHz.
    public let source: [Double]
    /// Target including adjustments, offset the way AutoEq compares it with the source.
    public let target: [Double]
    /// The correction the filters aim for.
    public let equalization: [Double]
    /// What the fitted filters do, excluding preamp.
    public let fitted: [Double]
    /// RMS difference between `fitted` and `equalization` from 20 Hz to 10 kHz, in dB.
    public let rmsErrorDB: Double
    /// Predicted result: source with the fitted EQ applied.
    public var equalizedSource: [Double] { zip(source, fitted).map(+) }
}

public enum AutoEQ {
    /// Frequency grid step for equalization (`DEFAULT_STEP`).
    static let step = 1.01
    /// Frequency grid step for filter optimization (`DEFAULT_BIQUAD_OPTIMIZATION_F_STEP`).
    static let optimizationStep = 1.02

    /// Generates a parametric EQ that makes `source` sound like `target`.
    public static func fit(source: FrequencyResponse, target: FrequencyResponse, name: String, options: AutoEQOptions = AutoEQOptions()) -> AutoEQResult {
        let grid = frequencies(step: step)

        // FrequencyResponse.process: interpolate, center, compensate.
        var raw = interpolate(source, to: grid)
        let sourceCenter = interpolate(x: grid, y: raw, at: [1_000])[0]
        raw = raw.map { $0 - sourceCenter }

        var targetRaw = interpolate(target, to: grid)
        let targetCenter = interpolate(x: grid, y: targetRaw, at: [1_000])[0]
        targetRaw = targetRaw.map { $0 - targetCenter }
        let adjustments = targetAdjustments(grid, options: options)
        targetRaw = zip(targetRaw, adjustments).map(+)

        var error = zip(raw, targetRaw).map(-)
        if options.minimizeMeanError {
            let band = grid.indices.filter { grid[$0] >= 100 && grid[$0] <= 10_000 }
            let delta = band.map { error[$0] }.reduce(0, +) / Double(band.count)
            error = error.map { $0 - delta }
            targetRaw = targetRaw.map { $0 + delta }
        }

        // FrequencyResponse.smoothen + equalize.
        let equalization = equalize(grid: grid, error: error, options: options)

        // FrequencyResponse.optimize_parametric_eq with 8_PEAKING_WITH_SHELVES.
        let optimizationGrid = frequencies(step: optimizationStep)
        let optimizationTarget = interpolate(x: grid, y: equalization, at: optimizationGrid)
        var peq = PEQ(frequencies: optimizationGrid, sampleRate: options.sampleRate, target: optimizationTarget, peakingCount: options.peakingFilterCount)
        peq.optimize()

        let filters = peq.sortedFilters.map { band -> Filter in
            var rounded = band.filter
            rounded.frequency = (rounded.frequency * 10).rounded() / 10
            rounded.gainDB = (rounded.gainDB * 10).rounded() / 10
            rounded.q = (rounded.q * 100).rounded() / 100
            return rounded
        }
        var preset = ParametricPreset(name: name, filters: filters)
        let fitted = grid.map { preset.responseDB(at: $0, sampleRate: options.sampleRate) }
        // webapp/main.py: preamp = -max_gain - 0.1, max taken on the optimization grid.
        let maxGain = optimizationGrid.map { preset.responseDB(at: $0, sampleRate: options.sampleRate) }.max() ?? 0
        preset.preampDB = ((-maxGain - 0.1) * 100).rounded() / 100

        let fitRange = grid.indices.filter { grid[$0] <= 10_000 }
        let rms = sqrt(fitRange.map { pow(fitted[$0] - equalization[$0], 2) }.reduce(0, +) / Double(fitRange.count))

        return AutoEQResult(
            preset: preset, frequencies: grid, source: raw, target: targetRaw,
            equalization: equalization, fitted: fitted, rmsErrorDB: rms
        )
    }

    // MARK: utils.py

    /// `generate_frequencies`: geometric sequence from 20 Hz while ≤ 20 kHz.
    static func frequencies(from lower: Double = 20, to upper: Double = 20_000, step: Double) -> [Double] {
        var result: [Double] = []
        var frequency = lower
        while frequency <= upper {
            result.append(frequency)
            frequency *= step
        }
        return result
    }

    /// `log_tilt`: tilt in dB, pivoting at the log-centre of 20 Hz–20 kHz.
    static func logTilt(_ frequency: Double, steepness: Double) -> Double {
        log2(frequency / (20 * sqrt(20_000.0 / 20))) * steepness
    }

    /// `smoothing_window_size`: window length in samples for a window of `octaves`, rounded up to odd.
    static func smoothingWindowSize(_ frequencies: [Double], octaves: Double) -> Int {
        let steps = (1..<frequencies.count).map { frequencies[$0] / frequencies[$0 - 1] }
        let stepSize = steps.reduce(0, +) / Double(steps.count)
        var n = Int((log(pow(2, octaves)) / log(stepSize)).rounded(.toNearestOrEven))
        if n % 2 == 0 { n += 1 }
        return n
    }

    /// `log_f_sigmoid`: weight going from `normal` to `treble` across `range` on a log axis.
    static func logFrequencySigmoid(_ frequency: Double, range: ClosedRange<Double>, normal: Double = 0, treble: Double = 1) -> Double {
        let center = log10(sqrt(range.upperBound / range.lowerBound) * range.lowerBound)
        let halfRange = log10(range.upperBound) - center
        let a = 1 / (1 + exp(-(log10(frequency) - center) / (halfRange / 4)))
        return a * -(normal - treble) + normal
    }

    /// `log_log_gradient`: slope in dB per octave.
    static func logLogGradient(_ f0: Double, _ f1: Double, _ g0: Double, _ g1: Double) -> Double {
        (g1 - g0) / (log(f1 / f0) / log(2))
    }

    // MARK: frequency_response.py

    /// `interpolate`: first-order spline on log10 frequency, which extrapolates linearly past the ends.
    static func interpolate(_ response: FrequencyResponse, to grid: [Double]) -> [Double] {
        interpolate(x: response.frequencies, y: response.db, at: grid)
    }

    static func interpolate(x: [Double], y: [Double], at points: [Double]) -> [Double] {
        let logX = x.map(log10)
        return points.map { point in
            let p = log10(point)
            var upper = logX.partitionIndex { $0 >= p }
            upper = min(max(upper, 1), logX.count - 1)
            let lower = upper - 1
            let t = (p - logX[lower]) / (logX[upper] - logX[lower])
            return y[lower] + t * (y[upper] - y[lower])
        }
    }

    /// `create_target`: bass boost, treble boost and tilt added to the target.
    static func targetAdjustments(_ grid: [Double], options: AutoEQOptions) -> [Double] {
        let bass = BiquadCoefficients(filter: Filter(type: .lowShelf, frequency: 105, gainDB: options.bassBoostDB, q: 0.7), sampleRate: options.sampleRate)
        let treble = BiquadCoefficients(filter: Filter(type: .highShelf, frequency: 10_000, gainDB: options.trebleDB, q: 0.7), sampleRate: options.sampleRate)
        return grid.map {
            bass.magnitudeDB(at: $0, sampleRate: options.sampleRate)
                + treble.magnitudeDB(at: $0, sampleRate: options.sampleRate)
                + logTilt($0, steepness: options.tiltDBPerOctave)
        }
    }

    /// `_smoothen`: Savitzky-Golay (order 2) at the normal and treble window sizes, crossfaded with a sigmoid.
    static func smoothen(_ data: [Double], grid: [Double], windowSize: Double, trebleWindowSize: Double, treble: ClosedRange<Double>) -> [Double] {
        let normal = savitzkyGolay(data, window: smoothingWindowSize(grid, octaves: windowSize))
        let trebleSmoothed = savitzkyGolay(data, window: smoothingWindowSize(grid, octaves: trebleWindowSize))
        return grid.indices.map { i in
            let k = logFrequencySigmoid(grid[i], range: treble)
            return normal[i] * (1 - k) + trebleSmoothed[i] * k
        }
    }

    /// `equalize`: inverse of the smoothed error with slopes limited, treble scaled, boosts capped and smoothed.
    static func equalize(grid: [Double], error: [Double], options: AutoEQOptions) -> [Double] {
        let smoothedError = smoothen(error, grid: grid, windowSize: options.windowSize, trebleWindowSize: options.trebleWindowSize, treble: options.trebleFrequencies)
        let y = smoothedError.map { -$0 }

        let peaks = findPeaks(y, minProminence: 1).indices
        let dips = findPeaks(y.map { -$0 }, minProminence: 1).indices
        guard !peaks.isEmpty || !dips.isEmpty else { return y }

        let limitFree = protectionMask(y, peaks: peaks, dips: dips)
        let rtlStart = findRTLStart(y, peaks: peaks, dips: dips)
        let ltr = limitedLTRSlope(x: grid, y: y, maxSlope: options.maxSlopeDBPerOctave, startIndex: 0, peaks: peaks, limitFree: limitFree)
        let rtl = limitedRTLSlope(x: grid, y: y, maxSlope: options.maxSlopeDBPerOctave, startIndex: rtlStart, peaks: peaks, limitFree: limitFree)

        var combined = zip(ltr, rtl).map { min($0, $1) }
        for i in combined.indices {
            combined[i] *= logFrequencySigmoid(grid[i], range: options.trebleFrequencies, normal: 1, treble: options.trebleGainK)
            combined[i] = min(combined[i], options.maxBoostDB)
        }
        return smoothen(combined, grid: grid, windowSize: 1.0 / 5, trebleWindowSize: 1.0 / 5, treble: options.trebleFrequencies)
    }

    /// `protection_mask`: regions around dips lower than their neighbouring dips, which slope limiting must not touch.
    static func protectionMask(_ y: [Double], peaks: [Int], dips dipsIn: [Int]) -> [Bool] {
        var dips = dipsIn
        var dipLevels: [Double]
        if let lastPeak = peaks.last, dips.isEmpty || lastPeak > dips.last! {
            dips.append(y[lastPeak...].indices.min { y[$0] < y[$1] }!)
            dipLevels = dips.map { y[$0] }
        } else {
            dips.append(y.count - 1)
            dipLevels = dips.map { y[$0] }
            dipLevels[dipLevels.count - 1] = y.min()!
        }

        var mask = [Bool](repeating: false, count: y.count)
        guard dips.count >= 3 else { return mask }
        for i in 1..<(dips.count - 1) {
            let dip = dips[i]
            guard let left = (0..<dip).last(where: { y[$0] >= dipLevels[i - 1] }),
                  let right = (dip..<y.count).first(where: { y[$0] >= dipLevels[i + 1] }) else { continue }
            let leftIndex = left + 1, rightIndex = right - 1
            if leftIndex <= rightIndex {
                for j in leftIndex...rightIndex { mask[j] = true }
            }
        }
        return mask
    }

    /// `find_rtl_start`
    static func findRTLStart(_ y: [Double], peaks: [Int], dips: [Int]) -> Int {
        if let lastPeak = peaks.last, dips.isEmpty || lastPeak > dips.last! {
            let level = dips.last.map { y[$0] } ?? max(y[0], y[y.count - 1])
            return (lastPeak..<y.count).first { y[$0] <= level } ?? y.count - 1
        }
        return dips.last!
    }

    /// `limited_ltr_slope` (without slope decay or concha interference, which autoeq.app doesn't use).
    static func limitedLTRSlope(x: [Double], y: [Double], maxSlope: Double, startIndex: Int, peaks: [Int], limitFree: [Bool]) -> [Double] {
        var limited: [Double] = []
        var clipped: [Bool] = []
        var regionStart: Int?

        for i in x.indices {
            if i <= startIndex {
                limited.append(y[i])
                clipped.append(false)
                continue
            }
            let slope = logLogGradient(x[i], x[i - 1], y[i], limited[i - 1])
            if slope > maxSlope && !limitFree[i] {
                if !clipped[i - 1] { regionStart = i }
                clipped.append(true)
                limited.append(limited[i - 1] + maxSlope * log2(x[i] / x[i - 1]))
            } else {
                limited.append(y[i])
                if clipped[i - 1], let start = regionStart {
                    // A limited region must contain a peak, otherwise the limitation is discarded.
                    if !peaks.contains(where: { $0 >= start && $0 < i }) {
                        for j in start..<i {
                            limited[j] = y[j]
                            clipped[j] = false
                        }
                    }
                    regionStart = nil
                }
                clipped.append(false)
            }
        }
        return limited
    }

    /// `limited_rtl_slope`: the left-to-right limiter run over reversed data.
    static func limitedRTLSlope(x: [Double], y: [Double], maxSlope: Double, startIndex: Int, peaks: [Int], limitFree: [Bool]) -> [Double] {
        let n = x.count
        let limited = limitedLTRSlope(
            x: x,
            y: y.reversed(),
            maxSlope: maxSlope,
            startIndex: n - startIndex - 1,
            peaks: peaks.map { n - $0 - 1 },
            limitFree: limitFree.reversed()
        )
        return limited.reversed()
    }
}

// MARK: - SciPy equivalents

extension AutoEQ {
    /// `scipy.signal.savgol_filter(data, window, 2)` with the default `mode='interp'`: interior points
    /// use the centred least-squares quadratic; the first and last half-windows use a quadratic fitted
    /// to the first and last full windows.
    static func savitzkyGolay(_ data: [Double], window requestedWindow: Int) -> [Double] {
        let window = min(requestedWindow, data.count % 2 == 1 ? data.count : data.count - 1)
        guard window > 2 else { return data }
        let half = window / 2

        let m = Double(half)
        let denominator = (2 * m + 3) * (2 * m + 1) * (2 * m - 1)
        let weights = (-half...half).map { j in (3 * (3 * m * m + 3 * m - 1) - 15 * Double(j * j)) / denominator }

        var result = data
        for i in half..<(data.count - half) {
            var sum = 0.0
            for (k, w) in weights.enumerated() { sum += w * data[i - half + k] }
            result[i] = sum
        }

        let head = quadraticFit(Array(data[0..<window]))
        for i in 0..<half { result[i] = head(Double(i)) }
        let tailStart = data.count - window
        let tail = quadraticFit(Array(data[tailStart...]))
        for i in (data.count - half)..<data.count { result[i] = tail(Double(i - tailStart)) }
        return result
    }

    /// Least-squares quadratic through (index, value) points.
    private static func quadraticFit(_ values: [Double]) -> (Double) -> Double {
        let center = Double(values.count - 1) / 2
        var s = [Double](repeating: 0, count: 5), t = [Double](repeating: 0, count: 3)
        for (i, value) in values.enumerated() {
            let x = Double(i) - center
            var power = 1.0
            for k in 0..<5 {
                s[k] += power
                if k < 3 { t[k] += power * value }
                power *= x
            }
        }
        let c = solve([[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]], t)
        return { x in
            let d = x - center
            return c[0] + c[1] * d + c[2] * d * d
        }
    }

    struct Peaks {
        var indices: [Int] = []
        var heights: [Double] = []
        var prominences: [Double] = []
        var widths: [Double] = []
    }

    /// `scipy.signal.find_peaks` with `prominence` (and optionally `height` and `width=0`).
    static func findPeaks(_ x: [Double], minProminence: Double, minHeight: Double? = nil, computeWidths: Bool = false) -> Peaks {
        // _local_maxima_1d: plateaus report their middle sample.
        var candidates: [Int] = []
        var i = 1
        while i < x.count - 1 {
            if x[i - 1] < x[i] {
                var ahead = i + 1
                while ahead < x.count - 1 && x[ahead] == x[i] { ahead += 1 }
                if x[ahead] < x[i] {
                    candidates.append((i + ahead - 1) / 2)
                    i = ahead
                }
            }
            i += 1
        }
        if let minHeight { candidates = candidates.filter { x[$0] >= minHeight } }

        var peaks = Peaks()
        for peak in candidates {
            // peak_prominences without a window.
            var leftMin = x[peak], leftBase = peak
            var j = peak
            while j >= 0 && x[j] <= x[peak] {
                if x[j] < leftMin { leftMin = x[j]; leftBase = j }
                j -= 1
            }
            var rightMin = x[peak], rightBase = peak
            j = peak
            while j < x.count && x[j] <= x[peak] {
                if x[j] < rightMin { rightMin = x[j]; rightBase = j }
                j += 1
            }
            let prominence = x[peak] - max(leftMin, rightMin)
            guard prominence >= minProminence else { continue }

            peaks.indices.append(peak)
            peaks.heights.append(x[peak])
            peaks.prominences.append(prominence)
            if computeWidths {
                // peak_widths at rel_height 0.5.
                let height = x[peak] - prominence * 0.5
                var left = peak
                while leftBase < left && height < x[left] { left -= 1 }
                var leftPosition = Double(left)
                if x[left] < height { leftPosition += (height - x[left]) / (x[left + 1] - x[left]) }
                var right = peak
                while right < rightBase && height < x[right] { right += 1 }
                var rightPosition = Double(right)
                if x[right] < height { rightPosition -= (height - x[right]) / (x[right - 1] - x[right]) }
                peaks.widths.append(rightPosition - leftPosition)
            }
        }
        return peaks
    }

    /// Solves a small dense linear system by Gaussian elimination with partial pivoting.
    static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        var a = matrix, b = vector
        let n = b.count
        for column in 0..<n {
            let pivot = (column..<n).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            guard abs(a[column][column]) > 1e-300 else { continue }
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = abs(a[row][row]) > 1e-300 ? sum / a[row][row] : 0
        }
        return x
    }
}

// MARK: - peq.py

/// AutoEq's PEQ: a low shelf at 105 Hz and a high shelf at 10 kHz (gain only) plus peaking filters
/// (frequency, Q and gain), optimised against `target`.
struct PEQ {
    struct Band {
        enum Kind: Int { case lowShelf = 0, peaking = 1, highShelf = 2 }
        var kind: Kind
        var frequency: Double
        var q: Double
        var gain: Double

        var filter: Filter {
            let type: FilterType = switch kind {
            case .lowShelf: .lowShelf
            case .peaking: .peaking
            case .highShelf: .highShelf
            }
            return Filter(type: type, frequency: frequency, gainDB: gain, q: q)
        }

        // Bounds from constants.py.
        static let peakingFrequency = 20.0...10_000.0
        static let peakingQ = 0.18248...6.0
        static let gainRange = -20.0...20.0
    }

    let f: [Double]
    let fs: Double
    let target: [Double]
    private(set) var bands: [Band]
    private let index10k: Int
    private let fitEnd: Int
    private let cosW: [Double], sinW: [Double], cos2W: [Double], sin2W: [Double]

    init(frequencies: [Double], sampleRate: Double, target: [Double], peakingCount: Int) {
        f = frequencies
        fs = sampleRate
        self.target = target
        bands = [Band(kind: .lowShelf, frequency: 105, q: 0.7, gain: 0), Band(kind: .highShelf, frequency: 10_000, q: 0.7, gain: 0)]
            + Array(repeating: Band(kind: .peaking, frequency: 1_000, q: sqrt(2), gain: 0), count: peakingCount)
        index10k = Self.nearestIndex(of: 10_000, in: frequencies)
        // Loss covers [index of 20 Hz, index of 20 kHz), as NumPy slicing excludes the end.
        fitEnd = Self.nearestIndex(of: 20_000, in: frequencies)
        let w = f.map { 2 * Double.pi * $0 / sampleRate }
        cosW = w.map(cos)
        sinW = w.map(sin)
        cos2W = w.map { cos(2 * $0) }
        sin2W = w.map { sin(2 * $0) }
    }

    static func nearestIndex(of frequency: Double, in frequencies: [Double]) -> Int {
        frequencies.indices.min { abs(frequencies[$0] - frequency) < abs(frequencies[$1] - frequency) }!
    }

    var sortedFilters: [Band] {
        bands.sorted { ($0.kind.rawValue, $0.frequency) < ($1.kind.rawValue, $1.frequency) }
    }

    func response(_ band: Band) -> [Double] {
        let c = BiquadCoefficients(filter: band.filter, sampleRate: fs)
        return f.indices.map { i in
            let nr = c.b0 + c.b1 * cosW[i] + c.b2 * cos2W[i]
            let ni = c.b1 * sinW[i] + c.b2 * sin2W[i]
            let dr = 1 + c.a1 * cosW[i] + c.a2 * cos2W[i]
            let di = c.a1 * sinW[i] + c.a2 * sin2W[i]
            return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
        }
    }

    // MARK: Initialization (_init_optimizer_params)

    /// Initialises in AutoEq's order: high shelf, low shelf, then peaking filters, each from what
    /// the previous filters left of the target.
    mutating func initialize() {
        var remaining = target
        let order = [1, 0] + Array(2..<bands.count)
        for index in order {
            switch bands[index].kind {
            case .lowShelf, .highShelf:
                // Gain is the target averaged with a 1 dB shelf's response as weights.
                var unit = bands[index]
                unit.gain = 1
                let weights = response(unit)
                let gain = zip(remaining, weights).map(*).reduce(0, +) / weights.reduce(0, +)
                bands[index].gain = Band.gainRange.clamp(gain)
            case .peaking:
                initializePeaking(index, remaining: remaining)
            }
            let r = response(bands[index])
            for i in remaining.indices { remaining[i] -= r[i] }
        }
    }

    /// `Peaking.init`: centre on the largest peak or dip by width × height, with matching width and height.
    private mutating func initializePeaking(_ index: Int, remaining target: [Double]) {
        let positive = AutoEQ.findPeaks(target.map { max($0, 0) }, minProminence: 0, minHeight: 0, computeWidths: true)
        let negative = AutoEQ.findPeaks(target.map { max(-$0, 0) }, minProminence: 0, minHeight: 0, computeWidths: true)
        let minIndex = Self.nearestIndex(of: Band.peakingFrequency.lowerBound, in: f)
        let maxIndex = Self.nearestIndex(of: Band.peakingFrequency.upperBound, in: f)

        let candidates = zip(positive.indices + negative.indices, zip(positive.widths + negative.widths, positive.heights + negative.heights))
            .filter { $0.0 >= minIndex && $0.0 <= maxIndex }
        guard let best = candidates.max(by: { $0.1.0 * $0.1.1 < $1.1.0 * $1.1.1 }) else {
            bands[index].frequency = f[(minIndex + maxIndex) / 2]
            bands[index].q = sqrt(2)
            bands[index].gain = 0
            return
        }
        let (peak, (width, height)) = best
        bands[index].frequency = Band.peakingFrequency.clamp(f[peak])
        let bandwidth = width * log2(f[1] / f[0])
        bands[index].q = Band.peakingQ.clamp(sqrt(pow(2, bandwidth)) / (pow(2, bandwidth) - 1))
        bands[index].gain = Band.gainRange.clamp(target[peak] > 0 ? height : -height)
    }

    // MARK: Loss (_optimizer_loss)

    /// Residuals whose sum of squares is AutoEq's loss squared: the error up to 20 kHz with everything above
    /// 10 kHz replaced by its mean, plus each peaking filter's sharpness penalty.
    /// `responses` are the bands' responses, passed in so callers can reuse unchanged ones.
    private func residuals(_ bands: [Band], responses: [[Double]]) -> [Double] {
        var total = [Double](repeating: 0, count: f.count)
        for r in responses { for i in total.indices { total[i] += r[i] } }

        let highCount = Double(f.count - index10k)
        var targetHigh = 0.0, totalHigh = 0.0
        for i in index10k..<f.count {
            targetHigh += target[i]
            totalHigh += total[i]
        }
        let highError = (targetHigh - totalHigh) / highCount

        let fitScale = 1 / sqrt(Double(fitEnd))
        var result = [Double](repeating: 0, count: fitEnd + f.count * bands.count)
        for i in 0..<fitEnd {
            result[i] = (i >= index10k ? highError : target[i] - total[i]) * fitScale
        }

        // Sharpness penalty: peaking filters steeper than about 18 dB/octave.
        var offset = fitEnd
        for (band, r) in zip(bands, responses) {
            if band.kind == .peaking {
                let gainLimit = -0.09503189270199464 + 20.575128011847003 * (1 / band.q)
                let x = band.gain / gainLimit - 1
                let scale = 1 / (1 + exp(-x * 100)) / sqrt(Double(f.count))
                for i in r.indices { result[offset + i] = r[i] * scale }
            }
            offset += f.count
        }
        return result
    }

    // MARK: Optimization

    /// Parameters: shelves contribute gain; peaking filters contribute log10 frequency, Q and gain.
    private func parameters(_ bands: [Band]) -> [Double] {
        bands.flatMap { band -> [Double] in
            band.kind == .peaking ? [log10(band.frequency), band.q, band.gain] : [band.gain]
        }
    }

    private func bands(from parameters: [Double]) -> [Band] {
        var result = bands
        var i = 0
        for index in result.indices {
            if result[index].kind == .peaking {
                result[index].frequency = pow(10, parameters[i])
                result[index].q = parameters[i + 1]
                result[index].gain = parameters[i + 2]
                i += 3
            } else {
                result[index].gain = parameters[i]
                i += 1
            }
        }
        return result
    }

    private func bounds() -> [ClosedRange<Double>] {
        bands.flatMap { band -> [ClosedRange<Double>] in
            band.kind == .peaking
                ? [log10(Band.peakingFrequency.lowerBound)...log10(Band.peakingFrequency.upperBound), Band.peakingQ, Band.gainRange]
                : [Band.gainRange]
        }
    }

    /// Which band each parameter belongs to.
    private func bandIndices() -> [Int] {
        bands.indices.flatMap { index in Array(repeating: index, count: bands[index].kind == .peaking ? 3 : 1) }
    }

    /// Bounded Levenberg-Marquardt on the residuals, with a forward-difference Jacobian.
    mutating func optimize() {
        initialize()
        let limits = bounds()
        let owner = bandIndices()
        var p = parameters(bands)
        var currentBands = bands
        var responses = currentBands.map(response)
        var r = residuals(currentBands, responses: responses)
        var cost = r.reduce(0) { $0 + $1 * $1 }
        var lambda = 1e-3

        for _ in 0..<200 {
            // Each parameter only changes its own band, so only that band's response is recomputed.
            var jacobian = [[Double]](repeating: [], count: p.count)
            for k in p.indices {
                var shifted = p
                let h = 1e-6 * max(1, abs(p[k]))
                shifted[k] = limits[k].upperBound - p[k] < h ? p[k] - h : p[k] + h
                let step = shifted[k] - p[k]
                let shiftedBands = bands(from: shifted)
                var shiftedResponses = responses
                shiftedResponses[owner[k]] = response(shiftedBands[owner[k]])
                let rShifted = residuals(shiftedBands, responses: shiftedResponses)
                jacobian[k] = zip(rShifted, r).map { ($0 - $1) / step }
            }

            var jtj = [[Double]](repeating: [Double](repeating: 0, count: p.count), count: p.count)
            var jtr = [Double](repeating: 0, count: p.count)
            for a in p.indices {
                for b in a..<p.count {
                    var value = 0.0
                    for i in r.indices { value += jacobian[a][i] * jacobian[b][i] }
                    jtj[a][b] = value
                    jtj[b][a] = value
                }
                var value = 0.0
                for i in r.indices { value += jacobian[a][i] * r[i] }
                jtr[a] = value
            }

            var improved = false
            for _ in 0..<10 {
                var damped = jtj
                for k in p.indices { damped[k][k] += lambda * max(jtj[k][k], 1e-12) }
                let delta = AutoEQ.solve(damped, jtr.map { -$0 })
                let candidate = p.indices.map { limits[$0].clamp(p[$0] + delta[$0]) }
                let candidateBands = bands(from: candidate)
                let candidateResponses = candidateBands.map(response)
                let candidateResiduals = residuals(candidateBands, responses: candidateResponses)
                let candidateCost = candidateResiduals.reduce(0) { $0 + $1 * $1 }
                if candidateCost < cost {
                    let relativeChange = (cost - candidateCost) / max(cost, 1e-300)
                    p = candidate
                    currentBands = candidateBands
                    responses = candidateResponses
                    r = candidateResiduals
                    cost = candidateCost
                    lambda = max(lambda / 3, 1e-9)
                    improved = relativeChange > 1e-10
                    break
                }
                lambda *= 4
            }
            if !improved { break }
        }
        bands = currentBands
    }
}

private extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

private extension Array where Element == Double {
    /// Index of the first element for which `predicate` is true, assuming the array is partitioned.
    func partitionIndex(where predicate: (Double) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
