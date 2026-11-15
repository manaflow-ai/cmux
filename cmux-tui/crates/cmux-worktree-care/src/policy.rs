//! A verdict per worktree. Pure: the facts, the sessions, the registered
//! programs and
//! the disk go in, a verdict comes out, so every rule has a test.
//!
//! The order of the rules is the order of the guarantees:
//!
//! 1. Never touch what is in use: a locked worktree, a git operation under
//!    way, an open acpmux session in it, a process working in it.
//! 2. Never lose work: a worktree whose work no archive can keep (a nested
//!    repository, a changed submodule, too much data) is only trimmed.
//! 3. Leave recent work alone: nothing was used for `recent`.
//! 4. Then reclaim: at once when its work is already on a base branch
//!    (finished), after `idle_pushed` when everything is pushed, after
//!    `idle_unpushed` when its work goes into an archive first. The waits
//!    shrink as the disk fills.
//!
//! A kept worktree that is idle may still be trimmed: its build output
//! (`node_modules`, `target/`) goes, which a build makes again.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::inventory::Worktree;
use crate::procs::{self, Process};

const HOUR_MS: u64 = 60 * 60 * 1000;
const DAY_MS: u64 = 24 * HOUR_MS;

/// How full the disk is, from its used share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Pressure {
    /// Under `high`.
    Normal,
    /// From `high` (80%).
    High,
    /// From `critical` (90%).
    Critical,
}

/// The thresholds and waits of a pass.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// Used share from which the waits shrink (0.80).
    pub high: f64,
    /// Used share from which they shrink most (0.90).
    pub critical: f64,
    /// Hours a worktree is left alone after its last use, per pressure.
    /// Long, because only registered programs (acpmux and Claude Code
    /// sessions) are seen: a shell, build or editor working in a worktree
    /// counts only through the files it touches.
    pub recent_hours: [u64; 3],
    /// Hours before a clean, pushed worktree goes.
    pub idle_pushed_hours: [u64; 3],
    /// Hours before a worktree with work only here is archived and goes.
    pub idle_unpushed_hours: [u64; 3],
    /// Hours before a kept worktree's build output goes.
    pub trim_hours: [u64; 3],
    /// Days an archive (its ref, bundle and manifest) is kept.
    pub keep_archive_days: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            high: 0.80,
            critical: 0.90,
            recent_hours: [24, 12, 6],
            idle_pushed_hours: [72, 24, 6],
            idle_unpushed_hours: [7 * 24, 72, 24],
            trim_hours: [72, 12, 3],
            keep_archive_days: 14,
        }
    }
}

impl Settings {
    pub fn pressure(&self, used_fraction: f64) -> Pressure {
        if used_fraction >= self.critical {
            Pressure::Critical
        } else if used_fraction >= self.high {
            Pressure::High
        } else {
            Pressure::Normal
        }
    }
}

fn hours(table: [u64; 3], pressure: Pressure) -> u64 {
    table[pressure as usize] * HOUR_MS
}

/// An agent session and the folder it works in.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub name: String,
    pub cwd: PathBuf,
    /// Not closed: it may run again in its folder.
    pub open: bool,
    /// Milliseconds since the epoch of its last change.
    pub updated_ms: u64,
}

/// What happens to a worktree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    /// Left as it is.
    Keep,
    /// Its build output goes; the worktree stays.
    Trim,
    /// Its folder goes: nothing lives only there (the manifest is kept).
    Reclaim,
    /// Its work goes into an archive, then its folder goes.
    Archive,
}

/// A verdict and why.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Verdict {
    pub action: Action,
    pub reason: String,
}

fn verdict(action: Action, reason: impl Into<String>) -> Verdict {
    Verdict { action, reason: reason.into() }
}

