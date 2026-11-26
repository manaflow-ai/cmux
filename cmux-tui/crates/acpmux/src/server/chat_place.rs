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
/// cloudDisabled, signedIn}}` → `{chat, mode: {mode, machine?}, picked, place: {on:
/// "this-mac"|"cloud"|"machine"|"nowhere", hybrid?, id?}, why, chip, local: {name, busy, room,
/// ramFree}}`.
pub(super) async fn read(hub: &Hub, params: &Value) -> Value {
    let verdict = super::place::place(hub, &json!({"hubHealth": false})).await;
    // An existing chat's stored pin, for a read with no pick of its own.
    let stored = chat_of(params)
        .filter(|c| !picks().contains_key(c))
        .and_then(|c| hub.resolve(&c).ok())
        .map(|session| (hub.place_mode_of(&session), session.meta().place_mode.is_some()));
    answer(params, &verdict, &hub.peers(), stored)
}

/// [`read`] from the placement verdict and the peer rows. `stored`: an existing chat's mode and
/// whether it was pinned, weighed when the request names no mode and the chat has no pick here.
fn answer(
    params: &Value,
    verdict: &Value,
    peers: &[Value],
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
mod tests {
    use super::*;

    fn verdict(busy: bool) -> Value {
        json!({"hosts": [{"name": "mac", "local": true, "room": if busy { 0.0 } else { 3.0 },
            "ramFree": 12e9, "load": busy, "refused": busy.then_some("no room: RAM is the limit")}]})
    }

    fn peers() -> Vec<Value> {
        vec![
            json!({"name": "studio", "connected": true, "state": "connected"}),
            json!({"name": "old", "connected": false, "state": "offline"}),
        ]
    }

    const PRO: &str = r#"{"plan": "next_pro", "signedIn": true}"#;

    /// A pick is the chat's own: another chat stays Auto, and picking Auto clears it.
    #[test]
    fn a_pick_is_kept_for_its_chat_only() {
        keep("chat-a", PlaceMode::Cloud);
        assert_eq!(mode_of("chat-a"), (PlaceMode::Cloud, true));
        assert_eq!(mode_of("chat-b"), (PlaceMode::Auto, false));
        keep("chat-a", PlaceMode::Auto);
        assert_eq!(mode_of("chat-a"), (PlaceMode::Auto, false));
    }

    /// The read: Auto's chip from this Mac's room, Cloud when it is busy, a pinned peer only
    /// while its link is up.
    #[test]
    fn the_read_names_the_place_and_the_chip() {
        let account: Value = serde_json::from_str(PRO).unwrap();
        let v = answer(
            &json!({"chat": "c-read-1", "account": account}),
            &verdict(false),
            &peers(),
            None,
        );
        assert_eq!(v["chip"], "Auto · This Mac: 12 GB free", "{v:#}");
        assert_eq!(v["place"], json!({"on": "this-mac"}));
        assert_eq!(v["picked"], false);
        assert_eq!(v["mode"], json!({"mode": "auto"}));

        let v = answer(
            &json!({"chat": "c-read-1", "account": account}),
            &verdict(true),
            &peers(),
            None,
        );
        assert_eq!(v["chip"], "Auto · Cloud: this Mac is busy", "{v:#}");
        assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}));

        // Signed out (no account sent): this Mac, busy.
        let v = answer(&json!({"chat": "c-read-1"}), &verdict(true), &peers(), None);
        assert_eq!(v["place"], json!({"on": "this-mac"}), "{v:#}");

        keep("c-read-2", PlaceMode::Machine { id: "studio".into() });
        let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers(), None);
        assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
        assert_eq!(v["picked"], true);
        keep("c-read-2", PlaceMode::Machine { id: "old".into() });
        let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers(), None);
        assert_eq!(v["place"], json!({"on": "nowhere"}), "{v:#}");

        // A mode in the params is weighed instead of the chat's.
        let v = answer(
            &json!({"chat": "c-read-2", "mode": "cloud", "account": account}),
            &verdict(false),
            &peers(),
            None,
        );
        assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
        assert_eq!(v["chip"], "Cloud · New VM");
        keep("c-read-2", PlaceMode::Auto);

        // An existing chat with no pick here reads as its stored pin.
        let pinned = Some((PlaceMode::Machine { id: "studio".into() }, true));
        let v = answer(&json!({"chat": "c-read-3"}), &verdict(false), &peers(), pinned);
        assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
        assert_eq!(v["picked"], true);
    }
}
