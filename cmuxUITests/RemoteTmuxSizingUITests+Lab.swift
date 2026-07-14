import XCTest
import Foundation
import Darwin

extension RemoteTmuxSizingUITests {

    /// The layout-shape zoo: one window per split SHAPE, because sizing bugs
    /// are shape-dependent (a boundary miss can hit a nested column while
    /// even columns land clean). Names double as the tab titles the
    /// exploratory sweep clicks through.
    static let shapeNames = ["even3", "nested", "rows3", "grid4", "deep", "sixcol", "mainh"]

    func requireTmux() throws {
        try XCTSkipIf(tmuxBin == nil, "tmux binary not found; e2e workflow installs it via brew")
    }

    func buildLabSession() throws {
        _ = tmux(["kill-server"])
        XCTAssertNotNil(
            tmux(["new-session", "-d", "-s", sessionName, "-x", "180", "-y", "45"]),
            "lab server never started: \(lastTmuxFailure ?? "no stderr captured")"
        )
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["select-layout", "-t", "\(sessionName):0", "even-horizontal"])
        _ = tmux(["new-window", "-t", sessionName])
        _ = tmux(["select-window", "-t", "\(sessionName):0"])
    }

    /// Builds one window per shape (plus the plain single-pane window), all
    /// panes running the width probe.
    func buildShapeZoo() throws {
        _ = tmux(["kill-server"])
        XCTAssertNotNil(
            tmux(["new-session", "-d", "-s", sessionName, "-x", "180", "-y", "45",
                  "-n", "even3"]),
            "lab server never started: \(lastTmuxFailure ?? "no stderr captured")"
        )
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["select-layout", "-t", "\(sessionName):0", "even-horizontal"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "nested"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):1"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):1.1"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "rows3"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):2"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):2"])
        _ = tmux(["select-layout", "-t", "\(sessionName):2", "even-vertical"])
        // One NON-first zoo window runs with tmux title rows so the sweep
        // covers the batch list-windows + pane-rects path where the layout
        // string's geometry is wrong (tmux publishes the pre-title tree).
        _ = tmux(["set", "-w", "-t", "\(sessionName):2", "pane-border-status", "top"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "grid4"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):3"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):3.0"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):3.2"])
        _ = tmux(["select-layout", "-t", "\(sessionName):3", "tiled"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "deep"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):4"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):4.1"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):4.2"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "sixcol"])
        for _ in 0..<5 {
            _ = tmux(["split-window", "-h", "-t", "\(sessionName):5"])
            _ = tmux(["select-layout", "-t", "\(sessionName):5", "even-horizontal"])
        }
        _ = tmux(["new-window", "-t", sessionName, "-n", "mainh"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):6"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):6.1"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):6.1"])
        _ = tmux(["select-layout", "-t", "\(sessionName):6", "main-horizontal"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "plain"])
        _ = tmux(["select-window", "-t", "\(sessionName):0"])
    }

    /// Maps a window NAME to its tmux window id (the `@N` number).
    func windowId(named name: String) -> Int? {
        guard let out = tmux(["list-windows", "-t", sessionName, "-F", "#{window_id} #{window_name}"]) else {
            return nil
        }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, String(parts[1]) == name,
               let id = Int(parts[0].dropFirst()) {
                return id
            }
        }
        return nil
    }

    /// Selects the tab titled `name` via `surface.focus` — the socket twin of
    /// clicking the tab bar. It flips the same tab-visibility state a click
    /// does (the mirror re-owns its size on selection), without routing a
    /// mouse event through whatever else is on the desktop.
    @discardableResult
    func selectTab(named name: String) -> Bool {
        // Poll: surface titles arrive over the control stream shortly after
        // the mirror window opens, so the first lookups can race them.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let list = socketJSON(method: "surface.list", params: [:]),
               let surfaces = list["surfaces"] as? [[String: Any]],
               let surfaceId = surfaces.first(where: { $0["title"] as? String == name })?["id"] as? String {
                let response = socketJSON(method: "surface.focus", params: ["surface_id": surfaceId])
                return response?["ok"] as? Bool == true
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    /// Mirrors the lab host in a dedicated, activated cmux window — the
    /// `cmux ssh-tmux` entry point. Activation matters: it mounts the mirror
    /// views, and only mounted views have geometry to feed the client-size
    /// push (`remote.tmux.mirror` alone creates unselected workspaces whose
    /// windows never claim a size).
    func attachSession() {
        let response = socketJSON(method: "remote.tmux.window", params: [
            "host": "e2e-shim-host",
            "activate": true,
        ])
        XCTAssertEqual(response?["ok"] as? Bool, true, "remote.tmux.window failed: \(response ?? [:])")
        XCTAssertEqual(response?["mirrored"] as? Bool, true, "host not mirrored: \(response ?? [:])")
        mirrorWindowId = response?["window_id"] as? String
    }
}
