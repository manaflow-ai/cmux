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
            false,
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
            false,
            None,
        );
        assert_eq!(v["chip"], "Auto · Cloud: this Mac is busy", "{v:#}");
        assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}));

        // Signed out (no account sent): this Mac, busy.
        let v = answer(&json!({"chat": "c-read-1"}), &verdict(true), &peers(), false, None);
        assert_eq!(v["place"], json!({"on": "this-mac"}), "{v:#}");

        keep("c-read-2", PlaceMode::Machine { id: "studio".into() });
        let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers(), false, None);
        assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
        assert_eq!(v["picked"], true);
        keep("c-read-2", PlaceMode::Machine { id: "old".into() });
        let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers(), false, None);
        assert_eq!(v["place"], json!({"on": "nowhere"}), "{v:#}");

        // A mode in the params is weighed instead of the chat's.
        let v = answer(
            &json!({"chat": "c-read-2", "mode": "cloud", "account": account}),
            &verdict(false),
            &peers(),
            false,
            None,
        );
        assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
        assert_eq!(v["chip"], "Cloud · New VM");
        keep("c-read-2", PlaceMode::Auto);

        // An existing chat with no pick here reads as its stored pin.
        let pinned = Some((PlaceMode::Machine { id: "studio".into() }, true));
        let v = answer(&json!({"chat": "c-read-3"}), &verdict(false), &peers(), false, pinned);
        assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
        assert_eq!(v["picked"], true);
    }

    /// A busy Mac's verdict with `studio` enrolled and accepting (its `autoCloud` block, as
    /// `placement.rs` copies it from studio's health) and `old` on an older build (none).
    fn verdict_enrolled() -> Value {
        json!({"hosts": [
            {"name": "mac", "local": true, "room": 0.0, "ramFree": 1e9, "load": true,
             "refused": "no room: RAM is the limit",
             "autoCloud": {"v": 1, "enrolled": false, "caps": ["arm64", "macos"]}},
            {"name": "studio", "local": false, "room": 6.0, "ramFree": 40e9, "load": false,
             "autoCloud": {"v": 1, "enrolled": true, "accepting": true, "ownerIdle": true,
                "caps": ["arm64", "macos", "xcode"], "policy": {"teams": [], "agents": []}}},
            {"name": "old", "local": false, "room": 9.0, "load": false}]})
    }

    /// New: with AutoCloud on here, a busy Mac places on the enrolled, idle peer before Cloud,
    /// and says so (`v: 2`, `tier: "enrolled"`). Off (the default): Cloud, as before.
    #[test]
    fn auto_takes_an_enrolled_idle_machine_before_cloud_only_with_autocloud_on() {
        let account: Value = serde_json::from_str(PRO).unwrap();
        let p = json!({"chat": "c-enr-1", "account": account});
        let v = answer(&p, &verdict_enrolled(), &peers(), true, None);
        assert_eq!(v["v"], 3);
        assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
        assert_eq!(v["tier"], "enrolled");
        assert_eq!(v["chip"], "Auto · studio: 40 GB free");
        assert_eq!(v["enrolled"].as_array().map(Vec::len), Some(1), "{v:#}");
        let off = answer(&p, &verdict_enrolled(), &peers(), false, None);
        assert_eq!(off["place"], json!({"on": "cloud", "hybrid": true}), "{off:#}");
        assert_eq!(off["tier"], "freestyle");
        // Our pool, when the caller says it can take the chat: the same Cloud place, its tier.
        let pooled = json!({"chat": "c-enr-1", "account": account, "cloudPool": true});
        let v = answer(&pooled, &verdict_enrolled(), &peers(), false, None);
        assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
        assert_eq!(v["tier"], "cloud-pool");
        // A version 2 answer's tier still reads.
        assert_eq!(
            serde_json::from_value::<place_mode::Tier>(json!("cloud")).unwrap(),
            place_mode::Tier::Freestyle
        );
        // Its link down: not a candidate.
        let down = vec![json!({"name": "studio", "connected": false, "state": "offline"})];
        let v = answer(&p, &verdict_enrolled(), &down, true, None);
        assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
        // Mac work no enrolled Mac fits (no simulator on studio) never goes to the cloud.
        let need = json!({"chat": "c-enr-1", "account": account,
            "need": {"caps": ["ios-simulator"]}});
        let v = answer(&need, &verdict_enrolled(), &peers(), true, None);
        assert_eq!(v["place"], json!({"on": "nowhere"}), "{v:#}");
        assert_eq!(v["chip"], "Auto · needs a Mac");
        assert!(v["why"].as_str().unwrap().contains("no enrolled Mac is free"), "{v:#}");
        // Xcode work studio fits goes to studio.
        let need = json!({"chat": "c-enr-1", "account": account, "need": {"caps": ["xcode"]}});
        let v = answer(&need, &verdict_enrolled(), &peers(), true, None);
        assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
    }

    /// Old against new, both ways: a version 1 reader (the fields it read before) reads a
    /// version 2 answer; a version 1 request (no `need`) and a verdict from an older acpmux
    /// (no `autoCloud` on any row) give the version 1 answer.
    #[test]
    fn chat_place_v1_and_v2_read_each_other() {
        #[derive(serde::Deserialize)]
        #[allow(dead_code)]
        struct V1 {
            chat: Option<String>,
            mode: PlaceMode,
            picked: bool,
            place: place_mode::Place,
            why: String,
            chip: String,
            local: Value,
        }
        let account: Value = serde_json::from_str(PRO).unwrap();
        let p = json!({"chat": "c-enr-2", "account": account});
        let new = answer(&p, &verdict_enrolled(), &peers(), true, None);
        let old: V1 = serde_json::from_value(new).expect("a v1 reader reads v2");
        assert_eq!(old.place, place_mode::Place::Machine { id: "studio".into() });
        let v1_verdict = verdict(true);
        let v = answer(&p, &v1_verdict, &peers(), true, None);
        assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
        assert_eq!(v["chip"], "Auto · Cloud: this Mac is busy");
        assert_eq!(v["enrolled"], json!([]));
        // A v1 Facts (no enrolled, no need, no caps) still parses.
        let facts: Facts = serde_json::from_value(json!({"local": {"name": "mac"},
            "account": {}, "machines": []}))
        .unwrap();
        assert!(facts.enrolled.is_empty() && facts.need == place_mode::Need::default());
        // A v1 Decision (no tier) still parses.
        let d: place_mode::Decision =
            serde_json::from_value(json!({"place": {"on": "this-mac"}, "why": "", "chip": ""}))
                .unwrap();
        assert_eq!(d.tier, None);
    }
}
