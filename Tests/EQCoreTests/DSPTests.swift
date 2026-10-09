import Foundation
import Testing
@testable import EQCore

struct BiquadTests {
    let sampleRate = 48_000.0

    @Test func peakingFilterHitsGainAtCenter() {
        let c = BiquadCoefficients(filter: Filter(type: .peaking, frequency: 1000, gainDB: 6, q: 1), sampleRate: sampleRate)
        #expect(abs(c.magnitudeDB(at: 1000, sampleRate: sampleRate) - 6) < 0.01)
        #expect(abs(c.magnitudeDB(at: 20, sampleRate: sampleRate)) < 0.1)
    }

    @Test func shelvesReachGainAwayFromCorner() {
        let low = BiquadCoefficients(filter: Filter(type: .lowShelf, frequency: 105, gainDB: 4, q: 0.7), sampleRate: sampleRate)
        #expect(abs(low.magnitudeDB(at: 10, sampleRate: sampleRate) - 4) < 0.1)
        #expect(abs(low.magnitudeDB(at: 5000, sampleRate: sampleRate)) < 0.1)

        let high = BiquadCoefficients(filter: Filter(type: .highShelf, frequency: 10_000, gainDB: -5, q: 0.7), sampleRate: sampleRate)
        #expect(abs(high.magnitudeDB(at: 20_000, sampleRate: sampleRate) + 5) < 0.3)
        #expect(abs(high.magnitudeDB(at: 100, sampleRate: sampleRate)) < 0.1)
    }

    @Test func disabledAndOutOfRangeFiltersAreIdentity() {
        let disabled = Filter(type: .peaking, frequency: 1000, gainDB: 6, q: 1, isEnabled: false)
        #expect(BiquadCoefficients(filter: disabled, sampleRate: sampleRate) == .identity)

        let aboveNyquist = Filter(type: .peaking, frequency: 30_000, gainDB: 6, q: 1)
        #expect(BiquadCoefficients(filter: aboveNyquist, sampleRate: sampleRate) == .identity)
    }

    @Test func presetResponseIncludesPreamp() {
        let preset = ParametricPreset(name: "p", preampDB: -3, filters: [Filter(type: .peaking, frequency: 1000, gainDB: 3, q: 1)])
        #expect(abs(preset.responseDB(at: 1000)) < 0.01)
        #expect(abs(preset.responseDB(at: 20) + 3) < 0.1)
    }
}

struct EQProcessorTests {
    /// Runs a sine through the processor and returns the output level relative to the input, in dB.
    private func measuredGainDB(_ processor: EQProcessor, frequency: Double, sampleRate: Double, stride: Int = 1) -> Double {
        let frames = Int(sampleRate) // 1 second; the second half is past the filter's settling time
        var buffer = [Float](repeating: 0, count: frames * stride)
        for i in 0..<frames {
            buffer[i * stride] = Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate) * 0.5)
        }
        processor.beginCycle()
        buffer.withUnsafeMutableBufferPointer {
            processor.process($0.baseAddress!, frames: frames, stride: stride, channel: 0)
        }
        let tail = (frames / 2..<frames).map { Double(buffer[$0 * stride]) }
        let rms = sqrt(tail.map { $0 * $0 }.reduce(0, +) / Double(tail.count))
        return 20 * log10(rms / (0.5 / sqrt(2)))
    }

    @Test func flatPresetPassesAudioThrough() {
        let processor = EQProcessor()
        #expect(abs(measuredGainDB(processor, frequency: 1000, sampleRate: 48_000)) < 0.01)
    }

    @Test func appliesPresetToAudio() {
        let preset = ParametricPreset(name: "p", preampDB: -2, filters: [Filter(type: .peaking, frequency: 1000, gainDB: 6, q: 1)])
        let processor = EQProcessor(preset: preset, sampleRate: 48_000)
        #expect(abs(measuredGainDB(processor, frequency: 1000, sampleRate: 48_000) - 4) < 0.05)
    }

    @Test func processesInterleavedChannelInPlace() {
        let preset = ParametricPreset(name: "p", preampDB: -6)
        let processor = EQProcessor(preset: preset, sampleRate: 44_100)
        #expect(abs(measuredGainDB(processor, frequency: 440, sampleRate: 44_100, stride: 2) + 6) < 0.01)
    }

    @Test func picksUpPresetAndSampleRateChanges() {
        let processor = EQProcessor()
        processor.setPreset(ParametricPreset(name: "p", filters: [Filter(type: .peaking, frequency: 1000, gainDB: -6, q: 1)]))
        processor.setSampleRate(96_000)
        #expect(abs(measuredGainDB(processor, frequency: 1000, sampleRate: 96_000) + 6) < 0.05)
    }
}
