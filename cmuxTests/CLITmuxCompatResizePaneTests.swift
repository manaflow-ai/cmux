import Darwin
import Foundation
import Testing

extension CLITmuxCompatRemoteSplitTests {
    @Test func absoluteResizeCarriesExactTmuxCellTarget() throws {
        let params = try captureResize(arguments: ["-x", "3"])
        #expect(params["absolute_axis"] as? String == "horizontal")
        #expect((params["target_pixels"] as? NSNumber)?.intValue == 24)
        #expect((params["target_cells"] as? NSNumber)?.intValue == 3)
        #expect(params["target_percentage"] == nil)
        #expect(params["tmux_compat"] as? Bool == true)
    }

    @Test func absoluteResizePreservesTmuxPercentageTarget() throws {
        let params = try captureResize(arguments: ["-x", "50%"])
        #expect(params["absolute_axis"] as? String == "horizontal")
        #expect((params["target_pixels"] as? NSNumber)?.intValue == 320)
        #expect(params["target_cells"] == nil)
        #expect((params["target_percentage"] as? NSNumber)?.intValue == 50)
        #expect(params["tmux_compat"] as? Bool == true)
    }

    @Test func directionalResizeUsesPositionalAmountAndDefaultsToOneCell() throws {
        let explicit = try captureResize(arguments: ["-L", "7"])
        #expect(explicit["direction"] as? String == "left")
        #expect((explicit["amount"] as? NSNumber)?.intValue == 56)
        #expect((explicit["amount_cells"] as? NSNumber)?.intValue == 7)

        let defaulted = try captureResize(arguments: ["-R"])
        #expect(defaulted["direction"] as? String == "right")
        #expect((defaulted["amount"] as? NSNumber)?.intValue == 8)
        #expect((defaulted["amount_cells"] as? NSNumber)?.intValue == 1)
    }

    private func captureResize(arguments: [String]) throws -> [String: Any] {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CLITmuxCompatRemoteSplitBundleToken.self
        )
        let socketPath = Self.makeSocketPath("tmuxrs")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceID = "11111111-1111-4111-8111-111111111111"
        let paneID = "33333333-3333-4333-8333-333333333333"
        let capture = ResizeCapture()
        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.current":
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspaces": [["id": workspaceID, "ref": "workspace:1", "selected": true]],
                ])
            case "pane.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "container_frame": ["width": 640, "height": 816],
                    "panes": [[
                        "id": paneID,
                        "ref": "pane:1",
                        "index": 0,
                        "focused": true,
                        "columns": 80,
                        "rows": 24,
                        "cell_width_px": 16,
                        "cell_height_px": 34,
                        "cell_width_points": 8,
                        "cell_height_points": 17,
                    ]],
                ])
            case "pane.resize":
                capture.record(payload["params"] as? [String: Any] ?? [:])
                return Self.v2Response(id: id, ok: true, result: ["pane_id": paneID])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unsupported", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["__tmux-compat", "resize-pane", "-t", "pane:1"] + arguments,
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "HOME": NSTemporaryDirectory(),
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 30
        )
        #expect(handled.wait(timeout: .now() + 30) == .success)
        #expect(state.errorSnapshot() == [])
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        return try #require(capture.snapshot())
    }

    private final class ResizeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var params: [String: Any]?

        func record(_ params: [String: Any]) {
            lock.lock()
            self.params = params
            lock.unlock()
        }

        func snapshot() -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return params
        }
    }
}
