import Testing

/// Waits for `condition` itself, never for a number of scheduler turns: the
/// suites' own copies waited a fixed 200 to 5,000 `Task.yield()`s and returned
/// before the mock source answered on a loaded parallel run (flakes
/// FLAKE-HOMECACHE-YIELD-WAIT and FLAKE-HOMECORE-ATTACHMENT-TIMEOUTS). Polls
/// every 2 ms until `condition` holds or `timeout` passes; a wait that runs out
/// records an issue at the caller's line, so the failure names the wait.
@MainActor
public func waitUntil(timeout: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("waited \(timeout) and the condition never held", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
