import Foundation
import os

/// Applies a `ParametricPreset` to audio in real time.
///
/// `setPreset` / `setSampleRate` may be called from any thread. The audio thread calls
/// `beginCycle()` once per render cycle and then `process` per channel. Neither of those
/// allocates or blocks: new coefficients are staged under a lock that the audio thread only
/// ever *tries* to take, so a busy UI thread delays a preset change by one cycle at most.
public final class EQProcessor: @unchecked Sendable {
    public static let maxFilters = 64
    public static let maxChannels = 8

    private let lock = OSAllocatedUnfairLock()

    // Staging area, guarded by `lock`.
    private var preset: ParametricPreset
    private var sampleRate: Double
    private let stagedCoefficients: UnsafeMutablePointer<BiquadCoefficients>
    private var stagedCount = 0
    private var stagedGain = 1.0
    private var hasStagedChanges = true
    private var resetRequested = false

    // Audio thread only.
    private let activeCoefficients: UnsafeMutablePointer<BiquadCoefficients>
    private var activeCount = 0
    private var activeGain = 1.0
    /// Transposed direct form II state: two values per filter per channel.
    private let filterState: UnsafeMutablePointer<Double>

    public init(preset: ParametricPreset = .flat, sampleRate: Double = 48_000) {
        self.preset = preset
        self.sampleRate = sampleRate
        stagedCoefficients = .allocate(capacity: Self.maxFilters)
        stagedCoefficients.initialize(repeating: .identity, count: Self.maxFilters)
        activeCoefficients = .allocate(capacity: Self.maxFilters)
        activeCoefficients.initialize(repeating: .identity, count: Self.maxFilters)
        filterState = .allocate(capacity: Self.maxChannels * Self.maxFilters * 2)
        filterState.initialize(repeating: 0, count: Self.maxChannels * Self.maxFilters * 2)
        lock.withLockUnchecked { stage() }
    }

    deinit {
        stagedCoefficients.deallocate()
        activeCoefficients.deallocate()
        filterState.deallocate()
    }

    public func setPreset(_ preset: ParametricPreset) {
        lock.withLockUnchecked {
            self.preset = preset
            stage()
        }
    }

    public func setSampleRate(_ sampleRate: Double) {
        lock.withLockUnchecked {
            guard sampleRate > 0, sampleRate != self.sampleRate else { return }
            self.sampleRate = sampleRate
            resetRequested = true
            stage()
        }
    }

    /// Clears filter memory, e.g. after the audio stream restarts. Applied on the next cycle.
    public func reset() {
        lock.withLockUnchecked { resetRequested = true }
    }

    private func stage() {
        let filters = preset.filters.filter(\.isEnabled).prefix(Self.maxFilters)
        for (index, filter) in filters.enumerated() {
            stagedCoefficients[index] = BiquadCoefficients(filter: filter, sampleRate: sampleRate)
        }
        stagedCount = filters.count
        stagedGain = pow(10, preset.preampDB / 20)
        hasStagedChanges = true
    }

    // MARK: Audio thread

    /// Picks up staged changes. Call once per render cycle, before `process`.
    public func beginCycle() {
        lock.withLockIfAvailableUnchecked {
            if resetRequested {
                filterState.update(repeating: 0, count: Self.maxChannels * Self.maxFilters * 2)
                resetRequested = false
            }
            guard hasStagedChanges else { return }
            activeCoefficients.update(from: stagedCoefficients, count: stagedCount)
            activeCount = stagedCount
            activeGain = stagedGain
            hasStagedChanges = false
        }
    }

    /// Filters `frames` samples in place. `stride` is the distance between consecutive
    /// samples of this channel: 1 for non-interleaved buffers, the channel count for interleaved.
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, stride: Int, channel: Int) {
        guard channel < Self.maxChannels else { return }
        let state = filterState + channel * Self.maxFilters * 2
        let count = activeCount
        let gain = activeGain

        for frame in 0..<frames {
            var x = Double(samples[frame * stride]) * gain
            for i in 0..<count {
                let c = activeCoefficients[i]
                let y = c.b0 * x + state[2 * i]
                state[2 * i] = c.b1 * x - c.a1 * y + state[2 * i + 1]
                state[2 * i + 1] = c.b2 * x - c.a2 * y
                x = y
            }
            samples[frame * stride] = Float(x)
        }
    }
}
