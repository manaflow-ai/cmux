//! What every seed must hold, checked on its outcome. Each invariant is a property a person
//! sees: a reply that skips or repeats text, a prompt that runs twice or never, a chat stuck on
//! "reconnecting".

use std::collections::BTreeMap;
use std::time::Duration;

use crate::world::{Kind, Outcome};

/// The longest a fault may take to recover from: a silent link is declared dead within 6 s (a
/// probe every 2 s, answered within 4 s), its first redial goes at once, a failed one waits at
/// most one 5 s backoff step, and a dial that stalls fails at the 15 s attempt timeout (its link
/// open included): 6 + 5 + 15 = 26 s, under the bound. Before the 6 s silent-link death the
/// detection alone took up to 20 s (a 5 s interval and a 15 s deadline), and seed 479's silent
/// relay took 35 s to recover; it is kept in `seeds_that_found_bugs_hold`.
pub const RECOVERY_BOUND: Duration = Duration::from_secs(30);

pub struct Invariant {
    pub name: &'static str,
    pub check: fn(&Outcome) -> Result<(), String>,
}

pub const INVARIANTS: &[Invariant] = &[
    Invariant { name: "the run converges", check: ran },
    Invariant { name: "no event is lost", check: none_lost },
    Invariant { name: "no event arrives twice", check: none_twice },
    Invariant { name: "events arrive in order", check: in_order },
    Invariant { name: "every prompt runs once, start to result", check: prompts_once },
    Invariant { name: "a session ends only typed", check: ends_typed },
    Invariant { name: "a session ends only for a cause", check: ends_explained },
    Invariant { name: "every fault recovers in bound", check: recovered },
];

/// Not modelled yet, said in every run's summary.
pub const NOT_CHECKED: &[&str] = &[
    "the relay's own protocol (park, circuit join, batch frames): links are opened directly",
    "ticket and grant expiry (TicketCache reads the wall clock, not the paused one)",
    "a frame lost or corrupted inside a live link (fatal by design: SequenceGap, a Noise error)",
];

pub fn check(o: &Outcome) -> Result<(), String> {
    for inv in INVARIANTS {
        (inv.check)(o).map_err(|e| format!("{}: {e}", inv.name))?;
    }
    Ok(())
}

fn ran(o: &Outcome) -> Result<(), String> {
    o.error.clone().map_or(Ok(()), Err)
}

fn none_lost(o: &Outcome) -> Result<(), String> {
    let lost: Vec<u64> = (1..=o.log.len() as u64).filter(|seq| !o.seqs.contains(seq)).collect();
    if lost.is_empty() {
        Ok(())
    } else {
        Err(format!("{} of {} events never reached the app: {lost:?}", lost.len(), o.log.len()))
    }
}

fn none_twice(o: &Outcome) -> Result<(), String> {
    let mut counts: BTreeMap<u64, u32> = BTreeMap::new();
    for seq in &o.seqs {
        *counts.entry(*seq).or_default() += 1;
    }
    let twice: Vec<u64> = counts.into_iter().filter(|(_, n)| *n > 1).map(|(s, _)| s).collect();
    if twice.is_empty() { Ok(()) } else { Err(format!("delivered more than once: {twice:?}")) }
}

fn in_order(o: &Outcome) -> Result<(), String> {
    match o.seqs.windows(2).find(|w| w[1] != w[0] + 1) {
        None if o.seqs.first().is_none_or(|first| *first == 1) => Ok(()),
        None => Err(format!("the first event delivered was {:?}, not 1", o.seqs.first())),
        Some(w) => Err(format!("event {} came right after {}", w[1], w[0])),
    }
}

fn prompts_once(o: &Outcome) -> Result<(), String> {
    for id in 0..o.plan.prompts.len() as u32 {
        let started = o.log.iter().filter(|e| e.prompt == id && e.kind == Kind::Started).count();
        let results = o
            .log
            .iter()
            .filter(|e| e.prompt == id && matches!(e.kind, Kind::Result { .. }))
            .count();
        if started != 1 || results != 1 {
            return Err(format!("prompt {id}: started {started} times, {results} results"));
        }
    }
    Ok(())
}

fn ends_typed(o: &Outcome) -> Result<(), String> {
    if o.untyped_ends.is_empty() {
        Ok(())
    } else {
        Err(format!("sessions ended untyped: {:?}", o.untyped_ends))
    }
}

fn ends_explained(o: &Outcome) -> Result<(), String> {
    if o.ends.len() as u32 <= o.session_enders {
        Ok(())
    } else {
        Err(format!(
            "{} sessions ended ({:?}), and only {} faults could end one (a daemon restart, an \
             outage past the resume lease)",
            o.ends.len(),
            o.ends,
            o.session_enders
        ))
    }
}

fn recovered(o: &Outcome) -> Result<(), String> {
    for r in o.recoveries.iter().filter(|r| !r.interrupted) {
        match r.took {
            None => {
                return Err(format!("{} healed at {:?} and never recovered", r.kind, r.healed_at));
            }
            Some(took) if took > RECOVERY_BOUND => {
                return Err(format!(
                    "{} healed at {:?} took {:?} to recover (bound {:?})",
                    r.kind, r.healed_at, took, RECOVERY_BOUND
                ));
            }
            Some(_) => {}
        }
    }
    Ok(())
}
