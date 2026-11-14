//! The carrier hold (pure): an update waits while a person's carrier
//! session is attached to the session host, for at most [`CARRIER_MAX_HOLD`].
//!
//! A restart of `cmux-host.service` restarts the session host, which ends
//! every carrier session on it: the Mac's chat or terminal drops and has to
//! dial again. The relay chat's busy count did this job before the carrier
//! cut (#37210) and went with it, so nothing held an update for a carrier
//! session, and a link that came up during a connect hold was cut when the
//! hold ran out (production start runs, 2026-11-08: the flips came 5:01 to
//! 5:03 after the link started, the hold's 5 minutes from the role start).
//!
//! The session host's sessions come from its admin channel
//! (`cmux-tui remote enroll connections --json`, cmux-remote's
//! `ServerConnectionSnapshot` list). A session that is connected, or
//! reconnecting inside its resume lease, is attached: a restart ends both.
//! A list that cannot be read holds the update too, under the same bound.
//!
//! The bound: a Mac can stay attached for days, and a stuck session must
//! not keep a machine on an old build. Once attached sessions have held one
//! update for [`CARRIER_MAX_HOLD`], they no longer hold it; the update goes
//! at the next idle gap of the agent turns (acpmux's busy sessions, which
//! still hold it). A session that was not there at the last look is a new
//! connect (a claimed spare's first link, a reconnect): the caller starts
//! the connect hold for it, past the bound too.

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use serde_json::Value;

/// How long attached carrier sessions may hold one update.
pub const CARRIER_MAX_HOLD: Duration = Duration::from_secs(30 * 60);

/// The attached sessions in a `remote enroll connections --json` reply
/// (connected, or reconnecting within the resume lease), each as
/// `device/session#generation`. The generation is part of it: a reconnect
/// inside the resume lease keeps its device and session ids and bumps only
/// the generation, and it is a new connect the connect hold must cover.
///
/// Fails closed: `None` (which holds the update like an unreadable list)
/// unless the reply is an array whose every entry is an object with a string
/// `device_id` and `session_id`, a numeric `generation` and a known `state`.
pub fn attached_sessions_in(json: &str) -> Option<Vec<String>> {
    let v: Value = serde_json::from_str(json.trim()).ok()?;
    let mut attached = Vec::new();
    for c in v.as_array()? {
        let device = c.get("device_id")?.as_str()?;
        let session = c.get("session_id")?.as_str()?;
        let generation = c.get("generation")?.as_u64()?;
        match c.get("state")?.as_str()? {
            "connected" | "reconnecting" => {
                attached.push(format!("{device}/{session}#{generation}"));
            }
            "disconnected" | "closed" => {}
            _ => return None,
        }
    }
    Some(attached)
}

/// What one look at the carrier sessions found.
#[derive(Debug, PartialEq, Eq)]
pub struct CarrierLook {
    /// Why the update waits, or `None` when the carrier does not hold it.
    pub busy: Option<String>,
    /// A session attached that the last look that read the list did not see
    /// (every session, when no look has read it yet).
    pub new_session: bool,
    /// This look is the one that found the bound passed (log it once).
    pub bound_passed: bool,
}

/// The carrier hold's state between looks.
#[derive(Debug, Default)]
pub struct CarrierHold {
    /// When attached sessions (or an unreadable list) first held the update.
    since: Option<Instant>,
    /// The sessions at the last look that could read them.
    seen: Option<BTreeSet<String>>,
    /// Whether the bound was already reported for this hold.
    passed: bool,
}

impl CarrierHold {
    /// One look at `now`: the attached sessions, or why they are unknown.
    pub fn look(&mut self, now: Instant, sessions: Result<Vec<String>, String>) -> CarrierLook {
        // No list read before (the first look, or every look so far failed,
        // maybe for longer than the bound): every attached session is new.
        let new_session = match (&sessions, &self.seen) {
            (Ok(ids), Some(seen)) => ids.iter().any(|id| !seen.contains(id)),
            (Ok(ids), None) => !ids.is_empty(),
            (Err(_), _) => false,
        };
        if let Ok(ids) = &sessions {
            self.seen = Some(ids.iter().cloned().collect());
        }
        let why = match &sessions {
            Ok(ids) if ids.is_empty() => {
                self.since = None;
                self.passed = false;
                return CarrierLook { busy: None, new_session, bound_passed: false };
            }
            Ok(ids) => format!("{} carrier session(s) attached", ids.len()),
            Err(e) => format!("carrier sessions unknown ({e})"),
        };
        let since = *self.since.get_or_insert(now);
        match CARRIER_MAX_HOLD.checked_sub(now.saturating_duration_since(since)) {
            Some(left) if !left.is_zero() => CarrierLook {
                busy: Some(format!("{why}, held at most {} s more", left.as_secs())),
                new_session,
                bound_passed: false,
            },
            _ => {
                let bound_passed = !self.passed;
                self.passed = true;
                CarrierLook { busy: None, new_session, bound_passed }
            }
        }
    }
}
