import Foundation
import Testing
@testable import EQCore

private func sine(frequency: Double, amplitude: Double, sampleRate: Double, frames: Int) -> [Float] {
    (0..<frames).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

struct SpectrumAnalyzerTests {
    @Test func sineReadsItsLevelInDBFS() {
        let analyzer = SpectrumAnalyzer(size: 8192, sampleRate: 48_000)
        let bin = 700
        let frequency = analyzer.frequency(ofBin: bin)
        analyzer.analyze(sine(frequency: frequency, amplitude: 0.5, sampleRate: 48_000, frames: 8192)[...])

        let peak = analyzer.magnitudesDB.indices.max { analyzer.magnitudesDB[$0] < analyzer.magnitudesDB[$1] }!
        #expect(peak == bin)
        #expect(abs(Double(analyzer.magnitudesDB[bin]) - 20 * log10(0.5)) < 0.1)
        // Far from the tone, the window keeps leakage below -90 dB.
        #expect(analyzer.magnitudesDB[bin * 2] < -90)
    }

    @Test func silenceIsVeryQuiet() {
        let analyzer = SpectrumAnalyzer(size: 4096, sampleRate: 48_000)
        analyzer.analyze([Float](repeating: 0, count: 100)[...])
        #expect(analyzer.magnitudesDB.allSatisfy { $0 < -150 })
    }
}

struct LoudnessMeterTests {
    private func stereo(_ mono: [Float]) -> [Float] {
        mono.flatMap { [$0, $0] }
    }

    @Test func referenceSineMeasuresMinus20LUFS() {
        // EBU Tech 3341: a 1 kHz sine at -20 dBFS in both channels reads -20 LUFS.
        let meter = LoudnessMeter(sampleRate: 48_000)
        meter.process(interleaved: stereo(sine(frequency: 1000, amplitude: 0.1, sampleRate: 48_000, frames: 48_000 * 4))[...])

        #expect(abs(meter.momentaryLUFS + 20) < 0.1)
        #expect(abs(meter.shortTermLUFS + 20) < 0.1)
        #expect(abs(meter.integratedLUFS + 20) < 0.1)
        #expect(abs(meter.peakDB.left + 20) < 0.01)
    }

    @Test func integratedLoudnessGatesOutSilence() {
        let meter = LoudnessMeter(sampleRate: 44_100)
        meter.process(interleaved: stereo(sine(frequency: 1000, amplitude: 0.1, sampleRate: 44_100, frames: 44_100 * 3))[...])
        meter.process(interleaved: [Float](repeating: 0, count: 44_100 * 2 * 5)[...])

        #expect(meter.momentaryLUFS == -.infinity)
        // 27 full-tone gating blocks plus three straddling the end of the tone (3/4, 1/2 and 1/4 full)
        // pass the gates; the 5 s of silence is gated out.
        let expected = -20 + 10 * log10(28.5 / 30)
        #expect(abs(meter.integratedLUFS - expected) < 0.05)
    }
}

struct AudioRingBufferTests {
    @Test func readsWhatWasWritten() {
        let ring = AudioRingBuffer(capacity: 16)
        let left: [Float] = [1, 2, 3], right: [Float] = [-1, -2, -3]
        ring.write(left: left, leftStride: 1, right: right, rightStride: 1, frames: 3)

        var position = 0
        var output: [Float] = []
        #expect(ring.read(from: &position, into: &output) == 3)
        #expect(output == [1, -1, 2, -2, 3, -3])
        #expect(ring.read(from: &position, into: &output) == 0)
    }

    @Test func slowReaderSkipsToNewestAudio() {
        let ring = AudioRingBuffer(capacity: 8)
        let samples = (0..<20).map(Float.init)
        ring.write(left: samples, leftStride: 1, right: samples, rightStride: 1, frames: 20)

        var position = 0
        var output: [Float] = []
        #expect(ring.read(from: &position, into: &output) == 4)
        #expect(output.first == 16)
        #expect(position == 20)
    }
}
