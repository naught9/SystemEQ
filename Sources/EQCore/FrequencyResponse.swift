import Foundation

public enum FrequencyResponseParseError: Error, Equatable, LocalizedError {
    case notEnoughPoints

    public var errorDescription: String? {
        "Not a frequency response: expected lines of \"frequency, dB\"."
    }
}

/// A frequency response curve, such as a headphone measurement or a target curve,
/// stored as (frequency, dB) points in ascending frequency order.
public struct FrequencyResponse: Sendable, Equatable {
    public var name: String
    public var frequencies: [Double]
    public var db: [Double]

    public init(name: String, frequencies: [Double], db: [Double]) {
        precondition(frequencies.count == db.count)
        self.name = name
        self.frequencies = frequencies
        self.db = db
    }

    /// Parses the two-column text exported by squig.link, AutoEQ and REW. Columns may be
    /// separated by tabs, commas, semicolons or spaces; header and comment lines are skipped.
    public static func parse(_ text: String, name: String) throws -> FrequencyResponse {
        var points: [(Double, Double)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let numbers = line
                .split(whereSeparator: { $0 == "\t" || $0 == "," || $0 == ";" || $0 == " " })
                .prefix(2)
                .compactMap { Double($0) }
            guard numbers.count == 2, numbers[0] > 0, numbers[1].isFinite else { continue }
            points.append((numbers[0], numbers[1]))
        }

        points.sort { $0.0 < $1.0 }
        var frequencies: [Double] = [], db: [Double] = []
        for (frequency, value) in points where frequency != frequencies.last {
            frequencies.append(frequency)
            db.append(value)
        }
        guard frequencies.count >= 10 else { throw FrequencyResponseParseError.notEnoughPoints }
        return FrequencyResponse(name: name, frequencies: frequencies, db: db)
    }

    public static func parse(contentsOf url: URL) throws -> FrequencyResponse {
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? url.deletingPathExtension().lastPathComponent
        return try parse(text, name: name)
    }

    /// Log-spaced frequencies from `lower` to `upper` Hz inclusive.
    public static func logGrid(from lower: Double = 20, to upper: Double = 20_000, pointsPerOctave: Double = 48) -> [Double] {
        let count = Int((log2(upper / lower) * pointsPerOctave).rounded()) + 1
        return (0..<count).map { lower * pow(upper / lower, Double($0) / Double(count - 1)) }
    }

    /// The response at `frequency`, interpolated linearly on a log-frequency axis and held
    /// constant beyond the measured range.
    public func value(at frequency: Double) -> Double {
        guard frequency > frequencies[0] else { return db[0] }
        guard frequency < frequencies[frequencies.count - 1] else { return db[db.count - 1] }

        var low = 0, high = frequencies.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if frequencies[mid] <= frequency { low = mid } else { high = mid }
        }
        let t = log(frequency / frequencies[low]) / log(frequencies[high] / frequencies[low])
        return db[low] + t * (db[high] - db[low])
    }

    public func resampled(to grid: [Double]) -> [Double] {
        grid.map(value(at:))
    }
}

/// Fractional-octave smoothing of `values` sampled on a log grid with `pointsPerOctave` spacing.
/// The window is `octaves(frequency)` wide, so it can vary across the spectrum.
func smoothed(_ values: [Double], grid: [Double], pointsPerOctave: Double, octaves: (Double) -> Double) -> [Double] {
    var prefix = [0.0]
    prefix.reserveCapacity(values.count + 1)
    for value in values { prefix.append(prefix[prefix.count - 1] + value) }

    return grid.indices.map { i in
        let halfWidth = Int((octaves(grid[i]) * pointsPerOctave / 2).rounded())
        let lower = max(0, i - halfWidth), upper = min(values.count - 1, i + halfWidth)
        return (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
    }
}
