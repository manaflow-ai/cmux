import CmuxCLISocketAuth
import os
import Testing

private final class CLITestCounter: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<Int>(initialState: 0)

    var value: Int {
        storage.withLock { $0 }
    }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

/// App-host smoke coverage for the package credential boundary.
@Suite(.serialized)
struct CLISocketCredentialResolverTests {
    @Test
    func initialConnectionDemandDoesNotReadDeferredSources() {
        let fileReads = CLITestCounter()
        let keychainReads = CLITestCounter()
        let resolver = SocketCredentialResolver(
            explicitPassword: nil,
            socketPath: "/tmp/cmux-debug-allow-all.sock",
            environment: [:],
            filePasswordProvider: {
                fileReads.increment()
                return "file-password"
            },
            keychainPasswordProvider: { _ in
                keychainReads.increment()
                return "keychain-password"
            }
        )

        #expect(!SocketAuthenticationChallenge.isRequired("PONG"))
        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(fileReads.value == 0)
        #expect(keychainReads.value == 0)
    }
}
