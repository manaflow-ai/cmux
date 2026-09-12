import CmuxCLISocketAuth
import Foundation
import os
import Testing

// All mutable storage is confined to the lock; callbacks access it synchronously.
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
    @Test(arguments: [true, false])
    func nextOperationCanResolveAfterPriorProviderDeadline(returnsPassword: Bool) throws {
        let instant = Date(timeIntervalSince1970: 1_000)
        // This per-test clock bridges synchronous Sendable callbacks without sleeping.
        let clock = OSAllocatedUnfairLock(initialState: instant)
        var attempt = SocketCredentialResolutionAttempt(now: { clock.withLock { $0 } })
        var providerCalls = 0
        #expect(throws: SocketCredentialResolutionAttempt.Failure.self) {
            try attempt.resolve(
                provider: { _ in
                    providerCalls += 1
                    clock.withLock { $0.addTimeInterval(2) }
                    return returnsPassword ? "cached-password" : nil
                },
                deadline: instant.addingTimeInterval(1)
            )
        }
        #expect(!attempt.isCompleted)
        let nextResult = try attempt.resolve(
            provider: { _ in
                providerCalls += 1
                return "cached-password"
            },
            deadline: instant.addingTimeInterval(3)
        )
        #expect(nextResult == "cached-password")
        #expect(attempt.isCompleted)
        #expect(providerCalls == 2)
    }

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
