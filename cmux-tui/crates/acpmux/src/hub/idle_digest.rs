//! Idle-time digests, RFD 0158 §10, first piece: harness magic `idleDigest`, off unless
//! `agents.harnessMagic.idleDigest.enabled` is `true` (`ACPMUX_HM_IDLEDIGEST` `0` or `1`
//! overrides it). While a chat sleeps, a file holds what it will want on wake; files, never
//! context.
//!
//! When a chat hibernates (`idle.rs`), its folder's git state is written to
//! `<acpmux home>/digests/<session>.md`: branch, HEAD, its upstream and how far ahead or behind,
//! the uncommitted files and the diff's size. When it wakes, the file is written again with what
//! moved while it slept: the commits HEAD gained and how far the upstream moved. On this VM, 24
//! of 34 wakes spent one of their first three tool calls re-reading that kind of state (git
//! status, log or diff; a PR's or run's state; a log's tail).
//!
//! Git only, no model: every call is bounded ([`GIT_BOUND`]), owned (`cmux_process`), and run
//! off the hub's tasks; a folder that is not a repository, a slow git or a full disk writes no
//! digest and never holds up the sleep or the wake. The next pieces: the wake's first prompt
//! names the file, and a cheap model adds a CI-failure digest.

use cmux_process::{Command, Stdio};
use serde_json::Value;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The feature's name in its setting, kill switch and stamp.
pub(crate) const FEATURE: &str = "idleDigest";

/// The longest one git call may run.
const GIT_BOUND: Duration = Duration::from_secs(3);

/// The uncommitted files listed by name; the rest are counted.
const MAX_FILES: usize = 30;

/// The commits listed by subject; the rest are counted.
const MAX_COMMITS: usize = 20;

/// Whether the feature is on: the environment's `ACPMUX_HM_IDLEDIGEST` (`0` off, `1` on), then
/// the settings key (off unless `true`).
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, &super::harness_magic::setting_key(FEATURE)))
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

/// [`enabled_with`] now.
pub(crate) fn enabled() -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    let env = std::env::var(super::harness_magic::env_key(FEATURE)).ok();
    enabled_with(doc.as_ref(), env.as_deref())
}

/// Where `session`'s digest lives under `home`.
pub(crate) fn path_in(home: &Path, session: &str) -> PathBuf {
    home.join("digests").join(format!("{session}.md"))
}

/// One git call in `dir`, bounded by [`GIT_BOUND`]: its trimmed output, or `None` on failure,
/// timeout or a folder that is not a repository.
fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let mut out = tempfile::tempfile().ok()?;
    let mut child = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(Stdio::null())
        .stdout(out.try_clone().ok()?)
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    match child.wait_timeout(GIT_BOUND) {
        Ok(Some(s)) if s.success() => {}
        _ => return None,
    }
    let mut text = String::new();
    out.rewind().ok()?;
    out.read_to_string(&mut text).ok()?;
    Some(text.trim_end().to_owned())
}

/// A folder's git state, as the digest reads it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct State {
    pub branch: String,
    pub head: String,
    pub upstream: Option<String>,
    pub upstream_head: Option<String>,
    pub ahead: u64,
    pub behind: u64,
    /// `git status --porcelain` lines.
    pub dirty: Vec<String>,
    /// `git diff --shortstat HEAD`.
    pub diff_stat: String,
}

/// `dir`'s git state now, or `None` when it is not a repository or git did not answer.
pub(crate) fn read_state(dir: &Path) -> Option<State> {
    let head = git(dir, &["rev-parse", "HEAD"])?;
    let branch = git(dir, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    let upstream = git(dir, &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]);
    let upstream_head = upstream.as_ref().and_then(|_| git(dir, &["rev-parse", "@{u}"]));
    let (ahead, behind) = upstream
        .as_ref()
        .and_then(|_| git(dir, &["rev-list", "--left-right", "--count", "HEAD...@{u}"]))
        .and_then(|s| parse_counts(&s))
        .unwrap_or((0, 0));
    let dirty = git(dir, &["status", "--porcelain", "--untracked-files=normal"])
        .map(|s| s.lines().map(str::to_owned).collect())
        .unwrap_or_default();
    let diff_stat = git(dir, &["diff", "--shortstat", "HEAD"]).unwrap_or_default();
    Some(State {
        branch,
        head,
        upstream,
        upstream_head,
        ahead,
        behind,
        dirty,
        diff_stat: diff_stat.trim().to_owned(),
    })
}

/// `rev-list --left-right --count`'s `A\tB`.
pub(crate) fn parse_counts(s: &str) -> Option<(u64, u64)> {
    let mut it = s.split_whitespace();
    Some((it.next()?.parse().ok()?, it.next()?.parse().ok()?))
}

/// What moved while the chat slept: `slept` is the state at hibernation, `now` at wake.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Moved {
    /// `git log --oneline slept.head..now.head` lines.
    pub commits: Vec<String>,
    /// How many commits the upstream gained.
    pub upstream_gained: u64,
}

/// The commits between the two states, read in `dir`.
pub(crate) fn read_moved(dir: &Path, slept: &State, now: &State) -> Moved {
    let range = format!("{}..{}", slept.head, now.head);
    let commits = if slept.head == now.head {
        Vec::new()
    } else {
        git(dir, &["log", "--oneline", "--no-decorate", &range])
            .map(|s| s.lines().map(str::to_owned).collect())
            .unwrap_or_default()
    };
    let upstream_gained = match (&slept.upstream_head, &now.upstream_head) {
        (Some(a), Some(b)) if a != b => git(dir, &["rev-list", "--count", &format!("{a}..{b}")])
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0),
        _ => 0,
    };
    Moved { commits, upstream_gained }
}

