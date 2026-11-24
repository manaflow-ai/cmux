//! Lifting the update hold (`workspace_registry/update_hold_store.rs`).
//!
//! An update's `server hold-terminals` marked every terminal with no tab and
//! no `keep` mark as `keep` before the app quit, so the reaper of the owner
//! that ran then (of any build) left them alone when the app's attach
//! streams ended. This owner lifts the mark of each held terminal once a
//! client streams it again or a tab shows it, and of the rest when the hold
//! is [`UPDATE_HOLD_MAX`] old. A lifted terminal is the reaper's again, with
//! a new grace: it was retained while marked, so its unplaced time restarts.
//!
//! Nothing here ends a terminal, and the reaper is unchanged.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use super::Mux;
use crate::workspace_registry::update_hold_store::UpdateHold;

/// How long a held terminal that no client streams and no tab shows keeps
/// its mark. As long as the owner keeps an unattended session
/// (`server/owner_keepers.rs`): the hold must outlast an update that waits
/// for the user, and must not hold a PTY for ever.
pub const UPDATE_HOLD_MAX: Duration = Duration::from_secs(24 * 60 * 60);

/// How often the owner looks at a hold that still names terminals. No hold,
/// no look: the thread runs only while the hold file exists.
const UPDATE_HOLD_POLL: Duration = Duration::from_secs(1);

/// What one pass over the hold did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UpdateHoldPass {
    /// Terminals whose mark was lifted because a client streams them or a
    /// tab shows them.
    pub lifted: Vec<String>,
    /// Terminals whose mark was lifted because the hold expired.
    pub expired: Vec<String>,
    /// Terminals still held.
    pub held: usize,
}

impl Mux {
    /// Mark every terminal with no tab and no `keep` mark as `keep` and name
    /// it in the hold file `path`. The owner-side form of `server
    /// hold-terminals`; returns the host ids held by this call.
    pub fn hold_terminals_for_update(
        &self,
        path: &Path,
        now_ms: u64,
    ) -> anyhow::Result<Vec<String>> {
        let terminals = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .update_hold_candidates()?;
        if terminals.is_empty() {
            return Ok(terminals);
        }
        // The file first: a mark the file does not name would never lift.
        UpdateHold::extend(path, &terminals, now_ms)?;
        let mut held = Vec::with_capacity(terminals.len());
        for terminal_id in terminals {
            match self.set_terminal_keep(&terminal_id, true) {
                Ok(()) => held.push(terminal_id),
                Err(error) => self.report_internal_diagnostic(format!(
                    "update hold: keep {terminal_id} failed: {error}"
                )),
            }
        }
        Ok(held)
    }

    /// One pass over the hold file `path`: lift the mark of every held
    /// terminal a client streams or a tab shows, and of every held terminal
    /// once the hold is `max_age` old; the others stay held.
    pub fn lift_update_hold(
        &self,
        path: &Path,
        now_ms: u64,
        max_age: Duration,
    ) -> anyhow::Result<UpdateHoldPass> {
        let Some(hold) = UpdateHold::read(path)? else {
            return Ok(UpdateHoldPass::default());
        };
        let max_age_ms = u64::try_from(max_age.as_millis()).unwrap_or(u64::MAX);
        let expired = now_ms.saturating_sub(hold.held_ms) >= max_age_ms;
        let (unplaced, placed) = self.unplaced_and_placed_terminals();
        // The client registry is read after the state lock is released.
        let views: Vec<(String, crate::SurfaceId)> = {
            let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            state
                .terminal_catalog
                .values()
                .filter_map(|runtime| {
                    let identity = self.resource_terminal_host_identity(runtime)?;
                    unplaced
                        .contains(&identity.terminal_id)
                        .then_some((identity.terminal_id, runtime.id))
                })
                .collect()
        };
        let mut pass = UpdateHoldPass::default();
        let mut left = Vec::new();
        for terminal_id in hold.terminals {
            let shown = placed.contains(&terminal_id)
                || views
                    .iter()
                    .any(|(id, view)| *id == terminal_id && self.terminal_view_attached(*view));
            if !shown && !expired {
                // Also a terminal this owner has not adopted yet: it keeps
                // its mark until the owner serves it or the hold expires.
                left.push(terminal_id);
                continue;
            }
            match self.set_terminal_keep(&terminal_id, false) {
                Ok(()) if shown => pass.lifted.push(terminal_id),
                // Ended or unknown: the registry prunes its mark.
                Ok(()) | Err(_) => pass.expired.push(terminal_id),
            }
        }
        pass.held = left.len();
        UpdateHold { held_ms: hold.held_ms, terminals: left }.write(path)?;
        Ok(pass)
    }
}

fn unix_now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Start lifting the update hold of this owner's session, when an update
/// left one. Returns whether a hold was found. The thread ends with the
/// hold or the mux, and holds neither the mux nor a lock while it waits.
pub fn start_update_hold_release(mux: &Arc<Mux>) -> std::io::Result<bool> {
    let Some(directory) = mux.session_state_directory() else {
        return Ok(false);
    };
    let path = directory.join(crate::workspace_registry::update_hold_store::UPDATE_HOLD_FILE);
    if !path.is_file() {
        return Ok(false);
    }
    let weak = Arc::downgrade(mux);
    std::thread::Builder::new().name("mux-update-hold".into()).spawn(move || {
        loop {
            let Some(mux) = weak.upgrade() else { break };
            match mux.lift_update_hold(&path, unix_now_ms(), UPDATE_HOLD_MAX) {
                Ok(pass) if pass.held == 0 => break,
                Ok(_) => {}
                Err(error) => {
                    mux.report_internal_diagnostic(format!("update hold: {error}"));
                    break;
                }
            }
            drop(mux);
            std::thread::sleep(UPDATE_HOLD_POLL);
        }
    })?;
    Ok(true)
}

#[cfg(test)]
#[path = "update_hold_tests.rs"]
mod tests;
