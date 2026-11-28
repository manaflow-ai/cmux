//! The model probes leave no chats behind (Lawrence 2026-10-11, "opening chat doesnt work").
//!
//! At daemon start acpmux asks every ACP harness for its models with one `session/new` in its own
//! `<acpmux home>/unattended` folder (`hub::lifecycle` `probe_one`). Claude Code and Codex write a
//! transcript for that session, which showed up in All chats as "New chat · unattended". No
//! person works in that folder, so every transcript recorded there is a probe's: this removes
//! them after each probe and once at start (probes of earlier runs).

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// At daemon start: the probe transcripts earlier runs left in the
/// unattended folder, and `_acpmux/complete` run folders a crash left
/// behind (`complete::places`).
pub fn at_daemon_start() {
    remove_probe_transcripts(&crate::protected_folders::unattended_cwd());
    let places = crate::complete::places::Places::for_daemon();
    let swept = places.sweep_stale_runs(crate::complete::places::STALE_RUN);
    if swept > 0 {
        tracing::info!(swept, "removed stale one-shot run folders");
    }
}

/// Removes Claude Code's and Codex's transcripts of sessions that ran in `unattended`.
pub fn remove_probe_transcripts(unattended: &Path) {
    let Some(home) = dirs::home_dir() else { return };
    let claude =
        login_var("CLAUDE_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(|| home.join(".claude"));
    remove_claude(&claude, unattended);
    let codex = login_var("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".codex"));
    remove_codex(&codex, unattended, Duration::from_secs(3 * 24 * 3600));
}

/// A variable from the daemon's environment, else the imported login environment (under launchd
/// the daemon lacks what `.zshenv` exports), as the chat index reads its roots.
fn login_var(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| crate::login_env::var(key).filter(|v| !v.is_empty()))
}

/// Claude Code keeps a folder's sessions in `projects/<the folder, every non-alphanumeric
/// character a '-'>`: the probe folder's project folder holds only probes.
fn remove_claude(config: &Path, unattended: &Path) {
    let name: String = unattended
        .to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let project = config.join("projects").join(name);
    if project.is_dir() {
        let _ = fs::remove_dir_all(&project);
    }
}

/// Codex keeps rollouts by day (`sessions/YYYY/MM/DD/rollout-*.jsonl`); the first line's
/// `session_meta` names the session's folder. Only recent files are read (a probe's is fresh).
fn remove_codex(codex: &Path, unattended: &Path, window: Duration) {
    let cutoff = SystemTime::now().checked_sub(window).unwrap_or(SystemTime::UNIX_EPOCH);
    let target = unattended.to_string_lossy();
    let mut stack = vec![codex.join("sessions")];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                // Day folders older than the window hold no probe of this run or the last ones.
                if meta.modified().map(|m| m >= cutoff).unwrap_or(true) {
                    stack.push(path);
                }
            } else if meta.modified().map(|m| m >= cutoff).unwrap_or(false)
                && path.extension().is_some_and(|e| e == "jsonl")
                && rollout_cwd(&path).is_some_and(|cwd| cwd == target)
            {
                let _ = fs::remove_file(&path);
            }
        }
    }
}

/// The `cwd` of a Codex rollout's first line (`{"type":"session_meta","payload":{"cwd":...}}`).
fn rollout_cwd(path: &Path) -> Option<String> {
    use std::io::{BufRead, BufReader, Read};
    let file = fs::File::open(path).ok()?;
    let mut first = String::new();
    // A session_meta line carries instructions too; 1 MiB bounds a broken file.
    BufReader::new(file.take(1 << 20)).read_line(&mut first).ok().filter(|n| *n > 0)?;
    let value: serde_json::Value = serde_json::from_str(first.trim()).ok()?;
    value.get("payload")?.get("cwd")?.as_str().map(str::to_owned)
}
