//! An owner that answers `identify` but whose workspace registry lock never
//! comes back (https://github.com/manaflow-ai/cmux/issues/32621).
//!
//! `identify` and `ping` are built to answer without the registry lock, so an
//! owner deadlocked on it still reads as ready: ensure reused it, every
//! workspace request timed out, and a reinstall did not help. `server-stats`
//! also answers without the lock and names the current holder with how long
//! it has held it (`registry_lock.holder.held_for_us`, every server since
//! `server-stats` exists). No request path holds the registry for anything
//! near `WEDGED_REGISTRY_HOLD`: a holder past it is a lock that will not come
//! back, and the owner is reported unavailable so the app replaces it
//! (`--replace-unresponsive`, `UnresponsiveOwnerWatch`).

use std::time::{Duration, Instant};

use serde_json::Value;

use super::OwnerSpec;

/// How long one registry hold may last before the owner counts as wedged:
/// far past any request or startup batch, which hold it for milliseconds to
/// seconds, so a slow owner is never replaced.
pub(super) const WEDGED_REGISTRY_HOLD: Duration = Duration::from_secs(120);

/// Whether the session's owner reports a registry lock held for at least
/// `WEDGED_REGISTRY_HOLD`. Any failure to read the stats (an older owner, a
/// busy one, a closed connection) is not evidence and keeps the owner.
pub(super) fn registry_wedged(spec: &OwnerSpec, deadline: Instant) -> bool {
    let Ok(stream) =
        cmux_tui_core::server::connect_session_socket(&spec.socket, spec.socket_is_derived)
    else {
        return false;
    };
    let request = serde_json::json!({"id":1,"cmd":"server-stats"});
    super::identify::exchange(stream, deadline, &request)
        .ok()
        .is_some_and(|stats| stats_show_wedged(&stats))
}

/// `server-stats` data whose registry holder has held the lock for at least
/// `WEDGED_REGISTRY_HOLD`.
pub(super) fn stats_show_wedged(stats: &Value) -> bool {
    stats
        .pointer("/registry_lock/holder/held_for_us")
        .and_then(Value::as_u64)
        .is_some_and(|held| Duration::from_micros(held) >= WEDGED_REGISTRY_HOLD)
}