/// The verdict for `worktree` at `now_ms`.
pub fn decide(
    worktree: &Worktree,
    main_root: Option<&Path>,
    sessions: &[Session],
    processes: &[Process],
    pressure: Pressure,
    settings: &Settings,
    now_ms: u64,
) -> Verdict {
    use Action::*;
    if worktree.locked {
        return verdict(Keep, "locked");
    }
    let facts = match &worktree.facts {
        Ok(facts) => facts,
        Err(error) => return verdict(Keep, format!("unreadable: {error}")),
    };
    if let Some(operation) = &facts.operation {
        return verdict(Keep, format!("a {operation} is under way"));
    }
    // Sessions first, open or closed: a closed one's last change is use.
    let mut last_use = facts.last_activity_ms;
    for session in sessions.iter().filter(|s| inside(&s.cwd, &worktree.path)) {
        if session.open {
            return verdict(Keep, format!("session {} is open in it", session.name));
        }
        last_use = last_use.max(session.updated_ms);
    }
    if let Some(process) = procs::inside(processes, &worktree.path) {
        return verdict(Keep, format!("process {} works in it", process.pid));
    }
    // A session working in the main checkout may also work in worktrees it
    // made (Claude Code's own, a subagent's) between its tool calls: while
    // one was active in the last day, the repository's worktrees get the
    // longest waits.
    let pressure = match main_root {
        Some(main)
            if sessions.iter().any(|s| {
                s.open && inside(&s.cwd, main) && now_ms.saturating_sub(s.updated_ms) < DAY_MS
            }) || procs::inside(processes, main).is_some() =>
        {
            Pressure::Normal
        }
        _ => pressure,
    };
    let idle = now_ms.saturating_sub(last_use);
    let idle_hours = idle / HOUR_MS;
    let trim = |reason: String| {
        if !facts.build_output.is_empty() && idle >= hours(settings.trim_hours, pressure) {
            verdict(Trim, format!("{reason}; build output idle {idle_hours} h"))
        } else {
            verdict(Keep, reason)
        }
    };
    if let Some(why) = &facts.unarchivable {
        return trim(format!("cannot archive: {why}"));
    }
    if idle < hours(settings.recent_hours, pressure) {
        return verdict(Keep, format!("used {} min ago", idle / 60_000));
    }
    let only_here = !facts.is_clean_and_pushed();
    // Finished work (its PR merged or squashed in) needs no long wait.
    if let Some(evidence) = &facts.finished
        && facts.changed == 0
        && facts.untracked.is_empty()
    {
        let action = if only_here { Archive } else { Reclaim };
        return verdict(action, format!("finished: {evidence}; idle {idle_hours} h"));
    }
    if !only_here && idle >= hours(settings.idle_pushed_hours, pressure) {
        return verdict(Reclaim, format!("everything pushed; idle {idle_hours} h"));
    }
    if only_here && idle >= hours(settings.idle_unpushed_hours, pressure) {
        return verdict(Archive, format!("{}; idle {idle_hours} h", only_here_reason(facts)));
    }
    trim(format!("idle {idle_hours} h"))
}

fn only_here_reason(facts: &crate::Facts) -> String {
    let mut parts = Vec::new();
    if facts.unpushed > 0 {
        parts.push(format!("{} unpushed commits", facts.unpushed));
    }
    if facts.changed > 0 {
        parts.push(format!("{} changed files", facts.changed));
    }
    if !facts.untracked.is_empty() {
        parts.push(format!("{} untracked files", facts.untracked.len()));
    }
    if !facts.ignored_data.is_empty() {
        parts.push(format!("{} ignored entries", facts.ignored_data.len()));
    }
    if !facts.has_remotes {
        parts.push("no remote".to_string());
    }
    parts.join(", ")
}

fn inside(folder: &Path, root: &Path) -> bool {
    folder.starts_with(root)
        || std::fs::canonicalize(folder)
            .ok()
            .zip(std::fs::canonicalize(root).ok())
            .is_some_and(|(folder, root)| folder.starts_with(root))
}

#[cfg(test)]
mod care_tests;
