//! What every seed must hold (HQ#6740). Each invariant reads what the run left: the app's view
//! (what it sent, what it was told), the daemon's log on the simulated disk, and what the agent
//! was given. An invariant is one entry of [`INVARIANTS`]; new ones plug in there, each with a
//! broken run it must catch in `sim.rs`'s `MUTATIONS` (a check never shown to fail proves nothing).
//!
//! Not checked yet, with the hook each needs:
//!
//! - Stale epochs are rejected ([`NOT_CHECKED`]): needs the per-session seq log and its
//!   epoch from the idempotent-delivery work (HQ#6740). Once a record or a client request carries
//!   the daemon incarnation's epoch, the check is: no record in the log was written under an
//!   epoch older than one already in it, and every request the app sends under an old epoch is
//!   refused. The simulation already restarts the daemon at any step; the app only has to send
//!   its last epoch.
//! - The bare resend (the web pane's: same id, no `_meta.acpmux.resend`): `SIM_RESEND=0` runs it.
//!   It holds once the daemon reads a logged prompt id as a resend whatever the flag says
//!   (manaflow-ai/cmux#34548); then CI gates on both.
//!
//! Known gaps the simulation shows today (off in the per-PR run, `SIM_FAULTS=power` shows them):
//! see [`KNOWN_GAPS`]. A seed counts as one only when it holds once the gap's cause is taken
//! away ([`known_gaps_of`]), so a new failure under the same options still fails the run.

use crate::agent::Given;
use crate::world::{self, Options, Outcome, Run};
use std::collections::BTreeMap;

/// A gap the simulation found and nobody has fixed yet, with its issue.
pub struct KnownGap {
    pub name: &'static str,
    /// The same options with the gap's cause taken away, when these options can show it. A
    /// seed that fails, and holds when rerun this way, shows the gap; a seed that still fails
    /// is a real failure, and the sweep goes red for it.
    pub without: fn(&Options) -> Option<Options>,
}

/// Found by the simulation and not fixed yet: each names its issue. The per-PR run leaves its
/// fault class off until the fix lands; the sweep runs it and counts the seeds that show it.
pub const KNOWN_GAPS: &[KnownGap] = &[
    // A power loss right after a prompt is accepted loses it: the daemon answers
    // `prompt_accepted` before its `user_message` is flushed (no `flush_session` on the prompt
    // path), so the ack is not durable (HQ#6740: "The daemon acks on durable append"). What a
    // lost record leads to is the same gap: the prompt is lost, a retry of it is not known and
    // runs again, or the saved metadata names a seq whose records are gone, so the log starts
    // past 1. The fix is the durable journal with ack after durable, manaflow-ai/cmux#33919.
    KnownGap {
        name: "power loss after prompt_accepted (SIM_FAULTS=power)",
        without: power_as_crash,
    },
    // A retry under a logged prompt id without `_meta.acpmux.resend` runs the prompt again after
    // a restart: `Hub::knows_prompt` reads the log only for a resend (manaflow-ai/cmux#34548).
    KnownGap {
        name: "a bare resend after a restart is applied twice (SIM_RESEND=0)",
        without: flagged_resend,
    },
];

/// A power loss as a crash at the same step: it keeps what was written.
fn power_as_crash(o: &Options) -> Option<Options> {
    (o.faults.0.power_loss && o.power_drops_unflushed)
        .then_some(Options { power_drops_unflushed: false, ..*o })
}

/// Every retry carries `_meta.acpmux.resend`, as the Mac's prompt journal sends it.
fn flagged_resend(o: &Options) -> Option<Options> {
    (!o.resend).then_some(Options { resend: true, ..*o })
}

/// The known gaps that explain a failing seed under `opts`: those these options can show, when
/// the seed holds with all of them taken away. Empty when it still fails: a real failure.
pub fn known_gaps_of(seed: u64, opts: &Options) -> Vec<&'static str> {
    let mut without = *opts;
    let mut names = Vec::new();
    for gap in KNOWN_GAPS {
        if let Some(o) = (gap.without)(&without) {
            without = o;
            names.push(gap.name);
        }
    }
    if names.is_empty() || check(&world::run(seed, &without)).is_err() {
        return Vec::new();
    }
    names
}

pub struct Invariant {
    pub name: &'static str,
    pub check: fn(&Run) -> Result<(), String>,
}

