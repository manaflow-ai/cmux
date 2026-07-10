import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserProxyConfigurationNetworkProcessMonitorTests {
    @Test("The proxy route monitor reports its NetworkProcess exit")
    @MainActor
    func reportsObservedProcessExit() async throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let monitor = BrowserProxyConfigurationNetworkProcessMonitor()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            monitor.observe(processIdentifier: Int(process.processIdentifier)) {
                continuation.resume()
            }
            process.terminate()
        }
    }
}
