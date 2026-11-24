//! The chat-title hit/miss log: one JSON line per title outcome in `$ACPMUX_HOME/titles.jsonl`
//! (owner-only; past 4 MB it moves to `titles.jsonl.1`, as `cross-host-audit.jsonl` does), so
//! the titler can be tuned from counts (Leo, 2026-11-24: "> log hits and misses to tune
//! it."). The `chat_title` tracing line never reached `daemon.log`, and a person renaming a
//! chat after its title was made was recorded nowhere.
//!
//! `{"at": ms, "session": id, "harness", "model": str|null, "outcome", "prev_source":
//! str|null, "words": n, "ms": n}` where `outcome` is
//! - `generated`: a model's title was applied (`words`, `ms` of the request),
//! - `empty`: the request came back with no usable title,
//! - `error`: the completion call failed,
//! - `no_command`: no title command applies to the harness,
//! - `harness`: the harness's own title replaced the one before (`prev_source`),
//! - `renamed`: a person renamed a chat whose title came from `generated`, `harness`, `task` or
//!   `prompt` (`prev_source`: the source of the title they replaced): the miss.
//!
//! Never the prompt or the title's text, only its word count. A write that fails is skipped.

use super::*;
use std::path::PathBuf;

pub const FILE: &str = "titles.jsonl";

const CAP: u64 = 4 << 20;

#[cfg(test)]
thread_local! {
    pub(super) static TEST_PATH: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

/// Under test only a thread that named a path writes: other tests never touch the real home.
fn path() -> Option<PathBuf> {
    #[cfg(test)]
    return TEST_PATH.with(|p| p.borrow().clone());
    #[cfg(not(test))]
    Some(crate::config::home().join(FILE))
}

/// Append one outcome line.
pub(super) fn record(
    session: &Session,
    harness: &str,
    model: Option<&str>,
    outcome: &str,
    prev_source: Option<&str>,
    words: usize,
    ms: u64,
) {
    let line = json!({
        "at": crate::store::now_ms(),
        "session": session.id,
        "harness": harness,
        "model": model,
        "outcome": outcome,
        "prev_source": prev_source,
        "words": words,
        "ms": ms,
    });
    let Some(path) = path() else { return };
    if let Err(e) = crate::xhost_audit::append_capped(&path, &line, CAP) {
        static SAID: std::sync::Once = std::sync::Once::new();
        SAID.call_once(|| eprintln!("acpmux: cannot write the title log: {e}"));
    }
}

/// A person renamed a chat and its title was replaced: a miss when a made title had stood.
pub(super) fn renamed(session: &Session, harness: &str, prev_source: Option<&str>) {
    if matches!(prev_source, Some("generated" | "harness" | "task" | "prompt")) {
        record(session, harness, None, "renamed", prev_source, 0, 0);
    }
}
