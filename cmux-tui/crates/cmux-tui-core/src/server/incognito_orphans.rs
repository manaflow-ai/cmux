//! Incognito workspaces outlive no app crash (design/spaces.md "Incognito":
//! deleted at close, at quit and after a crash; leak 8 of the incognito
//! audit). The daemon closes every ephemeral workspace left by an earlier
//! run at its start (`Mux::close_ephemeral_workspaces`), but an app that
//! crashes while the daemon keeps running used to find its incognito
//! workspaces again and show them in a new incognito window.
//!
//! The daemon owns that close (OWNERSHIP-PRINCIPLES.md): it remembers which
//! app process (the socket peer key, `token:<pid>.<pidversion>`, of a
//! role-main connection) created each ephemeral workspace. When a role-main
//! connection of another process reads the session (`session.snapshot` or
//! `session.events`, the app's first reads) while the creating process has
//! no connection left, those workspaces are closed first, so the new app
//! never sees them. A creator that reconnects (same process) keeps its
//! workspaces. The record is in memory only: a daemon restart closes every
//! ephemeral workspace anyway.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::Mux;
use crate::panic_free::RecoverPoison;
use crate::request_origin::HelloRole;
use crate::resource::ResourceOperation;

/// Ephemeral workspace public id -> the peer key of the app process that
/// created it.
#[derive(Default)]
pub(crate) struct IncognitoCreators {
    by_workspace: Mutex<HashMap<String, String>>,
    /// Held by a move for its whole run ([`MoveClaim`]).
    moves: Mutex<()>,
}

/// The peer key of `client` when it is an app connection (role main).
fn app_peer_key(mux: &Mux, client: u64) -> Option<String> {
    let state = mux.control_clients.state.lock().recover_poison();
    let record = state.clients.get(&client)?;
    (record.origin.role == HelloRole::Main).then(|| record.origin.peer_key.clone()).flatten()
}

/// After a resource request answered: remember the creator of the
/// ephemeral workspace an app connection's `workspace.create {ephemeral}`
/// made.
pub(super) fn note_create(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
    ephemeral: bool,
    response: &Value,
) {
    if operation != ResourceOperation::WorkspaceCreate || !ephemeral || response["ok"] != true {
        return;
    }
    let result = &response["result"];
    let Some(workspace) =
        result["value"]["workspace_id"].as_str().or_else(|| result["workspace_id"].as_str())
    else {
        return;
    };
    let Some(peer_key) = app_peer_key(mux, client) else { return };
    mux.control_clients
        .incognito_creators
        .by_workspace
        .lock()
        .recover_poison()
        .insert(workspace.to_string(), peer_key);
}

/// A move in flight that may make incognito workspaces
/// (`state::ephemeral_moves` marks a workspace made for content moved out
/// of an incognito one). Moves run one at a time while it lives, so the
/// incognito workspaces that appear between [`begin_move`] and
/// [`MoveClaim::finish`] are exactly this move's, and they go to its app.
pub(super) struct MoveClaim<'a> {
    before: HashSet<String>,
    _moves: std::sync::MutexGuard<'a, ()>,
}

/// Before a move: nothing while no incognito workspace is tracked (a move
/// then makes none an app owns).
pub(super) fn begin_move(mux: &Mux) -> Option<MoveClaim<'_>> {
    let creators = &mux.control_clients.incognito_creators;
    if creators.by_workspace.lock().recover_poison().is_empty() {
        return None;
    }
    let moves = creators.moves.lock().recover_poison();
    match mux.read_registry_state(crate::state::store::ephemeral_workspaces) {
        Ok(before) => Some(MoveClaim { before: before.into_iter().collect(), _moves: moves }),
        Err(error) => {
            eprintln!("cmux-tui: could not list incognito workspaces before a move: {error:#}");
            None
        }
    }
}

impl MoveClaim<'_> {
    /// After the move: app connection `client` owns the incognito
    /// workspaces it made.
    pub(super) fn finish(self, mux: &Mux, client: u64) {
        let Some(peer_key) = app_peer_key(mux, client) else { return };
        let after = match mux.read_registry_state(crate::state::store::ephemeral_workspaces) {
            Ok(after) => after,
            Err(error) => {
                eprintln!("cmux-tui: could not list incognito workspaces after a move: {error:#}");
                return;
            }
        };
        let mut by_workspace =
            mux.control_clients.incognito_creators.by_workspace.lock().recover_poison();
        for workspace in after.into_iter().filter(|workspace| !self.before.contains(workspace)) {
            by_workspace.entry(workspace).or_insert_with(|| peer_key.clone());
        }
    }
}