pub const INVARIANTS: &[Invariant] = &[
    Invariant { name: "the run finished", check: ran },
    Invariant { name: "no prompt or steer is lost", check: none_lost },
    Invariant { name: "no prompt or steer is applied twice", check: none_twice },
    Invariant { name: "event seq has no gaps", check: seq_gap_free },
    Invariant {
        name: "a resumed chat ends as an uninterrupted one",
        check: resumed_equals_uninterrupted,
    },
    Invariant { name: "every hub is gone with its simulation", check: hubs_dropped },
    Invariant {
        name: "every send is answered within the liveness budget once faults heal",
        check: answered_within_budget,
    },
];

/// How long after a send is due, or after the plan's last fault heals if that is later, its
/// answer may take. Faults in the plan always heal, so "no prompt or steer is lost" alone holds
/// for a client that takes until [`crate::app::GIVE_UP`] (30 min) to get through: a reconnect
/// loop that never settles, or a retry that keeps picking the dead path, passes it. This bound
/// is the liveness half (a deterministic simulator's "no state convergence" check, reading note
/// hq docs/reading/2026-11-21-tigerbeetle-vopr-simulation.md): once the network and daemon are
/// healthy, the system must converge in bounded time, not just eventually.
///
/// The app's own waits set its floor: QUIET (20 s) to notice a silent connection, a 5 s connect
/// timeout, 500 ms backoff, then the replayed turn; the sweep's latest answer is printed in the
/// run's summary (`sim: latest answer after heal`), so the budget can be tightened on data.
pub const LIVENESS_BUDGET: std::time::Duration = std::time::Duration::from_secs(180);

/// How long past its deadline (due time or last heal, whichever is later) each answered send
/// took: (prompt id, its lateness). Sends with no answer are left to `none_lost`.
pub fn answer_lateness(o: &Outcome) -> Vec<(String, std::time::Duration)> {
    let Some(ready) = o.app.ready_at else { return Vec::new() };
    o.app
        .items
        .iter()
        .filter_map(|(s, i)| {
            let at = i.answered_at?;
            let from = ready + s.at.max(o.app.calm_after);
            Some((s.prompt_id.clone(), at.saturating_sub(from)))
        })
        .collect()
}

fn answered_within_budget(run: &Run) -> Result<(), String> {
    for o in std::iter::once(&run.faulty).chain(run.uninterrupted.as_ref()) {
        for (id, late) in answer_lateness(o) {
            if late > LIVENESS_BUDGET {
                return Err(format!(
                    "{id} was answered {} after it was due and every fault had healed \
                     (budget {}): the system recovers, but not in bounded time",
                    world::human(late),
                    world::human(LIVENESS_BUDGET)
                ));
            }
        }
    }
    Ok(())
}

/// Invariants the design asks for that no check covers yet, each with the hook it needs (see the
/// module text). Every run prints them, so a green run never reads as having checked them.
pub const NOT_CHECKED: &[&str] =
    &["stale epochs are rejected (needs the daemon's epoch from idempotent delivery, HQ#6740)"];

/// Every invariant on `run`: the first that fails, by name.
pub fn check(run: &Run) -> Result<(), String> {
    for inv in INVARIANTS {
        (inv.check)(run).map_err(|e| format!("{}: {e}", inv.name))?;
    }
    Ok(())
}

/// A hub kept alive past its simulation keeps its audit thread, runtime and fds (~13 MB a
/// seed): the known-gap sweep's runner ran out of memory on it (a strong `Hub` in the session
/// tap, `hub/tap.rs`).
fn hubs_dropped(run: &Run) -> Result<(), String> {
    let (alive, built) = run.hubs;
    if alive > 0 {
        return Err(format!("{alive} of {built} hubs outlived the simulation"));
    }
    Ok(())
}

fn ran(run: &Run) -> Result<(), String> {
    for (which, o) in [("faulty", Some(&run.faulty)), ("uninterrupted", run.uninterrupted.as_ref())]
    {
        let Some(o) = o else { continue };
        if let Some(e) = &o.error {
            return Err(format!("the {which} simulation stopped: {e}"));
        }
        if o.app.session.is_none() {
            return Err(format!("the {which} run never got its chat"));
        }
    }
    Ok(())
}

/// The app's prompt id of what the agent was given. The daemon keeps the client's id to itself
/// (the agent's `session/prompt` carries none), so a given prompt is known by its text, which
/// is unique per send ("task N").
fn prompt_id_of(o: &Outcome, g: &Given) -> Option<String> {
    g.prompt_id.clone().or_else(|| {
        o.app.items.iter().find(|(s, _)| s.text == g.text).map(|(s, _)| s.prompt_id.clone())
    })
}

