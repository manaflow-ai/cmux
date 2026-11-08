import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Polls a terminal runtime for its controlling TTY with one shared timeout policy.
struct TerminalControllingTTYWaiter {
    private let clock: ContinuousClock
    private let pollInterval: Duration

    init(
        clock: ContinuousClock = ContinuousClock(),
        pollInterval: Duration = .milliseconds(10)
    ) {
        self.clock = clock
        self.pollInterval = pollInterval
    }

    func wait(
        for terminal: TerminalPanel,
        timeout: Duration = .seconds(5)
    ) async throws -> String {
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let ttyName = await terminal.surface.controllingTTYName() {
                return ttyName
            }
            try await clock.sleep(for: pollInterval)
        }
        if let ttyName = await terminal.surface.controllingTTYName() {
            return ttyName
        }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENODEV),
            userInfo: [NSLocalizedDescriptionKey: "Terminal surface did not expose a controlling TTY"]
        )
    }
}
