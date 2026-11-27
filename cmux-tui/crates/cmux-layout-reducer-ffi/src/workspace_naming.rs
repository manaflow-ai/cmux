//! `cmux-workspace-naming`'s rules over the JSON channel (ops `workspace_naming_*`): the name a
//! new or moved workspace takes, the auto-name label and what it persists, the activity prompt
//! and its reply, and the namer's hold and submission ledger. The app's holds and namers each
//! keep an id; one set of rules keeps their state for every call.

use crate::ERR_INVALID;
use cmux_workspace_naming::ops::WorkspaceNaming;
use std::sync::{Mutex, PoisonError};

static RULES: Mutex<Option<WorkspaceNaming>> = Mutex::new(None);

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(WorkspaceNaming::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let mut rules = RULES.lock().unwrap_or_else(PoisonError::into_inner);
    let reply = rules
        .get_or_insert_with(WorkspaceNaming::new)
        .call(operation, request)
        .map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
