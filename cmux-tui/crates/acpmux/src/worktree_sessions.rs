//! The agent sessions on this machine and the folders worktrees live in,
//! for worktree cleanup (`cmux-worktree-care`): `acpmux worktree` and the
//! daemon's own passes (`hub/worktree_care.rs`) read them the same way.
//!
//! Sessions come from every acpmux state folder on this machine (the
//! person's daemon, Chief's, every build's, as the build resolvers name
//! them), read from their session files, so a session of a daemon this
//! process does not talk to still keeps its worktree. What works where
//! outside acpmux comes from Claude Code's own session registry. A session not closed is open while its daemon runs;
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

/// The setting naming more acpmux state folders to read (a supervisor's
/// own daemons), as a list of paths.
pub const SETTING_STATE_HOMES: &str = "worktrees.stateHomes";

/// A bundled build other than NIGHTLY: its home is one of the per-build
/// homes, so its parent is where they all live.
const A_BUNDLED_BUILD: &str = "com.cmuxterm.app.debug";

/// The acpmux state folders on this machine, as the build resolvers name
/// them (`BuildIdentity`): this process's home, the shared one, every
/// build's, every Chief's (and an isolated Chief's), and those the
/// `worktrees.stateHomes` setting adds.
pub fn state_folders(home: &Path) -> Vec<PathBuf> {
    use cmux_agent_pane_policy::build_identity::BuildIdentity;
    let shared = BuildIdentity::new(None, None);
    let mut homes =
        vec![crate::config::home(), crate::config::default_home(), shared.acpmux_home(home)];
    let children = |folder: &Path| -> Vec<PathBuf> {
        std::fs::read_dir(folder)
            .map(|entries| entries.flatten().map(|e| e.path()).collect())
            .unwrap_or_default()
    };
    if let Some(builds) = BuildIdentity::new(Some(A_BUNDLED_BUILD), None).acpmux_home(home).parent()
    {
        homes.extend(children(builds));
    }
    let chief_roots = std::env::var_os("CMUX_NEXT_CHIEF_ROOT")
        .map(PathBuf::from)
        .into_iter()
        .chain(shared.chief_home(home, "default").parent().map(Path::to_path_buf));
    for root in chief_roots {
        for chief in children(&root) {
            homes.push(chief.join("acpmux"));
            // An isolated Chief: `<root>/isolated/<tag>/acpmux`.
            homes.extend(children(&chief).into_iter().map(|tag| tag.join("acpmux")));
        }
    }
    homes.extend(setting_homes());
    homes.retain(|state| state.join("sessions").is_dir());
    homes.sort();
    homes.dedup();
    homes
}

fn setting_homes() -> Vec<PathBuf> {
    let crate::user_settings::Settings::Parsed(doc) = crate::user_settings::read() else {
        return Vec::new();
    };
    crate::user_settings::value(&doc, SETTING_STATE_HOMES)
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str())
        .map(|p| match p.strip_prefix("~/") {
            Some(rest) => dirs::home_dir().map_or_else(|| PathBuf::from(p), |h| h.join(rest)),
            None => PathBuf::from(p),
        })
        .collect()
}

/// The Claude Code config folders whose session registries name what works
/// where: the login one (`CLAUDE_CONFIG_DIR`, else `~/.claude`) and every
/// harness profile's own (`chats::sources::launch_roots`) in each state
/// folder's config.
pub fn claude_homes(home: &Path, configs: &[crate::config::Config]) -> Vec<PathBuf> {
    use cmux_chat_index::AdapterKind;
    let mut dirs = vec![
        crate::chats::sources::login_var("CLAUDE_CONFIG_DIR")
            .map_or_else(|| home.join(".claude"), PathBuf::from),
    ];
    for config in configs {
        dirs.extend(
            crate::chats::sources::launch_roots(config)
                .into_iter()
                .filter(|root| root.harness == AdapterKind::ClaudeCode)
                // A root is `<CLAUDE_CONFIG_DIR>/projects`.
                .filter_map(|root| root.path.parent().map(Path::to_path_buf)),
        );
    }
    dirs.sort();
    dirs.dedup();
    dirs
}

/// Every state folder's config that loads.
pub fn state_configs(home: &Path) -> Vec<crate::config::Config> {
    state_folders(home)
        .iter()
        .filter_map(|state| crate::config::Config::load_from(&state.join("config.json")).ok())
        .collect()
}

/// What works where besides acpmux sessions, for a pass (`Options::uses`):
/// the running Claude Code sessions of `claude_homes`.
pub fn uses(claude_homes: Vec<PathBuf>) -> std::sync::Arc<cmux_worktree_care::procs::Uses> {
    std::sync::Arc::new(move || cmux_worktree_care::procs::claude_sessions(&claude_homes))
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
        // The shared state folder of this home (`BuildIdentity` with no build).
        let state = cmux_agent_pane_policy::build_identity::BuildIdentity::new(None, None)
            .acpmux_home(&home);
        let session = state.join("sessions/one");
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
        let skipped = on_disk(&home, Some(&state));
        assert!(skipped.iter().all(|s| s.name != "lane"));
        let _ = std::fs::remove_dir_all(home);
    }
}
