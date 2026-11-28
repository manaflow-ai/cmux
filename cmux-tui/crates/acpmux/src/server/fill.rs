//! The machine's fill on an attached chat (RFD 0139 readiness, AutoCloud MVP A3).
//!
//! A Cloud seed checks a folder out head-first and downloads the rest in the background
//! (`cmux-tui-core` `git_seed`). While it does, `.git/cmux-seed-filling` exists and holds
//! `{"fill":N}`; it is removed once the tree is whole. A connection whose `_acpmux/attach` says
//! `fill: true` (the capability [`AUTOCLOUD_FILL`] advertises it) for a chat in such a folder hears
//! `_acpmux/fill {sessionId, fill, _meta: {acpmux: {fill}}}` on each change, and a last 100 when
//! the marker goes. Nothing is sent to any other connection, and nothing for a folder that is not
//! filling, so it is off for everyone who did not ask.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use serde_json::json;

use super::Conn;
#[allow(unused_imports)]
use crate::capabilities::AUTOCLOUD_FILL;
use crate::rpc::{Message, method};

/// The seed's marker in the git dir (`git_seed/run.rs` `FILLING`).
const MARKER: &str = "cmux-seed-filling";

/// How often a follower reads the marker: a stat and a few bytes.
const EVERY: Duration = Duration::from_secs(1);

/// The longest a follower runs: a fill that never ends (a seed killed for good) stops being
/// followed; a new attach starts again.
const AT_MOST: Duration = Duration::from_secs(60 * 60);

/// On by default (Leo: "it doesnt work if it's not \"on by default\""); the live probe is the
/// seed's marker, and `ACPMUX_FILL=0` (or `off`, `false`, `no`) is the kill switch.
const KILL_SWITCH: &str = "ACPMUX_FILL";

fn killed(value: Option<&str>) -> bool {
    value.is_some_and(|v| {
        matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "off" | "false" | "no")
    })
}

/// The fill of the checkout holding `cwd`: None when it is whole (no marker in it or any
/// folder above, up to the first `.git`); the marker's figure otherwise, 0 when it has none.
pub(crate) fn fill_of(cwd: &Path) -> Option<u8> {
    let mut at = Some(cwd);
    while let Some(dir) = at {
        let git_dir = dir.join(".git");
        if git_dir.is_dir() {
            let text = match std::fs::read(git_dir.join(MARKER)) {
                Ok(text) => text,
                Err(_) => return None,
            };
            return Some(parse(&text));
        }
        if git_dir.exists() {
            // A worktree's or submodule's `.git` file: not a seed's checkout.
            return None;
        }
        at = dir.parent();
    }
    None
}

/// `{"fill":N}` clamped to 100; 0 for an empty or unreadable figure.
fn parse(text: &[u8]) -> u8 {
    serde_json::from_slice::<serde_json::Value>(text)
        .ok()
        .and_then(|v| v.get("fill").and_then(serde_json::Value::as_u64))
        .map_or(0, |fill| u8::try_from(fill.min(100)).unwrap_or(100))
}

fn note(session: &str, fill: u8) -> Message {
    Message::notification(
        method::MUX_FILL,
        json!({"sessionId": session, "fill": fill, "_meta": {"acpmux": {"fill": fill}}}),
    )
}

/// Follows `session`'s folder for `conn` when its attach asked for fills (`fill: true`) and the
/// folder is filling: the figure now, each change, and 100 at the end. Owned by the
/// connection's scope.
pub(super) fn follow(conn: &Arc<Conn>, asked: bool, session: &str, cwd: &Path) {
    if !asked || killed(std::env::var(KILL_SWITCH).ok().as_deref()) {
        return;
    }
    let Some(first) = fill_of(cwd) else { return };
    conn.send(&note(session, first));
    let (conn_task, session, cwd) = (conn.clone(), session.to_owned(), cwd.to_path_buf());
    conn.scope.spawn_named("fill-follow", async move {
        let conn = conn_task;
        let mut last = first;
        let started = tokio::time::Instant::now();
        loop {
            tokio::select! {
                () = conn.closed() => return,
                () = tokio::time::sleep(EVERY) => {}
            }
            let now = fill_of(&cwd);
            let fill = now.unwrap_or(100);
            if fill != last {
                conn.send(&note(&session, fill));
                last = fill;
            }
            if now.is_none() || started.elapsed() > AT_MOST {
                return;
            }
        }
    });
}

#[cfg(test)]
#[path = "fill_tests.rs"]
mod tests;
