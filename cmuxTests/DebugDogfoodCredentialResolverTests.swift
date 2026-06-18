import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

// The resolver only exists in DEBUG (it is the macOS dogfood auto-sign-in seam,
// compiled out of release builds), so the whole suite is DEBUG-gated. In a
// release test build there is nothing to test: the auto-sign-in path does not
// exist, which is the production guarantee.
#if DEBUG
@Suite struct DebugDogfoodCredentialResolverTests {
    /// Build a resolver over an ordered list of `(path, contents)` secret-file
    /// fakes, so a test never reads the real `~/.secrets` files and the file
    /// precedence order is deterministic (a plain `[String: String]` would
    /// iterate in undefined key order).
    private func makeResolver(
        environment: [String: String],
        files: [(path: String, contents: String)] = []
    ) -> DebugDogfoodCredentialResolver {
        let table = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        return DebugDogfoodCredentialResolver(
            environment: environment,
            secretFilePaths: files.map(\.path),
            readFile: { table[$0] }
        )
    }

    @Test func noCredentialsAnywhereResolvesNil() {
        let resolver = makeResolver(environment: ["HOME": "/Users/test"])
        #expect(resolver.resolve() == nil)
    }

    @Test func dogfoodEnvCredentialsResolve() {
        let resolver = makeResolver(environment: [
            "CMUX_DOGFOOD_STACK_EMAIL": "lawrence@manaflow.ai",
            "CMUX_DOGFOOD_STACK_PASSWORD": "dog-pw",
        ])
        #expect(
            resolver.resolve()
                == .init(email: "lawrence@manaflow.ai", password: "dog-pw")
        )
    }

    @Test func uitestEnvCredentialsResolveWhenNoDogfood() {
        let resolver = makeResolver(environment: [
            "CMUX_UITEST_STACK_EMAIL": "agent-dev@manaflow.ai",
            "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
        ])
        #expect(
            resolver.resolve()
                == .init(email: "agent-dev@manaflow.ai", password: "agent-pw")
        )
    }

    @Test func dogfoodAccountWinsOverUitestAccountAcrossSources() {
        // The dog Mac case: the agent (uitest) creds are in the environment, but
        // the human dogfood creds are only in a secret file. Dogfood must win so
        // the dog Mac comes up as lawrence, not the agent account.
        let resolver = makeResolver(
            environment: [
                "CMUX_UITEST_STACK_EMAIL": "agent-dev@manaflow.ai",
                "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
            ],
            files: [
                (
                    "/secrets/cmuxterm-dev.env",
                    """
                    CMUX_DOGFOOD_STACK_EMAIL=lawrence@manaflow.ai
                    CMUX_DOGFOOD_STACK_PASSWORD=dog-pw
                    """
                ),
            ]
        )
        #expect(
            resolver.resolve()
                == .init(email: "lawrence@manaflow.ai", password: "dog-pw")
        )
    }

    @Test func envWinsOverFileWithinSameAccount() {
        let resolver = makeResolver(
            environment: [
                "CMUX_DOGFOOD_STACK_EMAIL": "env@manaflow.ai",
                "CMUX_DOGFOOD_STACK_PASSWORD": "env-pw",
            ],
            files: [
                (
                    "/secrets/cmuxterm-dev.env",
                    """
                    CMUX_DOGFOOD_STACK_EMAIL=file@manaflow.ai
                    CMUX_DOGFOOD_STACK_PASSWORD=file-pw
                    """
                ),
            ]
        )
        #expect(
            resolver.resolve()
                == .init(email: "env@manaflow.ai", password: "env-pw")
        )
    }

    @Test func earlierFileWinsOverLaterFile() {
        // cmuxterm-dev.env is listed before cmux.env, so it takes precedence.
        let resolver = DebugDogfoodCredentialResolver(
            environment: [:],
            secretFilePaths: ["/secrets/cmuxterm-dev.env", "/secrets/cmux.env"],
            readFile: { path in
                switch path {
                case "/secrets/cmuxterm-dev.env":
                    return """
                    CMUX_DOGFOOD_STACK_EMAIL=devfile@manaflow.ai
                    CMUX_DOGFOOD_STACK_PASSWORD=dev-pw
                    """
                case "/secrets/cmux.env":
                    return """
                    CMUX_DOGFOOD_STACK_EMAIL=cmuxfile@manaflow.ai
                    CMUX_DOGFOOD_STACK_PASSWORD=cmux-pw
                    """
                default:
                    return nil
                }
            }
        )
        #expect(
            resolver.resolve()
                == .init(email: "devfile@manaflow.ai", password: "dev-pw")
        )
    }

    @Test func fallsThroughToCmuxEnvFileWhenDevFileLacksCreds() {
        let resolver = DebugDogfoodCredentialResolver(
            environment: [:],
            secretFilePaths: ["/secrets/cmuxterm-dev.env", "/secrets/cmux.env"],
            readFile: { path in
                switch path {
                case "/secrets/cmuxterm-dev.env":
                    return "# no stack creds here\nE2B_API_KEY=abc\n"
                case "/secrets/cmux.env":
                    return """
                    CMUX_UITEST_STACK_EMAIL=agent@manaflow.ai
                    CMUX_UITEST_STACK_PASSWORD=agent-pw
                    """
                default:
                    return nil
                }
            }
        )
        #expect(
            resolver.resolve()
                == .init(email: "agent@manaflow.ai", password: "agent-pw")
        )
    }

    @Test func partialCredentialPairIsIgnored() {
        // Email without password must not yield a half-resolved credential.
        let resolver = makeResolver(environment: [
            "CMUX_DOGFOOD_STACK_EMAIL": "lawrence@manaflow.ai",
        ])
        #expect(resolver.resolve() == nil)
    }

    @Test func emptyCredentialValuesAreIgnored() {
        let resolver = makeResolver(environment: [
            "CMUX_DOGFOOD_STACK_EMAIL": "",
            "CMUX_DOGFOOD_STACK_PASSWORD": "",
        ])
        #expect(resolver.resolve() == nil)
    }

    @Test func parsesQuotedAndCommentedEnvFile() {
        let parsed = DebugDogfoodCredentialResolver.parseEnvFile(
            """
            # comment line
            CMUX_DOGFOOD_STACK_EMAIL="lawrence@manaflow.ai"
            CMUX_DOGFOOD_STACK_PASSWORD='secret value'

            BLANK_AFTER=1
            """
        )
        #expect(parsed["CMUX_DOGFOOD_STACK_EMAIL"] == "lawrence@manaflow.ai")
        #expect(parsed["CMUX_DOGFOOD_STACK_PASSWORD"] == "secret value")
        #expect(parsed["BLANK_AFTER"] == "1")
    }
}

