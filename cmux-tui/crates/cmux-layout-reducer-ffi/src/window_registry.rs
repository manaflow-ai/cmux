//! `cmux_layout_reducer::window_registry` over the JSON channel (op `registry_apply`): one action
//! on the app's window registry (which windows exist, the workspaces each lists and owns, their
//! recency and kind). `schemas/window-registry/vectors.json` has every action with the answer the
//! app's Swift `WindowRegistry` gave.
//!
//! - `registry_apply` `{registry, action}` -> `{registry, changes, value}`: `action` is
//!   `{kind, ...}` (`openWindow`, `close`, `move`, `reconcile`, `gather`, a query such as `owner`);
//!   `changes` is `{emptied, moved, discarded}`; `value` is the action's answer (null for most).
//!
//! The op is not `window_*`: that prefix is [`crate::window_rules`]'s.

use crate::ERR_INVALID;
use cmux_layout_reducer::window_registry::{Action, Registry};
use serde::Deserialize;
use serde_json::json;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"registry_apply"
}

#[derive(Deserialize)]
struct ApplyRequest {
    registry: Registry,
    action: Action,
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let ApplyRequest { mut registry, action } =
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    let (changes, value) = registry.apply(action);
    let reply = json!({ "registry": registry, "changes": changes, "value": value });
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
