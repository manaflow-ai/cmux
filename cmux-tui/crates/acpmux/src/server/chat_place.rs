//! `_acpmux/chat_place_set` and `_acpmux/chat_place`: a new chat's place mode (Auto, Cloud, or
//! one machine) and where it starts with it, for the composer's place picker and chip
//! ([`crate::place_mode`]). The pick is the chat's own: it is kept by chat id (the
//! draft's or the session's) and never becomes the default; a chat with none is Auto. A chat
//! that exists and has no pick here reads as its stored pin (`SessionMeta::place_mode`, what
//! `_acpmux/place_set` and the one-time migration keep: `hub/place_migrate.rs`).
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
/// cloudDisabled, signedIn}, "need"?: {caps, team, agent}, "cloudPool"?: bool}` → `{v: 3, chat,
/// mode: {mode, machine?}, picked, place: {on: "this-mac"|"cloud"|"machine"|"nowhere", hybrid?,
/// id?}, why, chip, tier?: "this-mac"|"enrolled"|"cloud-pool"|"freestyle", local: {name, busy,
/// room, ramFree, caps}, enrolled: [{name, autoCloud, room, ramFree, folder}]}`. Version 2 added
/// `v`, `tier`, `enrolled`, `need` and `local.caps`; a version 1 reader ignores them and reads
/// the rest as before (an enrolled pick is a `machine` place, which it already starts on).
/// Version 3 split `tier: "cloud"` into `cloud-pool` (our pool, when `cloudPool` says it can
/// take the chat) and `freestyle`; `place` is the same `cloud` either way, so a version 2 reader
/// starts the same chat, and a version 2 `cloud` reads as [`Tier::Freestyle`].
pub(super) async fn read(hub: &Hub, params: &Value) -> Value {
    let verdict = super::place::place(hub, &json!({"hubHealth": false})).await;
    // An existing chat's stored pin, for a read with no pick of its own.
    let stored = chat_of(params)
        .filter(|c| !picks().contains_key(c))
        .and_then(|c| hub.resolve(&c).ok())
        .map(|session| (hub.place_mode_of(&session), session.meta().place_mode.is_some()));
    answer(params, &verdict, &hub.peers(), crate::placement::auto_cloud_on(), stored)
}

/// The `_acpmux/chat_place` answer's version: 2 added the AutoCloud enrolled tier; 3 split Cloud
/// into `cloud-pool` and `freestyle` (RFD 0172, "Explicit order").
pub(crate) const CHAT_PLACE_VERSION: u32 = 3;

/// [`read`] from the placement verdict, the peer rows, and whether AutoCloud is on here.
/// `stored`: an existing chat's mode and whether it was pinned, weighed when the request names
/// no mode and the chat has no pick here.
fn answer(
    params: &Value,
    verdict: &Value,
    peers: &[Value],
    auto_cloud: bool,
    stored: Option<(PlaceMode, bool)>,
) -> Value {
    let chat = chat_of(params);
    let (mode, picked) = match (PlaceMode::from_params(params), stored) {
        (Ok(mode), _) => (mode, true),
        (Err(_), Some(stored)) => stored,
        (Err(_), None) => chat.as_deref().map_or((PlaceMode::Auto, false), mode_of),
    };
    let account: Account = params
        .get("account")
        .and_then(|a| serde_json::from_value(a.clone()).ok())
        .unwrap_or_default();
    let machines: Vec<String> = peers
        .iter()
        .filter(|row| crate::placement::link_down(row).is_none())
        .filter_map(|row| row.get("name").and_then(Value::as_str).map(str::to_owned))
        .collect();
    // AutoCloud's enrolled tier, only with AutoCloud on here (`cloud.autoCloud`, default off),
    // and only machines whose link is up.
    let enrolled = if auto_cloud {
        place_mode::enrolled_of(verdict)
            .into_iter()
            .filter(|m| machines.iter().any(|n| n.eq_ignore_ascii_case(&m.name)))
            .collect()
    } else {
        Vec::new()
    };
    let need =
        params.get("need").and_then(|n| serde_json::from_value(n.clone()).ok()).unwrap_or_default();
    let cloud_pool = params.get("cloudPool").and_then(Value::as_bool).unwrap_or(false);
    let facts = Facts {
        local: place_mode::local_of(verdict),
        account,
        machines,
        enrolled,
        need,
        cloud_pool,
    };
    let decision = place_mode::decide(&mode, &facts);
    json!({
        "v": CHAT_PLACE_VERSION,
        "tier": decision.tier,
        "enrolled": facts.enrolled,
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
