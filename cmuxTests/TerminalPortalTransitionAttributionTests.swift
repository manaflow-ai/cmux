import CMUXMobileCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalPortalTransitionAttributionTests {
    @Test(arguments: [TerminalWorkContext.Transition.unknown, .split, .restore, .reveal, .resize])
    func rendererRefreshUsesTypedOriginInsteadOfReasonText(transition: TerminalWorkContext.Transition) async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        let log = DiagnosticLog(capacity: 8)
        let (events, continuation) = AsyncStream<DiagnosticEvent>.makeStream()
        log.setEventTap { continuation.yield($0) }
        defer { log.setEventTap(nil); continuation.finish() }
        TerminalGeometryDiagnostics(log: log).refresh(
            fixture.hosted, reason: "portal.reveal", transition: transition
        )
        var iterator = events.makeAsyncIterator()
        let started = try #require(await iterator.next())
        let finished = try #require(await iterator.next())
        #expect(started.code == .terminalWorkStarted)
        #expect(finished.code == .terminalWorkFinished)
        #expect(started.terminalWork?.phase == .rendererRefresh)
        #expect(started.terminalWork?.context.transition == transition)
        #expect(finished.terminalWork == started.terminalWork)
    }

    @Test(arguments: [TerminalWorkContext.Transition.split, .restore])
    @MainActor
    func queuedGeometryRetainsItsOwnerTransitionAfterTheScopeEnds(transition: TerminalWorkContext.Transition) throws {
        let fixture = TerminalPortalTestWorkspace()
        defer { fixture.tearDown() }
        let workspace = try #require(AppDelegate.shared?.tabManagerFor(tabId: fixture.id)?.workspacesById[fixture.id])
        let scheduler = TerminalPortalReconciliationScheduler()
        var delivered: TerminalWorkContext.Transition?
        do {
            let finish = workspace.beginTerminalGeometryTransition(transition)
            defer { finish() }
            do {
                let finishNested = workspace.beginTerminalGeometryTransition(.reveal)
                defer { finishNested() }
                let captured = TerminalGeometryDiagnostics().context(workspaceID: fixture.id, transition: .unknown)
                #expect(captured.transition == transition)
                scheduler.stage(transition: captured.transition) { _ in }
            }
            #expect(workspace.terminalGeometryTransition == transition)
        }
        #expect(workspace.terminalGeometryTransition == .unknown)
        scheduler.stage(reasons: .bindingRequired) { delivered = $0.transition }
        scheduler.flushPendingReconciliation()
        #expect(delivered == transition)
        // A later enclosing operation must not replace a queued request's
        // already captured origin when its interval is finally recorded.
        let finishLater = workspace.beginTerminalGeometryTransition(.resize)
        defer { finishLater() }
        let laterContext = TerminalGeometryDiagnostics().context(workspaceID: fixture.id, transition: transition)
        #expect(laterContext.transition == transition)
    }

}
