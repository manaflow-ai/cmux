@testable import CmuxiOSSSHCore
import CmuxMobileWire
import Foundation
import Testing

@Suite struct SSHTmuxLifecycleMutationTests {
    private let epoch = SSHTmuxServerEpoch(serverPID: 42, serverStart: 1_793_331_200)!

    @Test func wireOperationsRoundTripWithStableHostIDs() throws {
        let createParams: JSONValue = .object([
            "server_pid": .int(42), "server_start": .int(1_793_331_200),
            "session_id": .string("$7"), "name": .string("editor")
        ])
        let create = try #require(SSHTmuxLifecycleMutation(op: "ssh.tmux.window.create", params: createParams))
        #expect(create.isValid)
        #expect(create.op == "ssh.tmux.window.create")
        #expect(create.params == createParams)
        #expect(SSHTmuxLifecycleMutation(op: create.op, params: create.params) == create)

        let renameParams: JSONValue = .object([
            "server_pid": .int(42), "server_start": .int(1_793_331_200),
            "window_id": .string("@12"), "name": .string("renamed")
        ])
        let rename = try #require(SSHTmuxLifecycleMutation(op: "ssh.tmux.window.rename", params: renameParams))
        #expect(rename.params == renameParams)

        let killParams: JSONValue = .object([
            "server_pid": .int(42), "server_start": .int(1_793_331_200),
            "window_id": .string("@12")
        ])
        let kill = try #require(SSHTmuxLifecycleMutation(op: "ssh.tmux.window.kill", params: killParams))
        #expect(kill.params == killParams)
    }

    @Test func malformedTargetsAndNamesFailClosed() {
        let base: [String: JSONValue] = [
            "server_pid": .int(42), "server_start": .int(1_793_331_200),
            "window_id": .string("@12"), "name": .string("ok")
        ]
        for (key, value) in [
            ("server_pid", JSONValue.int(0)),
            ("server_start", JSONValue.int(-1)),
            ("window_id", JSONValue.string("@bad")),
            ("name", JSONValue.string("line\nfeed")),
            ("extra", JSONValue.string("refuse")),
        ] {
            var object = base
            object[key] = value
            #expect(SSHTmuxLifecycleMutation(op: "ssh.tmux.window.rename", params: .object(object)) == nil)
        }
        let tooLong = String(repeating: "x", count: SSHTmuxLifecycleMutation.maximumNameBytes + 1)
        var create = base
        create.removeValue(forKey: "window_id")
        create.removeValue(forKey: "name")
        create["session_id"] = .string("$7")
        create["name"] = .string(tooLong)
        #expect(SSHTmuxLifecycleMutation(op: "ssh.tmux.window.create", params: .object(create)) == nil)
    }

    @Test func ownerKeysArePrintableAndBounded() {
        #expect(SSHTmuxLifecycleMutation.validIdempotencyKey("ssh-create-1"))
        #expect(!SSHTmuxLifecycleMutation.validIdempotencyKey(""))
        #expect(!SSHTmuxLifecycleMutation.validIdempotencyKey("has space"))
        #expect(!SSHTmuxLifecycleMutation.validIdempotencyKey(String(repeating: "k", count: 257)))
        #expect(SSHTmuxLifecycleMutation.createWindow(server: epoch, sessionID: "$7", name: nil).isValid)
        #expect(!SSHTmuxLifecycleMutation.renameWindow(server: epoch, windowID: "@12", name: "\u{2028}").isValid)
    }
}
