//! `tab.create_terminal` in a workspace whose screen holds nothing but an
//! agent chat: the terminal opens in a new column on the chat's right,
//! never among the chat's own tabs.
//!
//! The app opens an agent chat as one plain pane, so a terminal made with
//! only the workspace named (`cmux tab create terminal --workspace <ws>`,
//! the Chief's "show the work in the subagent's workspace", an MCP
//! `tab_create_terminal {workspace}`) had no pane to go to but the chat's
//! own, and became a tab in the chat's strip (Lawrence 2026-11-19: "agent
//! chat that is on left, will open stuff to the right"). With a pane on the
//! right the tab goes there (`right_pane_beside_focused_dock`); this module
//! is the case with none: one `pane.split` right of the chat that shares
//! the window (`fit`), as `workspace.open_url` makes for a link and as the
//! CLI makes for a terminal the chat's own agent opens (cli/beside.rs).
//! The split takes the creation's command, folder, size and correlation
//! key; a split has no name, so a `tab.rename` gives the new tab the name
//! the creation asked for. The focus stays in the chat (the router's
//! `pane.split` does not take it).
//!
//! The split runs under the creation's own idempotency and correlation
//! keys, so the request's creation record (`session.creation.resolve`) is
//! the split's, and a retry is answered by what that record says: a split
//! made before is sent again and replays, also now that the chat is no
//! longer alone; a tab the daemon's own path made before (the chat was not
//! alone then) is left to that path, which replays it; with no record the
//! split is made only for a chat that is alone. A retry after the chat
//! left its place gets the daemon's conflict error, never a second
//! terminal. One creation decides and splits at a time, so two that arrive
//! together make one column, not two. A request that names a screen or a
//! pane, a screen with a dock, and a chat that runs no session (the New
//! Tab page) keep the daemon's own placement.

use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::{
    ParsedResourceRequest, dispatch_resource_request, open_url, resource_operation_error,
    validate_resource_envelope,
};
use crate::Mux;
use crate::mux::PANE_SPLIT_FIT_FIELD;
use crate::resource::{RequestEnvelope, ResourceError, ResourceOperation};

/// What the split takes from the creation it stands for (`name` goes to the
/// rename, `correlation_key` is always set).
const CARRIED: [&str; 8] =
    ["machine", "session", "cwd", "argv", "shell", "cols", "rows", "expected_revision"];

/// Held from the decision to the split's answer: the next creation then
/// sees the column this one made.
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

/// The split's reply, when `request` is a terminal for a workspace that
/// holds only an agent chat; `None` leaves the request to its own path.
pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Option<Value>, ResourceError> {
    if request.envelope.operation != ResourceOperation::TabCreateTerminal {
        return Ok(None);
    }
    let (Some(key), Some(params)) =
        (request.envelope.idempotency_key.as_deref(), request.envelope.params.as_object())
    else {
        return Ok(None);
    };
    if !open_url::names_only_workspace(&request.selectors) {
        return Ok(None);
    }
    // No chat that is not docked: nothing to decide, so no wait for the lock.
    if open_url::undocked_chat(mux, &request.selectors).is_none() {
        return Ok(None);
    }
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(chat) = open_url::undocked_chat(mux, &request.selectors) else { return Ok(None) };
    let correlation = params.get("correlation_key").and_then(Value::as_str).unwrap_or(key);
    let record = mux.resource_creation_resolution(correlation).map_err(resource_operation_error)?;
    // An earlier attempt's path answers this one too; a first attempt goes
    // right only for a chat that is alone.
    let split_name = ResourceOperation::PaneSplit.wire_name();
    let made_by = record.get("operation").and_then(Value::as_str);
    if !made_by.map_or(chat.alone, |operation| operation == split_name) {
        return Ok(None);
    }
    let mut split = Map::new();
    for field in CARRIED {
        if let Some(value) = params.get(field) {
            split.insert(field.to_string(), value.clone());
        }
    }
    split.insert("correlation_key".to_string(), json!(correlation));
    split.insert("pane".to_string(), json!(chat.pane.as_str()));
    split.insert("direction".to_string(), json!("right"));
    split.insert(PANE_SPLIT_FIT_FIELD.to_string(), json!(true));
    let mut created = inner(mux, request, ResourceOperation::PaneSplit, split, key)?;
    let name = params.get("name").filter(|name| name.is_string());
    let tab = created.pointer("/value/tab_id").and_then(Value::as_str).map(str::to_owned);
    if let (Some(name), Some(tab)) = (name, tab) {
        let mut rename = Map::new();
        for selector in ["machine", "session"] {
            if let Some(value) = params.get(selector) {
                rename.insert(selector.to_string(), value.clone());
            }
        }
        rename.insert("tab".to_string(), json!(tab));
        rename.insert("name".to_string(), name.clone());
        match inner(mux, request, ResourceOperation::TabRename, rename, &name_key(key)) {
            // The revision a caller chains from is the one after the name.
            Ok(renamed) => {
                if let (Some(reply), Some(revision)) =
                    (created.as_object_mut(), renamed.get("revision"))
                {
                    reply.insert("revision".to_string(), revision.clone());
                }
            }
            // The same key with another name: refused, as the daemon's own
            // path refuses a key sent again with other input.
            Err(error) if error.code == "idempotency.conflict" => return Err(error),
            // The terminal is made: a name that cannot be set (its tab
            // closed meanwhile) does not fail the creation, which a caller
            // would send again and get a second terminal.
            Err(_) => {}
        }
    }
    Ok(Some(created))
}

/// One step of `request`, as its actor, through the router.
fn inner(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
    operation: ResourceOperation,
    params: Map<String, Value>,
    key: &str,
) -> Result<Value, ResourceError> {
    let envelope = RequestEnvelope::request(
        request.envelope.id.clone(),
        operation,
        Value::Object(params),
        Some(key.to_string()),
    );
    dispatch_resource_request(mux, validate_resource_envelope(envelope, request.actor.clone())?)
}

/// The rename's key, derived from the request's key (at most 128 bytes): a
/// retry replays the rename.
fn name_key(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    let hash: String = digest.iter().take(16).map(|byte| format!("{byte:02x}")).collect();
    format!("tab-beside-chat-name-{hash}")
}
