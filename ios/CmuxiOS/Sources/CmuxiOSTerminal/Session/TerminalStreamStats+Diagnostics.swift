extension TerminalStreamStats {
    /// DEBUG diagnostics keys (terminal.json in the simulator gallery).
    var diagnostics: [String: String] {
        var out = [
            "frames": String(frames), "frames_skipped": String(skippedFrames),
            "frames_undecodable": String(undecodableFrames), "restores": String(restores),
            "restores_refused": String(refusedRestores), "history_pages": String(historyPages),
            "fed_bytes": String(fedBytes), "snapshot_requests": String(snapshotRequests),
            "digest_checks": String(digestChecks),
        ]
        if let restoredGeneration { out["restored_generation"] = String(restoredGeneration) }
        if let grid {
            out["surface_grid"] = "\(grid.cols)x\(grid.rows) generation \(grid.generation)" + (grid.locked ? " locked" : "")
        }
        return out
    }
}
