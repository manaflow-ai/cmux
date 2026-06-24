import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite
struct BrowserHTTPBasicAuthPromptCoordinatorTests {
    private final class BrowserAuthChallengeSenderStub: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    private func makeAuthChallenge(
        host: String = "basic-auth.test",
        protocolName: String = "https",
        port: Int = 443
    ) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: host,
            port: port,
            protocol: protocolName,
            realm: "EnableIT",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: BrowserAuthChallengeSenderStub()
        )
    }

    @Test
    func separatesProtocolProtectionSpaces() throws {
        let coordinator = BrowserHTTPBasicAuthPromptCoordinator()
        let httpChallenge = makeAuthChallenge(
            host: "same-origin.test",
            protocolName: "http",
            port: 8080
        )
        let httpsChallenge = makeAuthChallenge(
            host: "same-origin.test",
            protocolName: "https",
            port: 8080
        )
        var promptCompletions: [BrowserHTTPBasicAuthPromptCoordinator.Completion] = []
        var firstDisposition: URLSession.AuthChallengeDisposition?
        var secondDisposition: URLSession.AuthChallengeDisposition?

        #expect(coordinator.handle(
            challenge: httpChallenge,
            startPrompt: { finishPrompt, _ in
                promptCompletions.append(finishPrompt)
                return true
            }
        ) { disposition, _ in
            firstDisposition = disposition
        })

        #expect(coordinator.handle(
            challenge: httpsChallenge,
            startPrompt: { finishPrompt, _ in
                promptCompletions.append(finishPrompt)
                return true
            }
        ) { disposition, _ in
            secondDisposition = disposition
        })

        #expect(promptCompletions.count == 1)
        #expect(secondDisposition == nil)

        let firstPromptCompletion = try #require(promptCompletions.first)
        firstPromptCompletion(
            .useCredential,
            URLCredential(user: "alice", password: "secret", persistence: .forSession)
        )

        #expect(firstDisposition == .useCredential)
        #expect(secondDisposition == nil)
        #expect(promptCompletions.count == 2)

        let secondPromptCompletion = try #require(promptCompletions.dropFirst().first)
        secondPromptCompletion(.cancelAuthenticationChallenge, nil)

        #expect(secondDisposition == .cancelAuthenticationChallenge)
    }

    @Test
    func reusableCancellationCancelsQueuedWork() {
        let coordinator = BrowserHTTPBasicAuthPromptCoordinator()
        let firstChallenge = makeAuthChallenge(host: "first.test")
        let secondChallenge = makeAuthChallenge(host: "second.test")
        let thirdChallenge = makeAuthChallenge(host: "third.test")
        var promptStartCount = 0
        var firstDisposition: URLSession.AuthChallengeDisposition?
        var secondDisposition: URLSession.AuthChallengeDisposition?
        var thirdDisposition: URLSession.AuthChallengeDisposition?

        func startPrompt(
            _ finishPrompt: @escaping BrowserHTTPBasicAuthPromptCoordinator.Completion,
            _ registerCancelPrompt: @escaping BrowserHTTPBasicAuthPromptCoordinator.PromptCancellationRegistration
        ) -> Bool {
            _ = finishPrompt
            _ = registerCancelPrompt
            promptStartCount += 1
            return true
        }

        #expect(coordinator.handle(
            challenge: firstChallenge,
            startPrompt: startPrompt
        ) { disposition, _ in
            firstDisposition = disposition
        })

        #expect(coordinator.handle(
            challenge: secondChallenge,
            startPrompt: startPrompt
        ) { disposition, _ in
            secondDisposition = disposition
        })

        #expect(promptStartCount == 1)

        coordinator.cancelAll(allowFuturePrompts: true)

        #expect(firstDisposition == .cancelAuthenticationChallenge)
        #expect(secondDisposition == .cancelAuthenticationChallenge)

        #expect(coordinator.handle(
            challenge: thirdChallenge,
            startPrompt: startPrompt
        ) { disposition, _ in
            thirdDisposition = disposition
        })

        #expect(promptStartCount == 2)
        #expect(thirdDisposition == nil)
    }

    @Test
    func handlesReentrantSameSpaceRetry() throws {
        let coordinator = BrowserHTTPBasicAuthPromptCoordinator()
        let challenge = makeAuthChallenge()
        var promptCompletions: [BrowserHTTPBasicAuthPromptCoordinator.Completion] = []
        var firstDisposition: URLSession.AuthChallengeDisposition?
        var retryDisposition: URLSession.AuthChallengeDisposition?

        func startPrompt(
            _ finishPrompt: @escaping BrowserHTTPBasicAuthPromptCoordinator.Completion,
            _ registerCancelPrompt: @escaping BrowserHTTPBasicAuthPromptCoordinator.PromptCancellationRegistration
        ) -> Bool {
            _ = registerCancelPrompt
            promptCompletions.append(finishPrompt)
            return true
        }

        #expect(coordinator.handle(
            challenge: challenge,
            startPrompt: startPrompt
        ) { disposition, _ in
            firstDisposition = disposition
            #expect(coordinator.handle(
                challenge: challenge,
                startPrompt: startPrompt
            ) { retryReturnedDisposition, _ in
                retryDisposition = retryReturnedDisposition
            })
        })

        #expect(promptCompletions.count == 1)

        let firstPromptCompletion = try #require(promptCompletions.first)
        firstPromptCompletion(
            .useCredential,
            URLCredential(user: "alice", password: "bad", persistence: .forSession)
        )

        #expect(firstDisposition == .useCredential)
        #expect(retryDisposition == nil)
        #expect(promptCompletions.count == 2)

        let retryPromptCompletion = try #require(promptCompletions.dropFirst().first)
        retryPromptCompletion(.cancelAuthenticationChallenge, nil)

        #expect(retryDisposition == .cancelAuthenticationChallenge)
    }

    @Test
    func cancelAllDismissesActivePromptBeforeCompletingChallenge() {
        let coordinator = BrowserHTTPBasicAuthPromptCoordinator()
        let challenge = makeAuthChallenge()
        var cancelPromptCalled = false
        var completionCount = 0
        var disposition: URLSession.AuthChallengeDisposition?

        #expect(coordinator.handle(
            challenge: challenge,
            startPrompt: { finishPrompt, registerCancelPrompt in
                registerCancelPrompt {
                    cancelPromptCalled = true
                    finishPrompt(.cancelAuthenticationChallenge, nil)
                }
                return true
            }
        ) { challengeDisposition, _ in
            completionCount += 1
            disposition = challengeDisposition
        })

        coordinator.cancelAll()

        #expect(cancelPromptCalled)
        #expect(completionCount == 1)
        #expect(disposition == .cancelAuthenticationChallenge)
    }
}
