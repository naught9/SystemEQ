import CoreAudio
import EQCore
import Foundation
import Observation

/// Routes all system audio through an `EQProcessor`.
///
/// A muted global process tap captures every app's output (except our own), and a private
/// aggregate device built on the current default output device plays the processed audio.
/// If this app quits or crashes, macOS removes the tap and audio goes straight to the device again.
@Observable @MainActor
final class SystemAudioEQ {
    enum State: Equatable {
        case stopped
        case running(outputDevice: String)
        case failed(String)
    }

    private(set) var state = State.stopped
    let processor = EQProcessor()

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    func start() {
        stop()
        do {
            try build()
            watchDefaultOutputDevice()
        } catch {
            tearDown()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        if let defaultDeviceListener {
            var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, defaultDeviceListener)
            self.defaultDeviceListener = nil
        }
        tearDown()
        state = .stopped
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
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the output device")

        processor.setSampleRate(try aggregateID.read(kAudioDevicePropertyNominalSampleRate, default: Float64(48_000)))
        processor.reset()
        watchSampleRate()

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, Self.makeRenderBlock(processor: processor, tapChannels: tapChannels)),
            "Creating the audio callback"
        )
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio")

        state = .running(outputDevice: outputName)
    }

    private func tearDown() {
        if aggregateID != .unknown {
            if let sampleRateListener {
                var address = AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &address, .main, sampleRateListener)
            }
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        sampleRateListener = nil
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    // MARK: Listeners

    /// Rebuilds on the new device when the user switches outputs, e.g. plugging in headphones.
    private func watchDefaultOutputDevice() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.defaultDeviceListener != nil else { return }
                self.tearDown()
                do {
                    try self.build()
                } catch {
                    self.tearDown()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(.system, &address, .main, listener) == noErr {
            defaultDeviceListener = listener
        }
    }

    private func watchSampleRate() {
        let device = aggregateID
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let rate = try? device.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0)) else { return }
                self.processor.setSampleRate(rate)
            }
        }
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr {
            sampleRateListener = listener
        }
    }

    // MARK: Rendering

    /// Built outside the main actor so the block carries no actor isolation: it runs on the audio thread.
    private nonisolated static func makeRenderBlock(processor: EQProcessor, tapChannels: Int) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            render(
                input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                output: UnsafeMutableAudioBufferListPointer(output),
                tapChannels: tapChannels,
                processor: processor
            )
        }
    }

    /// Copies the tap's audio to the output device's first channels and applies the EQ.
    /// Real-time safe: no allocation, locking or Objective-C messaging.
    nonisolated static func render(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        tapChannels: Int,
        processor: EQProcessor
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
    }
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