/// Integration coverage for the `MacAuthComposition` wrapper that feeds resolved
/// creds into `AuthLaunchOptions`. The wrapper, not the resolver, is where a
/// regression would re-introduce the "agent creds in env shadow the dogfood
/// file" bug, so these tests drive the wrapper directly with injected file
/// fakes.
@Suite struct MacAuthCompositionDogfoodAutoSignInTests {
    @Test func dogfoodFileWinsOverAgentEnvCredsOnDogMac() {
        // Dog-Mac scenario: agent (uitest) creds in the environment, human
        // dogfood creds only in the secret file. The build must come up as the
        // human dogfood account, so the file creds win and overwrite the env
        // uitest keys that AuthLaunchOptions reads.
        let merged = MacAuthComposition.environmentWithDogfoodAutoSignIn(
            [
                "CMUX_UITEST_STACK_EMAIL": "agent-dev@manaflow.ai",
                "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
            ],
            secretFilePaths: ["/secrets/cmuxterm-dev.env"],
            readFile: { _ in
                """
                CMUX_DOGFOOD_STACK_EMAIL=lawrence@manaflow.ai
                CMUX_DOGFOOD_STACK_PASSWORD=dog-pw
                """
            }
        )
        #expect(merged["CMUX_UITEST_STACK_EMAIL"] == "lawrence@manaflow.ai")
        #expect(merged["CMUX_UITEST_STACK_PASSWORD"] == "dog-pw")
    }

    @Test func leavesAgentEnvCredsWhenNoDogfoodFile() {
        // CI UI-test scenario: only uitest env creds, no secret file. The
        // resolver returns that same pair, so the merge is a no-op.
        let merged = MacAuthComposition.environmentWithDogfoodAutoSignIn(
            [
                "CMUX_UITEST_STACK_EMAIL": "agent-dev@manaflow.ai",
                "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
            ],
            secretFilePaths: ["/secrets/cmuxterm-dev.env"],
            readFile: { _ in nil }
        )
        #expect(merged["CMUX_UITEST_STACK_EMAIL"] == "agent-dev@manaflow.ai")
        #expect(merged["CMUX_UITEST_STACK_PASSWORD"] == "agent-pw")
    }

    @Test func injectsNothingWhenNoCredentialsAvailable() {
        let merged = MacAuthComposition.environmentWithDogfoodAutoSignIn(
            ["HOME": "/Users/test"],
            secretFilePaths: ["/secrets/cmuxterm-dev.env"],
            readFile: { _ in nil }
        )
        #expect(merged["CMUX_UITEST_STACK_EMAIL"] == nil)
        #expect(merged["CMUX_UITEST_STACK_PASSWORD"] == nil)
    }
}
#endif
