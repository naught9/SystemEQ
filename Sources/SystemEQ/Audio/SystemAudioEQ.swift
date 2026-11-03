import CoreAudio
import EQCore
import Foundation
import Observation
import os
import Synchronization

private let log = Logger(subsystem: "com.jakemclain.SystemEQ", category: "audio")

/// Routes all system audio through an `EQProcessor`.
///
/// A muted global process tap captures every app's output (except our own), and a private
/// aggregate device built on the current default output device plays the processed audio.
/// If this app quits or crashes, macOS removes the tap and audio goes straight to the device again.
/// The tap keeps muting while it exists even if our playback stops, so a watchdog removes it
/// when the render callback stalls, and the chain is rebuilt when Core Audio or the device restarts.
@Observable @MainActor
final class SystemAudioEQ {
    enum State: Equatable {
        case stopped
        case running(outputDevice: String)
        case failed(String)
    }

    private(set) var state = State.stopped
    let processor = EQProcessor()
    /// Post-EQ audio for the visualizers.
    let meterBuffer = AudioRingBuffer()
    private(set) var sampleRate = 48_000.0

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    private let heartbeat = RenderHeartbeat()
    private var watchdog: DispatchSourceTimer?
    private var lastCycles = 0
    private var lastCycleTime = SuspendingClock.now
    private var builtAt = SuspendingClock.now
    private var retry: DispatchWorkItem?
    private var consecutiveFailures = 0
    private var recoveringServiceRestart = false

    /// How long the render callback may go uncalled before the tap is removed.
    private static let stallLimit = Duration.milliseconds(1500)
    /// Delays between attempts to recover from a stall or failed start, after which we give up.
    private static let retryDelays: [Double] = [1, 3, 10, 30]

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    func start() {
        stop()
        consecutiveFailures = 0
        watchSystem()
        rebuild()
    }

