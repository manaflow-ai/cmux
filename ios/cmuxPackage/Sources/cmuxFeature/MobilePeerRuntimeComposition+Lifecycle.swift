import CMUXMobileCore
import CmuxAuthRuntime
import Foundation

// Scene-phase lifecycle: the endpoint is preserved across backgrounding, the
// supervisor parks automatic dial triggers while inactive, and a real
// foreground return revalidates auth before re-driving the connection.
extension MobilePeerRuntimeComposition {
    // MARK: - Scene phase

    /// Archives the diagnostic ring without touching the runtime. Called on
    /// scene inactivation (the app switcher opening) so a force-quit that
    /// never delivers a background transition still leaves the previous
    /// launch's events exportable.
    public func archiveDiagnostics() {
        diagnosticLog?.record(DiagnosticEvent(
            .appLifecycleChanged,
            a: DiagnosticAppLifecyclePhase.inactive.rawValue
        ))
        persistDiagnosticsSnapshot()
    }

    /// Preserves the endpoint when iOS backgrounds the scene. Automatic dial
    /// triggers park in the supervisor until the scene returns.
    public func didEnterBackground() {
        diagnosticLog?.record(DiagnosticEvent(
            .appLifecycleChanged,
            a: DiagnosticAppLifecyclePhase.background.rawValue
        ))
        requiresFullForegroundRefreshOnNextActive = true
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        persistDiagnosticsSnapshot()
        let supervisor = supervisor
        Task {
            await supervisor?.noteScenePhase(active: false)
        }
    }

    /// Health-checks and refreshes the preserved endpoint on a real foreground
    /// return.
    ///
    /// Transient inactive edges caused by system UI do not revalidate auth or
    /// restart the transport runtime.
    ///
    /// - Returns: `true` for a cold activation or a return from background;
    ///   `false` for a transient inactive-to-active edge.
    @discardableResult
    public func didBecomeActive() -> Bool {
        diagnosticLog?.record(DiagnosticEvent(
            .appLifecycleChanged,
            a: DiagnosticAppLifecyclePhase.active.rawValue
        ))
        let requiresFullRefresh = requiresFullForegroundRefreshOnNextActive
        requiresFullForegroundRefreshOnNextActive = false
        let supervisor = supervisor
        guard requiresFullRefresh else {
            permissionRefreshTask?.cancel()
            permissionRefreshTask = Task {
                await supervisor?.noteScenePhase(active: true)
            }
            return false
        }
        guard !signOutInProgress else { return true }
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        let auth = auth
        let diagnosticLog = diagnosticLog
        Task { @MainActor [weak self] in
            await supervisor?.noteScenePhase(active: true)
            if let auth {
                diagnosticLog?.recordAppEvent(.authRevalidationStarted)
                await auth.revalidateSession()
                guard !Task.isCancelled else {
                    diagnosticLog?.recordAppEvent(
                        .authRevalidationFailed,
                        failure: .cancelled
                    )
                    return
                }
                guard auth.isAuthenticated else {
                    diagnosticLog?.recordAppEvent(
                        .authRevalidationFailed,
                        failure: .authorizationFailed
                    )
                    return
                }
                diagnosticLog?.recordAppEvent(.authRevalidationSucceeded)
            }
            guard let self, !Task.isCancelled else { return }
            await self.supervisor.note(trigger: .foreground)
        }
        return true
    }

    /// Reads the previous launch's archive (once) and replaces it with the
    /// current ring, off the main actor: backgrounding must not spend the
    /// suspension window on filesystem work.
    func persistDiagnosticsSnapshot() {
        guard let diagnosticLog, let diagnosticArchive else { return }
        let needsPreviousLoad = previousLaunchDiagnosticReport == nil
        Task.detached(priority: .utility) { [weak self] in
            let previous = needsPreviousLoad ? diagnosticArchive.load() : nil
            if needsPreviousLoad {
                await self?.cachePreviousLaunchReport(previous)
            }
            diagnosticArchive.save(await diagnosticLog.snapshot())
        }
    }

    private func cachePreviousLaunchReport(_ report: DiagnosticReport?) {
        guard previousLaunchDiagnosticReport == nil else { return }
        previousLaunchDiagnosticReport = .some(report)
    }
}
