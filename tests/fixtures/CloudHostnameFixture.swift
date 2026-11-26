import Foundation

/// Runs the app's production label path in a fresh, isolated process.
@main
struct CloudHostnameFixture {
    static func main() throws {
        var samples: [[String: Any]] = []
        for phase in ["cold", "warm"] {
            let start = ContinuousClock.now
            let name = CloudTuiClientPaths.deviceName()
            let elapsed = start.duration(to: .now).components
            samples.append([
                "phase": phase,
                "name": name,
                "duration_ms": Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            ])
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: samples))
    }
}
