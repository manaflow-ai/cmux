import Foundation

extension V2ControlService {
    func requestDirectoryRefresh(run: UUID) {
        guard directorySyncTask == nil, (socket != nil || httpMode) else { return }
        let taskID = UUID()
        directorySyncTaskID = taskID
        directorySyncTask = Task { [weak self] in
            guard let self else { return }
            var didRefresh = false
            do {
                _ = try await self.refreshDirectory()
                didRefresh = true
            }
            catch { await self.maintenanceFailed(error, schema: "directory.request.v1", run: run) }
            await self.directorySyncFinished(run: run, taskID: taskID, didRefresh: didRefresh)
        }
    }

    private func directorySyncFinished(run: UUID, taskID: UUID, didRefresh: Bool) {
        guard runID == run, directorySyncTaskID == taskID else { return }
        directorySyncTask = nil
        directorySyncTaskID = nil
        // A directory.changed event can arrive while the current refresh is
        // blocked persisting its snapshot. Keep the newest requested revision
        // and immediately drain it after the in-flight operation completes.
        // Failed refreshes retain their normal maintenance cooldown.
        if didRefresh, wantedDirectoryRevision > (cache.directory?.revision ?? 0) {
            requestDirectoryRefresh(run: run)
        }
    }

    func scheduleMaintenance(run: UUID) {
        guard runID == run, status == .ready else {
            journal("maintenance-not-scheduled", [
                "reason": runID == run ? "status" : "run-superseded",
                "status": String(describing: status),
            ])
            return
        }
        journal("maintenance-scheduled", ["http_mode": String(httpMode)])
        scheduleRenewalHealthCheck(run: run)
#if DEBUG
        if let interval = verificationRenewalInterval, nextVerificationRenewalAt == nil {
            nextVerificationRenewalAt = dependencies.now().addingTimeInterval(interval)
        }
#endif
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in await self?.maintain(run: run) }
    }

    func scheduleRenewalHealthCheck(run: UUID) {
        guard runID == run, status == .ready else { return }
        let now = dependencies.now().timeIntervalSince1970
        let refreshAfter = [
            cache.ticket?.refreshAfter,
            cache.relayCredentials.map(\.refreshAfter).min(),
        ].compactMap { $0 }.map { TimeInterval($0) }.min()
        guard let refreshAfter else {
            renewalHealthTask?.cancel()
            renewalHealthTask = nil
            return
        }
        armRenewalHealthCheck(run: run, delay: max(0, refreshAfter + 300 - now))
    }

    private func armRenewalHealthCheck(run: UUID, delay: TimeInterval) {
        renewalHealthTask?.cancel()
        let dependencies = dependencies
        renewalHealthTask = Task { [weak self] in
            do { try await dependencies.sleep(delay) }
            catch { return }
            await self?.renewalHealthCheckFired(run: run)
        }
    }

    private func renewalHealthCheckFired(run: UUID) {
        renewalHealthTask = nil
        guard runID == run, status == .ready, !Task.isCancelled else { return }
        let now = Int(dependencies.now().timeIntervalSince1970)
        var overdue: [String: String] = [:]
        if !cache.authorityRevoked,
           let refreshAfter = cache.relayCredentials.map(\.refreshAfter).min(),
           now - refreshAfter > 300 {
            overdue["relay_overdue_s"] = String(now - refreshAfter)
            let expires = cache.relayCredentials.map(\.expiresAt).max() ?? now
            overdue["relay_expires_in_s"] = String(expires - now)
        }
        if !cache.authorityRevoked, let ticket = cache.ticket,
           now - ticket.refreshAfter > 300 {
            overdue["ticket_overdue_s"] = String(now - ticket.refreshAfter)
        }
        if overdue.isEmpty {
            scheduleRenewalHealthCheck(run: run)
        } else {
            overdue["status"] = String(describing: status)
            overdue["failure"] = failure?.diagnosticCode ?? "none"
            journal("credential-renewal-overdue", overdue)
            armRenewalHealthCheck(run: run, delay: 300)
        }
    }

    private func maintain(run: UUID) async {
        while runID == run, status == .ready, !Task.isCancelled {
            let now = dependencies.now().timeIntervalSince1970
            let ticketRefreshAfter = cache.ticket?.refreshAfter
            let relayRefreshAfter = cache.relayCredentials.map(\.refreshAfter).min()
            let directoryRefreshAfter = cache.directory.map { $0.permissionExpiresAt - 300 }
            let ticketDue = due(ticketRefreshAfter, schema: "ticket.request.v1", now: now)
            let relayDue = due(relayRefreshAfter, schema: "relay.request.v1", now: now)
            let directoryDue = due(directoryRefreshAfter, schema: "directory.request.v1", now: now)
#if DEBUG
            let verificationDue = nextVerificationRenewalAt?.timeIntervalSince1970 ?? .infinity
#else
            let verificationDue = TimeInterval.infinity
#endif
            let next = min(ticketDue, relayDue, directoryDue, verificationDue)
            journal("maintenance-planned", [
                "sleep_s": String(Int(max(0, next - now))),
                "ticket_in_s": String(Int(ticketDue - now)),
                "relay_in_s": String(Int(relayDue - now)),
                "directory_in_s": String(Int(directoryDue - now)),
                // A renewal pushed past its refresh time by a cooldown is
                // otherwise invisible; name the deferred schemas explicitly.
                "deferred": deferredSchemas(
                    now: now,
                    ticket: (ticketRefreshAfter, ticketDue),
                    relay: (relayRefreshAfter, relayDue),
                    directory: (directoryRefreshAfter, directoryDue)
                ).joined(separator: ","),
            ])
            do { try await dependencies.sleep(max(0, next - now)) }
            catch {
                journal("maintenance-exited", ["reason": "sleep-cancelled"])
                return
            }
            guard runID == run, !Task.isCancelled else {
                journal("maintenance-exited", ["reason": Task.isCancelled ? "cancelled" : "run-superseded"])
                return
            }
            guard socket != nil || httpMode else {
                // Nothing restarts maintenance until the next reconnect or
                // foreground. Renewals stop here while status stays .ready.
                journal("maintenance-exited", ["reason": "no-transport", "status": String(describing: status)])
                return
            }
            let deadline = dependencies.now().timeIntervalSince1970 + 0.1
#if DEBUG
            let forceVerification = verificationDue <= deadline
            if forceVerification, let interval = verificationRenewalInterval {
                nextVerificationRenewalAt = dependencies.now().addingTimeInterval(interval)
            }
#else
            let forceVerification = false
#endif
            // Independent refreshes share the same socket but no peer teardown path.
            await withTaskGroup(of: Void.self) { group in
                if ticketDue <= deadline || forceVerification {
                    group.addTask {
                        do { _ = try await self.refreshAPITicket() }
                        catch { await self.maintenanceFailed(error, schema: "ticket.request.v1", run: run) }
                    }
                }
                if relayDue <= deadline || forceVerification {
                    group.addTask {
                        do { _ = try await self.refreshRelayCredentials() }
                        catch { await self.maintenanceFailed(error, schema: "relay.request.v1", run: run) }
                    }
                }
                if directoryDue <= deadline || forceVerification {
                    group.addTask {
                        do { _ = try await self.refreshDirectory() }
                        catch { await self.maintenanceFailed(error, schema: "directory.request.v1", run: run) }
                    }
                }
            }
        }
        journal("maintenance-exited", [
            "reason": Task.isCancelled ? "cancelled" : (runID == run ? "status" : "run-superseded"),
            "status": String(describing: status),
        ])
    }

    private func due(_ timestamp: Int?, schema: String, now: TimeInterval) -> TimeInterval {
        max(Double(timestamp ?? Int(now)), cooldowns[schema]?.timeIntervalSince1970 ?? 0, cooldowns[operation(schema)]?.timeIntervalSince1970 ?? 0)
    }

    /// Schemas whose next run is later than their own refresh time because a
    /// schema or operation cooldown dominates.
    private func deferredSchemas(
        now: TimeInterval,
        ticket: (Int?, TimeInterval),
        relay: (Int?, TimeInterval),
        directory: (Int?, TimeInterval)
    ) -> [String] {
        let wanted: [(String, Int?, TimeInterval)] = [
            ("ticket.request.v1", ticket.0, ticket.1),
            ("relay.request.v1", relay.0, relay.1),
            ("directory.request.v1", directory.0, directory.1),
        ]
        return wanted.compactMap { schema, refreshAfter, nextDue in
            nextDue > Double(refreshAfter ?? Int(now)) ? schema : nil
        }
    }

    private func maintenanceFailed(_ error: any Error, schema: String, run: UUID) {
        guard runID == run, !Task.isCancelled else { return }
        let mapped = mapFailure(error)
        journal("refresh-failed", ["schema": schema, "failure": mapped.diagnosticCode])
        // The receive owner already records server cooldowns. Do not count one
        // rejected schema twice or overwrite its long backoff with a short one.
        if case .server = mapped {} else { record(mapped, schema: schema) }
        let retry = dependencies.now().addingTimeInterval(30 * (0.8 + 0.4 * dependencies.jitter()))
        cooldowns[operation(schema)] = max(cooldowns[operation(schema)] ?? retry, retry)
    }
}
