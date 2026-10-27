//! A pooled entry's process priority (p14-energy-038): best-effort while it
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

    /// `p` at its normal priority again, before a claim serves it. An entry
    /// that did not come back is ended (None): the session starts cold
    /// rather than run best-effort.
    pub(super) async fn pool_foreground(&self, mut p: Pooled) -> Option<Pooled> {
        let Some(set_group) = self.pool.priority.get().filter(|_| p.background).cloned() else {
            return Some(p);
        };
        let record = p.record.clone();
        let changed = crate::daemon::spawn_blocking(move || {
            set_entry(&set_group, &record, ProcessPriority::UserVisible)
        })
        .await;
        match changed {
            Ok(Ok(())) => {
                p.background = false;
                Some(p)
            }
            Ok(Err(e)) => {
                tracing::warn!(harness = %p.key.harness, "a pooled agent did not return to normal priority; it ends and the session starts cold: {e}");
                self.pool_discard(vec![p]);
                None
            }
            Err(e) => {
                tracing::warn!(harness = %p.key.harness, "a pooled agent's priority change failed; it ends and the session starts cold: {e}");
                self.pool_discard(vec![p]);
                None
            }
        }
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
