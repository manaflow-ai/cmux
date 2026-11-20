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
//! A retry with the same key finds the split its first attempt made (by
//! the split's creation record) and sends the same split again, which
//! replays, also now that the chat is no longer alone. A request that
//! names a screen or a pane, a screen with a dock, and a chat that runs no
//! session (the New Tab page) keep the daemon's own placement.

use std::sync::Arc;

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
/// rename).
const CARRIED: [&str; 9] = [
    "machine",
    "session",
    "correlation_key",
    "cwd",
    "argv",
    "shell",
    "cols",
    "rows",
    "expected_revision",
];

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
    let Some(chat) = open_url::undocked_chat(mux, &request.selectors) else { return Ok(None) };
    let steps = StepKeys::new(key);
    // The split's creation record is under the caller's correlation key
    // when the creation names one, else under the split's own key.
    let correlation =
        params.get("correlation_key").and_then(Value::as_str).unwrap_or(steps.split.as_str());
    if !chat.alone && !split_before(mux, correlation)? {
        return Ok(None);
    }
    let mut split = Map::new();
    for field in CARRIED {
        if let Some(value) = params.get(field) {
            split.insert(field.to_string(), value.clone());
        }
    }
    split.insert("pane".to_string(), json!(chat.pane.as_str()));
    split.insert("direction".to_string(), json!("right"));
    split.insert(PANE_SPLIT_FIT_FIELD.to_string(), json!(true));
    let created = inner(mux, request, ResourceOperation::PaneSplit, split, &steps.split)?;
    let name = params.get("name").filter(|name| name.is_string());
    if let (Some(name), Some(tab)) = (name, created["value"]["tab_id"].as_str()) {
        let mut rename = Map::new();
        for selector in ["machine", "session"] {
            if let Some(value) = params.get(selector) {
                rename.insert(selector.to_string(), value.clone());
            }
        }
        rename.insert("tab".to_string(), json!(tab));
        rename.insert("name".to_string(), name.clone());
        inner(mux, request, ResourceOperation::TabRename, rename, &steps.name)?;
    }
    Ok(Some(created))
}

/// Whether an earlier attempt of this request made its split.
fn split_before(mux: &Arc<Mux>, correlation: &str) -> Result<bool, ResourceError> {
    let resolution =
        mux.resource_creation_resolution(correlation).map_err(resource_operation_error)?;
    Ok(resolution["operation"].as_str() == Some(ResourceOperation::PaneSplit.wire_name()))
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

/// The keys of the steps, derived from the request's key (at most 128
/// bytes): a retry replays each step.
struct StepKeys {
    split: String,
    name: String,
}

impl StepKeys {
    fn new(key: &str) -> Self {
        let digest = Sha256::digest(key.as_bytes());
        let hash: String = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect();
        Self {
            split: format!("tab-beside-chat-{hash}"),
            name: format!("tab-beside-chat-name-{hash}"),
        }
    }
}
