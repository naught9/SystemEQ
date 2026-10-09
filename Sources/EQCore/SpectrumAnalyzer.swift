import Accelerate

/// Magnitude spectrum of the most recent `size` samples, in dBFS: a full-scale sine reads 0 dB.
///
/// Uses a 4-term Blackman-Harris window, whose ~92 dB sidelobe rejection keeps loud
/// bass from smearing over quiet treble.
public final class SpectrumAnalyzer {
    public let size: Int
    public let sampleRate: Double
    /// `size / 2` bins; bin `i` is centred on `i * sampleRate / size` Hz.
    public private(set) var magnitudesDB: [Float]

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let scale: Float
    private var real: [Float]
    private var imaginary: [Float]

    /// `size` must be a power of two.
    public init(size: Int, sampleRate: Double) {
        precondition(size >= 64 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.sampleRate = sampleRate
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self)!

        let a: [Double] = [0.35875, 0.48829, 0.14128, 0.01168]
        window = (0..<size).map { n in
            let x = 2 * Double.pi * Double(n) / Double(size)
            return Float(a[0] - a[1] * cos(x) + a[2] * cos(2 * x) - a[3] * cos(3 * x))
        }
        // vDSP's real FFT returns twice the DFT. A sine of amplitude A then peaks at
        // A * N * coherentGain, so dividing by that reads amplitude directly.
        scale = 1 / (Float(size) * window.reduce(0, +) / Float(size))
        magnitudesDB = [Float](repeating: -200, count: size / 2)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
    }

    public func frequency(ofBin bin: Int) -> Double {
        Double(bin) * sampleRate / Double(size)
    }

    /// Analyses the last `size` samples of `samples` (zero-padded at the front if shorter).
    public func analyze(_ samples: ArraySlice<Float>) {
        var input = [Float](repeating: 0, count: size)
        let tail = samples.suffix(size)
        input.replaceSubrange((size - tail.count)..<size, with: tail)
        vDSP.multiply(input, window, result: &input)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                input.withUnsafeBytes {
                    vDSP.convert(interleavedComplexVector: Array($0.bindMemory(to: DSPComplex.self)), toSplitComplexVector: &split)
                }
                fft.forward(input: split, output: &split)
                // Bin 0 packs DC and Nyquist together; neither is useful for display.
                realBuffer[0] = 0
                imaginaryBuffer[0] = 0

                magnitudesDB.withUnsafeMutableBufferPointer { output in
                    vDSP.absolute(split, result: &output)
                    vDSP.multiply(scale, output, result: &output)
                    vDSP.add(1e-10, output, result: &output)
                    vDSP.convert(amplitude: output, toDecibels: &output, zeroReference: 1)
                }
            }
        }
    }
}
