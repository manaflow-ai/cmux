//! Machines whose own remote chain refused a start this daemon forwarded there: the sandbox
//! canary or its keeper said no (`hub/remote_sandbox.rs`, reason `remote.sandbox_refused`), and
//! every later remote start there is refused the same way until that machine is fixed. Such a
//! machine answers, so `peer_down` never sees it, yet an automatic pick that chose it started
//! nothing (coordinator, 2026-11-18: automatic placement picked a host that refuses every remote
//! start). While its record is fresh (`FRESH_MS`) the automatic pick ranks it after the machines with no
//! record that stand as well against their lane cap and room (`placement::place_demoting`),
//! listed with the reason and the time; it is never taken out, so a record never makes "no
//! machine has room". A
//! start there that works clears it; a start that names the machine still goes there, which is
//! how it clears once the machine is fixed. A refusal of the start's own inputs
//! (`START_REASON`) is never recorded: it says nothing about the machine.
//!
//! In memory on the daemon that forwards starts (`Hub::start_refusals`), keyed by canonical host
//! name, at most `MAX` machines: no disk, and constant cost whatever the number of sessions.

use crate::rpc::RpcError;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Mutex;

/// The reason a refusal by the machine's own remote chain carries (`remote_sandbox.rs`
/// `Refused::Host`: its sandbox canary, keeper, bwrap or platform): recorded here.
pub const REASON: &str = "remote.sandbox_refused";

/// The reason a refusal of the start's own inputs carries (`remote_sandbox.rs` `Refused::Start`:
/// its folder, session id, a profile argument or env value, `sr` options): the same start is
/// refused on every machine, so it says nothing about this one and is never recorded.
pub const START_REASON: &str = "remote.start_refused";

/// How long a refusal keeps the machine last in the automatic pick: 30 minutes.
pub const FRESH_MS: u64 = 30 * 60 * 1000;

/// The most machines kept; the oldest record goes first.
const MAX: usize = 64;

/// The most characters of a refusal's text kept: a canary's refusal quotes its stderr.
const WHY_CHARS: usize = 400;

/// One refusal: when (Unix ms) and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub at_ms: u64,
    pub why: String,
}

#[derive(Default)]
pub struct StartRefusals(Mutex<HashMap<String, Refusal>>);

/// Whether `e` is a refusal by the machine's own remote chain (`REASON`).
pub fn is_chain_refusal(e: &RpcError) -> bool {
    reason(e.data.as_ref()) == Some(REASON)
}

/// The `reason` of an error's `data`.
pub fn reason(data: Option<&Value>) -> Option<&str> {
    data?.get("reason")?.as_str()
}

impl StartRefusals {
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<String, Refusal>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `host`'s remote chain refused a start at `at_ms`, saying `why`.
    pub fn record(&self, host: &str, at_ms: u64, why: &str) {
        let why: String = why.chars().take(WHY_CHARS).collect();
        let mut map = self.map();
        map.insert(crate::placement::canonical(host), Refusal { at_ms, why });
        while map.len() > MAX {
            let Some(oldest) = map.iter().min_by_key(|(_, r)| r.at_ms).map(|(k, _)| k.clone())
            else {
                break;
            };
            map.remove(&oldest);
        }
    }

    /// A start on `host` worked: its record goes.
    pub fn clear(&self, host: &str) {
        self.map().remove(&crate::placement::canonical(host));
    }

    /// `host`'s refusal while it is fresh at `now_ms`; a stale one is dropped.
    pub fn fresh(&self, host: &str, now_ms: u64) -> Option<Refusal> {
        let key = crate::placement::canonical(host);
        let mut map = self.map();
        let r = map.get(&key)?.clone();
        if now_ms.saturating_sub(r.at_ms) >= FRESH_MS {
            map.remove(&key);
            return None;
        }
        Some(r)
    }

    /// The outcome of a start forwarded to `host`: a chain refusal is recorded, a start that
    /// worked clears the record, any other failure leaves it as it was.
    pub fn note<T>(&self, host: &str, result: &Result<T, RpcError>, now_ms: u64) {
        match result {
            Ok(_) => self.clear(host),
            Err(e) if is_chain_refusal(e) => self.record(host, now_ms, core(host, &e.message)),
            Err(_) => {}
        }
    }
}

