//! `_acpmux/chat_place_set` and `_acpmux/chat_place`: a new chat's place mode (Auto, Cloud, or
//! one machine) and where it starts with it, for the composer's place picker and chip
//! ([`crate::place_mode`]). The pick is the chat's own: it is kept by chat id (the
//! draft's or the session's) and never becomes the default; a chat with none is Auto.
//!
//! The read weighs this machine and its connected peers with `_acpmux/place` (`place.rs`), and
//! the account the caller sends (acpmux reads no billing). Part of the request handler
//! (`requests.rs`), on this machine's unix socket and the app's own pane only, as
//! `_acpmux/place` is.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use cmux_cloud_start_core::hybrid::Account;

use crate::place_mode::{self, Facts, PlaceMode};
use serde_json::{Value, json};

use crate::hub::Hub;
use crate::rpc::RpcError;

/// The picks, by chat id. A daemon restart forgets them: the chats go back to Auto, the
/// default, which is where a chat nobody picked for starts.
fn picks() -> std::sync::MutexGuard<'static, HashMap<String, PlaceMode>> {
    static PICKS: OnceLock<Mutex<HashMap<String, PlaceMode>>> = OnceLock::new();
    PICKS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

fn chat_of(params: &Value) -> Option<String> {
    params
        .get("chat")
        .or_else(|| params.get("sessionId"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(str::to_owned)
}

/// Keeps `mode` as `chat`'s pick; Auto clears it (Auto is what a chat with none has).
fn keep(chat: &str, mode: PlaceMode) {
    let mut picks = picks();
    if mode == PlaceMode::Auto {
        picks.remove(chat);
    } else {
        picks.insert(chat.to_owned(), mode);
    }
}

/// `chat`'s mode and whether the person picked it: its pick, else Auto.
pub(crate) fn mode_of(chat: &str) -> (PlaceMode, bool) {
    picks().get(chat).cloned().map_or((PlaceMode::Auto, false), |m| (m, true))
}

/// `{"chat": ID, "mode": "auto"|"cloud"|"machine", "machine"?: ID, "account"?: {...}}` → the chat's read ([`read`]) once the pick is kept.
pub(super) async fn set(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let chat = chat_of(params).ok_or_else(|| {
        RpcError::invalid_params("_acpmux/chat_place_set needs the chat's id (`chat`)")
    })?;
    let mode = PlaceMode::from_params(params)
        .map_err(|why| RpcError::invalid_params(format!("_acpmux/chat_place_set: {why}")))?;
    keep(&chat, mode);
    Ok(read(hub, &json!({"chat": chat, "account": params.get("account")})).await)
}

/// `{"chat"?: ID, "mode"?: ... (a mode to weigh instead of the chat's), "account"?: {plan, flag,
/// cloudDisabled, signedIn}}` → `{chat, mode: {mode, machine?}, picked, place: {on:
/// "this-mac"|"cloud"|"machine"|"nowhere", hybrid?, id?}, why, chip, local: {name, busy, room,
/// ramFree}}`.
pub(super) async fn read(hub: &Hub, params: &Value) -> Value {
    let verdict = super::place::place(hub, &json!({"hubHealth": false})).await;
    answer(params, &verdict, &hub.peers())
}

/// [`read`] from the placement verdict and the peer rows.
fn answer(params: &Value, verdict: &Value, peers: &[Value]) -> Value {
    let chat = chat_of(params);
    let (mode, picked) = match PlaceMode::from_params(params) {
        Ok(mode) => (mode, true),
        Err(_) => chat.as_deref().map_or((PlaceMode::Auto, false), mode_of),
    };
    let account: Account = params
        .get("account")
        .and_then(|a| serde_json::from_value(a.clone()).ok())
        .unwrap_or_default();
    let machines = peers
        .iter()
        .filter(|row| crate::placement::link_down(row).is_none())
        .filter_map(|row| row.get("name").and_then(Value::as_str).map(str::to_owned))
        .collect();
    let facts = Facts { local: place_mode::local_of(verdict), account, machines };
    let decision = place_mode::decide(&mode, &facts);
    json!({
        "chat": chat,
        "mode": mode,
        "picked": picked,
        "place": decision.place,
        "why": decision.why,
        "chip": decision.chip,
        "local": facts.local,
    })
}

#[cfg(test)]
#[path = "chat_place_tests.rs"]
mod tests;
