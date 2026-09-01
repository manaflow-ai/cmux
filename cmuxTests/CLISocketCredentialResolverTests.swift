import CmuxCLISocketAuth
import Testing

/// App-host smoke coverage for the package credential boundary.
@Suite(.serialized)
struct CLISocketCredentialResolverTests {
    @Test
    func allowAllInitialConnectionDoesNotReadDeferredSources() {
        var fileReads = 0
        var keychainReads = 0
        let resolver = SocketCredentialResolver(
            explicitPassword: nil,
            socketPath: "/tmp/cmux-debug-allow-all.sock",
            environment: [:],
            filePasswordProvider: {
                fileReads += 1
                return "file-password"
            },
            keychainPasswordProvider: { _ in
                keychainReads += 1
                return "keychain-password"
            }
        )

        #expect(!SocketAuthenticationChallenge.isRequired("PONG"))
        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(fileReads == 0)
        #expect(keychainReads == 0)
    }
}
