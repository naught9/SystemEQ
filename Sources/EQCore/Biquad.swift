import Foundation

/// Normalized biquad coefficients (a0 == 1), computed with the
/// Audio EQ Cookbook formulas that AutoEQ and Equalizer APO also use.
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double, b1: Double, b2: Double
    public var a1: Double, a2: Double

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public init(filter: Filter, sampleRate: Double) {
        // Bands at or above Nyquist can't be realised at this sample rate.
        guard filter.isEnabled, filter.frequency > 0, filter.frequency < sampleRate / 2, filter.q > 0 else {
            self = .identity
            return
        }

        let w0 = 2 * Double.pi * filter.frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * filter.q)
        let a = pow(10, filter.gainDB / 40)

        let b0, b1, b2, a0, a1, a2: Double
        switch filter.type {
        case .peaking:
            b0 = 1 + alpha * a
            b1 = -2 * cosW0
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW0
            a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW0 + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - s)
            a0 = (a + 1) + (a - 1) * cosW0 + s
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - s
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW0 + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - s)
            a0 = (a + 1) - (a - 1) * cosW0 + s
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - s
        case .lowPass:
            b0 = (1 - cosW0) / 2
            b1 = 1 - cosW0
            b2 = (1 - cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosW0) / 2
            b1 = -(1 + cosW0)
            b2 = (1 + cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        case .notch:
            b0 = 1
            b1 = -2 * cosW0
            b2 = 1
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        }

        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude response at `frequency`, in dB.
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)

        let numReal = b0 + b1 * cos1 + b2 * cos2
        let numImag = -(b1 * sin1 + b2 * sin2)
        let denReal = 1 + a1 * cos1 + a2 * cos2
        let denImag = -(a1 * sin1 + a2 * sin2)

        let numerator = numReal * numReal + numImag * numImag
        let denominator = denReal * denReal + denImag * denImag
        return 10 * log10(numerator / denominator)
    }
}
