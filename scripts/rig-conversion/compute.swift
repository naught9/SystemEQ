import Foundation
let dir = CommandLine.arguments[1].hasSuffix("/") ? CommandLine.arguments[1] : CommandLine.arguments[1] + "/"
let grid = FrequencyResponse.logGrid(from: 20, to: 20_000, pointsPerOctave: 48)
func channels(_ folder: String, _ label: String) -> [FrequencyResponse] {
    ["L", "R"].compactMap { try? FrequencyResponse.parse(contentsOf: URL(filePath: "\(dir)\(folder)/\(label) \($0).txt")) }
}
func mean(_ rs: [FrequencyResponse]) -> [Double] {
    grid.map { f in rs.map { $0.value(at: f) }.reduce(0, +) / Double(rs.count) }
}
let labels = try String(contentsOfFile: dir + "pairs.tsv", encoding: .utf8).split(separator: "\n").map { String($0.split(separator: "\t")[0]) }
var deltas: [[Double]] = []
var used: [String] = []
for label in labels {
    let a = channels("m5128", label), b = channels("m711", label)
    guard !a.isEmpty, !b.isEmpty else { continue }
    var d = zip(mean(a), mean(b)).map(-)
    let band = grid.indices.filter { grid[$0] >= 500 && grid[$0] <= 2_000 }
    let offset = band.map { d[$0] }.reduce(0, +) / Double(band.count)
    d = d.map { $0 - offset }
    deltas.append(d); used.append(label)
}
func percentile(_ values: [Double], _ p: Double) -> Double {
    let s = values.sorted(); let x = p * Double(s.count - 1); let i = Int(x)
    return i + 1 < s.count ? s[i] + (x - Double(i)) * (s[i + 1] - s[i]) : s[i]
}
let median = grid.indices.map { i in percentile(deltas.map { $0[i] }, 0.5) }
let q1 = grid.indices.map { i in percentile(deltas.map { $0[i] }, 0.25) }
let q3 = grid.indices.map { i in percentile(deltas.map { $0[i] }, 0.75) }
// Smooth 1/6 octave in the bass and mids, widening to 1/2 octave above 8 kHz where IEMs disagree most.
let smoothedMedian = smoothed(median, grid: grid, pointsPerOctave: 48) { f in
    let t = min(max(log(f / 4_000) / log(2.0), 0), 1)
    return 1.0 / 6 + t * (0.5 - 1.0 / 6)
}
print("\(used.count) IEMs")
print("  freq  median  smoothed   IQR")
for f in [20.0, 50, 100, 200, 300, 500, 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 10000, 12000, 15000, 18000] {
    let i = grid.indices.min { abs(grid[$0] - f) < abs(grid[$1] - f) }!
    print(String(format: "%6.0f  %+6.1f  %+6.1f    %4.1f", f, median[i], smoothedMedian[i], q3[i] - q1[i]))
}
var csv = "frequency,raw\n"
for (f, v) in zip(grid, smoothedMedian) { csv += String(format: "%.2f,%.3f\n", f, v) }
try csv.write(toFile: dir + "IEC 711 to B&K 5128.csv", atomically: true, encoding: .utf8)
try used.joined(separator: "\n").write(toFile: dir + "used.txt", atomically: true, encoding: .utf8)
