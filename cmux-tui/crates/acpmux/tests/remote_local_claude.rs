//! D13 (cx-44j.38): a remote device never controls a Claude Code session
//! the Mac started. Its process runs with the user's own Claude permission
//! rules (allow rules run tools with no acpmux request), so the remote floor
//! cannot hold there. A prompt, a permission answer or a mode set from the
//! Web is refused with `remote.local_claude_session`; reads stay. A Web
//! request may not adopt, fork, load or resume such a session either. A
//! session on another harness keeps Web control.
//!
//! The owner's own paired phone is the owner, not a remote device: it controls
//! such a chat as the Mac does, until the phone is removed (Leo, 2026-11-14:
//! "chat writable in both directions / this is obviously what we need").

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::pairing::Role;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_device, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arlc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            // Claude Code that reports system/init every turn (its mode included).
            "initclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                "env": {"FAKE_CLAUDE_SKILLS": "1"}},
            "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "ftarget": {"argv": ["python3", FAKE], "family": "target"},
            "fother": {"argv": ["python3", FAKE], "family": "other"},
        },
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        "webAskingModes": {"target": ["strict"], "other": ["strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A connection, and the `_meta.acpmux.via` its requests carry (a paired
/// machine forwarding for its own Web client says `web`).
/// Replies that came in while another was awaited are kept for their own `reply`.
struct Client(
    mpsc::Sender<String>,
    mpsc::Receiver<String>,
    i64,
    Option<&'static str>,
    std::collections::HashMap<i64, Value>,
);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0, None, Default::default())
    }

    /// A connection that presented the paired credential `token`, served as
    /// its role says (a phone as Web under its own id, as the Mac's mobile
    /// host connects for it), forwarding for its Web client when `via_web`.
    fn device(hub: &Arc<Hub>, token: &str, via_web: bool) -> Self {
        let proof = hub.pairing.device_for(token).expect("a live credential");
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_device(hub.clone(), in_rx, out_tx, proof));
        Client(in_tx, out_rx, 0, via_web.then_some("web"), Default::default())
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        self.reply(id).await
    }

    /// Send a request without waiting for its answer; its id.
    async fn send(&mut self, m: &str, mut params: Value) -> i64 {
        self.2 += 1;
        let id = self.2;
        if let Some(via) = self.3 {
            let meta = params.as_object_mut().unwrap().entry("_meta").or_insert(json!({}));
            let mux = meta.as_object_mut().unwrap().entry("acpmux").or_insert(json!({}));
            mux["via"] = json!(via);
        }
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        id
    }

    async fn reply(&mut self, id: i64) -> Value {
        if let Some(v) = self.4.remove(&id) {
            return v;
        }
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            match v.get("id").and_then(Value::as_i64) {
                Some(got) if got == id => return v,
                Some(got) if v.get("method").is_none() => {
                    self.4.insert(got, v);
                }
                _ => {}
            }
        }
    }

    async fn new_session(&mut self, d: &Path, harness: &str) -> String {
        let p = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let r = self.call("session/new", p).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", p).await
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test]
async fn a_web_device_cannot_control_a_claude_session_the_mac_started_but_can_read_it() {
    let d = dir("control");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let r = web.prompt(&s, "hi").await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let text = r["error"]["message"].as_str().unwrap_or_default();
    // The refusal says what to do from each side (#41629): start a new chat on the other device,
    // or reopen the chat on this Mac.
    assert!(text.contains("From another device, start a new chat there"), "{text}");
    assert!(text.contains("close and reopen the chat"), "{text}");
    for (m, p) in [
        ("session/set_mode", json!({"sessionId": s, "modeId": "plan"})),
        (
            "_acpmux/permission_respond",
            json!({"sessionId": s, "permissionId": "p1", "optionId": "allow_once"}),
        ),
    ] {
        let r = web.call(m, p).await;
        assert_eq!(reason(&r), "remote.local_claude_session", "{m}: {r}");
    }
    // Nor change or end it.
    for (m, p) in [
        ("_acpmux/set_rules", json!({"sessionId": s, "rules": null})),
        ("_acpmux/set_policy", json!({"sessionId": s, "policy": "ask"})),
        ("_acpmux/kill", json!({"sessionId": s, "purge": true})),
        ("session/close", json!({"sessionId": s})),
    ] {
        let r = web.call(m, p).await;
        assert_eq!(reason(&r), "remote.local_claude_session", "{m}: {r}");
    }
    // Reads stay available.
    let r = web.call("_acpmux/events", json!({"sessionId": s, "limit": 50})).await;
    assert!(r["result"]["events"].is_array(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_claude_adapter_session_the_mac_started_is_refused_too() {
    let d = dir("adapter");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "fclaude").await;
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = web.prompt(&s, "hi").await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_device_cannot_copy_or_adopt_a_claude_session_the_mac_started() {
    let d = dir("copy");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let r = web
        .call("session/fork", json!({"sessionId": s, "cwd": d.join("work"), "mcpServers": []}))
        .await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let adopt = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {
        "harness": "fakeclaude", "adopt": {"agentSessionId": "fake-claude-session", "harness": "fakeclaude"}}}});
    let r = web.call("session/new", adopt).await;
    assert_eq!(reason(&r), "remote.adopt_refused", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_session_on_another_harness_keeps_web_control() {
    let d = dir("other");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "ftarget").await;
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "strict"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = web.prompt(&s, "hi").await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A web model switch (a fork onto another harness, `hub/fork.rs` `Retarget`) of a chat the Mac
/// started keeps the Mac's origin, so onto Claude it would run with the Mac's Claude permissions:
/// refused as D13 refuses controlling such a chat, before any process starts. The Mac itself may.
#[tokio::test]
async fn a_web_switch_of_a_mac_chat_onto_claude_is_refused() {
    let d = dir("switch");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "ftarget").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let before = hub.sessions().len();
    let p = json!({"sessionId": s, "cwd": d.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "fakeclaude"}}});
    let r = web.call("session/fork", p).await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    // A Claude adapter (family claude, not Claude Code itself) is Claude too.
    let p = json!({"sessionId": s, "cwd": d.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "fclaude"}}});
    let r = web.call("session/fork", p).await;
    assert!(r.get("error").is_some(), "{r}");
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    assert_eq!(hub.sessions().len(), before, "a refused switch made no chat");
    let _ = std::fs::remove_dir_all(&d);
}

