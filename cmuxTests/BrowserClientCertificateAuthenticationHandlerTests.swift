import Foundation
import Testing

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
            candidatePicker: { _, presentedCandidates, completion in
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
            candidatePicker: { _, presentedCandidates, completion in
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
}
