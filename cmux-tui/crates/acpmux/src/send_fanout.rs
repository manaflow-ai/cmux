//! One caller sending the same prompt to many sessions in a short window
//! (`_acpmux/send_fanout`). `acpmux ls` lists every machine's sessions, and a script that read
//! that list as its own sent one prompt to each: on 2026-11-20 a boot hook's recovery prompt
//! went to sessions fleet-wide, other lanes' helpers among them. Nothing is refused: the send
//! CLI notes each send here, and the daemon answers once per caller and prompt with the count
//! and the machines when [`THRESHOLD`] distinct sessions got that prompt within [`WINDOW_MS`];
//! the CLI writes it to stderr.
//!
//! The cost is bounded: a ring of at most [`RING`] recent sends (a caller key, a hash of the
//! prompt, the target, its machine and when), pruned by age on each note; no history is read.

use std::collections::{BTreeSet, VecDeque};
use std::sync::{LazyLock, Mutex};

use serde_json::{Value, json};

/// Distinct sessions that make a fan-out.
pub const THRESHOLD: usize = 10;
/// How far back a send counts.
pub const WINDOW_MS: u64 = 60_000;
/// The most recent sends kept, all callers together.
pub const RING: usize = 512;

/// One send noted.
#[derive(Clone, Debug)]
struct Sent {
    caller: String,
    hash: String,
    session: String,
    machine: String,
    at: u64,
}

/// The recent sends, oldest first, and the (caller, hash) pairs already warned about.
#[derive(Debug, Default)]
pub struct Ring {
    sent: VecDeque<Sent>,
    warned: VecDeque<(String, String, u64)>,
}

/// A fan-out: how many distinct sessions got the prompt, and their machines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fanout {
    pub sessions: usize,
    pub machines: Vec<String>,
}

impl Ring {
    /// Notes `caller`'s send of the prompt hashed `hash` to `session` on `machine` at `now`;
    /// the fan-out the first time that caller's prompt reaches [`THRESHOLD`] sessions in the
    /// window, else None.
    pub fn note(
        &mut self,
        caller: &str,
        hash: &str,
        session: &str,
        machine: &str,
        now: u64,
    ) -> Option<Fanout> {
        let since = now.saturating_sub(WINDOW_MS);
        while self.sent.front().is_some_and(|s| s.at < since) {
            self.sent.pop_front();
        }
        while self.warned.front().is_some_and(|w| w.2 < since) {
            self.warned.pop_front();
        }
        if self.sent.len() >= RING {
            self.sent.pop_front();
        }
        self.sent.push_back(Sent {
            caller: caller.to_owned(),
            hash: hash.to_owned(),
            session: session.to_owned(),
            machine: machine.to_owned(),
            at: now,
        });
        if self.warned.iter().any(|(c, h, _)| c == caller && h == hash) {
            return None;
        }
        let same = || self.sent.iter().filter(|s| s.caller == caller && s.hash == hash);
        let sessions: BTreeSet<&str> = same().map(|s| s.session.as_str()).collect();
        if sessions.len() < THRESHOLD {
            return None;
        }
        let machines: BTreeSet<&str> = same().map(|s| s.machine.as_str()).collect();
        if self.warned.len() >= RING {
            self.warned.pop_front();
        }
        self.warned.push_back((caller.to_owned(), hash.to_owned(), now));
        Some(Fanout {
            sessions: sessions.len(),
            machines: machines.into_iter().map(str::to_owned).collect(),
        })
    }
}

static RECENT: LazyLock<Mutex<Ring>> = LazyLock::new(|| Mutex::new(Ring::default()));

/// The daemon's `_acpmux/send_fanout`: `params` name `hash`, `session` and `machine`, and
/// `from` when the connection proved no session (`caller`). Answers `{"fanout": null}`, or the
/// count and machines.
pub fn handle(caller: Option<&str>, params: &Value, now: u64) -> Value {
    let field = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or_default();
    let caller = caller
        .filter(|c| !c.is_empty())
        .or_else(|| Some(field("from")).filter(|f| !f.is_empty()))
        .unwrap_or("anonymous");
    let (hash, session) = (field("hash"), field("session"));
    if hash.is_empty() || session.is_empty() {
        return json!({"fanout": null});
    }
    let machine = Some(field("machine")).filter(|m| !m.is_empty()).unwrap_or("local");
    let mut ring = RECENT.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    match ring.note(caller, hash, session, machine, now) {
        Some(f) => json!({"fanout": {"sessions": f.sessions, "machines": f.machines}}),
        None => json!({"fanout": null}),
    }
}

/// The hash a send notes: the prompt's sha256, hex, cut to 16 bytes. Only the hash leaves
/// the CLI.
pub fn prompt_hash(text: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(text.as_bytes());
    digest.iter().take(16).map(|b| format!("{b:02x}")).collect()
}

/// The machine a send's target names: `HOST/NAME`'s host, else this one.
pub fn machine_of(session: &str) -> &str {
    match session.split_once('/') {
        Some((host, rest)) if !host.is_empty() && !rest.is_empty() => host,
        _ => "local",
    }
}

/// The stderr line for a fan-out the daemon answered (`{"fanout": {...}}`), if any.
pub fn warning(reply: &Value) -> Option<String> {
    let f = reply.get("fanout").filter(|f| !f.is_null())?;
    let n = f.get("sessions").and_then(Value::as_u64)?;
    let machines: Vec<&str> = f
        .get("machines")
        .and_then(Value::as_array)
        .map(|m| m.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let on = if machines.len() == 1 { "machine" } else { "machines" };
    Some(format!(
        "send: this prompt went to {n} sessions in {}s, on {} {on} ({}); `acpmux ls` lists every \
         machine's sessions, `--machine local` only this one's",
        WINDOW_MS / 1000,
        machines.len(),
        machines.join(", ")
    ))
}

#[cfg(test)]
#[path = "send_fanout_tests.rs"]
mod tests;
