//! Part of `Hub`; see `hub/mod.rs`. A turn gone silent ends the harness's unbounded file
//! listing. Claude Code counts the files of its folder with `rg --no-config --files --hidden
//! <cwd>` (no depth bound) as it starts and when asked for its context; in a folder that holds
//! hundreds of worktrees and mirrors (Leo's `~/Projects`) that listing ran past 12 minutes under
//! load while the prompt sat unread for 22 (Leo: "this thing keeps getting stuck???"). Claude
//! Code gives the count a 1 to 3 s deadline it did not keep there. When a turn logs `turn_silent`
//! (`silent_turn.rs`), acpmux sends SIGTERM to every such listing under the chat's own agent
//! and logs `listing_ended` {turnId, pid, args}: a count Claude Code loses only reads as unknown.
//! A listing a tool asked for (Glob's `--null`, a `--glob` that picks files) or one with a depth
//! bound is left alone, as is every process outside the chat's own agent.

use super::*;

/// Whether `argv` is a whole-tree file listing by ripgrep: `--files` and `--hidden`, no
/// `--max-depth`, no `--null` (Glob), and every glob an exclusion.
pub(super) fn unbounded_listing(argv: &[String]) -> bool {
    let Some(program) = argv.first() else { return false };
    if std::path::Path::new(program).file_name().is_none_or(|n| n != "rg") {
        return false;
    }
    let has = |flag: &str| argv.iter().any(|a| a == flag);
    if !has("--files") || !has("--hidden") || has("--null") {
        return false;
    }
    if argv.iter().any(|a| a == "--max-depth" || a.starts_with("--max-depth=")) {
        return false;
    }
    let mut words = argv.iter();
    while let Some(word) = words.next() {
        if matches!(word.as_str(), "--glob" | "-g" | "--iglob")
            && words.next().is_none_or(|g| !g.starts_with('!'))
        {
            return false;
        }
    }
    true
}

impl Hub {
    /// Ends the unbounded listings under `session`'s agent, as its turn `turn_id` goes silent.
    #[cfg(unix)]
    pub(super) async fn end_silent_listings(&self, session: &Arc<Session>, turn_id: &str) {
        let Some(pid) = session.child.lock().await.as_ref().and_then(|c| c.pid) else { return };
        let ended = tokio::task::spawn_blocking(move || {
            crate::agent_host::tree::terminate_under(&[pid], |a| unbounded_listing(a))
        })
        .await
        .unwrap_or_default();
        for (pid, args) in ended {
            tracing::warn!(session = %session.id, pid, "ended an unbounded file listing of a silent turn");
            self.append(
                session,
                "mux",
                "listing_ended",
                json!({"turnId": turn_id, "pid": pid, "args": args}),
            );
        }
    }

    #[cfg(not(unix))]
    pub(super) async fn end_silent_listings(&self, _session: &Arc<Session>, _turn_id: &str) {}
}

#[cfg(test)]
#[path = "silent_listing_tests.rs"]
mod tests;