/// A family name with no profile of the same name (`other`, served by `fother`) is resolved as
/// the fork resolves it before D13 judges the switch: a non-Claude family is not refused as a
/// local Claude session (review of cmux#41030 at eee5f8d9).
#[tokio::test]
async fn a_web_switch_by_family_name_is_judged_by_the_profile_it_resolves_to() {
    let d = dir("switch-family");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = local.new_session(&d, "ftarget").await;
    let p = json!({"sessionId": s, "cwd": d.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "other"}}});
    let r = web.call("session/fork", p).await;
    assert_ne!(reason(&r), "remote.local_claude_session", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The phone the Mac app pairs with its mobile host (Settings > Mobile > Phones): the person's
/// own `phone` credential (`_acpmux/pair_issue` role `phone`), which the app issues only for a
/// phone its host admits under the Mac owner's account. Its id and token.
fn own_phone(hub: &Hub, name: &str) -> (String, String) {
    let (device, token) = hub.pairing.issue_phone(name).unwrap();
    (device.id, token)
}

/// The owner's paired phone sends to a Claude chat started on the Mac and it runs; it changes
/// its mode and stops it as the Mac would (Leo, 2026-11-14, refused with "Only the cmux app on
/// this Mac can control a Claude chat started on this Mac": "wtf do i do these options dont do
/// anything").
#[tokio::test]
async fn the_owners_paired_phone_controls_a_claude_chat_the_mac_started() {
    let d = dir("phone");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let (_, token) = own_phone(&hub, "phone-iphone");
    let mut phone = Client::device(&hub, &token, false);
    let r = phone.prompt(&s, "hello from the phone").await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let r = phone.call("session/set_mode", json!({"sessionId": s, "modeId": "plan"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = phone.call("session/cancel", json!({"sessionId": s})).await;
    assert_ne!(reason(&r), "remote.local_claude_session", "{r}");
    // A Claude adapter (family claude) the Mac started too.
    let s = local.new_session(&d, "fclaude").await;
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = phone.prompt(&s, "hi").await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Every other client keeps the refusal: the shared dashboard token (a browser, any account, a
/// phone the host gave no credential), and a paired machine that is not a phone forwarding for
/// its Web client. The refusal names the one action that works from there (`new_chat`), which
/// the composer draws as a button. A read-only machine controls nothing.
#[tokio::test]
async fn an_unpaired_or_other_account_client_is_still_refused() {
    let d = dir("others");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let laptop = hub.pairing.issue("laptop", Role::Client).unwrap().1;
    for (who, mut c) in [
        ("dashboard", Client::new(&hub, Origin::Web)),
        ("client machine", Client::device(&hub, &laptop, true)),
    ] {
        let r = c.prompt(&s, "hi").await;
        assert_eq!(reason(&r), "remote.local_claude_session", "{who}: {r}");
        assert_eq!(r["error"]["data"]["action"], "new_chat", "{who}: {r}");
    }
    let viewer = hub.pairing.issue("viewer", Role::ReadOnly).unwrap().1;
    let r = Client::device(&hub, &viewer, false).prompt(&s, "hi").await;
    assert!(r.get("error").is_some(), "read-only machine: {r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Removing the phone in Settings revokes its credential: its very next request is refused, on
/// a connection still open too, as a revoked machine's Full-access setting is.
#[tokio::test]
async fn a_removed_phone_is_refused() {
    let d = dir("removed");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let (id, token) = own_phone(&hub, "phone-iphone");
    let mut phone = Client::device(&hub, &token, false);
    let r = phone.prompt(&s, "before").await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    hub.pairing.revoke(&id).unwrap();
    let r = phone.prompt(&s, "after").await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The chat runs in the mode the Mac gave it, one that does not ask included (the stand-in Claude
/// starts in `bypassPermissions`): the phone's own Full-access setting, on by default and the
/// person's switch, is what lets it drive such a chat. Turned off, the phone is still not refused
/// as a remote device (D13), but the Web's asking-mode rule holds it again at its next request.
#[tokio::test]
async fn the_phones_full_access_setting_off_puts_the_asking_rule_back() {
    let d = dir("phone-off");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let (id, token) = own_phone(&hub, "phone-iphone");
    let mut phone = Client::device(&hub, &token, false);
    let r = phone.prompt(&s, "on").await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    hub.pairing.set_full_access(&id, false).unwrap();
    let r = phone.prompt(&s, "off").await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The phone's Stop ends a running turn of a chat the Mac started, as the Mac's does (Leo's ask:
/// "chat writable in both directions"). The stand-in's "long-step" runs until the interrupt.
#[tokio::test]
async fn the_owners_phone_stops_a_running_turn_of_a_chat_the_mac_started() {
    let d = dir("phone-stop");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let (_, token) = own_phone(&hub, "phone-iphone");
    let mut phone = Client::device(&hub, &token, false);
    let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": "long-step"}]});
    let turn = phone.send("session/prompt", p).await;
    while local.call("_acpmux/info", json!({"sessionId": s})).await["result"]["turn"].is_null() {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let r = phone.call("session/cancel", json!({"sessionId": s})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = phone.reply(turn).await;
    assert_eq!(r["result"]["stopReason"], "cancelled", "{r}");
    // Any other Web client still may not.
    let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": "long-step"}]});
    let turn = local.send("session/prompt", p).await;
    while local.call("_acpmux/info", json!({"sessionId": s})).await["result"]["turn"].is_null() {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let r = Client::new(&hub, Origin::Web).call("session/cancel", json!({"sessionId": s})).await;
    assert!(r.get("error").is_some(), "{r}");
    assert!(local.call("session/cancel", json!({"sessionId": s})).await.get("error").is_none());
    let _ = local.reply(turn).await;
    let _ = std::fs::remove_dir_all(&d);
}

/// Claude Code reports system/init, its mode in it, on every turn: that report of the mode the
/// chat already has does not end the phone's turn (review of cmux#43251 at f5ba5381, F2).
#[tokio::test]
async fn a_mode_report_does_not_end_the_phones_turn() {
    let d = dir("phone-init");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "initclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let (_, token) = own_phone(&hub, "phone-iphone");
    let mut phone = Client::device(&hub, &token, false);
    for text in ["one", "two"] {
        let r = phone.prompt(&s, text).await;
        assert_eq!(r["result"]["stopReason"], "end_turn", "{text}: {r}");
    }
    let r = local.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
    assert!(!r.to_string().contains("remote_floor_cancel"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The phone copies a chat the Mac started in a mode that does not ask (the stand-in runs
/// `bypassPermissions`), as it drives one (review of cmux#43251 at f5ba5381, F4); a dashboard
/// client still may not.
#[tokio::test]
async fn the_owners_phone_forks_a_chat_the_mac_started() {
    let d = dir("phone-fork");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let (_, token) = own_phone(&hub, "phone-iphone");
    let mut phone = Client::device(&hub, &token, false);
    let p = json!({"sessionId": s, "cwd": d.join("work"), "mcpServers": []});
    let r = phone.call("session/fork", p.clone()).await;
    assert!(r["result"]["sessionId"].is_string(), "{r}");
    let r = Client::new(&hub, Origin::Web).call("session/fork", p).await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The Cloud VM's cmux link (`cmux-tui/src/link/phone_chat.rs`, RFD 0135 gate 4) admits a phone
/// only after its owner check, then reaches this daemon over the owner-only local socket, its
/// prompts marked `via: cloud-mobile` with the phone's id as `ownerPhone`. A local socket client
/// sending that claim: what the owner's paired phone is under D13, never with Full access.
fn cloud_phone(hub: &Arc<Hub>, origin: Origin) -> Client {
    let mut c = Client::new(hub, origin);
    c.3 = Some("cloud-mobile");
    c
}

fn owner_claim(device: &str, full: bool) -> Value {
    json!({"device": device, "fullAccess": full})
}

async fn claimed(c: &mut Client, m: &str, mut params: Value, claim: &Value) -> Value {
    params["_meta"] = json!({"acpmux": {"ownerPhone": claim}});
    c.call(m, params).await
}

async fn claimed_prompt(c: &mut Client, s: &str, text: &str, claim: &Value) -> Value {
    let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
    claimed(c, "session/prompt", p, claim).await
}

/// Accepted on the owner-checked path: the local socket, a Cloud mobile prompt, the claim.
#[tokio::test]
async fn the_owner_checked_cloud_phone_sends_to_a_claude_chat_the_vm_started() {
    let d = dir("cloud-phone");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fclaude").await;
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let mut phone = cloud_phone(&hub, Origin::Local);
    let r = claimed_prompt(&mut phone, &s, "from the phone", &owner_claim("phone-1", false)).await;
    assert!(r.get("error").is_none(), "{r}");
    // The same Cloud mobile prompt with no claim (no owner check behind it) is refused.
    let mut other = cloud_phone(&hub, Origin::Local);
    let r = other.prompt(&s, "no claim").await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The claim from anything but the local socket (or the owner's peer daemon, which vouches for
/// its own paired phone) counts for nothing: a Web or dashboard client, a paired machine that
/// is not a phone.
#[tokio::test]
async fn the_owner_phone_claim_from_a_non_local_connection_is_refused() {
    let d = dir("cloud-phone-remote");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fclaude").await;
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let laptop = hub.pairing.issue("laptop", Role::Client).unwrap().1;
    let mut laptop = Client::device(&hub, &laptop, false);
    laptop.3 = Some("cloud-mobile");
    for (who, mut c) in [("web", cloud_phone(&hub, Origin::Web)), ("client machine", laptop)] {
        let r = claimed_prompt(&mut c, &s, "hi", &owner_claim("phone-1", true)).await;
        assert!(r.get("error").is_some(), "{who}: {r}");
        assert_eq!(reason(&r), "remote.local_claude_session", "{who}: {r}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// The local socket's claim never carries Full access, whatever it says: a chat out of the Web's
/// policy (the stand-in Claude runs `bypassPermissions`) is held at the asking rule, not run;
/// its copy is refused; the peer-only Full-access notice is not this connection's to send.
#[tokio::test]
async fn the_cloud_phone_claim_grants_no_full_access() {
    let d = dir("cloud-phone-full");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d, "fakeclaude").await;
    assert!(local.prompt(&s, "hello").await.get("error").is_none());
    let mut phone = cloud_phone(&hub, Origin::Local);
    let claim = owner_claim("phone-1", true);
    let r = claimed_prompt(&mut phone, &s, "bypass", &claim).await;
    assert!(r.get("error").is_some(), "{r}");
    assert_ne!(reason(&r), "remote.local_claude_session", "D13 passed, Full access did not: {r}");
    let p = json!({"sessionId": s, "cwd": d.join("work"), "mcpServers": []});
    let r = claimed(&mut phone, "session/fork", p, &claim).await;
    assert!(r.get("error").is_some(), "{r}");
    let p = json!({"device": "phone-1", "fullAccess": true});
    let r = claimed(&mut phone, "_acpmux/owner_phone_changed", p, &claim).await;
    assert!(r.get("error").is_some(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}
