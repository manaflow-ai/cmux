//! `tab-attention-v1`: a "needs you" mark expires after
//! [`crate::state::tab_state_store::ATTENTION_MAX_AGE_MS`]. Reads already
//! skip an expired mark; this sweep clears its row through the state commit,
//! so the presentation cache, the raw tree and `session.events` drop it too.
//! It runs when the daemon starts and again when the oldest remaining mark
//! expires.

use std::sync::Weak;
use std::time::Duration;

use crate::Actor;
use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::state::tab_state_store::{attention_expiry, clear_expired_attention};
use crate::state::values::fresh_upserts;

/// The longest the sweep waits between passes: a mark set while it waits
/// expires a day later, so it is read again well before then.
const MAX_SWEEP_WAIT_MS: u64 = 60 * 60 * 1000;

impl Mux {
    /// Clear every mark expired at `now_ms`. One read when none expired;
    /// otherwise a commit that decides again in its own transaction and
    /// restates the live tabs it cleared. Returns when the first remaining
    /// mark expires (Unix ms), if any.
    pub(crate) fn expire_attention_marks(&self, actor: &Actor, now_ms: u64) -> Option<u64> {
        let expiry =
            match self.personal_state_read(|connection| attention_expiry(connection, now_ms)) {
                Ok(expiry) => expiry,
                Err(error) => {
                    eprintln!("cmux-tui: reading attention marks to expire failed: {error}");
                    return None;
                }
            };
        if expiry.expired.is_empty() {
            return expiry.next_ms;
        }
        let fingerprint = serde_json::json!({
            "operation": "tab.attention.expired",
            "tabs": expiry.expired,
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        let result = self.commit_state(
            &WorkspaceMutation::local("cmux-tui-tab-attention", actor.clone()),
            "tab.attention.expired",
            &fingerprint,
            None,
            StateEffects::PRESENTATION,
            |transaction, _state| {
                let cleared = clear_expired_attention(transaction, now_ms)?;
                let changes = fresh_upserts(transaction, &[], &[], &cleared)?;
                Ok(StateChanges::new(serde_json::json!({"tabs": cleared}), changes))
            },
        );
        if let Err(error) = result {
            eprintln!("cmux-tui: clearing expired attention marks failed: {error:#}");
        }
        expiry.next_ms
    }
}

/// Daemon start: sweep on the constructing thread, then on a worker that
/// wakes when the next mark expires (at most [`MAX_SWEEP_WAIT_MS`] apart).
/// The worker holds the mux only during a pass and ends once it is gone.
/// In-crate tests drive [`Mux::expire_attention_marks`] with their own clock.
pub(crate) fn start(mux: &Arc<Mux>) {
    let next = mux.expire_attention_marks(&Actor::Daemon, now_ms());
    if cfg!(test) {
        return;
    }
    let weak = Arc::downgrade(mux);
    let spawned = std::thread::Builder::new()
        .name("mux-attention-expiry".into())
        .spawn(move || sweep_until_gone(&weak, next));
    if spawned.is_err() {
        mux.report_internal_diagnostic("attention mark expiry worker not started");
    }
}

fn sweep_until_gone(mux: &Weak<Mux>, mut next: Option<u64>) {
    loop {
        let now = now_ms();
        let wait = next.map_or(MAX_SWEEP_WAIT_MS, |next| next.saturating_sub(now));
        // A mark expires at its deadline exactly; the extra millisecond keeps
        // the pass from waking just before it.
        std::thread::sleep(Duration::from_millis(wait.min(MAX_SWEEP_WAIT_MS) + 1));
        let Some(owner) = mux.upgrade() else { return };
        next = owner.expire_attention_marks(&Actor::Daemon, now_ms());
    }
}