/// How many times the agent was given each prompt id.
fn applied(o: &Outcome) -> BTreeMap<String, usize> {
    let mut n = BTreeMap::new();
    for g in &o.given {
        if let Some(id) = prompt_id_of(o, g) {
            *n.entry(id).or_default() += 1;
        }
    }
    n
}

/// The chat's `user_message` records under each prompt id.
fn logged(o: &Outcome) -> BTreeMap<String, usize> {
    let mut n = BTreeMap::new();
    for records in o.log.values() {
        for r in records.iter().filter(|r| r.dir == "mux" && r.kind == "user_message") {
            if let Some(id) = r.msg["promptId"].as_str() {
                *n.entry(id.to_owned()).or_default() += 1;
            }
        }
    }
    n
}

/// Every send has its answer, and every answered one reached the agent and the log.
fn none_lost(run: &Run) -> Result<(), String> {
    let o = &run.faulty;
    let (applied, logged) = (applied(o), logged(o));
    for (send, item) in &o.app.items {
        let id = &send.prompt_id;
        match &item.outcome {
            None => {
                return Err(format!(
                    "{id} never got its answer (sent {} times, accepted: {}, logged {}, given {})",
                    item.sent,
                    item.accepted,
                    logged.get(id).unwrap_or(&0),
                    applied.get(id).unwrap_or(&0)
                ));
            }
            Some(Err(e)) => return Err(format!("{id} was refused: {e}")),
            Some(Ok(stop)) if stop == "cancelled" => {
                return Err(format!("{id} ended cancelled though nobody stopped it"));
            }
            Some(Ok(_)) => {}
        }
        if applied.get(id).copied().unwrap_or(0) == 0 {
            return Err(format!("{id} was answered but the agent never got it"));
        }
        if logged.get(id).copied().unwrap_or(0) == 0 {
            return Err(format!("{id} reached the agent but its user_message is not in the log"));
        }
    }
    Ok(())
}

fn none_twice(run: &Run) -> Result<(), String> {
    let o = &run.faulty;
    for (id, n) in applied(o) {
        if n > 1 {
            let incarnations: Vec<(u64, bool)> = o
                .given
                .iter()
                .filter(|g| prompt_id_of(o, g).as_deref() == Some(&id))
                .map(|g| (g.incarnation, g.steer))
                .collect();
            return Err(format!(
                "the agent was given {id} {n} times (daemon incarnation, as a steer: {incarnations:?})"
            ));
        }
    }
    for (id, n) in logged(o) {
        if n > 1 {
            return Err(format!("{id} has {n} user_message records"));
        }
    }
    Ok(())
}

fn seq_gap_free(run: &Run) -> Result<(), String> {
    for o in std::iter::once(&run.faulty).chain(run.uninterrupted.as_ref()) {
        for (chat, records) in &o.log {
            let first = records.first().map_or(1, |r| r.seq);
            if first != 1 {
                return Err(format!("chat {chat}'s log starts at seq {first}"));
            }
            for (want, r) in (1..).zip(records) {
                if r.seq != want {
                    return Err(format!(
                        "chat {chat}: seq {} after {} ({} {})",
                        r.seq,
                        want - 1,
                        r.dir,
                        r.kind
                    ));
                }
            }
        }
    }
    Ok(())
}

/// What a chat ends as, whatever the path: each prompt id, how many times the agent applied it,
/// and whether it ended answered; the chats made; the turns still open.
fn end_state(o: &Outcome) -> (Vec<(String, usize, bool)>, usize, usize) {
    let applied = applied(o);
    let prompts = o
        .app
        .items
        .iter()
        .map(|(s, i)| {
            let id = s.prompt_id.clone();
            let n = applied.get(&id).copied().unwrap_or(0);
            (id, n, matches!(&i.outcome, Some(Ok(stop)) if stop != "cancelled"))
        })
        .collect();
    let open = o
        .log
        .values()
        .map(|records| {
            let started = records.iter().filter(|r| r.kind == "turn_started").count();
            let ended = records.iter().filter(|r| r.kind == "turn_result").count();
            started.saturating_sub(ended)
        })
        .sum();
    (prompts, o.log.len(), open)
}

fn resumed_equals_uninterrupted(run: &Run) -> Result<(), String> {
    let Some(calm) = &run.uninterrupted else { return Ok(()) };
    let (a, b) = (end_state(&run.faulty), end_state(calm));
    if a != b {
        return Err(format!("with faults it ended as {a:?}; without, as {b:?}"));
    }
    Ok(())
}
