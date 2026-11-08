//! Notices the daemon leaves for one Claude Code subagent of a session, which acpmux's Bash hook
//! in that session (`bg_hook.rs`) hands to the subagent (W5-M, 2026-11-08).
//!
//! A Claude Code subagent (the Agent tool) runs in its lead's process, inside the lead's acpmux
//! session: acpmux cannot prompt it, and its harness takes `session/prompt` only for the lead's
//! own conversation. The one way into a subagent's context is a hook's answer to one of its own
//! tool calls, which Claude Code names by the subagent's `agent_id`. So a report a subagent asked
//! for (`hub/lane_report_subagents.rs`) is left here, and the hook gives it to the subagent after
//! its next shell command (`PostToolUse`, `additionalContext`).
//!
//! `<home>/run/subagent-notices/<session>/<agent id>/`, the folders 0700:
//!
//! - `<id>.json`, 0600: one notice, `{text, lane, report}`: `text` is what the subagent reads,
//!   the rest is what the daemon needs to give it to the lead instead. Written whole under
//!   another name first, then renamed, so no reader sees half of one.
//! - `stopped`: the subagent's `SubagentStop` hook ran; it reads no more notices. Notices left
//!   after it go to the lead.
//!
//! Each notice is taken exactly once, by whoever renames it first ([`take`]): the hook for the
//! subagent, or the daemon for the lead (the subagent stopped, or no subagent of the session
//! runs any more). Both sides write first and check the other's mark after, so a notice left as
//! the subagent stops is still taken by one of them.

use serde_json::Value;
use std::path::{Path, PathBuf};

/// The folder below the daemon's `run` folder.
const DIR: &str = "subagent-notices";
/// The mark a subagent's `SubagentStop` hook leaves.
const STOPPED: &str = "stopped";
/// A notice's file name ends with this.
const SUFFIX: &str = ".json";

/// `session`'s folder: its id with anything but `A-Za-z0-9-_` replaced, as the MCP config's
/// name is (`agent_tools::mcp_config_path`).
pub fn session_dir(home: &Path, session: &str) -> PathBuf {
    let safe: String = session
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    home.join("run").join(DIR).join(safe)
}

/// The folder of subagent `agent` (Claude Code's `agent_id`) of `session`; none for an id that
/// is no plain word ([`name_word`]).
pub fn agent_dir(home: &Path, session: &str, agent: &str) -> Option<PathBuf> {
    name_word(agent).then(|| session_dir(home, session).join(agent))
}

/// A plain word (`cli::sender::subagent_word`) that is one file name of its own: not `.`, `..`
/// or hidden.
fn name_word(word: &str) -> bool {
    crate::cli::sender::subagent_word(word) && !word.starts_with('.')
}

/// Leaves `notice` as `<id>.json` in `dir` (an [`agent_dir`]); `id` is a plain word.
pub fn leave(dir: &Path, id: &str, notice: &Value) -> std::io::Result<PathBuf> {
    if !name_word(id) {
        return Err(std::io::Error::other("a notice id is a plain word"));
    }
    create_private(dir)?;
    let path = dir.join(format!("{id}{SUFFIX}"));
    let part = dir.join(format!(".{id}.{}", uuid::Uuid::now_v7()));
    write_private(&part, notice.to_string().as_bytes())?;
    std::fs::rename(&part, &path).inspect_err(|_| {
        let _ = std::fs::remove_file(&part);
    })?;
    Ok(path)
}

/// Takes the notice at `path`: its content when this call took it, none when another reader
/// took it first (or it cannot be read).
pub fn take(path: &Path) -> Option<Value> {
    let mut taken = path.as_os_str().to_owned();
    taken.push(format!(".taken-{}", uuid::Uuid::now_v7()));
    let taken = PathBuf::from(taken);
    std::fs::rename(path, &taken).ok()?;
    let text = std::fs::read(&taken);
    let _ = std::fs::remove_file(&taken);
    serde_json::from_slice(&text.ok()?).ok()
}

