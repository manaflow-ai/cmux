//! A pooled entry's process priority: best-effort while it
//! waits in the pool, normal again before a claim serves it. The entry's two
//! processes are the ones its record names, its host and its harness, each
//! leading its own process group; nothing else is looked up
//! (`cmux_tui_platform::process_priority`).

use super::*;

/// Set `priority` on `record`'s host group, then its harness group.
fn set_entry(
    set_group: &GroupPriority,
    record: &HostRecord,
    priority: ProcessPriority,
) -> Result<(), PriorityError> {
    set_group(record.host_pid, priority)?;
    match record.harness_pid {
        Some(harness) => set_group(harness, priority),
        None => Ok(()),
    }
}

impl Hub {
    /// Run `p` best-effort, in place (the claim guard's drop).
    pub(super) fn pool_background(&self, mut p: Pooled) -> Pooled {
        if let Some(set_group) = self.pool.priority.get().filter(|_| !p.background) {
            let changed = set_entry(set_group, &p.record, ProcessPriority::BestEffort);
            backgrounded(&mut p, Ok(changed));
        }
        p
    }

    /// [`Hub::pool_background`] off the runtime's workers.
    pub(super) async fn pool_background_async(&self, mut p: Pooled) -> Pooled {
        if let Some(set_group) = self.pool.priority.get().filter(|_| !p.background).cloned() {
            let record = p.record.clone();
            let changed = crate::daemon::spawn_blocking(move || {
                set_entry(&set_group, &record, ProcessPriority::BestEffort)
            })
            .await;
            backgrounded(&mut p, changed);
        }
        p
    }

    /// The claimed entry `id` at its normal priority again, before the claim
    /// serves it: true when it is back. It stays in `claimed` meanwhile, so
    /// a `stop_pool` that drains the claims ends it (false then). An entry
    /// that did not come back is ended (false): the session starts cold
    /// rather than run best-effort.
    pub(super) async fn pool_foreground(&self, id: &str) -> bool {
        let wanted = {
            let claimed = lock(&self.pool.claimed);
            let Some(p) = claimed.get(id) else { return false };
            let set_group = self.pool.priority.get().filter(|_| p.background).cloned();
            set_group.map(|set_group| (set_group, p.record.clone()))
        };
        let Some((set_group, record)) = wanted else { return true };
        let changed = crate::daemon::spawn_blocking(move || {
            set_entry(&set_group, &record, ProcessPriority::UserVisible)
        })
        .await
        .map_err(|e| e.to_string())
        .and_then(|changed| changed.map_err(|e| e.to_string()));
        // `stop_pool` may have drained the claims meanwhile: it ends the entry then.
        let mut claimed = lock(&self.pool.claimed);
        if let Err(failed) = changed {
            let Some(p) = claimed.remove(id) else { return false };
            drop(claimed);
            tracing::warn!(harness = %p.key.harness, "a pooled agent did not return to normal priority; it ends and the session starts cold: {failed}");
            self.pool_discard(vec![p]);
            return false;
        }
        let Some(p) = claimed.get_mut(id) else { return false };
        p.background = false;
        true
    }

    /// A pooled start under way, counted until the guard drops; the daemon
    /// is at its normal priority before the start forks its host.
    pub(super) fn pool_start_in_flight(self: &Arc<Self>) -> StartInFlight {
        self.pool.in_flight.fetch_add(1, Ordering::SeqCst);
        self.clients.foreground();
        StartInFlight(self.clone())
    }

    /// Pooled starts under way (`Hub::idle_quiet`).
    pub(crate) fn pool_starts_in_flight(&self) -> usize {
        self.pool.in_flight.load(Ordering::SeqCst)
    }
}

/// One pooled start under way ([`Hub::pool_start_in_flight`]); its drop
/// lets the daemon's idle priority ask again.
pub(super) struct StartInFlight(Arc<Hub>);

impl Drop for StartInFlight {
    fn drop(&mut self) {
        self.0.pool.in_flight.fetch_sub(1, Ordering::SeqCst);
        self.0.clients.work_changed();
    }
}

/// Record a best-effort attempt on `p`. It counts as best-effort even when a
/// part failed (a group this user may not change, one that ended): the claim
/// then puts back whatever did change, and an entry that cannot come back
/// is not served.
fn backgrounded(
    p: &mut Pooled,
    changed: Result<Result<(), PriorityError>, tokio::task::JoinError>,
) {
    p.background = true;
    match changed {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            tracing::debug!(harness = %p.key.harness, "a pooled agent is partly best-effort: {e}")
        }
        Err(e) => {
            tracing::warn!(harness = %p.key.harness, "a pooled agent's priority change failed: {e}")
        }
    }
}
