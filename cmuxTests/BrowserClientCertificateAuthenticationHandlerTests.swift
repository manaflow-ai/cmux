import AppKit
import Foundation
import LocalAuthentication
import Security
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite
struct BrowserClientCertificateAuthenticationHandlerTests {
    private final class BrowserAuthChallengeSenderStub: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    private func makeChallenge(
        authenticationMethod: String = NSURLAuthenticationMethodClientCertificate
    ) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: "client.badssl.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: authenticationMethod
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

    private func makeProtectionSpace(
        host: String,
        port: Int = 443,
        protocolName: String = "https"
    ) -> URLProtectionSpace {
        URLProtectionSpace(
            host: host,
            port: port,
            protocol: protocolName,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
    }

    @Test
    func identityLookupQueryRequiresAcceptedCertificateIssuers() {
        let query = BrowserClientCertificateCredentialStore().identityLookupQuery(
            for: makeProtectionSpace(host: "mtls.example")
        )

        #expect(query == nil)
    }

    @Test
    func identityLookupQueryDisallowsKeychainAuthenticationUI() throws {
        let acceptedIssuer = Data([0x30, 0x03, 0x31, 0x01, 0x30])
        let query = try #require(BrowserClientCertificateCredentialStore().identityLookupQuery(
            acceptedIssuers: [acceptedIssuer]
        ))
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        let issuers = try #require(query[kSecMatchIssuers as String] as? [Data])

