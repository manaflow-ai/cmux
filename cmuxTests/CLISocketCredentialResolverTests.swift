import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the CLI socket credential boundary.
///
/// A connection has two distinct credential demands: an initial request, which
/// must remain credential-free until the server challenges it, and an explicit
/// authentication challenge. Keeping those demands separate prevents a
/// successful allow-all request from touching LocalAuthentication.
@Suite(.serialized)
struct CLISocketCredentialResolverTests {
    private final class CallCounter {
        var value = 0
    }

    private func resolver(
        explicit: String? = nil,
        environmentPassword: String? = nil,
        filePassword: String? = nil,
        keychainPassword: String? = nil,
        fileCounter: CallCounter = CallCounter(),
        keychainCounter: CallCounter = CallCounter()
    ) -> SocketCredentialResolver {
        var environment: [String: String] = [:]
        if let environmentPassword {
            environment["CMUX_SOCKET_PASSWORD"] = environmentPassword
        }
        return SocketCredentialResolver(
            explicitPassword: explicit,
            socketPath: "/tmp/cmux-debug-credential-test.sock",
            environment: environment,
            filePasswordProvider: {
                fileCounter.value += 1
                return filePassword
            },
            keychainPasswordProvider: { _ in
                keychainCounter.value += 1
                return keychainPassword
            }
        )
    }

    @Test
    func explicitPasswordWinsWithoutReadingDeferredSources() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            explicit: "flag-password",
            environmentPassword: "environment-password",
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == "flag-password")
        #expect(resolver.password(for: .authenticationRequired) == "flag-password")
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)
        #expect(resolver.source == .explicit)
    }

    @Test
    func environmentPasswordWinsWithoutReadingDeferredSources() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            environmentPassword: "environment-password",
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == "environment-password")
        #expect(resolver.password(for: .authenticationRequired) == "environment-password")
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)
        #expect(resolver.source == .environment)
    }

    @Test
    func filePasswordIsReadOnlyAfterAuthenticationChallengeAndCached() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)

        #expect(resolver.password(for: .authenticationRequired) == "file-password")
        #expect(resolver.password(for: .authenticationRequired) == "file-password")
        #expect(fileCounter.value == 1)
        #expect(keychainCounter.value == 0)
        #expect(resolver.source == .file)
    }

    @Test
    func keychainProviderIsDemandDrivenAndInvokedAtMostOnce() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            filePassword: nil,
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(keychainCounter.value == 0)

        #expect(resolver.password(for: .authenticationRequired) == "keychain-password")
        #expect(resolver.password(for: .authenticationRequired) == "keychain-password")
        #expect(fileCounter.value == 1)
        #expect(keychainCounter.value == 1)
        #expect(resolver.source == .keychain)
    }

    @Test
    func allowAllResponsesNeverDemandCredentials() {
        #expect(!SocketAuthenticationChallenge.isRequired("PONG"))
        #expect(!SocketAuthenticationChallenge.isRequired(#"{"id":"1","ok":true,"result":{}}"#))
        #expect(SocketAuthenticationChallenge.isRequired("ERROR: Authentication required — send auth <password> first"))
        #expect(
            SocketAuthenticationChallenge.isRequired(
                #"{"id":"1","ok":false,"error":{"code":"auth_required","message":"Authentication required"}}"#
            )
        )
    }
}
