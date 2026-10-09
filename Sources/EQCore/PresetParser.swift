import Foundation

public enum PresetParseError: Error, Equatable, LocalizedError {
    /// The text contained no preamp or filter lines, e.g. a raw frequency response measurement.
    case notParametricEQ
    case invalidLine(number: Int, text: String)

    public var errorDescription: String? {
        switch self {
        case .notParametricEQ:
            "Not a parametric EQ preset. Frequency response measurements can't be applied directly."
        case let .invalidLine(number, text):
            "Couldn't read line \(number): \(text)"
        }
    }
}

/// Parses the Equalizer APO parametric format that AutoEQ and squig.link export:
///
///     Preamp: -6.44 dB
///     Filter 1: ON LS Fc 105.0 Hz Gain 2.8 dB Q 0.70
///     Filter 2: ON PK Fc 78.5 Hz Gain 1.1 dB Q 4.44
///
/// Lines that aren't preamp or filter lines are ignored, so comments and
/// other Equalizer APO commands don't prevent a preset from loading.
public enum PresetParser {
    public static func parse(_ text: String, name: String) throws -> ParametricPreset {
        var preset = ParametricPreset(name: name)
        var sawPreamp = false

        for (index, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let lowered = line.lowercased()
            if lowered.hasPrefix("preamp:") {
                guard let gain = number(after: "preamp:", in: lowered) else {
                    throw PresetParseError.invalidLine(number: index + 1, text: line)
                }
                preset.preampDB += gain
                sawPreamp = true
            } else if lowered.hasPrefix("filter") {
                guard let filter = try parseFilter(lowered, lineNumber: index + 1, original: line) else { continue }
                preset.filters.append(filter)
            }
        }

        guard sawPreamp || !preset.filters.isEmpty else { throw PresetParseError.notParametricEQ }
        return preset
    }

    public static func parse(contentsOf url: URL) throws -> ParametricPreset {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Parses `filter[ n]: on|off <type> fc <f> hz [gain <g> db] [q <q> | bw oct <bw>]`.
    /// Returns nil for filter types this app doesn't support, such as Equalizer APO's "None".
    private static func parseFilter(_ line: String, lineNumber: Int, original: String) throws -> Filter? {
        guard let colon = line.firstIndex(of: ":") else {
            throw PresetParseError.invalidLine(number: lineNumber, text: original)
        }
        let tokens = line[line.index(after: colon)...].split(separator: " ").map(String.init)
        guard tokens.count >= 2, tokens[0] == "on" || tokens[0] == "off" else {
            throw PresetParseError.invalidLine(number: lineNumber, text: original)
        }

        let type: FilterType
        switch tokens[1] {
        case "pk", "peq", "peak": type = .peaking
        case "ls", "lsc", "lsq", "lowshelf": type = .lowShelf
        case "hs", "hsc", "hsq", "highshelf": type = .highShelf
        case "lp", "lpq": type = .lowPass
        case "hp", "hpq": type = .highPass
        case "no", "notch": type = .notch
        default: return nil
        }

        func value(after key: String) -> Double? {
            guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count else { return nil }
            return Double(tokens[i + 1])
        }

        guard let frequency = value(after: "fc"), frequency > 0 else {
            throw PresetParseError.invalidLine(number: lineNumber, text: original)
        }

        var q = value(after: "q")
        if q == nil, let i = tokens.firstIndex(of: "bw"), i + 2 < tokens.count, tokens[i + 1] == "oct",
           let bandwidth = Double(tokens[i + 2]), bandwidth > 0 {
            let factor = pow(2, bandwidth)
            q = sqrt(factor) / (factor - 1)
        }

        return Filter(
            type: type,
            frequency: frequency,
            gainDB: value(after: "gain") ?? 0,
            q: q ?? 0.7071,
            isEnabled: tokens[0] == "on"
        )
    }

    private static func number(after prefix: String, in line: String) -> Double? {
        line.dropFirst(prefix.count)
            .split(separator: " ")
            .lazy
            .compactMap { Double($0) }
            .first
    }
}

extension ParametricPreset {
    /// The preset in Equalizer APO / AutoEQ text format, readable by `PresetParser`.
    public var equalizerAPOText: String {
        var lines = [String(format: "Preamp: %.2f dB", preampDB)]
        for (index, filter) in filters.enumerated() {
            let code = switch filter.type {
            case .peaking: "PK"
            case .lowShelf: "LS"
            case .highShelf: "HS"
            case .lowPass: "LPQ"
            case .highPass: "HPQ"
            case .notch: "NO"
            }
            var line = String(format: "Filter %d: %@ %@ Fc %.1f Hz", index + 1, filter.isEnabled ? "ON" : "OFF", code, filter.frequency)
            if filter.type.usesGain { line += String(format: " Gain %.1f dB", filter.gainDB) }
            line += String(format: " Q %.2f", filter.q)
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
