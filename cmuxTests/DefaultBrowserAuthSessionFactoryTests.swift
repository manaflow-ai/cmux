import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct DefaultBrowserAuthSessionFactoryTests {
    @Test func startOpensSignInURLAndWaitsForExternalCallback() {
        let signInURL = URL(string: "https://cmux.test/handler/native-sign-in")!
        var openedURLs: [URL] = []
        var completions = 0
        let factory = DefaultBrowserAuthSessionFactory { url in
            openedURLs.append(url)
            return true
        }

        let session = factory.makeSession(
            signInURL: signInURL,
            callbackScheme: "cmux"
        ) { _ in
            completions += 1
        }

        #expect(session.start())
        #expect(openedURLs == [signInURL])
        #expect(completions == 0)

        session.cancel()
        #expect(completions == 0)
    }

    @Test func startReportsFailureWhenDefaultBrowserOpenFails() {
        let factory = DefaultBrowserAuthSessionFactory { _ in false }
        let session = factory.makeSession(
            signInURL: URL(string: "https://cmux.test/handler/native-sign-in")!,
            callbackScheme: "cmux",
            completion: { _ in }
        )

        #expect(session.start() == false)
    }
}
