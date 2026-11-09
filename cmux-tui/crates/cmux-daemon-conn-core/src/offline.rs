//! What happens to a person's action while the session daemon cannot be
//! reached (Leo, 2026-11-09: "i couldnt close the background task tab"):
//! it never shows, fails at once and comes back. The app shows the action
//! pending (its intent stays on the visible state), holds it while the
//! daemon is disconnected or connected but not answering, and replays it once,
//! in order, when the daemon answers again. Past [`HOLD_BOUND_MS`] it gives
//! the action up with one refusal the person sees, and the visible state
//! returns once. One transition each way, never a flip.
//!
//! The app keeps the held list (`DaemonStore` `HeldIntents`) and asks here:
//! - [`disposition`]: hold or reject a failed command, by its error's kind
//!   (the Swift `DaemonError` case name, as [`crate::errors::KINDS`]);
//! - [`sweep`]: which held actions replay now and which expire;
//! - [`text`]: the pending label and the refusal, in the person's words.

use serde::{Deserialize, Serialize};

/// How long an action waits for an unreachable daemon before it is given
/// up, milliseconds. Two minutes covers a daemon restart, a version handoff
/// and a short restart loop; past it the person is told once instead of
/// left waiting on an action that may never land.
pub const HOLD_BOUND_MS: u64 = 120_000;

/// What a failed command does with its shown intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Disposition {
    /// The daemon was not reached: keep the intent shown, pending, and
    /// replay it when the daemon answers again.
    Hold,
    /// The daemon refused it (or the error says nothing about reach): the
    /// intent leaves and the visible state returns.
    Reject,
}

/// Kinds that mean the command never reached a daemon that could answer.
const UNREACHED: [&str; 4] =
    ["notConnected", "connectionClosed", "daemonShutdown", "connectFailed"];

/// Hold or reject a command that failed with error `kind`. A missed
/// deadline (`timedOut`) holds only while the heartbeat says the daemon is
/// not answering (`answering` false): from a daemon that answers, a late
/// reply is load, which the caller settles with the next snapshot.
pub fn disposition(kind: &str, answering: bool) -> Disposition {
    if UNREACHED.contains(&kind) || (kind == "timedOut" && !answering) {
        Disposition::Hold
    } else {
        Disposition::Reject
    }
}

/// One held action, in the order the person made them.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Held {
    pub id: String,
    /// When it was first held (the app's monotonic clock, milliseconds).
    pub held_at_ms: u64,
    /// Its replay is in flight: neither replayed again nor expired until
    /// its outcome is known (a replay that fails to reach the daemon again
    /// goes back to held with its first `held_at_ms`).
    #[serde(default)]
    pub replaying: bool,
}

/// What to do with the held actions now.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Sweep {
    /// Send again now, in this order; the app marks each replaying.
    pub replay: Vec<String>,
    /// Past the bound: give up, one refusal each, the visible state returns.
    pub expire: Vec<String>,
    /// When the earliest still-held action expires (absolute, the app's
    /// clock); `None` when nothing waits on the clock.
    pub next_check_ms: Option<u64>,
}

/// The held actions' fate at `now_ms`. `reachable`: the daemon is connected
/// and answering. An action past `bound_ms` expires even when the daemon is
/// back, so a person never sees an action land minutes after they were told
/// it would not.
pub fn sweep(held: &[Held], now_ms: u64, reachable: bool, bound_ms: u64) -> Sweep {
    let mut out = Sweep::default();
    for entry in held {
        if entry.replaying {
            continue;
        }
        let expires_at = entry.held_at_ms.saturating_add(bound_ms);
        if now_ms >= expires_at {
            out.expire.push(entry.id.clone());
        } else if reachable {
            out.replay.push(entry.id.clone());
        } else {
            out.next_check_ms = Some(out.next_check_ms.map_or(expires_at, |at| at.min(expires_at)));
        }
    }
    out
}

/// The words for one held action.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Text {
    /// The pending action, for the health model's list ("Close Background task").
    pub pending: String,
    /// The health line's tail ("will close Background task when back").
    pub when_back: String,
    /// The one refusal past the bound.
    pub refusal: String,
}

/// The prefix of every refusal: what failed, before what was not done.
pub const REFUSAL_PREFIX: &str = "cmux couldn't reach its session service";

