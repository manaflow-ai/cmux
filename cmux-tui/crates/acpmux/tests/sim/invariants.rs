//! What every seed must hold (HQ#6740). Each invariant reads what the run left: the app's view
//! (what it sent, what it was told), the daemon's log on the simulated disk, and what the agent
//! was given. An invariant is one entry of [`INVARIANTS`]; new ones plug in there.
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
//! see [`KNOWN_GAPS`].

use crate::agent::Given;
use crate::world::{Outcome, Run};
use std::collections::BTreeMap;

/// Found by the simulation and not fixed yet: each names its issue. The per-PR run leaves its
/// fault class off until the fix lands.
pub const KNOWN_GAPS: &[&str] = &[
    // A power loss right after a prompt is accepted loses it: the daemon answers
    // `prompt_accepted` before its `user_message` is flushed (no `flush_session` on the prompt
    // path), so the ack is not durable (HQ#6740: "The daemon acks on durable append"). The fix
    // is the durable journal with ack after durable, manaflow-ai/cmux#33919.
    "power loss after prompt_accepted (SIM_FAULTS=power)",
    // A retry under a logged prompt id without `_meta.acpmux.resend` runs the prompt again after
    // a restart: `Hub::knows_prompt` reads the log only for a resend (manaflow-ai/cmux#34548).
    "a bare resend after a restart is applied twice (SIM_RESEND=0)",
];

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
];

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