/// The operations that can make a workspace for content moved out of
/// another one.
pub(super) fn moves_content(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::TabMove
            | ResourceOperation::TerminalMove
            | ResourceOperation::ScreenMove
            | ResourceOperation::TabGroupMove
            | ResourceOperation::LayoutBulk
            | ResourceOperation::WorkspaceLayoutApply
    )
}

/// The workspaces in `creators` whose creating process is not `reader`,
/// has no connection among `connected` and has exited (`gone`). A process
/// that exited cannot reconnect, so a close never races its return.
fn orphaned(
    creators: &HashMap<String, String>,
    reader: &str,
    connected: &HashSet<String>,
    gone: impl Fn(&str) -> bool,
) -> Vec<String> {
    creators
        .iter()
        .filter(|(_, creator)| {
            creator.as_str() != reader && !connected.contains(*creator) && gone(creator)
        })
        .map(|(workspace, _)| workspace.clone())
        .collect()
}

/// Whether the process of peer key `peer_key` (`token:<pid>.<pidversion>`)
/// has exited. A live process with that pid (the same one, or a later one
/// that reused the pid) keeps its workspaces: a wrong keep is undone at the
/// next daemon start, a wrong close loses an open space.
fn process_gone(peer_key: &str) -> bool {
    let Some(pid) = super::origin_gate::peer_pid(peer_key) else { return true };
    #[cfg(unix)]
    {
        let Ok(pid) = libc::pid_t::try_from(pid) else { return true };
        // SAFETY: signal 0 only checks that the process exists.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return false;
        }
        std::io::Error::last_os_error().raw_os_error() != Some(libc::EPERM)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        true
    }
}

/// The peer keys of every connection.
fn connected(mux: &Mux) -> HashSet<String> {
    let state = mux.control_clients.state.lock().recover_poison();
    state.clients.values().filter_map(|record| record.origin.peer_key.clone()).collect()
}

/// Before an app connection's session read: close the incognito workspaces
/// of app processes that are gone. Cheap when there are none.
pub(super) fn close_orphaned(mux: &Arc<Mux>, client: u64) {
    let creators = &mux.control_clients.incognito_creators;
    if creators.by_workspace.lock().recover_poison().is_empty() {
        return;
    }
    let Some(reader) = app_peer_key(mux, client) else { return };
    // Workspaces closed another way leave the record here.
    match mux.read_registry_state(crate::state::store::ephemeral_workspaces) {
        Ok(live) => {
            let live: HashSet<String> = live.into_iter().collect();
            creators.by_workspace.lock().recover_poison().retain(|workspace, _| live.contains(workspace));
        }
        Err(error) => {
            eprintln!("cmux-tui: could not list incognito workspaces: {error:#}");
            return;
        }
    }
    // Lock order: the client state, then the creators (never the reverse).
    let connected = connected(mux);
    let orphans = {
        let mut by_workspace = creators.by_workspace.lock().recover_poison();
        let orphans = orphaned(&by_workspace, &reader, &connected, process_gone);
        orphans
            .into_iter()
            .filter_map(|workspace| {
                by_workspace.remove(&workspace).map(|creator| (workspace, creator))
            })
            .collect::<Vec<_>>()
    };
    for (workspace, creator) in orphans {
        if let Err(error) = mux.close_ephemeral_workspace(&workspace) {
            eprintln!(
                "cmux-tui: could not close incognito workspace {workspace} of gone app {creator}: {error:#}"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_workspaces_of_a_gone_other_process_are_orphaned() {
        let creators = HashMap::from([
            ("gone".to_string(), "token:1.1".to_string()),
            ("reader".to_string(), "token:2.1".to_string()),
            ("connected".to_string(), "token:3.1".to_string()),
        ]);
        let connected = HashSet::from(["token:2.1".to_string(), "token:3.1".to_string()]);
        let all_gone = |_: &str| true;
        assert_eq!(orphaned(&creators, "token:2.1", &connected, all_gone), vec!["gone".to_string()]);
        // A new process with the old pid (another pid version) is another process.
        assert_eq!(orphaned(&creators, "token:1.2", &connected, all_gone), vec!["gone".to_string()]);
        // A creator whose process still runs keeps its workspaces.
        assert!(orphaned(&creators, "token:2.1", &connected, |_| false).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn a_running_process_is_not_gone() {
        assert!(!process_gone(&format!("token:{}.1", std::process::id())));
        // Above every pid_max (Linux 4194304, macOS 99999).
        assert!(process_gone("token:999999901.1"));
    }
}
