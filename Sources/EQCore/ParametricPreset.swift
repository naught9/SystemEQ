import Foundation

/// The shape of a single parametric EQ band.
public enum FilterType: String, Sendable, Codable, CaseIterable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch

    /// Whether the band's gain setting affects its response.
    public var usesGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf: true
        case .lowPass, .highPass, .notch: false
        }
    }
}

/// One band of a parametric EQ.
public struct Filter: Sendable, Equatable, Codable {
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(type: FilterType, frequency: Double, gainDB: Double = 0, q: Double = 0.7071, isEnabled: Bool = true) {
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }
}

/// A complete parametric EQ: a preamp followed by a chain of filters,
/// as produced by AutoEQ / Equalizer APO / squig.link.
public struct ParametricPreset: Sendable, Equatable, Codable {
    public var name: String
    public var preampDB: Double
    public var filters: [Filter]

    public init(name: String, preampDB: Double = 0, filters: [Filter] = []) {
        self.name = name
        self.preampDB = preampDB
        self.filters = filters
    }

    public static let flat = ParametricPreset(name: "Flat")

    /// Combined response of the preamp and all enabled filters at `frequency`, in dB.
    public func responseDB(at frequency: Double, sampleRate: Double = 48_000) -> Double {
        filters
            .filter(\.isEnabled)
            .reduce(preampDB) { total, filter in
                total + BiquadCoefficients(filter: filter, sampleRate: sampleRate).magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
    }
}
