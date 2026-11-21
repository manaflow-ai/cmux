//! A verdict per worktree. Pure: the facts, the sessions, the registered
//! programs and
//! the disk go in, a verdict comes out, so every rule has a test.
//!
//! The order of the rules is the order of the guarantees:
//!
//! 1. Never touch what is in use: a locked worktree, a git operation under
//!    way, an open acpmux session in it, a process working in it, an owner
//!    (`wt-owner.json`) that is alive wherever it works.
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
    /// Every id it goes by (acpmux's, its harness's), which a worktree's
    /// owner record may name.
    pub ids: Vec<String>,
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
    /// Milliseconds since its last use, once a rule read it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idle_ms: Option<u64>,
}

fn verdict(action: Action, reason: impl Into<String>) -> Verdict {
    Verdict { action, reason: reason.into(), idle_ms: None }
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
    // An owner may work in it from elsewhere (`git -C`, a loop whose folder
    // is another): while it lives, the worktree is in use.
    if let Some(why) =
        facts.owner.as_ref().and_then(|owner| owner_alive(owner, sessions, processes))
    {
        return verdict(Keep, why);
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
    // Every verdict from here on carries the idle time it was decided at.
    let verdict =
        |action, reason: String| Verdict { idle_ms: Some(idle), ..verdict(action, reason) };
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

/// Why `owner` is alive: its recorded process runs, an open session goes
/// by one of its ids, or a registered process runs its session. `None`
/// when none of these says so.
fn owner_alive(
    owner: &crate::inventory::Owner,
    sessions: &[Session],
    processes: &[Process],
) -> Option<String> {
    let name = owner.session_id.as_deref().unwrap_or("?");
    if owner.runs
        && let Some(pid) = owner.pid
    {
        return Some(format!("owner {name}'s process {pid} runs"));
    }
    if let Some(session) = sessions.iter().find(|s| s.open && s.ids.iter().any(|id| owner.is(id))) {
        return Some(format!("owner session {} is open", session.name));
    }
    processes
        .iter()
        .find(|p| p.session_id.as_deref().is_some_and(|id| owner.is(id)))
        .map(|p| format!("owner {name} runs as process {}", p.pid))
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
mod care_tests {
    use super::*;
    use crate::Facts;

    const NOW: u64 = 1_800_000_000_000;

    fn worktree(facts: Facts) -> Worktree {
        Worktree {
            path: PathBuf::from("/w/a"),
            branch: Some("feat/a".into()),
            head: Some("1".repeat(40)),
            locked: false,
            prunable: false,
            facts: Ok(facts),
        }
    }

    fn pushed(idle_hours: u64) -> Facts {
        Facts {
            has_remotes: true,
            last_activity_ms: NOW - idle_hours * HOUR_MS,
            ..Facts::default()
        }
    }

    fn decide_at(worktree: &Worktree, sessions: &[Session], pressure: Pressure) -> Verdict {
        decide(worktree, Some(Path::new("/r")), sessions, &[], pressure, &Settings::default(), NOW)
    }

    #[test]
    fn an_open_session_keeps_its_worktree_however_idle() {
        let session = Session {
            name: "lane".into(),
            cwd: "/w/a/src".into(),
            open: true,
            updated_ms: 0,
            ids: Vec::new(),
        };
        let v = decide_at(&worktree(pushed(1000)), &[session], Pressure::Critical);
        assert_eq!(v.action, Action::Keep);
        assert!(v.reason.contains("lane"));
    }

    #[test]
    fn a_closed_session_s_last_change_counts_as_use() {
        let session = Session {
            name: "lane".into(),
            cwd: "/w/a".into(),
            open: false,
            updated_ms: NOW,
            ids: Vec::new(),
        };
        assert_eq!(
            decide_at(&worktree(pushed(1000)), &[session], Pressure::Normal).action,
            Action::Keep
        );
    }

    #[test]
    fn a_process_inside_keeps_it() {
        let processes = [Process { pid: 7, cwd: "/w/a/web".into(), session_id: None }];
        let v = decide(
            &worktree(pushed(1000)),
            None,
            &[],
            &processes,
            Pressure::Critical,
            &Settings::default(),
            NOW,
        );
        assert_eq!(v.action, Action::Keep);
    }

    /// hq#13316: an owner working from another folder, pushed and idle 25 h
    /// by every other signal at high pressure, keeps its worktree while it
    /// lives, however that is known.
    #[test]
    fn a_worktree_whose_wt_owner_is_live_is_kept() {
        let owner = crate::inventory::Owner {
            session_id: Some("sid".into()),
            ids: vec!["chat".into()],
            pid: Some(7),
            runs: false,
        };
        let w = worktree(Facts { owner: Some(owner.clone()), ..pushed(25) });
        let elsewhere = |ids: Vec<String>, open| Session {
            name: "loop".into(),
            cwd: "/home/chats/loop".into(),
            open,
            updated_ms: 0,
            ids,
        };
        let at = |w: &Worktree, sessions: &[Session], processes: &[Process]| {
            decide(w, None, sessions, processes, Pressure::High, &Settings::default(), NOW)
        };
        // Gone by every sign: it goes, as on 2026-11-18.
        let gone = at(&w, &[elsewhere(vec!["chat".into()], false)], &[]);
        assert_eq!(gone.action, Action::Reclaim, "{}", gone.reason);
        assert_eq!(gone.reason, "everything pushed; idle 25 h");
        // Its recorded process runs.
        let running = worktree(Facts {
            owner: Some(crate::inventory::Owner { runs: true, ..owner }),
            ..pushed(25)
        });
        let v = at(&running, &[], &[]);
        assert_eq!((v.action, v.reason.as_str()), (Action::Keep, "owner sid's process 7 runs"));
        // An open acpmux session goes by one of its ids.
        let v = at(&w, &[elsewhere(vec!["other".into(), "chat".into()], true)], &[]);
        assert_eq!((v.action, v.reason.as_str()), (Action::Keep, "owner session loop is open"));
        // Claude Code's registry runs its session, in another folder.
        let registered =
            [Process { pid: 9, cwd: "/home/chats/loop".into(), session_id: Some("sid".into()) }];
        let v = at(&w, &[], &registered);
        assert_eq!((v.action, v.reason.as_str()), (Action::Keep, "owner sid runs as process 9"));
    }

    #[test]
    fn a_session_active_in_the_main_checkout_gets_its_worktrees_the_longest_waits() {
        let main = Session {
            name: "chief".into(),
            cwd: "/r/src".into(),
            open: true,
            updated_ms: NOW,
            ids: Vec::new(),
        };
        let w = worktree(pushed(30));
        assert_eq!(decide_at(&w, &[], Pressure::Critical).action, Action::Reclaim);
        assert_eq!(
            decide_at(&w, std::slice::from_ref(&main), Pressure::Critical).action,
            Action::Keep
        );
        let stale = Session { updated_ms: NOW - 2 * DAY_MS, ..main };
        assert_eq!(decide_at(&w, &[stale], Pressure::Critical).action, Action::Reclaim);
    }

    #[test]
    fn locked_and_mid_rebase_worktrees_are_kept() {
        let mut locked = worktree(pushed(1000));
        locked.locked = true;
        assert_eq!(decide_at(&locked, &[], Pressure::Critical).action, Action::Keep);
        let rebasing = worktree(Facts { operation: Some("rebase".into()), ..pushed(1000) });
        assert_eq!(decide_at(&rebasing, &[], Pressure::Critical).action, Action::Keep);
    }

    #[test]
    fn pushed_work_goes_sooner_as_the_disk_fills() {
        let w = worktree(pushed(30));
        assert_eq!(decide_at(&w, &[], Pressure::Normal).action, Action::Keep);
        assert_eq!(decide_at(&w, &[], Pressure::High).action, Action::Reclaim);
        assert_eq!(decide_at(&worktree(pushed(80)), &[], Pressure::Normal).action, Action::Reclaim);
    }

    #[test]
    fn unpushed_work_is_archived_never_just_removed() {
        let w = worktree(Facts { unpushed: 2, changed: 1, ..pushed(200) });
        let v = decide_at(&w, &[], Pressure::Normal);
        assert_eq!(v.action, Action::Archive, "{v:?}");
        assert!(v.reason.contains("2 unpushed"));
        let young = worktree(Facts { unpushed: 2, ..pushed(30) });
        assert_eq!(decide_at(&young, &[], Pressure::High).action, Action::Keep);
    }

    #[test]
    fn finished_work_goes_after_the_recent_window_only() {
        let finished = Facts {
            unpushed: 3,
            finished: Some("HEAD's changes are already in origin/main".into()),
            ..pushed(30)
        };
        assert_eq!(
            decide_at(&worktree(finished.clone()), &[], Pressure::Normal).action,
            Action::Archive
        );
        let fresh = Facts { last_activity_ms: NOW - HOUR_MS / 2, ..finished };
        assert_eq!(decide_at(&worktree(fresh), &[], Pressure::Critical).action, Action::Keep);
    }

    #[test]
    fn work_no_archive_can_keep_is_only_trimmed() {
        let w = worktree(Facts {
            unarchivable: Some("nested repository vendor/x/".into()),
            build_output: vec!["node_modules/".into()],
            ..pushed(500)
        });
        let v = decide_at(&w, &[], Pressure::Critical);
        assert_eq!(v.action, Action::Trim);
        assert!(v.reason.contains("nested repository"));
    }

    #[test]
    fn the_disk_s_used_share_names_its_pressure() {
        let settings = Settings::default();
        assert_eq!(settings.pressure(0.5), Pressure::Normal);
        assert_eq!(settings.pressure(0.85), Pressure::High);
        assert_eq!(settings.pressure(0.94), Pressure::Critical);
    }
}
