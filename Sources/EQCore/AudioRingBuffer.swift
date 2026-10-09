import Synchronization

/// A single-producer, single-consumer ring buffer of stereo frames for metering.
///
/// The audio thread writes without locking or allocating. A reader that falls more than
/// half the capacity behind skips ahead to the newest audio rather than reading torn data.
public final class AudioRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    /// Interleaved left/right samples.
    private let storage: UnsafeMutablePointer<Float>
    /// Total frames ever written. Only the audio thread stores; readers load.
    private let framesWritten = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int = 1 << 17) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        storage = .allocate(capacity: size * 2)
        storage.initialize(repeating: 0, count: size * 2)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: Audio thread

    public func write(left: UnsafePointer<Float>, leftStride: Int, right: UnsafePointer<Float>, rightStride: Int, frames: Int) {
        let start = framesWritten.load(ordering: .relaxed)
        for frame in 0..<frames {
            let slot = ((start + frame) & mask) * 2
            storage[slot] = left[frame * leftStride]
            storage[slot + 1] = right[frame * rightStride]
        }
        framesWritten.store(start + frames, ordering: .releasing)
    }

    // MARK: Reader

    /// Appends interleaved stereo frames written since `position` to `output`, and advances `position`.
    /// Returns the number of frames appended.
    @discardableResult
    public func read(from position: inout Int, into output: inout [Float]) -> Int {
        let end = framesWritten.load(ordering: .acquiring)
        let start = max(position, end - capacity / 2)
        guard end > start else { return 0 }
        output.reserveCapacity(output.count + (end - start) * 2)
        for frame in start..<end {
            let slot = (frame & mask) * 2
            output.append(storage[slot])
            output.append(storage[slot + 1])
        }
        position = end
        return end - start
    }
}
