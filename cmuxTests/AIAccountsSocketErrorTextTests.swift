import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux ai-accounts list` failed with "The Cloud VM request failed." whatever went wrong (#21754).
/// AI account requests share the Cloud VM socket wrapper, which replaced every error it did not
/// know with that line, including the accounts client's own text naming the real cause.
@Suite @MainActor struct AIAccountsSocketErrorTextTests {
    private static let cloudVMFallback = String(
        localized: "socket.cloudVM.requestFailed",
        defaultValue: "The Cloud VM request failed. Retry, or check the machine's status with `cmux vm ls`."
    )

    /// `v2VmCall` blocks its caller on a semaphore while `work` runs in a Task. A closure
    /// written in this `@MainActor` suite would run on the main actor the caller is blocking,
    /// so the call runs off the main actor (as `SurfaceSocketCommandTests` does).
    private func errorMessage(for failure: AIAccountsClientError) async throws -> String {
        let reply = await Task.detached {
            TerminalController.shared.v2VmCall(id: 9, timeoutSeconds: 10) {
                throw failure
            }
        }.value
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any], "\(reply)")
        return try #require(error["message"] as? String)
    }

    @Test(arguments: [
        AIAccountsClientError.httpStatus(503, ""),
        AIAccountsClientError.httpStatus(500, #"{"error":"subrouter accounts unavailable"}"#),
        AIAccountsClientError.notSignedIn,
        AIAccountsClientError.malformedResponse("missing `accounts` array"),
    ])
    func accountsFailureKeepsItsOwnMessage(_ failure: AIAccountsClientError) async throws {
        let message = try await errorMessage(for: failure)

        #expect(message == failure.description)
        #expect(!message.localizedCaseInsensitiveContains("Cloud VM"))
    }

    /// The pass-through keeps the Cloud VM wrapper's safety filter: text that names an
    /// origin or credentials still reads as the generic line.
    @Test func accountsFailureNamingAnOriginStaysHidden() async throws {
        let failure = AIAccountsClientError.backendUnreachable(
            url: "https://cmux.com",
            detail: "The request timed out."
        )

        let message = try await errorMessage(for: failure)
        #expect(message == Self.cloudVMFallback)
    }
}
