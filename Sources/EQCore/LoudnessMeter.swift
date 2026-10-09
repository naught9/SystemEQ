import Foundation

/// Stereo loudness metering per ITU-R BS.1770-4 / EBU R 128: K-weighted momentary (400 ms),
/// short-term (3 s) and gated integrated loudness in LUFS, plus sample peaks in dBFS.
public final class LoudnessMeter {
    public private(set) var momentaryLUFS = -Double.infinity
    public private(set) var shortTermLUFS = -Double.infinity
    public private(set) var integratedLUFS = -Double.infinity
    /// Highest absolute sample per channel since the last `takePeaks()`, in dBFS.
    public private(set) var peakDB: (left: Double, right: Double) = (-.infinity, -.infinity)

    public let sampleRate: Double
    private let blockFrames: Int
    private var stages: [BiquadCoefficients]
    /// Filter state per channel: two stages × two values.
    private var state = [[Double]](repeating: [0, 0, 0, 0], count: 2)

    // 100 ms sub-blocks of summed K-weighted power across channels.
    private var blockEnergy = 0.0
    private var blockFill = 0
    private var recentBlocks: [Double] = []
    /// Mean power of every 400 ms gating block (75 % overlap) since reset, for integrated loudness.
    private var gatingBlocks: [Double] = []
    private var peaks: (Float, Float) = (0, 0)

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        blockFrames = Int(sampleRate / 10)
        stages = Self.kWeighting(sampleRate: sampleRate)
    }

    public func reset() {
        state = [[0, 0, 0, 0], [0, 0, 0, 0]]
        blockEnergy = 0
        blockFill = 0
        recentBlocks = []
        gatingBlocks = []
        momentaryLUFS = -.infinity
        shortTermLUFS = -.infinity
        integratedLUFS = -.infinity
    }

    /// Feeds interleaved stereo samples.
    public func process(interleaved samples: ArraySlice<Float>) {
        var index = samples.startIndex
        while index + 1 < samples.endIndex {
            let left = samples[index], right = samples[index + 1]
            peaks = (max(peaks.0, abs(left)), max(peaks.1, abs(right)))

            let l = weighted(Double(left), channel: 0)
            let r = weighted(Double(right), channel: 1)
            blockEnergy += l * l + r * r
            blockFill += 1
            if blockFill == blockFrames { finishBlock() }
            index += 2
        }
        peakDB = (Self.decibels(Double(peaks.0)), Self.decibels(Double(peaks.1)))
    }

    /// Returns the peaks since the last call and starts a new peak window.
    public func takePeaks() -> (left: Double, right: Double) {
        defer { peaks = (0, 0) }
        return peakDB
    }

    private func weighted(_ x: Double, channel: Int) -> Double {
        var value = x
        for (stage, c) in stages.enumerated() {
            let s = stage * 2
            let y = c.b0 * value + state[channel][s]
            state[channel][s] = c.b1 * value - c.a1 * y + state[channel][s + 1]
            state[channel][s + 1] = c.b2 * value - c.a2 * y
            value = y
        }
        return value
    }

    private func finishBlock() {
        recentBlocks.append(blockEnergy / Double(blockFrames))
        if recentBlocks.count > 30 { recentBlocks.removeFirst(recentBlocks.count - 30) }
        blockEnergy = 0
        blockFill = 0

        momentaryLUFS = Self.loudness(ofMeanPower: mean(recentBlocks.suffix(4)))
        shortTermLUFS = Self.loudness(ofMeanPower: mean(recentBlocks.suffix(30)))

        if recentBlocks.count >= 4 {
            gatingBlocks.append(mean(recentBlocks.suffix(4)))
            integratedLUFS = gatedLoudness()
        }
    }

    /// Absolute gate at -70 LUFS, then a relative gate 10 LU below the absolute-gated loudness.
    private func gatedLoudness() -> Double {
        let absoluteGate = Self.meanPower(ofLoudness: -70)
        let aboveAbsolute = gatingBlocks.filter { $0 > absoluteGate }
        guard !aboveAbsolute.isEmpty else { return -.infinity }
        let relativeGate = mean(aboveAbsolute[...]) * pow(10, -10.0 / 10)
        let aboveRelative = aboveAbsolute.filter { $0 > relativeGate }
        return Self.loudness(ofMeanPower: mean(aboveRelative[...]))
    }

    private func mean(_ values: ArraySlice<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func loudness(ofMeanPower power: Double) -> Double {
        power > 0 ? -0.691 + 10 * log10(power) : -.infinity
    }

    static func meanPower(ofLoudness lufs: Double) -> Double {
        pow(10, (lufs + 0.691) / 10)
    }

    static func decibels(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    /// The BS.1770 K-weighting filter (a high shelf modelling the head, then a high-pass),
    /// derived for any sample rate from its analogue prototype.
    static func kWeighting(sampleRate: Double) -> [BiquadCoefficients] {
        var k = tan(Double.pi * 1681.974450955533 / sampleRate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = BiquadCoefficients(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )

        k = tan(Double.pi * 38.13547087602444 / sampleRate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let highPass = BiquadCoefficients(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        return [shelf, highPass]
    }
}