/// Takes every notice left in `dir`, oldest name first.
pub fn take_all(dir: &Path) -> Vec<Value> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with(SUFFIX) && !n.starts_with('.'))
        })
        .collect();
    paths.sort();
    paths.into_iter().filter_map(|p| take(&p)).collect()
}

/// The subagent folders of `session` that hold anything, with whether each one stopped.
pub fn agents(home: &Path, session: &str) -> Vec<(PathBuf, bool)> {
    let Ok(entries) = std::fs::read_dir(session_dir(home, session)) else { return Vec::new() };
    entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .map(|p| {
            let stopped = stopped(&p);
            (p, stopped)
        })
        .collect()
}

/// Marks the subagent of `dir` stopped: it reads no more notices.
pub fn mark_stopped(dir: &Path) -> std::io::Result<()> {
    create_private(dir)?;
    write_private(&dir.join(STOPPED), b"")
}

/// Whether the subagent of `dir` stopped.
pub fn stopped(dir: &Path) -> bool {
    dir.join(STOPPED).exists()
}

/// Removes `session`'s folder and every notice in it: the session closed.
pub fn forget(home: &Path, session: &str) {
    let _ = std::fs::remove_dir_all(session_dir(home, session));
}

/// Removes `session`'s emptied folders, once its notices were taken and no subagent of it runs.
/// A folder a notice was left in meanwhile stays: whoever left it takes it back ([`take`]).
pub fn tidy(home: &Path, session: &str) {
    for (dir, _) in agents(home, session) {
        let _ = std::fs::remove_file(dir.join(STOPPED));
        let _ = std::fs::remove_dir(&dir);
    }
    let _ = std::fs::remove_dir(session_dir(home, session));
}

/// `dir` and its parents, the folders acpmux makes owner-only.
fn create_private(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut at = Some(dir);
        // The session's folder and the subagent's: the shared `run` folder is the daemon's own.
        for _ in 0..2 {
            let Some(d) = at else { break };
            std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700))?;
            at = d.parent();
        }
    }
    Ok(())
}

/// Writes `bytes` to a new owner-only file at `path`.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)?.write_all(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_notice_is_taken_once_and_a_stop_mark_stays() {
        let home = std::env::temp_dir().join(format!("subagent-notice-{}", uuid::Uuid::now_v7()));
        let dir = agent_dir(&home, "s/1", "a0a68e7af3df5967e").unwrap();
        assert!(dir.starts_with(home.join("run/subagent-notices/s_1")), "{dir:?}");
        assert_eq!(agent_dir(&home, "s1", "../x"), None, "no path from an id");
        assert_eq!(agent_dir(&home, "s1", ".."), None, "no path from an id");
        assert_eq!(agent_dir(&home, "s1", "."), None, "no path from an id");
        let path = leave(&dir, "lane-report-1", &json!({"text": "one"})).unwrap();
        leave(&dir, "lane-report-2", &json!({"text": "two"})).unwrap();
        assert_eq!(take(&path), Some(json!({"text": "one"})));
        assert_eq!(take(&path), None, "taken once");
        assert_eq!(take_all(&dir), vec![json!({"text": "two"})]);
        assert!(take_all(&dir).is_empty());
        assert_eq!(agents(&home, "s/1"), vec![(dir.clone(), false)]);
        mark_stopped(&dir).unwrap();
        assert!(stopped(&dir));
        assert_eq!(agents(&home, "s/1"), vec![(dir.clone(), true)]);
        let kept = leave(&dir, "lane-report-3", &json!({"text": "three"})).unwrap();
        tidy(&home, "s/1");
        assert_eq!(take(&kept), Some(json!({"text": "three"})), "tidy keeps a left notice");
        tidy(&home, "s/1");
        assert!(agents(&home, "s/1").is_empty());
        leave(&dir, "lane-report-4", &json!({"text": "four"})).unwrap();
        forget(&home, "s/1");
        assert!(agents(&home, "s/1").is_empty());
        let _ = std::fs::remove_dir_all(&home);
    }
}