        #expect(query[kSecClass as String] as? String == kSecClassIdentity as String)
        #expect(query[kSecReturnRef as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(issuers == [acceptedIssuer])
        #expect(context.interactionNotAllowed)
        #expect(query[kSecUseAuthenticationUI as String] == nil)
    }

    @Test
    func usesPickerSelectionWhenOneClientCertificateCandidateExists() throws {
        let expectedCredential = URLCredential(
            user: "client-cert",
            password: "unused",
            persistence: .forSession
        )
        let handler = BrowserClientCertificateAuthenticationHandler { _ in
            [
                BrowserClientCertificateCredentialCandidate(
                    title: "BadSSL Client Certificate",
                    credential: expectedCredential
                ),
            ]
        }
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
        var pickerCandidateCount: Int?

        let handled = handler.handle(
            challenge: makeChallenge(),
            candidatePicker: { _, presentedCandidates, completion, _ in
                pickerCandidateCount = presentedCandidates.count
                completion(presentedCandidates[0])
            }
        ) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(pickerCandidateCount == 1)
        #expect(disposition == .useCredential)
        let returnedCredential = try #require(credential)
        #expect(returnedCredential === expectedCredential)
    }

    @Test
    func performsDefaultHandlingWhenCandidatesExistWithoutPicker() {
        let handler = BrowserClientCertificateAuthenticationHandler { _ in
            [
                BrowserClientCertificateCredentialCandidate(
                    credential: URLCredential(user: "user", password: "password", persistence: .forSession)
                ),
            ]
        }
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        let handled = handler.handle(challenge: makeChallenge()) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test
    func performsDefaultHandlingWhenNoClientCertificateCandidateExists() {
        let handler = BrowserClientCertificateAuthenticationHandler { _ in [] }
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        let handled = handler.handle(challenge: makeChallenge()) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test
    func ignoresNonClientCertificateChallenges() {
        let handler = BrowserClientCertificateAuthenticationHandler { _ in
            [
                BrowserClientCertificateCredentialCandidate(
                    credential: URLCredential(user: "user", password: "password", persistence: .forSession)
                ),
            ]
        }
        var completionCalled = false

        let handled = handler.handle(
            challenge: makeChallenge(authenticationMethod: NSURLAuthenticationMethodServerTrust)
        ) { _, _ in
            completionCalled = true
        }

        #expect(!handled)
        #expect(!completionCalled)
    }

    @Test
    func usesPickerSelectionWhenMultipleClientCertificateCandidatesExist() throws {
        let firstCredential = URLCredential(user: "first", password: "unused", persistence: .forSession)
        let secondCredential = URLCredential(user: "second", password: "unused", persistence: .forSession)
        let candidates = [
            BrowserClientCertificateCredentialCandidate(title: "First", credential: firstCredential),
            BrowserClientCertificateCredentialCandidate(title: "Second", credential: secondCredential),
        ]
        let handler = BrowserClientCertificateAuthenticationHandler { _ in candidates }
        var pickerCandidateCount: Int?
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        let handled = handler.handle(
            challenge: makeChallenge(),
            candidatePicker: { _, presentedCandidates, completion, _ in
                pickerCandidateCount = presentedCandidates.count
                completion(presentedCandidates[1])
            }
        ) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(pickerCandidateCount == 2)
        #expect(disposition == .useCredential)
        let returnedCredential = try #require(credential)
        #expect(returnedCredential === secondCredential)
    }

    @Test
    func pickerSanitizesCredentialReleaseOrigin() {
        let webView = WKWebView(frame: .zero)
        let candidate = BrowserClientCertificateCredentialCandidate(
            title: "Client",
            credential: URLCredential(user: "client-cert", password: "unused", persistence: .forSession)
        )
        let picker = BrowserClientCertificateCredentialPicker(
            webView: webView,
            presentAlert: { alert, presentedWebView, completion, _ in
                #expect(presentedWebView === webView)
                #expect(alert.informativeText.contains("https://mtls.example:8443"))
                #expect(alert.informativeText.contains("\u{202E}") == false)
                #expect(alert.informativeText.contains("\n") == false)
                completion(.alertSecondButtonReturn)
            }
        )
        var selectedCandidate: BrowserClientCertificateCredentialCandidate?

        picker.selectCredential(
            for: makeProtectionSpace(host: "mtls\u{202E}.example\n", port: 8443),
            candidates: [candidate]
        ) { selection in
            selectedCandidate = selection
        }

        #expect(selectedCandidate == nil)
    }

    @Test
    func coordinatorCoalescesDuplicateProtectionSpaceChallenges() throws {
        let expectedCredential = URLCredential(user: "client-cert", password: "unused", persistence: .forSession)
        let coordinator = BrowserClientCertificatePromptCoordinator()
        let challenge = makeChallenge()
        var promptCompletions: [BrowserClientCertificatePromptCoordinator.Completion] = []
        var firstDisposition: URLSession.AuthChallengeDisposition?
        var firstCredential: URLCredential?
        var secondDisposition: URLSession.AuthChallengeDisposition?
        var secondCredential: URLCredential?

        let handledFirstChallenge = coordinator.handle(
            challenge: challenge,
            startPrompt: { finishPrompt, _ in
                promptCompletions.append(finishPrompt)
                return true
            }
        ) { disposition, credential in
            firstDisposition = disposition
            firstCredential = credential
        }
        #expect(handledFirstChallenge)

        let handledSecondChallenge = coordinator.handle(
            challenge: challenge,
            startPrompt: { finishPrompt, _ in
                promptCompletions.append(finishPrompt)
                return true
            }
        ) { disposition, credential in
            secondDisposition = disposition
            secondCredential = credential
        }
        #expect(handledSecondChallenge)
        #expect(promptCompletions.count == 1)

        let promptCompletion = try #require(promptCompletions.first)
        promptCompletion(.useCredential, expectedCredential)

        #expect(firstDisposition == .useCredential)
        #expect(firstCredential === expectedCredential)
        #expect(secondDisposition == .useCredential)
        #expect(secondCredential === expectedCredential)
    }

    @Test
    func coordinatorBoundsQueuedProtectionSpaces() {
        let coordinator = BrowserClientCertificatePromptCoordinator()
        var promptStartCount = 0
        var overflowDisposition: URLSession.AuthChallengeDisposition?

        func startPrompt(
            _ finishPrompt: @escaping BrowserClientCertificatePromptCoordinator.Completion,
            _ registerCancelPrompt: @escaping BrowserClientCertificatePromptCoordinator.PromptCancellationRegistration
        ) -> Bool {
            _ = finishPrompt
            _ = registerCancelPrompt
            promptStartCount += 1
            return true
        }

        for index in 0..<6 {
            let challenge = URLAuthenticationChallenge(
                protectionSpace: makeProtectionSpace(host: "mtls-\(index).example"),
                proposedCredential: nil,
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: BrowserAuthChallengeSenderStub()
            )
            let handled = coordinator.handle(
                challenge: challenge,
                startPrompt: startPrompt
            ) { disposition, _ in
                if index == 5 {
                    overflowDisposition = disposition
                }
            }
            #expect(handled)
        }

        #expect(promptStartCount == 1)
        #expect(overflowDisposition == .cancelAuthenticationChallenge)
    }

    @Test
    func coordinatorCancelAllDismissesActivePromptBeforeCompletingChallenge() {
        let coordinator = BrowserClientCertificatePromptCoordinator()
        var cancelPromptCalled = false
        var completionCount = 0
        var disposition: URLSession.AuthChallengeDisposition?

        let handledChallenge = coordinator.handle(
            challenge: makeChallenge(),
            startPrompt: { finishPrompt, registerCancelPrompt in
                registerCancelPrompt {
                    cancelPromptCalled = true
                    finishPrompt(.cancelAuthenticationChallenge, nil)
                }
                return true
            }
        ) { returnedDisposition, _ in
            completionCount += 1
            disposition = returnedDisposition
        }
        #expect(handledChallenge)

        coordinator.cancelAll()

        #expect(cancelPromptCalled)
        #expect(completionCount == 1)
        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test
    func extendedKeyUsageAllowsOnlyTLSClientAuthentication() {
        let clientAuthenticationOID = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02])
        let serverAuthenticationOID = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
        let anyExtendedKeyUsageOID = Data([0x55, 0x1D, 0x25, 0x00])

        #expect(browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication(nil))
        #expect(browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication([clientAuthenticationOID]))
        #expect(browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication([anyExtendedKeyUsageOID]))
        #expect(!browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication([serverAuthenticationOID]))
        #expect(!browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication([]))
    }
}
