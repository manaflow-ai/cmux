//! `_acpmux/workspace_purge {workspaceId}`: ends and deletes every chat of one cmux workspace.
//!
//! An incognito space keeps no history, is never restored and is deleted when its window closes
//! (leo-workspace design/spaces.md "Incognito"; Leo, 2026-10-31: "like incognito spaces, each new
//! window is a space"). The app calls this for each workspace of an incognito window when the
//! window closes and at quit. A workspace's chats are the sessions acpmux recorded it for when
//! they started (`_meta.acpmux.workspaceId`, `session_env::workspace_id`): the app's own chats,
//! their sub-sessions, forks and side questions (each keeps its parent's), and an agent started
//! from the workspace's terminal (`CMUX_WORKSPACE_ID`).
//!
//! Each one is stopped and purged (`Hub::kill` with purge: its log, queue, background tasks and
//! temporary folder go). Its harness's own transcript would keep the chat in the device chat
//! index (Earlier, the palette, New Tab), so the transcript goes too, but only one this session
//! wrote itself (``own_transcripts``): a conversation the workspace only continued, an adopted
//! or watched chat that existed before, keeps its file.
//!
//! Local unix socket only, as `_acpmux/stats`: a WebSocket origin gets "Method not found".

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_chat_index::{AdapterKind, ChatKey};
use serde_json::{Value, json};

use super::super::{Origin, str_param};
use crate::hub::{Hub, Session};
use crate::rpc::RpcError;
use crate::store::SessionMeta;

pub(crate) const METHOD: &str = crate::rpc::method::MUX_WORKSPACE_PURGE;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::method_not_found(&format!(
            "{METHOD} (served only on the local unix socket)"
        )));
    }
    let workspace = str_param(params, "workspaceId")
        .filter(|w| crate::session_env::is_workspace_id(w))
        .ok_or_else(|| RpcError::invalid_params("workspaceId must be a workspace id (a UUID)"))?
        .to_ascii_lowercase();
    let mut purged = Vec::new();
    let mut transcripts = 0usize;
    for session in of_workspace(hub, &workspace) {
        // A parent's purge may already have taken this one.
        if !hub.resolve(&session.id).is_ok_and(|s| Arc::ptr_eq(&s, &session)) {
            continue;
        }
        // Read before the stop: the purge forgets the session.
        let files = own_transcripts(hub, &session.meta());
        if let Err(e) = hub.kill(&session, true).await {
            tracing::warn!(session = %session.id, "workspace purge failed: {}", e.message);
            continue;
        }
        purged.push(session.id.clone());
        // After the stop, so the harness writes no more of it.
        transcripts += files.iter().filter(|f| remove(f)).count();
        if let Some(index) = hub.chat_index().filter(|_| !files.is_empty()) {
            index.paths_changed(&files, false);
        }
    }
    Ok(json!({"workspaceId": workspace, "purged": purged, "transcripts": transcripts}))
}

/// This daemon's sessions recorded for `workspace` (a lowercase workspace id).
fn of_workspace(hub: &Hub, workspace: &str) -> Vec<Arc<Session>> {
    hub.sessions()
        .into_iter()
        .filter(|s| s.meta().workspace_id.as_deref() == Some(workspace))
        .collect()
}

/// The harness transcripts `meta`'s session wrote itself: for a Claude Code or Codex session, the
/// file the chat index holds for each agent session id it recorded, named for that id, and Claude
/// Code's folder of the same name beside it (subagents, tool results). Only one born after the
/// session was created: an older file is a conversation it continued (an adopted chat), which
/// is not this session's to delete. A watched chat writes none. Other harnesses: none yet.
fn own_transcripts(hub: &Hub, meta: &SessionMeta) -> Vec<PathBuf> {
    let (Some(index), None) = (hub.chat_index(), &meta.watching) else { return Vec::new() };
    let harness = match meta.family.as_deref() {
        Some("claude") => AdapterKind::ClaudeCode,
        Some("codex") => AdapterKind::Codex,
        _ => return Vec::new(),
    };
    let since = UNIX_EPOCH + Duration::from_millis(meta.created_at);
    let mut files = Vec::new();
    for id in meta.agent_session_id.iter().chain(&meta.previous_agent_session_ids) {
        let Some(chat) = index.get(&ChatKey { harness, session_id: id.clone() }) else { continue };
        let file = chat.entry.source_path;
        if !(file.is_absolute() && names(&file, id) && born_since(&file, since)) {
            continue;
        }
        let folder = file.with_file_name(id);
        if harness == AdapterKind::ClaudeCode && folder.is_dir() && born_since(&folder, since) {
            files.push(folder);
        }
        files.push(file);
    }
    files
}

/// Whether `file` is a transcript (`.jsonl`) whose name holds agent session `id`
/// (`<id>.jsonl`, Codex's `rollout-<time>-<id>.jsonl`), never a shared store file.
fn names(file: &Path, id: &str) -> bool {
    !id.is_empty()
        && file.extension().is_some_and(|e| e == "jsonl")
        && file.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.contains(id))
}

/// Whether `path` was created at or after `since`. Unknown (no birth time): false.
fn born_since(path: &Path, since: SystemTime) -> bool {
    std::fs::symlink_metadata(path).and_then(|m| m.created()).is_ok_and(|born| born >= since)
}

fn remove(path: &Path) -> bool {
    let removed =
        if path.is_dir() { std::fs::remove_dir_all(path) } else { std::fs::remove_file(path) };
    removed.is_ok()
}

#[cfg(test)]
#[path = "workspace_purge_tests.rs"]
mod tests;
