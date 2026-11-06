//! Part of `Hub`; see `hub/mod.rs`. A turn gone silent ends the harness's unbounded file
//! listing. Claude Code counts the files of its folder with `rg --no-config --files --hidden
//! <cwd>` (no depth bound) as it starts and when asked for its context; in a folder that holds
//! hundreds of worktrees and mirrors (Leo's `~/Projects`) that listing ran past 12 minutes under
//! load while the prompt sat unread for 22 (Leo: "this thing keeps getting stuck???"). Claude
//! Code gives the count a 1 to 3 s deadline it did not keep there. When a turn logs `turn_silent`
//! (`silent_turn.rs`), acpmux sends SIGTERM to every such listing under the chat's own agent
//! (found as `ChildAgent::harness_processes` finds them, never from a bare pid, each checked by
//! pid and start time before its signal, and only while that turn still runs silent) and logs
//! `listing_ended` {turnId, pid, args}: a count Claude Code loses only reads as unknown.
//! A listing a tool asked for (Glob's `--null`, a `--glob` that picks files) or one with a depth
//! bound is left alone, as is every process outside the chat's own agent.

use super::*;

/// Whether `argv` is a whole-tree file listing by ripgrep: `--files` and `--hidden`, no depth
/// bound and no `--null` (Glob) in any spelling, and every glob, apart or attached, an exclusion.
pub(super) fn unbounded_listing(argv: &[String]) -> bool {
    let Some(program) = argv.first() else { return false };
    if std::path::Path::new(program).file_name().is_none_or(|n| n != "rg") {
        return false;
    }
    let has = |flag: &str| argv.iter().any(|a| a == flag);
    // `-0` is `--null`; `-d N`, `-dN`, `-d=N`, `--maxdepth` and `--max-depth=N` bound the depth.
    if !has("--files") || !has("--hidden") || has("--null") || has("-0") {
        return false;
    }
    let depth = |a: &str| {
        matches!(a, "--max-depth" | "--maxdepth")
            || a.starts_with("--max-depth=")
            || a.starts_with("--maxdepth=")
            || a.strip_prefix("-d")
                .map(|n| n.strip_prefix('=').unwrap_or(n))
                .is_some_and(|n| n.is_empty() || n.bytes().all(|b| b.is_ascii_digit()))
    };
    if argv.iter().any(|a| depth(a)) {
        return false;
    }
    let mut words = argv.iter();
    while let Some(word) = words.next() {
        // A glob given apart (`--glob G`, `-g G`) or attached (`--glob=G`, `--iglob=G`, `-gG`).
        let glob = match word.as_str() {
            "--glob" | "-g" | "--iglob" => Some(words.next().map_or("", String::as_str)),
            w => w
                .strip_prefix("--glob=")
                .or_else(|| w.strip_prefix("--iglob="))
                .or_else(|| w.strip_prefix("-g").filter(|g| !g.is_empty())),
        };
        // One that picks files (not an `!` exclusion), or has no value: a tool asked for it.
        if glob.is_some_and(|g| !g.starts_with('!')) {
            return false;
        }
    }
    true
}

/// Whether the turn `turn_id` still runs and is still silent, as a listing is about to end:
/// `silent` is the session's `silent_turn`, `running` its running turn. One that heard its model
/// or ended while its listings were found leaves them, and the next turn's own, alone.
pub(super) fn still_silent(silent: Option<&str>, running: Option<&str>, turn_id: &str) -> bool {
    silent == Some(turn_id) && running == Some(turn_id)
}

impl Hub {
    /// Ends the unbounded listings under `session`'s agent, as its turn `turn_id` goes silent.
    #[cfg(unix)]
    pub(super) async fn end_silent_listings(&self, session: &Arc<Session>, turn_id: &str) {
        let Some(child) = session.child.lock().await.clone() else { return };
        let procs = child.harness_processes().await;
        let (watched, turn) = (session.clone(), turn_id.to_owned());
        let ended = tokio::task::spawn_blocking(move || {
            // Checked for each listing just before its signal, not once for all of them.
            crate::agent_host::tree::terminate_picked(&procs, |argv| {
                unbounded_listing(argv) && {
                    let silent =
                        watched.silent_turn.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    let running = watched.turn().map(|t| t.turn_id);
                    still_silent(silent.as_deref(), running.as_deref(), &turn)
                }
            })
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
