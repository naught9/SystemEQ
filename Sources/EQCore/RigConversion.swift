import Foundation

/// The coupler or head simulator a frequency response was measured on. IEM measurements and targets
/// from different rigs aren't directly comparable, so targets are converted to the source's rig.
public enum MeasurementRig: String, CaseIterable, Codable, Sendable {
    /// IEC 60318-4 ("711") ear simulator, used by most squig.link databases.
    case iec711 = "IEC 711"
    /// Brüel & Kjær 5128 head and torso simulator.
    case bk5128 = "B&K 5128"

    /// Guesses the rig from a file name or path, e.g. "Targets (B&K 5128)/Harman 2025 MoA Average Target.txt".
    public static func infer(from text: String) -> MeasurementRig? {
        let lowered = text.lowercased()
        if lowered.contains("5128") { return .bk5128 }
        if lowered.contains("711") || lowered.contains("60318-4") { return .iec711 }
        return nil
    }
}

/// Converts responses between measurement rigs using the average difference between them.
///
/// The conversion is reliable to within about a decibel up to 4 kHz. Above 8 kHz individual IEMs
/// differ between rigs by several dB, so only the smoothed average trend is applied there.
public enum RigConversion {
    static let iec711ToBK5128 = FrequencyResponse(
        name: "IEC 711 to B&K 5128",
        frequencies: iec711ToBK5128Points.map(\.frequency),
        db: iec711ToBK5128Points.map(\.db)
    )

    /// dB to add to a response measured on `source` to estimate it on `destination`.
    public static func offsetDB(at frequency: Double, from source: MeasurementRig, to destination: MeasurementRig) -> Double {
        switch (source, destination) {
        case (.iec711, .bk5128): iec711ToBK5128.value(at: frequency)
        case (.bk5128, .iec711): -iec711ToBK5128.value(at: frequency)
        default: 0
        }
    }
}

extension FrequencyResponse {
    /// This response as it would measure on `destination`, given it was measured on `source`.
    public func converted(from source: MeasurementRig, to destination: MeasurementRig) -> FrequencyResponse {
        guard source != destination else { return self }
        return FrequencyResponse(
            name: name,
            frequencies: frequencies,
            db: zip(frequencies, db).map { $1 + RigConversion.offsetDB(at: $0, from: source, to: destination) }
        )
    }
}