/// The words for `action` (`close`, `rename`, `move`, `pin`, `unpin`,
/// `color`, `icon`; anything else is shown as given) on `name` (a tab or
/// screen title).
pub fn text(action: &str, name: &str) -> Text {
    let (verb, done) = match action {
        "close" => ("Close", format!("{name} wasn't closed")),
        "rename" => ("Rename", format!("{name} wasn't renamed")),
        "move" => ("Move", format!("{name} wasn't moved")),
        "pin" => ("Pin", format!("{name} wasn't pinned")),
        "unpin" => ("Unpin", format!("{name} wasn't unpinned")),
        "color" => ("Change the color of", format!("{name}'s color wasn't changed")),
        "icon" => ("Change the icon of", format!("{name}'s icon wasn't changed")),
        other => {
            return Text {
                pending: other.to_string(),
                when_back: format!("will {} when back", lowercase_first(other)),
                refusal: format!("{REFUSAL_PREFIX}; \u{201c}{other}\u{201d} wasn't done"),
            };
        }
    };
    let pending = format!("{verb} {name}");
    Text {
        when_back: format!("will {} when back", lowercase_first(&pending)),
        refusal: format!("{REFUSAL_PREFIX}; {done}"),
        pending,
    }
}

fn lowercase_first(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn held(id: &str, at: u64) -> Held {
        Held { id: id.to_string(), held_at_ms: at, replaying: false }
    }

    #[test]
    fn daemon_down_holds_a_close_instead_of_rejecting_it() {
        for kind in ["notConnected", "connectionClosed", "daemonShutdown", "connectFailed"] {
            assert_eq!(disposition(kind, true), Disposition::Hold, "{kind}");
            assert_eq!(disposition(kind, false), Disposition::Hold, "{kind}");
        }
    }

    #[test]
    fn a_late_reply_holds_only_while_the_daemon_does_not_answer() {
        assert_eq!(disposition("timedOut", false), Disposition::Hold);
        assert_eq!(disposition("timedOut", true), Disposition::Reject);
    }

    #[test]
    fn a_refusal_is_rejected() {
        for kind in ["command", "malformedResponse", "wrongApp", "terminalStartTimedOut", "other"] {
            assert_eq!(disposition(kind, false), Disposition::Reject, "{kind}");
        }
    }

    #[test]
    fn while_unreachable_nothing_replays_and_the_bound_is_the_next_check() {
        let list = [held("a", 1_000), held("b", 5_000)];
        let out = sweep(&list, 10_000, false, HOLD_BOUND_MS);
        assert!(out.replay.is_empty());
        assert!(out.expire.is_empty());
        assert_eq!(out.next_check_ms, Some(1_000 + HOLD_BOUND_MS));
    }

    #[test]
    fn reconnect_replays_once_in_order() {
        let mut list = vec![held("a", 1_000), held("b", 2_000)];
        let out = sweep(&list, 3_000, true, HOLD_BOUND_MS);
        assert_eq!(out.replay, ["a", "b"]);
        assert_eq!(out.next_check_ms, None);
        // The app marks them replaying: a second sweep (another answering
        // edge) before their outcome sends nothing again.
        for entry in &mut list {
            entry.replaying = true;
        }
        let again = sweep(&list, 3_500, true, HOLD_BOUND_MS);
        assert!(again.replay.is_empty(), "no double replay");
        assert!(again.expire.is_empty());
    }

    #[test]
    fn past_the_bound_one_refusal_and_never_a_late_replay() {
        let list = [held("a", 0), held("b", 60_000)];
        let out = sweep(&list, HOLD_BOUND_MS, true, HOLD_BOUND_MS);
        assert_eq!(out.expire, ["a"]);
        assert_eq!(out.replay, ["b"]);
        // The app drops an expired one: the next sweep cannot refuse it twice.
        let rest = [held("b", 60_000)];
        let later = sweep(&rest, HOLD_BOUND_MS + 1, false, HOLD_BOUND_MS);
        assert!(later.expire.is_empty());
        assert_eq!(later.next_check_ms, Some(60_000 + HOLD_BOUND_MS));
    }

    #[test]
    fn a_replay_in_flight_does_not_expire_under_it() {
        let list = [Held { id: "a".into(), held_at_ms: 0, replaying: true }];
        let out = sweep(&list, HOLD_BOUND_MS * 2, false, HOLD_BOUND_MS);
        assert!(out.expire.is_empty());
        assert!(out.replay.is_empty());
        assert_eq!(out.next_check_ms, None);
    }

    #[test]
    fn the_words_name_the_action_and_its_target() {
        let close = text("close", "Background task");
        assert_eq!(close.pending, "Close Background task");
        assert_eq!(close.when_back, "will close Background task when back");
        assert_eq!(
            close.refusal,
            "cmux couldn't reach its session service; Background task wasn't closed"
        );
        let other = text("Reorder tabs", "x");
        assert_eq!(other.pending, "Reorder tabs");
        assert_eq!(other.when_back, "will reorder tabs when back");
        assert_eq!(
            other.refusal,
            "cmux couldn't reach its session service; \u{201c}Reorder tabs\u{201d} wasn't done"
        );
    }
}