    func stop() {
        for (selector, listener) in systemListeners {
            var address = AudioObjectPropertyAddress(selector)
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, listener)
        }
        systemListeners = []
        retry?.cancel()
        retry = nil
        recoveringServiceRestart = false
        tearDown()
        state = .stopped
    }

    private func rebuild() {
        retry?.cancel()
        retry = nil
        tearDown()
        do {
            try build()
        } catch {
            log.error("Starting failed: \(error.localizedDescription, privacy: .public)")
            tearDown()
            state = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    /// Tries again after a stall or failed start, backing off, and gives up so a persistent
    /// problem leaves audio playing unprocessed instead of cutting out over and over.
    private func scheduleRetry() {
        guard consecutiveFailures < Self.retryDelays.count else {
            log.error("Giving up after \(self.consecutiveFailures, privacy: .public) attempts")
            return
        }
        let delay = Self.retryDelays[consecutiveFailures]
        consecutiveFailures += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.systemListeners.isEmpty, !self.recoveringServiceRestart else { return }
                self.rebuild()
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func build() throws {
        let outputDevice = try AudioObjectID.defaultOutputDevice()
        let outputUID = try outputDevice.readString(kAudioDevicePropertyDeviceUID)
        let outputName = (try? outputDevice.readString(kAudioObjectPropertyName)) ?? outputUID

        // Exclude ourselves, or the tap would capture the processed audio we play and feed it back in.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try AudioObjectID.currentProcess()])
        description.name = "SystemEQ"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")

        let tapFormat = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let tapChannels = Int(tapFormat.mChannelsPerFrame)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SystemEQ",
            kAudioAggregateDeviceUIDKey: "SystemEQ-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                // The tap and device can run on slightly different clocks. Drift compensation
                // resamples the tap to match; use the best resampler so treble isn't dulled.
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the output device")

        let sampleRate = try aggregateID.read(kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))
        processor.setSampleRate(sampleRate)
        self.sampleRate = sampleRate
        processor.reset()
        watchDevices(output: outputDevice)

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, Self.makeRenderBlock(processor: processor, meter: meterBuffer, heartbeat: heartbeat, tapChannels: tapChannels)),
            "Creating the audio callback"
        )
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio")
        startWatchdog()

        state = .running(outputDevice: outputName)

        let deviceRate = (try? outputDevice.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
        let bufferFrames = (try? aggregateID.read(kAudioDevicePropertyBufferFrameSize, default: UInt32(0))) ?? 0
        log.info("""
            Started on \(outputName, privacy: .public): device \(deviceRate, privacy: .public) Hz, \
            aggregate \(sampleRate, privacy: .public) Hz, buffer \(bufferFrames, privacy: .public) frames, \
            tap \(tapFormat.mSampleRate, privacy: .public) Hz \(tapChannels, privacy: .public)ch \
            \(tapFormat.mBitsPerChannel, privacy: .public)-bit flags 0x\(String(tapFormat.mFormatFlags, radix: 16), privacy: .public)
            """)
    }

    /// Removes the tap and aggregate. Pass `objectsAreGone` after Core Audio restarts: the old IDs
    /// are dead and may already belong to new objects, so they're forgotten rather than destroyed.
    private func tearDown(objectsAreGone: Bool = false) {
        watchdog?.cancel()
        watchdog = nil
        if !objectsAreGone {
            for (object, selector, listener) in deviceListeners {
                var address = AudioObjectPropertyAddress(selector)
                AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
            }
            if aggregateID != .unknown {
                if let ioProcID {
                    AudioDeviceStop(aggregateID, ioProcID)
                    AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                }
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            if tapID != .unknown {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
        deviceListeners = []
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    // MARK: Watchdog

    /// Checks that the render callback is still being called. A running aggregate is called
    /// continuously, even when nothing is playing, so a stall means our output has stopped
    /// while the tap still mutes everything else.
    private func startWatchdog() {
        lastCycles = heartbeat.cycles.load(ordering: .relaxed)
        lastCycleTime = .now
        builtAt = .now
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkHeartbeat() }
        }
        timer.resume()
        watchdog = timer
    }

    private func checkHeartbeat() {
        guard aggregateID != .unknown else { return }
        // The suspending clock doesn't advance during sleep, when the callback legitimately stops.
        let now = SuspendingClock.now
        let cycles = heartbeat.cycles.load(ordering: .relaxed)
        if cycles != lastCycles {
            lastCycles = cycles
            lastCycleTime = now
            if now - builtAt > .seconds(10) { consecutiveFailures = 0 }
            return
        }
        guard now - lastCycleTime > Self.stallLimit else { return }
        log.error("The render callback stalled; removing the tap so system audio isn't muted")
        tearDown()
        state = .failed("Audio stopped responding. Retrying…")
        scheduleRetry()
    }

    // MARK: Listeners

    private func watchSystem() {
        // Rebuilds on the new device when the user switches outputs, e.g. plugging in headphones.
        let defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.systemListeners.isEmpty, !self.recoveringServiceRestart else { return }
                self.rebuild()
            }
        }
        // When coreaudiod restarts, every object we made is gone and our listeners with it.
        let restartListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.systemListeners.isEmpty else { return }
                log.error("Core Audio restarted; waiting for it to settle")
                if !self.recoveringServiceRestart {
                    self.tearDown(objectsAreGone: true)
                    self.stop()
                    self.watchSystem()
                    self.recoveringServiceRestart = true
                }
                self.retry?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.recoveringServiceRestart else { return }
                        self.recoveringServiceRestart = false
                        self.consecutiveFailures = 0
                        self.rebuild()
                    }
                }
                self.retry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
        }
        for (selector, listener) in [
            (kAudioHardwarePropertyDefaultOutputDevice, defaultDeviceListener),
            (kAudioHardwarePropertyServiceRestarted, restartListener),
        ] {
            var address = AudioObjectPropertyAddress(selector)
            if AudioObjectAddPropertyListenerBlock(.system, &address, .main, listener) == noErr {
                systemListeners.append((selector, listener))
            }
        }
    }

    /// Keeps the filters designed for the current sample rate, logs dropouts, and rebuilds if the
    /// output device or aggregate dies, e.g. Bluetooth headphones disconnecting.
    private func watchDevices(output: AudioDeviceID) {
        let device = aggregateID
        let sampleRateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let rate = try? device.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0)) else { return }
                log.info("Sample rate changed to \(rate, privacy: .public) Hz")
                self.processor.setSampleRate(rate)
                self.sampleRate = rate
            }
        }
        let overloadListener: AudioObjectPropertyListenerBlock = { _, _ in
            log.error("Audio dropout: the render callback missed its deadline")
        }
        func aliveListener(_ object: AudioObjectID) -> AudioObjectPropertyListenerBlock {
            { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.aggregateID == device else { return }
                    let alive = (try? object.read(kAudioDevicePropertyDeviceIsAlive, default: UInt32(0))) ?? 0
                    guard alive == 0 else { return }
                    log.error("An audio device died; rebuilding")
                    self.rebuild()
                }
            }
        }
        for (object, selector, listener) in [
            (device, kAudioDevicePropertyNominalSampleRate, sampleRateListener),
            (device, kAudioDeviceProcessorOverload, overloadListener),
            (device, kAudioDevicePropertyDeviceIsAlive, aliveListener(device)),
            (output, kAudioDevicePropertyDeviceIsAlive, aliveListener(output)),
        ] {
            var address = AudioObjectPropertyAddress(selector)
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr {
                deviceListeners.append((object, selector, listener))
            }
        }
    }

    // MARK: Rendering

    /// Built outside the main actor so the block carries no actor isolation: it runs on the audio thread.
    private nonisolated static func makeRenderBlock(processor: EQProcessor, meter: AudioRingBuffer, heartbeat: RenderHeartbeat, tapChannels: Int) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            heartbeat.cycles.wrappingAdd(1, ordering: .relaxed)
            render(
                input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                output: UnsafeMutableAudioBufferListPointer(output),
                tapChannels: tapChannels,
                processor: processor,
                meter: meter
            )
        }
    }

    /// Copies the tap's audio to the output device's first channels, applies the EQ, and copies the result for metering.
    /// Real-time safe: no allocation, locking or Objective-C messaging.
    nonisolated static func render(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        tapChannels: Int,
        processor: EQProcessor,
        meter: AudioRingBuffer
    ) {
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // The aggregate's inputs are the output device's own inputs (if any) followed by the tap.
        let inputChannels = input.reduce(0) { $0 + Int($1.mNumberChannels) }
        let outputChannels = output.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard tapChannels > 0, inputChannels >= tapChannels, outputChannels > 0 else { return }
        let firstTapChannel = inputChannels - tapChannels

        processor.beginCycle()
        for channel in 0..<min(tapChannels, outputChannels) {
            guard let source = ChannelView(input, channel: firstTapChannel + channel),
                  let destination = ChannelView(output, channel: channel) else { continue }
            let frames = min(source.frames, destination.frames)
            for frame in 0..<frames {
                destination.samples[frame * destination.stride] = source.samples[frame * source.stride]
            }
            processor.process(destination.samples, frames: frames, stride: destination.stride, channel: channel)
        }

        // Mono outputs meter the same channel on both sides.
        if let left = ChannelView(output, channel: 0) {
            let right = ChannelView(output, channel: min(1, outputChannels - 1)) ?? left
            meter.write(left: left.samples, leftStride: left.stride, right: right.samples, rightStride: right.stride, frames: min(left.frames, right.frames))
        }
    }
}

/// Counts render cycles so the watchdog can tell when Core Audio stops calling us.
private final class RenderHeartbeat: Sendable {
    let cycles = Atomic<Int>(0)
}

/// One channel within an AudioBufferList, which may be interleaved or not.
private struct ChannelView {
    let samples: UnsafeMutablePointer<Float>
    let stride: Int
    let frames: Int

    init?(_ list: UnsafeMutableAudioBufferListPointer, channel: Int) {
        var remaining = channel
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard channels > 0, let data = buffer.mData else { return nil }
                samples = data.assumingMemoryBound(to: Float.self) + remaining
                stride = channels
                frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return
            }
            remaining -= channels
        }
        return nil
    }
}