/// The refusal itself out of a forwarded start's message (`remote_guard/hint.rs` `refused_by`:
/// `refused by HOST: REASON; nothing was started. Instead:` and the command on later lines).
fn core<'a>(host: &str, message: &'a str) -> &'a str {
    let first = message.lines().next().unwrap_or_default();
    let first = first.strip_prefix(&format!("refused by {host}: ")).unwrap_or(first);
    first.split("; nothing was started").next().unwrap_or(first)
}

/// What the pick lists for a machine with a fresh refusal (`hosts[].refused`), at `now_ms`.
pub fn line(r: &Refusal, now_ms: u64) -> String {
    let minutes = now_ms.saturating_sub(r.at_ms) / 60_000;
    format!(
        "its remote chain refused a start at {} ({minutes} min ago; picked last for 30 min, or until \
         a start there works): {}",
        crate::clock_text::iso(r.at_ms),
        r.why
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn refused() -> RpcError {
        RpcError::new(-32000, "remote chain refused: the sandbox canary shows no sandbox")
            .with_data(json!({"reason": REASON}))
    }

    /// A chain refusal is recorded under the canonical name, with its time and text; a start
    /// that works clears it; any other failure leaves the record as it was.
    #[test]
    fn a_chain_refusal_is_recorded_and_a_start_that_works_clears_it() {
        let book = StartRefusals::default();
        let t = 1_000_000;
        book.note::<()>("Box.local", &Err(refused()), t);
        let r = book.fresh("box", t + 1).unwrap();
        assert_eq!(r.at_ms, t);
        assert!(r.why.contains("sandbox canary"), "{r:?}");
        let other = RpcError::internal("peer box timed out");
        book.note::<()>("box", &Err(other), t + 2);
        assert_eq!(book.fresh("box", t + 3).map(|r| r.at_ms), Some(t));
        book.note("box", &Ok(()), t + 4);
        assert_eq!(book.fresh("box", t + 5), None);
        // A forwarded start's refusal keeps only the refusal itself, not the command after it.
        let forwarded = RpcError::new(
            -32000,
            "refused by box: remote chain refused: canary; nothing was started. Instead:\n\
             acpmux new\nrefused by box: nothing was started; the command above runs it",
        )
        .with_data(json!({"reason": REASON, "host": "box"}));
        book.note::<()>("box", &Err(forwarded), t + 6);
        assert_eq!(book.fresh("box", t + 7).unwrap().why, "remote chain refused: canary");
        // A failure that is no chain refusal records nothing.
        book.note::<()>("vm", &Err(RpcError::internal("no")), t);
        assert_eq!(book.fresh("vm", t), None);
        // Nor does a refusal of the start's own inputs: only the host's kind is recorded.
        let start =
            RpcError::new(-32000, "remote start refused: a remote chain needs a session id")
                .with_data(json!({"reason": START_REASON}));
        book.note::<()>("vm", &Err(start), t);
        assert_eq!(book.fresh("vm", t), None);
    }

    /// A record keeps a machine out for 30 minutes, then lapses by itself.
    #[test]
    fn a_refusal_is_fresh_for_thirty_minutes() {
        let book = StartRefusals::default();
        book.record("box", 0, "remote chain refused: x");
        assert!(book.fresh("box", FRESH_MS - 1).is_some());
        assert_eq!(book.fresh("box", FRESH_MS), None);
        assert_eq!(book.fresh("box", 0), None, "a stale record is dropped");
    }

    /// The book holds at most `MAX` machines, dropping the oldest, and a long text is cut.
    #[test]
    fn the_book_is_bounded() {
        let book = StartRefusals::default();
        for i in 0..(MAX as u64 + 5) {
            book.record(&format!("h{i}"), 10 + i, &"x".repeat(2 * WHY_CHARS));
        }
        assert_eq!(book.map().len(), MAX);
        assert_eq!(book.fresh("h0", 20), None);
        let last = book.fresh(&format!("h{}", MAX + 4), 20).unwrap();
        assert_eq!(last.why.chars().count(), WHY_CHARS);
        let line = line(&last, 10 + MAX as u64 + 4 + 5 * 60_000);
        assert!(
            line.starts_with("its remote chain refused a start at 1970-01-01T00:00:00"),
            "{line}"
        );
        assert!(line.contains("(5 min ago;"), "{line}");
    }
}
