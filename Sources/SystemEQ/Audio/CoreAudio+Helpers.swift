import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed (\(status.fourCharCode))"
    }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
}

extension OSStatus {
    /// Core Audio errors are usually four printable characters, e.g. 'who?'.
    var fourCharCode: String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: self).bigEndian, Array.init)
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(self) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    /// Reads a fixed-size property value such as an AudioObjectID, Float64 or AudioStreamBasicDescription.
    func read<Value: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, default value: Value) throws -> Value {
        var address = AudioObjectPropertyAddress(selector)
        var value = value
        var size = UInt32(MemoryLayout<Value>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Reading property \(selector)")
        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Reading property \(selector)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        let device = try system.read(kAudioHardwarePropertyDefaultOutputDevice, default: unknown)
        guard device != unknown else { throw CoreAudioError(operation: "Finding the default output device", status: kAudioHardwareBadDeviceError) }
        return device
    }

    /// The Core Audio process object for this app. It exists once the app has connected to the
    /// audio system, which any earlier property read has already done.
    static func currentProcess() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var process = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process),
            "Finding this app's audio process"
        )
        guard process != unknown else { throw CoreAudioError(operation: "Finding this app's audio process", status: kAudioHardwareBadObjectError) }
        return process
    }
}
