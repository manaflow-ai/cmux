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
}

/// The peer key of `client` when it is an app connection (role main).
fn app_peer_key(mux: &Mux, client: u64) -> Option<String> {
    let state = mux.control_clients.state.lock().recover_poison();
    let record = state.clients.get(&client)?;
    (record.origin.role == HelloRole::Main).then(|| record.origin.peer_key.clone()).flatten()
}

/// After `workspace.create` answered: remember the creator of an ephemeral
/// workspace an app connection created.
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

/// The workspaces in `creators` whose creating process is not `reader` and
/// has no connection among `connected`.
fn orphaned(
    creators: &HashMap<String, String>,
    reader: &str,
    connected: &HashSet<String>,
) -> Vec<String> {
    creators
        .iter()
        .filter(|(_, creator)| creator.as_str() != reader && !connected.contains(*creator))
        .map(|(workspace, _)| workspace.clone())
        .collect()
}

/// Before an app connection's session read: close the incognito workspaces
/// of app processes that are gone. Cheap when there are none.
pub(super) fn close_orphaned(mux: &Arc<Mux>, client: u64) {
    let creators = &mux.control_clients.incognito_creators;
    if creators.by_workspace.lock().recover_poison().is_empty() {
        return;
    }
    let Some(reader) = app_peer_key(mux, client) else { return };
    let connected: HashSet<String> = {
        let state = mux.control_clients.state.lock().recover_poison();
        state.clients.values().filter_map(|record| record.origin.peer_key.clone()).collect()
    };
    let orphans = {
        let mut by_workspace = creators.by_workspace.lock().recover_poison();
        let orphans = orphaned(&by_workspace, &reader, &connected);
        for workspace in &orphans {
            by_workspace.remove(workspace);
        }
        orphans
    };
    for workspace in orphans {
        if let Err(error) = mux.close_ephemeral_workspace(&workspace) {
            eprintln!(
                "cmux-tui: could not close incognito workspace {workspace} of a gone app: {error:#}"
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
        assert_eq!(orphaned(&creators, "token:2.1", &connected), vec!["gone".to_string()]);
        // A new process with the old pid (another pid version) is another process.
        assert_eq!(orphaned(&creators, "token:1.2", &connected), vec!["gone".to_string()]);
    }
}
