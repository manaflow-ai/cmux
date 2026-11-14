//! What happens to a person's action while the session daemon cannot be
//! reached (Leo, 2026-11-09: "i couldnt close the background task tab"):
//! it never shows, fails at once and comes back. The app shows the action
//! pending (its intent stays on the visible state), holds it while the
//! daemon is disconnected or connected but not answering, and replays it once,
//! in order, when the daemon answers again. Past [`HOLD_BOUND_MS`] it gives
//! the action up with one refusal the person sees, and the visible state
//! returns once. One transition each way, never a flip.
//!
//! A request that timed out, or whose reply a closed connection lost, may
//! already sit in the daemon's queue: a
//! client timeout cancels nothing there. Such an action is `sent`, and it is
//! never replayed blindly nor refused for certain: once the daemon answers,
//! the app settles it from the daemon's state (replay only if it did not
//! land); past the bound with no answer, the one notice says it may still
//! happen.
//!
//! The app keeps the held list (`DaemonStore` `HeldIntents`) and asks here:
//! - [`disposition`]: hold or reject a failed command, by its error's kind
//!   (the Swift `DaemonError` case name, as [`crate::errors::KINDS`]);
//! - [`sweep`]: which held actions replay now and which expire;
//! - [`requeue`]: a replay or settle that failed, back on the held list;
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
    /// intent leaves and the visible state returns. When the same reply says
    /// `sent` (a late reply from a daemon that answers), the action may still
    /// land, so the person sees [`Text::unsure`], never [`Text::refusal`].
    Reject,
}

/// Kinds that mean the command never reached a daemon that could answer.
const UNREACHED: [&str; 4] =
    ["notConnected", "connectionClosed", "daemonShutdown", "connectFailed"];

/// The command may have reached the daemon before it failed with `kind`, so
/// a held copy is [`Held::sent`]: a missed deadline, or a connection that
/// closed (or a daemon that shut down) with the request written and its
/// reply lost. Only a connection that never opened (`notConnected`,
/// `connectFailed`) proves the daemon never had it.
pub fn maybe_sent(kind: &str) -> bool {
    matches!(kind, "timedOut" | "connectionClosed" | "daemonShutdown")
}

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
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Held {
    pub id: String,
    /// When it was first held (the app's monotonic clock, milliseconds).
    pub held_at_ms: u64,
    /// Its replay is in flight: neither replayed again nor expired until
    /// its outcome is known (a replay that fails to reach the daemon again
    /// goes back to held with its first `held_at_ms`).
    #[serde(default)]
    pub replaying: bool,
    /// It may have reached the daemon ([`maybe_sent`]): settled from the
    /// daemon's state instead of replayed, and never refused for certain.
    #[serde(default)]
    pub sent: bool,
    /// Its settle is in flight (the app reads the daemon's state): neither
    /// settled again nor expired until that read's outcome is known.
    #[serde(default)]
    pub settling: bool,
}

/// A replay or settle of `entry` failed with error `kind` and it goes back on
/// the held list: no longer in flight, its first `held_at_ms` kept, and still
/// [`Held::sent`] if this attempt (or any before it) may have reached the
/// daemon. A failure the daemon refused ([`disposition`] says reject) is
/// dropped instead of requeued.
pub fn requeue(entry: &Held, kind: &str) -> Held {
    Held {
        replaying: false,
        settling: false,
        sent: entry.sent || maybe_sent(kind),
        ..entry.clone()
    }
}

/// What to do with the held actions now.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Sweep {
    /// Send again now, in this order; the app marks each replaying.
    pub replay: Vec<String>,
    /// Past the bound: give up, one refusal each, the visible state returns.
    pub expire: Vec<String>,
    /// Sent ones with the daemon answering again before the bound: read
    /// whether each landed from the daemon's state, and replay only those
    /// that did not; the app marks each settling.
    pub settle: Vec<String>,
    /// Sent ones past the bound with no answer: give up with the notice
    /// that it may still happen ([`Text::unsure`]); the visible state returns
    /// and the daemon's next state settles it.
    pub unsure: Vec<String>,
    /// When the earliest still-held action expires (absolute, the app's
    /// clock); `None` when nothing waits on the clock.
    pub next_check_ms: Option<u64>,
}

/// The held actions' fate at `now_ms`. `reachable`: the daemon is connected
/// and answering. An action past `bound_ms` expires even when the daemon is
/// back (a late sweep, after the app was suspended or its timer ran late),
/// so a person never sees an action replayed minutes after they were told
/// it would not land; a sent one gets the may-still-happen notice instead.
pub fn sweep(held: &[Held], now_ms: u64, reachable: bool, bound_ms: u64) -> Sweep {
    let mut out = Sweep::default();
    for entry in held {
        if entry.replaying || entry.settling {
            continue;
        }
        let expires_at = entry.held_at_ms.saturating_add(bound_ms);
        if now_ms >= expires_at {
            let list = if entry.sent { &mut out.unsure } else { &mut out.expire };
            list.push(entry.id.clone());
        } else if entry.sent && reachable {
            out.settle.push(entry.id.clone());
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
    /// The notice past the bound for an action that may have reached the
    /// daemon: not a refusal, since it may still land.
    pub unsure: String,
}

/// The prefix of every refusal: what failed, before what was not done.
pub const REFUSAL_PREFIX: &str = "cmux couldn't reach its session service";

/// The words for `action` (`close`, `rename`, `move`, `pin`, `unpin`,
/// `color`, `icon`; anything else is shown as given) on `name` (a tab or
/// screen title).
pub fn text(action: &str, name: &str) -> Text {
    let (verb, done, maybe) = match action {
        "close" => ("Close", "wasn't closed", "may still close"),
        "rename" => ("Rename", "wasn't renamed", "may still be renamed"),
        "move" => ("Move", "wasn't moved", "may still move"),
        "pin" => ("Pin", "wasn't pinned", "may still be pinned"),
        "unpin" => ("Unpin", "wasn't unpinned", "may still be unpinned"),
        "color" => ("Change the color of", "'s color wasn't changed", "'s color may still change"),
        "icon" => ("Change the icon of", "'s icon wasn't changed", "'s icon may still change"),
        other => {
            return Text {
                pending: other.to_string(),
                when_back: format!("will {} when back", lowercase_first(other)),
                refusal: format!("{REFUSAL_PREFIX}; \u{201c}{other}\u{201d} wasn't done"),
                unsure: format!(
                    "{REFUSAL_PREFIX}; \u{201c}{other}\u{201d} may still happen when it's back"
                ),
            };
        }
    };
    // "Tab's color", "Tab wasn't closed": the possessive joins without a space.
    let join = |words: &str| {
        if words.starts_with('\'') { format!("{name}{words}") } else { format!("{name} {words}") }
    };
    let pending = format!("{verb} {name}");
    Text {
        when_back: format!("will {} when back", lowercase_first(&pending)),
        refusal: format!("{REFUSAL_PREFIX}; {}", join(done)),
        unsure: format!("{REFUSAL_PREFIX}; {} when it's back", join(maybe)),
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
mod tests;
