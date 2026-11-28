//! `cmux_layout_reducer::window_registry_store` over the JSON channel: the app's registry holder
//! (`WindowRegistryStore`), its launch memory (`RestoreClosedWindows`) and its workspace claims
//! (`WorkspaceClaims`). `schemas/window-registry-store/vectors.json` has every op with the answer
//! the app's Swift types gave.
//!
//! - `registry_store_apply` `{store, action}` -> `{store, changes, value}`: `action` is `{kind, ...}`
//!   (`apply` with a registry action, `gatherBegin`, `unlisted`, `takeCloseWork`, a query such as
//!   `members`); `changes` is the registry's; `value` is the action's answer (null for most).
//! - `registry_store_restore_closed` `{memory, registry, action}` -> `{memory, registry}`: `action`
//!   is `closed`, `reopened`, `awaiting`, `keepClosed` (closes windows of `registry`),
//!   `restoreEnded` or `settle` (with the workspaces the store lists as `listed`).
//! - `registry_store_claims` `{claims, action}` -> `{claims, value}`: `awaits` or `release`.
//!
//! The ops are not `window_*`: that prefix is [`crate::window_rules`]'s.

use crate::ERR_INVALID;
use cmux_layout_reducer::window_registry::Registry;
use cmux_layout_reducer::window_registry_store::{
    Claims, ClaimsAction, RestoreClosed, RestoreClosedAction, Store, StoreAction,
};
use serde::Deserialize;
use serde_json::{Value, json};

pub(crate) fn handles(operation: &[u8]) -> bool {
    matches!(
        operation,
        b"registry_store_apply" | b"registry_store_restore_closed" | b"registry_store_claims"
    )
}

#[derive(Deserialize)]
struct StoreRequest {
    store: Store,
    action: StoreAction,
}

#[derive(Deserialize)]
struct RestoreClosedRequest {
    memory: RestoreClosed,
    registry: Registry,
    action: RestoreClosedAction,
}

#[derive(Deserialize)]
struct ClaimsRequest {
    claims: Claims,
    action: ClaimsAction,
}

fn parse<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply: Value = match operation {
        b"registry_store_apply" => {
            let StoreRequest { mut store, action } = parse(request)?;
            let (changes, value) = store.run(action);
            json!({ "store": store, "changes": changes, "value": value })
        }
        b"registry_store_restore_closed" => {
            let RestoreClosedRequest { mut memory, mut registry, action } = parse(request)?;
            memory.run(&mut registry, action);
            json!({ "memory": memory, "registry": registry })
        }
        b"registry_store_claims" => {
            let ClaimsRequest { mut claims, action } = parse(request)?;
            let value = claims.run(action);
            json!({ "claims": claims, "value": value })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
