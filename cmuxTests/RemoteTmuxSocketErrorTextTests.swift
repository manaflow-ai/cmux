import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A remote tmux request that fails has to say why. Its errors carry their own wording, already
/// flattened and capped by `RemoteTmuxError`, and the socket wrapper they share with Cloud VM
/// requests replaced every one of them with the Cloud VM line, which sends the reader to
/// `cmux vm ls` for a problem with their ssh host.
@Suite struct RemoteTmuxSocketErrorTextTests {
    @Test(arguments: [
        RemoteTmuxError.unreachable("already attaching build-box"),
        RemoteTmuxError.launchFailed("ssh is not executable at /opt/missing/ssh"),
        RemoteTmuxError.windowCreationFailed,
    ])
    func remoteTmuxFailureKeepsItsOwnMessage(_ failure: RemoteTmuxError) throws {
        let reply = TerminalController.shared.v2VmCall(id: 7, timeoutSeconds: 10) {
            throw failure
        }
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any], "\(reply)")
        let message = try #require(error["message"] as? String)

        #expect(message == failure.message)
        #expect(!message.localizedCaseInsensitiveContains("Cloud VM"))
    }
}
