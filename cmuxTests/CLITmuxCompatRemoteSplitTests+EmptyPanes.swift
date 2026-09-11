import Darwin
import Foundation
import Testing

extension CLITmuxCompatRemoteSplitTests {
    private enum PaneSurfacesResponse {
        case valid
        case missing
        case nonArray
        case invalidIDs
    }

    /// Regression for #9917: an intentionally empty global Dock pane is a valid
    /// persisted cmux pane, but it has no surface that the tmux shim can target.
    /// `list-panes` must omit that pane instead of asking `tmuxFormatContext` to
    /// select a surface and aborting the whole listing.
    @Test func listPanesSkipsEmptyDockPane() throws {
        let result = try runListPanesWithEmptyDock()

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "33333333-3333-3333-3333-333333333333\n", Comment(rawValue: result.stdout))
        #expect(!result.stderr.contains("Pane has no surface"), Comment(rawValue: result.stderr))
    }

    /// A successful surface lookup may report no surface, but control-socket
    /// failures must abort instead of producing incomplete tmux format output.
    @Test func listPanesPropagatesSelectedSurfaceProtocolError() throws {
        let result = try runListPanesWithEmptyDock(failSelectedSurfaceLookup: true)

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, Comment(rawValue: result.stdout))
        #expect(
            result.stderr.contains("pane.surfaces protocol failure"),
            Comment(rawValue: result.stderr)
        )
    }

    /// A successful pane.surfaces response with no `surfaces` field is a
    /// protocol failure, not an empty pane.
    @Test func listPanesRejectsMissingSelectedSurfaceArray() throws {
        let result = try runListPanesWithEmptyDock(paneSurfacesResponse: .missing)

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, Comment(rawValue: result.stdout))
        #expect(result.stderr.contains("couldn't resolve the selected pane"), Comment(rawValue: result.stderr))
        #expect(!result.stderr.contains("pane.surfaces"), Comment(rawValue: result.stderr))
    }

    /// A successful pane.surfaces response with a non-array field must not be
    /// silently treated as an empty pane.
    @Test func listPanesRejectsNonArraySelectedSurfaceField() throws {
        let result = try runListPanesWithEmptyDock(paneSurfacesResponse: .nonArray)

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, Comment(rawValue: result.stdout))
        #expect(result.stderr.contains("couldn't resolve the selected pane"), Comment(rawValue: result.stderr))
        #expect(!result.stderr.contains("pane.surfaces"), Comment(rawValue: result.stderr))
    }

    /// A non-empty response without a usable surface ID is malformed, not an empty pane.
    @Test func listPanesRejectsNonEmptySurfaceArrayWithoutUsableIDs() throws {
        let result = try runListPanesWithEmptyDock(paneSurfacesResponse: .invalidIDs)

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, Comment(rawValue: result.stdout))
        #expect(result.stderr.contains("couldn't resolve the selected pane"), Comment(rawValue: result.stderr))
    }

    private func runListPanesWithEmptyDock(
        failSelectedSurfaceLookup: Bool = false,
        paneSurfacesResponse: PaneSurfacesResponse = .valid
    ) throws -> ProcessRunResult {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITmuxCompatRemoteSplitBundleToken.self)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-compat-empty-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = Self.makeSocketPath("tmuxempty")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let emptyPaneID = "22222222-2222-2222-2222-222222222222"
        let livePaneID = "33333333-3333-3333-3333-333333333333"
        let liveSurfaceID = "44444444-4444-4444-4444-444444444444"
        let panes: [[String: Any]] = [
            [
                "id": emptyPaneID,
                "ref": "pane:1",
                "index": 0,
                "focused": true,
                "surface_count": 0,
                "surface_ids": [],
            ],
            [
                "id": livePaneID,
                "ref": "pane:2",
                "index": 1,
                "focused": false,
                "surface_count": 1,
                "surface_ids": [liveSurfaceID],
                "selected_surface_id": liveSurfaceID,
                "columns": 80,
                "rows": 24,
            ],
        ]
        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspaces": [["id": workspaceID, "ref": "workspace:1", "index": 0, "selected": true]],
                ])
            case "surface.current":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "pane_id": livePaneID,
                    "surface_id": liveSurfaceID,
                ])
            case "pane.list":
                return Self.v2Response(id: id, ok: true, result: ["panes": panes])
            case "pane.surfaces":
                if failSelectedSurfaceLookup {
                    return Self.v2Response(id: id, ok: false, error: [
                        "code": "pane_surfaces_unavailable",
                        "message": "pane.surfaces protocol failure",
                    ])
                }
                switch paneSurfacesResponse {
                case .missing:
                    return Self.v2Response(id: id, ok: true, result: [:])
                case .nonArray:
                    return Self.v2Response(id: id, ok: true, result: ["surfaces": "not-an-array"])
                case .invalidIDs:
                    return Self.v2Response(id: id, ok: true, result: [
                        "surfaces": [["selected": true], ["id": ""]],
                    ])
                case .valid:
                    break
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                let paneID = params["pane_id"] as? String
                let surfaces: [[String: Any]] = paneID == livePaneID
                    ? [["id": liveSurfaceID, "ref": "surface:1", "index": 0, "selected": true]]
                    : []
                return Self.v2Response(id: id, ok: true, result: ["surfaces": surfaces])
            case "surface.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "surfaces": [["id": liveSurfaceID, "ref": "surface:1", "index": 0, "focused": true]],
                ])
            default:
                state.expect(false, "unexpected method: \(method)")
                return Self.v2Response(id: id, ok: false, error: ["code": "unsupported", "message": method])
            }
        }

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["__tmux-compat", "list-panes", "-F", "#{pane_uuid}"],
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "HOME": tmpDir.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 30
        )
        #expect(handled.wait(timeout: .now() + 30) == .success)
        #expect(state.errorSnapshot() == [])
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return result
    }
}