/// The digest's text: `state` now, and what moved since the sleep when the chat woke.
pub(crate) fn render(
    dir: &Path,
    state: &State,
    at: &str,
    moved: Option<&Moved>,
    slept_at: Option<&str>,
) -> String {
    let mut s = String::new();
    s.push_str("# Idle digest\n\n");
    s.push_str(&format!("Folder: `{}`. Written {at}", dir.display()));
    s.push_str(match moved {
        Some(_) => " at wake.\n\n",
        None => " at sleep.\n\n",
    });
    if let Some(m) = moved {
        s.push_str(&format!(
            "## Since the sleep{}\n\n",
            slept_at.map(|t| format!(" ({t})")).unwrap_or_default()
        ));
        if m.commits.is_empty() && m.upstream_gained == 0 {
            s.push_str("Nothing moved: same HEAD, same upstream.\n\n");
        } else {
            if !m.commits.is_empty() {
                s.push_str(&format!("HEAD gained {} commit(s):\n", m.commits.len()));
                for c in m.commits.iter().take(MAX_COMMITS) {
                    s.push_str(&format!("- {c}\n"));
                }
                if m.commits.len() > MAX_COMMITS {
                    s.push_str(&format!("- and {} more\n", m.commits.len() - MAX_COMMITS));
                }
                s.push('\n');
            }
            if m.upstream_gained > 0 {
                s.push_str(&format!("The upstream gained {} commit(s).\n\n", m.upstream_gained));
            }
        }
    }
    s.push_str("## Now\n\n");
    s.push_str(&format!("- Branch `{}` at `{}`\n", state.branch, short(&state.head)));
    match &state.upstream {
        Some(u) => s.push_str(&format!(
            "- Upstream `{u}`: {} ahead, {} behind\n",
            state.ahead, state.behind
        )),
        None => s.push_str("- No upstream\n"),
    }
    if state.dirty.is_empty() {
        s.push_str("- Working tree clean\n");
    } else {
        s.push_str(&format!("- {} uncommitted file(s)", state.dirty.len()));
        if !state.diff_stat.is_empty() {
            s.push_str(&format!(" ({})", state.diff_stat));
        }
        s.push_str(":\n");
        for l in state.dirty.iter().take(MAX_FILES) {
            s.push_str(&format!("  - `{l}`\n"));
        }
        if state.dirty.len() > MAX_FILES {
            s.push_str(&format!("  - and {} more\n", state.dirty.len() - MAX_FILES));
        }
    }
    s.push_str(&format!(
        "\n<!-- head {} upstream {} at {at} -->\n",
        state.head,
        state.upstream_head.as_deref().unwrap_or("-")
    ));
    s
}

/// The head, upstream head and time a digest written at sleep recorded, from its last line.
pub(crate) fn parse_marker(text: &str) -> Option<(String, Option<String>, String)> {
    let line = text.lines().rev().find(|l| l.starts_with("<!-- head "))?;
    let rest = line.strip_prefix("<!-- head ")?.strip_suffix(" -->")?;
    let mut it = rest.split(' ');
    let head = it.next()?.to_owned();
    (it.next()? == "upstream").then_some(())?;
    let up = it.next()?;
    (it.next()? == "at").then_some(())?;
    let at = it.collect::<Vec<_>>().join(" ");
    Some((head, (up != "-").then(|| up.to_owned()), at))
}

fn short(sha: &str) -> &str {
    sha.get(..12).unwrap_or(sha)
}

fn now_text() -> String {
    let ms = crate::store::now_ms();
    let secs = i64::try_from(ms / 1000).unwrap_or(0);
    chrono::DateTime::from_timestamp(secs, 0)
        .map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_default()
}

/// Which moment the digest is written at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Moment {
    Sleep,
    Wake,
}

/// Writes `session`'s digest under `home` for `dir` at `moment`; the bytes written, or `None`
/// when nothing was (no repository, git did not answer, the write failed). Blocking: run it off
/// the hub's tasks.
pub(crate) fn write_blocking(
    home: &Path,
    session: &str,
    dir: &Path,
    moment: Moment,
) -> Option<usize> {
    let state = read_state(dir)?;
    let path = path_in(home, session);
    let at = now_text();
    let text = match moment {
        Moment::Sleep => render(dir, &state, &at, None, None),
        Moment::Wake => {
            let before = std::fs::read_to_string(&path).ok().and_then(|t| parse_marker(&t));
            match before {
                Some((head, upstream_head, slept_at)) => {
                    let slept = State { head, upstream_head, ..State::default() };
                    let moved = read_moved(dir, &slept, &state);
                    render(dir, &state, &at, Some(&moved), Some(&slept_at))
                }
                None => render(dir, &state, &at, None, None),
            }
        }
    };
    std::fs::create_dir_all(path.parent()?).ok()?;
    crate::home_fs::write(&path, text.as_bytes()).ok()?;
    Some(text.len())
}

impl super::Hub {
    /// Writes `session`'s digest at `moment` when the feature is on, on a task the hub owns;
    /// never holds up the caller.
    pub(super) fn idle_digest(&self, session: &super::Session, moment: Moment) {
        if !enabled() {
            return;
        }
        let id = session.id.clone();
        let dir = session.meta().cwd.clone();
        let home = crate::config::home();
        self.scope.spawn_named("idle-digest", async move {
            let began = std::time::Instant::now();
            let id2 = id.clone();
            let wrote =
                tokio::task::spawn_blocking(move || write_blocking(&home, &id2, &dir, moment))
                    .await
                    .ok()
                    .flatten();
            let ms = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX);
            tracing::info!(session = %id, ?moment, bytes = ?wrote, ms, "idle digest");
        });
    }
}

#[cfg(test)]
#[path = "idle_digest_tests.rs"]
mod tests;
