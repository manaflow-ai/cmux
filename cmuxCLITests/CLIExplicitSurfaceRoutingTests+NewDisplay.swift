import Darwin
import Foundation
import Testing

extension CLIExplicitSurfaceRoutingTests {
    @Test(arguments: [
        ["--workspace"], ["--workspace", ""], ["--workspace", "   "], ["--workspace="],
        ["--workspace", "--no-open"],
        ["--workspace", "--token=synthetic-secret"],
        ["--workspace=--token=synthetic-secret"],
        ["--workspace", "  --token=synthetic-secret"],
    ])
    func surfaceNewDisplayRejectsMissingWorkspaceValues(arguments: [String]) throws {
        let execution = try runMockCommand(
            arguments: ["surface", "new-display", "--machine", "vivid-newt"] + arguments,
            socketName: "display-invalid-workspace"
        ) { line in
            let id = Self.jsonObject(line)?["id"] as? String ?? "unknown"
            return Self.v2Response(id: id, ok: true, result: ["resource": "vivid-newt/display/display:2"])
        }
        let output = execution.result.stderr + execution.result.stdout
        #expect(!execution.result.timedOut, Comment(rawValue: output))
        #expect(execution.result.status != 0, Comment(rawValue: output))
        #expect(!output.contains("synthetic-secret"), Comment(rawValue: output))
        #expect(try execution.state.requestObjects().isEmpty)
    }

    /// Omitting `--no-open` must send the API's default `open: true` request.
    @Test func surfaceNewDisplayDefaultsToOpen() throws {
        let execution = try runMockCommand(
            arguments: [
                "surface", "new-display",
                "--machine", "vivid-newt",
                "--workspace", "2",
            ],
            socketName: "surface-new-display-default-open"
        ) { line in
            guard let request = Self.jsonObject(line), let id = request["id"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            if request["method"] as? String == "workspace.list" {
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspaces": [["id": "workspace-id-2", "index": 2]]]
                )
            }
            guard request["method"] as? String == "surface.new_display" else {
                return Self.malformedRequestResponse(raw: line)
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: [
                    "resource": "vivid-newt/display/display:3",
                    "machine": "vivid-newt",
                    "open": true,
                ]
            )
        }

        #expect(!execution.result.timedOut, Comment(rawValue: execution.result.stderr))
        #expect(execution.result.status == 0, Comment(rawValue: execution.result.stderr + execution.result.stdout))
        let requests = try execution.state.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == ["workspace.list", "surface.new_display"])
        let request = try #require(requests.last)
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["machine"] as? String == "vivid-newt")
        #expect(params["workspace_id"] as? String == "workspace-id-2")
        #expect(params["open"] as? Bool == true)
        #expect(params["focus"] is Bool)
    }

    /// Explicit display flags still reach the socket unchanged when opening is disabled.
    @Test func surfaceNewDisplaySendsCloudMachineAndProjectionOptions() throws {
        let execution = try runMockCommand(
            arguments: [
                "surface", "new-display",
                "--machine", "vivid-newt",
                "--workspace", "00000000-0000-0000-0000-000000000002",
                "--no-open",
                "--focus",
            ],
            socketName: "surface-new-display"
        ) { line in
            guard let request = Self.jsonObject(line),
                  let id = request["id"] as? String,
                  request["method"] as? String == "surface.new_display" else {
                return Self.malformedRequestResponse(raw: line)
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: [
                    "resource": "vivid-newt/display/display:2",
                    "machine": "vivid-newt",
                    "open": false,
                ]
            )
        }

        #expect(!execution.result.timedOut, Comment(rawValue: execution.result.stderr))
        #expect(execution.result.status == 0, Comment(rawValue: execution.result.stderr + execution.result.stdout))
        let requests = try execution.state.requestObjects()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request["method"] as? String == "surface.new_display")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["machine"] as? String == "vivid-newt")
        #expect(params["workspace_id"] as? String == "00000000-0000-0000-0000-000000000002")
        #expect(params["open"] as? Bool == false)
        #expect(params["focus"] as? Bool == true)
        #expect(execution.result.stdout.contains("OK resource=vivid-newt/display/display:2"))
    }
}
