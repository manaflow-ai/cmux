//! The agent sessions on this machine and the folders worktrees live in,
//! for worktree cleanup (`cmux-worktree-care`): `acpmux worktree` and the
//! daemon's own passes (`hub/worktree_care.rs`) read them the same way.
//!
//! Sessions come from every acpmux state folder on this machine (the
//! person's daemon, Chief's, a tagged build's), read from their session
//! files, so a session of a daemon this process does not talk to still
//! keeps its worktree. A session not closed is open while its daemon runs;
//! a stopped daemon's sessions count as use at their last change.

use std::path::{Path, PathBuf};

use cmux_worktree_care::policy::Session;
use serde::Deserialize;

/// The folders agents' worktrees live under by default: ~/Projects, ~/wt
/// and its children, ~/.cmux/worktrees/*, ~/src, ~/code.
pub fn default_roots(home: &Path) -> Vec<PathBuf> {
    let mut roots =
        vec![home.join("Projects"), home.join("wt"), home.join("src"), home.join("code")];
    for parent in [home.join("wt"), home.join(".cmux/worktrees")] {
        if let Ok(entries) = std::fs::read_dir(&parent) {
            roots.extend(entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()));
        }
    }
    roots.retain(|root| root.is_dir());
    roots
}

/// A session file's fields cleanup reads.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionFile {
    name: String,
    cwd: PathBuf,
    status: String,
    #[serde(default)]
    updated_at: u64,
}

/// The acpmux state folders on this machine.
pub fn state_folders(home: &Path) -> Vec<PathBuf> {
    let mut homes = vec![crate::config::home(), crate::config::default_home()];
    if let Ok(entries) = std::fs::read_dir(home) {
        for entry in entries.flatten() {
            if !entry.file_name().to_string_lossy().starts_with(".acpmux") {
                continue;
            }
            let path = entry.path();
            // A supervised daemon keeps one folder per host.
            if let Ok(children) = std::fs::read_dir(&path) {
                homes.extend(children.flatten().map(|c| c.path()));
            }
            homes.push(path);
        }
    }
    if let Ok(entries) = std::fs::read_dir(home.join(".cmux/chief")) {
        homes.extend(entries.flatten().map(|e| e.path().join("acpmux")));
    }
    homes.retain(|state| state.join("sessions").is_dir());
    homes.sort();
    homes.dedup();
    homes
}

/// Every session in the state folders, except those of `skip` (a daemon
/// that reports its own sessions live).
pub fn on_disk(home: &Path, skip: Option<&Path>) -> Vec<Session> {
    let mut found = Vec::new();
    for state in state_folders(home) {
        if skip.is_some_and(|skip| skip == state) {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(state.join("sessions")) else { continue };
        let running = daemon_runs(&state);
        for entry in entries.flatten() {
            let Ok(bytes) = std::fs::read(entry.path().join("session.json")) else { continue };
            let Ok(file) = serde_json::from_slice::<SessionFile>(&bytes) else { continue };
            found.push(Session {
                name: file.name,
                cwd: file.cwd,
                open: running && file.status != "closed",
                updated_ms: file.updated_at,
            });
        }
    }
    found
}

/// Whether a daemon answers on the state folder's socket.
#[cfg(unix)]
fn daemon_runs(state: &Path) -> bool {
    std::os::unix::net::UnixStream::connect(state.join("acpmux.sock")).is_ok()
}

/// Windows: no socket to try, so every session not closed counts as open.
#[cfg(not(unix))]
fn daemon_runs(_state: &Path) -> bool {
    true
}

#[cfg(test)]
mod care_tests {
    use super::*;

    #[test]
    fn care_a_stopped_daemon_s_sessions_are_use_not_open() {
        let home = std::env::temp_dir()
            .join(format!("care-sessions-{}", cmux_worktree_care::inventory::now_ms()));
        let session = home.join(".acpmux-test/sessions/one");
        std::fs::create_dir_all(&session).unwrap();
        std::fs::write(
            session.join("session.json"),
            r#"{"name":"lane","cwd":"/w/a","status":"running","updatedAt":5}"#,
        )
        .unwrap();
        let found: Vec<_> = on_disk(&home, None).into_iter().filter(|s| s.name == "lane").collect();
        assert_eq!(found.len(), 1);
        assert!(!found[0].open, "no daemon answers there");
        assert_eq!(found[0].updated_ms, 5);
        let skipped = on_disk(&home, Some(&home.join(".acpmux-test")));
        assert!(skipped.iter().all(|s| s.name != "lane"));
        let _ = std::fs::remove_dir_all(home);
    }
}
