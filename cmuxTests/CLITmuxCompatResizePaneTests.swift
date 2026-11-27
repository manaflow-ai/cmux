import Darwin
import Foundation
import Testing

extension CLITmuxCompatRemoteSplitTests {
    @Test func absoluteResizeCarriesExactTmuxCellTarget() throws {
        let params = try captureResize(arguments: ["-x", "3"])
        #expect(params["absolute_axis"] as? String == "horizontal")
        #expect((params["target_pixels"] as? NSNumber)?.intValue == 36)
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

    @Test func exactAbsoluteResizeDoesNotRequireLocalPaneMetrics() throws {
        let cells = try captureResize(arguments: ["-x", "3"], includeMetrics: false)
        #expect((cells["target_cells"] as? NSNumber)?.intValue == 3)
        #expect(cells["target_pixels"] == nil)

        let percentage = try captureResize(arguments: ["-x", "50%"], includeMetrics: false)
        #expect((percentage["target_percentage"] as? NSNumber)?.intValue == 50)
        #expect(percentage["target_pixels"] == nil)

        let relative = try captureResize(arguments: ["-L", "7"], includeMetrics: false)
        #expect((relative["amount_cells"] as? NSNumber)?.intValue == 7)
        #expect(relative["amount"] == nil)
    }

    @Test func pixelOnlyPaneMetricsDoNotBecomePointFallbacks() throws {
        let cells = try captureResize(arguments: ["-x", "3"], includePointMetrics: false)
        #expect((cells["target_cells"] as? NSNumber)?.intValue == 3)
        #expect(cells["target_pixels"] == nil)

        let percentage = try captureResize(arguments: ["-x", "50%"], includePointMetrics: false)
        #expect((percentage["target_percentage"] as? NSNumber)?.intValue == 50)
        #expect((percentage["target_pixels"] as? NSNumber)?.intValue == 320)

        let relative = try captureResize(arguments: ["-L", "7"], includePointMetrics: false)
        #expect((relative["amount_cells"] as? NSNumber)?.intValue == 7)
        #expect(relative["amount"] == nil)
    }

    @Test func percentageWithoutContainerFrameOmitsPointFallback() throws {
        let params = try captureResize(arguments: ["-x", "50%"], includeContainerFrame: false)
        #expect((params["target_percentage"] as? NSNumber)?.intValue == 50)
        #expect(params["target_pixels"] == nil)
    }

    @Test func directionalResizeUsesPositionalAmountAndDefaultsToOneCell() throws {
        let explicit = try captureResize(arguments: ["-L", "7"])
        #expect(explicit["direction"] as? String == "left")
        #expect((explicit["amount"] as? NSNumber)?.intValue == 56)
        #expect((explicit["amount_cells"] as? NSNumber)?.intValue == 7)

        let attached = try captureResize(arguments: ["-L7"])
        #expect(attached["direction"] as? String == "left")
        #expect((attached["amount"] as? NSNumber)?.intValue == 56)
        #expect((attached["amount_cells"] as? NSNumber)?.intValue == 7)

        let defaulted = try captureResize(arguments: ["-R"])
        #expect(defaulted["direction"] as? String == "right")
        #expect((defaulted["amount"] as? NSNumber)?.intValue == 8)
        #expect((defaulted["amount_cells"] as? NSNumber)?.intValue == 1)
    }

    private func captureResize(
        arguments: [String],
        includeMetrics: Bool = true,
        includePointMetrics: Bool = true,
        includeContainerFrame: Bool = true
    ) throws -> [String: Any] {
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
                var pane: [String: Any] = [
                    "id": paneID,
                    "ref": "pane:1",
                    "index": 0,
                    "focused": true,
                    "columns": 80,
                    "rows": 24,
                ]
                var result: [String: Any] = ["panes": [pane]]
                if includeMetrics {
                    pane["cell_width_px"] = 16
                    pane["cell_height_px"] = 34
                    if includePointMetrics {
                        pane["cell_width_points"] = 8
                        pane["cell_height_points"] = 17
                    }
                    pane["pixel_frame"] = ["x": 0, "y": 0, "width": 652, "height": 438]
                    result["panes"] = [pane]
                    if includeContainerFrame {
                        result["container_frame"] = ["width": 640, "height": 816]
                    }
                }
                return Self.v2Response(id: id, ok: true, result: result)
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
