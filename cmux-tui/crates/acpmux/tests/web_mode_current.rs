//! ACP-REMOTE-GUARD P1 and B1/B2: a Web connection controls a session (a
//! prompt, a permission answer) only while its CURRENT mode is in the
//! asking table, whatever wrote that mode, and the hub checks again when a
//! queued prompt is dispatched. Reads stay; the unix socket and the local
//! app keep full control.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("awc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// The fake agent under the claude family (asking: default, plan), and as
/// handoff targets under `target` (asking: strict, from config) and the
/// opencode family (no row: the Web never drives it); its starting mode
/// `normal` is in no row.
fn hub(d: &Path, store_root: Option<&Path>) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "fopencode": {"argv": ["python3", FAKE], "family": "opencode"},
            "ftarget": {"argv": ["python3", FAKE], "family": "target"},
            "fnomode": {"argv": ["python3", FAKE], "env": {"FAKE_NO_MODES": "1"}},
        },
        "defaultHarness": "fclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        // A handoff target family whose row lists the fake's `strict`.
        "webAskingModes": {"target": ["strict"]},
    }))
    .unwrap();
    cfg.store.mode = if store_root.is_some() { StoreMode::Local } else { StoreMode::Memory };
    let root = store_root.unwrap_or(Path::new("/nonexistent"));
    let store = acpmux::store::open(&cfg.store, root).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// A client that presented the person key (`hub/person.rs`): the person
    /// at the Mac app, who may allow and widen.
    async fn person(hub: &Arc<Hub>, origin: Origin) -> Self {
        const KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let _ = hub.person.install_spawn_key(KEY);
        let mut c = Self::new(hub, origin);
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        assert!(r.get("error").is_none(), "{r}");
        // The app's proof of the key for this connection's challenge
        // (`hub/person.rs`); a Web or Peer connection gets no challenge.
        let challenge = &r["result"]["_meta"]["acpmux"]["personChallenge"];
        if let (Some(nonce), Some(conn)) =
            (challenge["nonce"].as_str(), challenge["connection"].as_str())
        {
            let transport = if origin == Origin::LocalApp {
                acpmux::hub::person::TRANSPORT_APP
            } else {
                acpmux::hub::person::TRANSPORT_UNIX
            };
            let proof = acpmux::hub::person::person_proof(KEY, transport, nonce, conn).unwrap();
            let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
            assert!(r.get("error").is_none(), "{r}");
        }
        c
    }

    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
        self.2
    }

    async fn reply(&mut self, id: i64) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        self.reply(id).await
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", p).await
    }

    async fn new_session(&mut self, d: &Path) -> String {
        self.new_on(d, None).await
    }

    /// A new session on `harness` (None: the default).
    async fn new_on(&mut self, d: &Path, harness: Option<&str>) -> String {
        let mut p = json!({"cwd": d.join("work"), "mcpServers": []});
        if let Some(h) = harness {
            p["_meta"] = json!({"acpmux": {"harness": h}});
        }
        let r = self.call("session/new", p).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test]
async fn a_local_session_in_a_mode_that_does_not_ask_refuses_web_control() {
    let d = dir("local");
    let hub = hub(&d, None);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut web = Client::new(&hub, Origin::Web);
    // Created over the unix socket: it keeps the harness's mode `normal`.
    // (Not a Claude session: the Web never controls one the Mac started,
    // D13, tests/remote_local_claude.rs.)
    let s = local.new_on(&d, Some("ftarget")).await;
    let r = web.prompt(&s, "from a paired device").await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    assert_eq!(r["error"]["data"]["mode"], json!("normal"), "{r}");
    assert_eq!(r["error"]["data"]["harness"], json!("ftarget"), "{r}");
    let allow = json!({"sessionId": s, "permissionId": "p", "optionId": "o"});
    let r = web.call("_acpmux/permission_respond", allow).await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    // A deny only narrows: no asking rule holds it (here: no such group).
    let deny = json!({"sessionId": s, "groupId": "g", "revision": 1, "decisionKey": "k",
                      "decision": "deny"});
    let r = web.call("_acpmux/permission_group_respond", deny).await;
    assert!(!reason(&r).starts_with("remote."), "{r}");
    // Reads stay.
    for m in ["_acpmux/attach", "_acpmux/events", "_acpmux/info"] {
        let r = web.call(m, json!({"sessionId": s, "limit": 0})).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
    }
    // The unix socket and the local app keep control.
    assert!(local.prompt(&s, "mine").await.get("error").is_none());
    assert!(app.prompt(&s, "mine too").await.get("error").is_none());
    // An asking mode set locally opens it to the Web.
    let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "strict"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(web.prompt(&s, "now").await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn an_internal_set_mode_to_a_mode_that_does_not_ask_refuses_web_control() {
    let d = dir("internal");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    // A Web session is moved to the asking default.
    let s = web.new_session(&d).await;
    assert!(web.prompt(&s, "hello").await.get("error").is_none());
    // A hub-internal caller (a preset, a handoff, a harness switch).
    let session = hub.resolve(&s).unwrap();
    hub.set_mode(&session, "bypassPermissions").await.unwrap();
    let r = web.prompt(&s, "after").await;
    assert!(reason(&r).starts_with("remote.mode_"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_session_loaded_in_a_mode_that_does_not_ask_refuses_web_control() {
    let d = dir("loaded");
    let root = d.join("store");
    let s = {
        let hub = hub(&d, Some(&root));
        let mut local = Client::person(&hub, Origin::Local).await;
        let s = local.new_on(&d, Some("ftarget")).await;
        let r = local.call("session/set_mode", json!({"sessionId": s, "modeId": "auto"})).await;
        assert!(r.get("error").is_none(), "{r}");
        hub.flush();
        let _ = hub.shutdown_all().await;
        s
    };
    // A new daemon loads it from the store, still in `auto`.
    let hub = hub(&d, Some(&root));
    let mut web = Client::new(&hub, Origin::Web);
    let r = web.prompt(&s, "after a restart").await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    assert_eq!(r["error"]["data"]["mode"], json!("auto"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Poll `_acpmux/events` until its text contains `needle`.
async fn wait_events(c: &mut Client, s: &str, needle: &str) -> String {
    for _ in 0..500 {
        let r = c.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
        let text = r.to_string();
        if text.contains(needle) {
            return text;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("no {needle:?} in the events of {s}");
}

#[tokio::test]
async fn a_queued_web_prompt_is_dropped_when_the_mode_left_the_table_before_dispatch() {
    let d = dir("queue");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut busy = Client::new(&hub, Origin::Local);
    let mut local = Client::person(&hub, Origin::Local).await;
    let s = web.new_session(&d).await;
    // A busy session: a local turn waits on a FIFO.
    let fifo = d.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let gate = format!("gate: {}", fifo.display());
    let busy_id = busy
        .send("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": gate}]}))
        .await;
    wait_events(&mut local, &s, "before-gate").await;
    // A Web prompt, accepted in the asking mode, waits in the queue.
    let queued = json!({"sessionId": s, "prompt": [{"type": "text", "text": "queued-web"}]});
    let web_id = web.send("session/prompt", queued).await;
    wait_events(&mut local, &s, "queued-web").await;
    // The mode leaves the table while it waits.
    let r = local
        .call("session/set_mode", json!({"sessionId": s, "modeId": "bypassPermissions"}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    // The busy turn ends; the queued Web prompt is dispatched next.
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    assert!(busy.reply(busy_id).await.get("error").is_none());
    let r = web.reply(web_id).await;
    assert!(reason(&r).starts_with("remote.mode_"), "{r}");
    let events = wait_events(&mut local, &s, "prompt_refused").await;
    assert!(!events.contains("echo: queued-web"), "the harness got the prompt: {events}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A Web handoff from a Web session to a new target on another harness.
async fn web_handoff(web: &mut Client, d: &Path, key: &str, target: &str) -> (String, String) {
    let src = web.new_session(d).await;
    assert!(web.prompt(&src, "some work").await.get("error").is_none());
    let p = json!({"sessionId": src, "harness": target, "handoffKey": key});
    let h = web.call("_acpmux/handoff_prepare", p).await;
    let id = h["result"]["handoffId"].as_str().unwrap_or_else(|| panic!("{h}")).to_owned();
    let target = h["result"]["target"]["sessionId"].as_str().unwrap().to_owned();
    (id, target)
}

fn start(id: &str) -> Value {
    json!({"handoffId": id, "revision": 1, "checkpoint": {"ref": "abc123", "attest": true}})
}

#[tokio::test]
async fn a_web_handoff_start_moves_a_new_target_to_an_asking_mode_first() {
    let d = dir("handoff-new");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::person(&hub, Origin::Local).await;
    let (id, target) = web_handoff(&mut web, &d, "k-new", "ftarget").await;
    // The target starts in the harness's own mode, which does not ask.
    let info = local.call("_acpmux/info", json!({"sessionId": target})).await;
    assert_eq!(info["result"]["modes"]["currentModeId"], json!("normal"), "{info}");
    let r = web.call("_acpmux/handoff_start", start(&id)).await;
    assert_eq!(r["result"]["outcome"], json!("started"), "{r}");
    let info = local.call("_acpmux/info", json!({"sessionId": target})).await;
    assert_eq!(info["result"]["modes"]["currentModeId"], json!("strict"), "{info}");
    let _ = std::fs::remove_dir_all(&d);
}

// D10: opencode has no mode that asks before each change, so a Web handoff
// never starts an opencode target. Since 307889914b9 (remote authority is
// bound when the session is resolved) the prepare itself is refused, before
// any target session exists.
#[tokio::test]
async fn a_web_handoff_to_an_opencode_target_is_refused_before_a_target_exists() {
    let d = dir("handoff-opencode");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::person(&hub, Origin::Local).await;
    let src = web.new_session(&d).await;
    assert!(web.prompt(&src, "some work").await.get("error").is_none());
    let p = json!({"sessionId": src, "harness": "fopencode", "handoffKey": "k-oc"});
    let r = web.call("_acpmux/handoff_prepare", p).await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    let sessions = local.call("_acpmux/sessions", json!({})).await;
    let made = sessions["result"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .any(|x| x["harness"] == json!("fopencode") && x["status"] != json!("ended"));
    assert!(!made, "a refused handoff left an opencode target: {sessions}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_handoff_start_whose_target_does_not_resolve_is_refused() {
    let d = dir("handoff-gone");
    let hub = hub(&d, None);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::person(&hub, Origin::Local).await;
    let (id, target) = web_handoff(&mut web, &d, "k-gone", "ftarget").await;
    let r = local.call("_acpmux/kill", json!({"sessionId": target, "purge": true})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = web.call("_acpmux/handoff_start", start(&id)).await;
    let msg = r["error"]["message"].as_str().unwrap_or_default();
    assert!(msg.contains("target cannot be resolved"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A session over the unix socket on the harness that reports no mode.
async fn no_mode_session(local: &mut Client, d: &Path) -> String {
    let p = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "fnomode"}}});
    let r = local.call("session/new", p).await;
    let s = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert!(r["result"]["modes"].is_null(), "no mode: {r}");
    s
}

async fn set_policy(local: &mut Client, s: &str, policy: &str) {
    let r = local.call("_acpmux/set_policy", json!({"sessionId": s, "policy": policy})).await;
    assert!(r.get("error").is_none(), "{r}");
}

#[tokio::test]
async fn a_session_with_no_mode_needs_an_asking_policy_for_web_control() {
    let d = dir("policy");
    let hub = hub(&d, None);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
    // With ask, the Web may prompt it.
    assert!(web.prompt(&s, "asks").await.get("error").is_none());
    // approve-all approves every tool call: refused, with the policy.
    set_policy(&mut local, &s, "approve-all").await;
    let r = web.prompt(&s, "approves").await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    assert_eq!(r["error"]["data"]["policy"], json!("approve-all"), "{r}");
    let answer = json!({"sessionId": s, "permissionId": "p", "optionId": "o"});
    let r = web.call("_acpmux/permission_respond", answer).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    // The unix socket keeps control.
    assert!(local.prompt(&s, "mine").await.get("error").is_none());
    // deny-all asks nothing but approves nothing either.
    set_policy(&mut local, &s, "deny-all").await;
    assert!(web.prompt(&s, "denies").await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

/// The latest prompt the session asks: its id, decision nonce and daemon run.
async fn pending_ask(c: &mut Client, s: &str, after: usize) -> (String, String, String) {
    for _ in 0..500 {
        let r = c.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
        let asks: Vec<Value> = r["result"]["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|e| e["kind"] == "permission_request")
            .cloned()
            .collect();
        if let Some(ask) = asks.get(after) {
            let text = |k: &str| ask["msg"][k].as_str().unwrap_or_default().to_owned();
            return (text("permissionId"), text("decisionNonce"), text("personInstance"));
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("no permission request {after} in the events of {s}");
}

/// Leo, 2026-10-21 ("this literally doesn't work"): a paired device drew
/// Allow and Deny for a prompt of an approve-reads session, and every answer
/// came back "this session's permission settings do not ask before it acts
/// (policy approve-reads); a paired device cannot prompt it or answer its
/// permissions". A deny only narrows and counts; an allow that carries the
/// person's decision proof for that very prompt is the person's own click and
/// counts; an allow with no proof stays refused. The device's read of the
/// asks says its group allows are refused, so it draws none.
#[tokio::test]
async fn a_paired_device_answers_an_approve_reads_prompt_with_a_deny_or_the_persons_proof() {
    const KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let d = dir("answers");
    let hub = hub(&d, None);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut turns = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
    set_policy(&mut local, &s, "approve-reads").await;
    let ask = |text: &str| json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
    let answer =
        |pid: &str, option: &str| json!({"sessionId": s, "permissionId": pid, "optionId": option});

    let turn = turns.send("session/prompt", ask("ask: touch marker")).await;
    let (pid, _, _) = pending_ask(&mut local, &s, 0).await;
    let r = web.call("_acpmux/permission_groups", json!({"sessionId": s})).await;
    assert_eq!(r["result"]["allowRefused"], json!("permission.person_required"), "{r}");
    let r = local.call("_acpmux/permission_groups", json!({"sessionId": s})).await;
    assert!(r["result"].get("allowRefused").is_none(), "{r}");
    let r = web.call("_acpmux/permission_respond", answer(&pid, "yes")).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "an allow with no proof: {r}");
    let r = web.call("_acpmux/permission_respond", answer(&pid, "no")).await;
    assert!(r.get("error").is_none(), "a deny: {r}");
    assert!(turns.reply(turn).await.get("error").is_none());
    wait_events(&mut local, &s, "chose no").await;

    let turn = turns.send("session/prompt", ask("ask: git push")).await;
    let (pid, nonce, instance) = pending_ask(&mut local, &s, 1).await;
    let proof =
        acpmux::hub::person::decision_proof(KEY, &instance, &s, &pid, "yes", &nonce).unwrap();
    let mut proved = answer(&pid, "yes");
    proved["_meta"] = json!({"acpmux": {"decisionNonce": nonce, "personDecision": proof}});
    let r = web.call("_acpmux/permission_respond", proved.clone()).await;
    assert!(r.get("error").is_none(), "an allow with the person's proof: {r}");
    assert!(turns.reply(turn).await.get("error").is_none());
    wait_events(&mut local, &s, "chose yes").await;
    // The proof counts once: used again, it is an allow with no proof.
    let r = web.call("_acpmux/permission_respond", proved).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "used again: {r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// What the person's phone signs for one prompt (`hub/approvers.rs`), as
/// lowercase hex of the raw P-256 signature.
#[allow(clippy::too_many_arguments)]
fn phone_signature(
    key: &ring::signature::EcdsaKeyPair,
    instance: &str,
    session: &str,
    permission: &str,
    option: &str,
    nonce: &str,
    expires_at: u64,
) -> String {
    let message = acpmux::hub::approvers::message(&acpmux::hub::approvers::Parts {
        instance,
        mac: "mac-1",
        approver: "phone-1",
        session,
        permission,
        option,
        nonce,
        expires_at,
        answers: "",
    });
    let sig = key.sign(&ring::rand::SystemRandom::new(), &message).unwrap();
    sig.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

fn phone_allow(s: &str, pid: &str, option: &str, nonce: &str, exp: u64, sig: &str) -> Value {
    json!({"sessionId": s, "permissionId": pid, "optionId": option,
           "_meta": {"acpmux": {"decisionNonce": nonce,
               "approverDecision": {"approver": "phone-1", "expiresAt": exp, "signature": sig}}}})
}

/// Waits until `needle` is in the events of `s` at least `n` times.
async fn wait_events_n(c: &mut Client, s: &str, needle: &str, n: usize) {
    for _ in 0..500 {
        let r = c.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
        if r.to_string().matches(needle).count() >= n {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("{needle:?} not {n} times in the events of {s}");
}

/// #24233's landing terms (hb-acpmux, 2026-10-25), for a phone's signed
/// Allow sent from a paired device under approve-reads: (1) it counts once,
/// for its own prompt, option and nonce, until it expires; (2) it allows once
/// only, never always, and changes no policy; (3) an unsigned allow stays
/// refused and a deny counts; (4) a phone unpaired after it signed counts
/// nothing.
#[tokio::test]
async fn a_phones_signed_allow_from_a_paired_device_counts_once_never_lasts_and_stops_when_unpaired()
 {
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    let key =
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
    let public: String = key.public_key().as_ref().iter().map(|b| format!("{b:02x}")).collect();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let exp = now + 120;
    let d = dir("phone");
    let hub = hub(&d, None);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut turns = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    let enroll = json!({"macDevice": "mac-1",
                        "approvers": [{"id": "phone-1", "publicKey": public, "name": "iPhone"}]});
    let r = local.call("_acpmux/approvers_set", enroll).await;
    assert!(r.get("error").is_none(), "{r}");
    let s = no_mode_session(&mut local, &d).await;
    set_policy(&mut local, &s, "approve-reads").await;
    let ask = |text: &str| json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
    let plain =
        |pid: &str, option: &str| json!({"sessionId": s, "permissionId": pid, "optionId": option});
    let respond = "_acpmux/permission_respond";

    // (2) An allow always, even signed for it, is refused; a deny counts.
    let turn = turns.send("session/prompt", ask("ask-always: rm -rf build")).await;
    let (pid, nonce, inst) = pending_ask(&mut local, &s, 0).await;
    let sig = phone_signature(&key, &inst, &s, &pid, "always", &nonce, exp);
    let r = web.call(respond, phone_allow(&s, &pid, "always", &nonce, exp, &sig)).await;
    assert_eq!(reason(&r), "remote.lasting_grant_refused", "{r}");
    let r = web.call(respond, plain(&pid, "no")).await;
    assert!(r.get("error").is_none(), "a deny: {r}");
    assert!(turns.reply(turn).await.get("error").is_none());
    wait_events_n(&mut local, &s, "chose no", 1).await;

    // (1) Expired: refused. The signed allow counts once.
    let turn = turns.send("session/prompt", ask("ask: touch marker")).await;
    let (pid, nonce, inst) = pending_ask(&mut local, &s, 1).await;
    let old = phone_signature(&key, &inst, &s, &pid, "yes", &nonce, now - 5);
    let r = web.call(respond, phone_allow(&s, &pid, "yes", &nonce, now - 5, &old)).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "expired: {r}");
    let sig = phone_signature(&key, &inst, &s, &pid, "yes", &nonce, exp);
    let allow = phone_allow(&s, &pid, "yes", &nonce, exp, &sig);
    let r = web.call(respond, allow.clone()).await;
    assert!(r.get("error").is_none(), "the phone's allow: {r}");
    assert!(turns.reply(turn).await.get("error").is_none());
    wait_events_n(&mut local, &s, "chose yes", 1).await;
    let r = web.call(respond, allow).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "used again: {r}");

    // (2, 3) No policy changed: an unsigned allow is still refused as approve-reads.
    let turn = turns.send("session/prompt", ask("ask: git push")).await;
    let (pid2, nonce2, inst) = pending_ask(&mut local, &s, 2).await;
    let r = web.call(respond, plain(&pid2, "yes")).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    assert_eq!(r["error"]["data"]["policy"], json!("approve-reads"), "{r}");
    // (1) The last prompt's signature counts nothing here, with either nonce.
    for n in [&nonce, &nonce2] {
        let r = web.call(respond, phone_allow(&s, &pid2, "yes", n, exp, &sig)).await;
        assert_eq!(reason(&r), "remote.policy_not_asking", "replayed: {r}");
    }
    // (4) Signed now, the phone unpaired before the allow arrives: refused.
    let signed_before = phone_signature(&key, &inst, &s, &pid2, "yes", &nonce2, exp);
    let unpair = json!({"macDevice": "mac-1", "approvers": []});
    let r = local.call("_acpmux/approvers_set", unpair).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = web.call(respond, phone_allow(&s, &pid2, "yes", &nonce2, exp, &signed_before)).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "unpaired: {r}");
    // (3) A deny still counts.
    let r = web.call(respond, plain(&pid2, "no")).await;
    assert!(r.get("error").is_none(), "a deny: {r}");
    assert!(turns.reply(turn).await.get("error").is_none());
    wait_events_n(&mut local, &s, "chose no", 2).await;
    let _ = std::fs::remove_dir_all(&d);
}

/// #24233 (2): the person's proved allow from a paired device, on a session
/// whose mode does not ask, counts once and leaves the mode as it was: the
/// Web still may not answer it without a proof.
#[tokio::test]
async fn a_proved_allow_from_a_paired_device_changes_no_mode() {
    const KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let d = dir("nomode-change");
    let hub = hub(&d, None);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut turns = Client::new(&hub, Origin::Local);
    let mut web = Client::new(&hub, Origin::Web);
    // `normal` is in no asking row for the `target` family.
    let s = local.new_on(&d, Some("ftarget")).await;
    let ask = |text: &str| json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
    let respond = "_acpmux/permission_respond";
    let turn = turns.send("session/prompt", ask("ask: touch marker")).await;
    let (pid, nonce, instance) = pending_ask(&mut local, &s, 0).await;
    let r =
        web.call(respond, json!({"sessionId": s, "permissionId": pid, "optionId": "yes"})).await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    let proof =
        acpmux::hub::person::decision_proof(KEY, &instance, &s, &pid, "yes", &nonce).unwrap();
    let mut proved = json!({"sessionId": s, "permissionId": pid, "optionId": "yes"});
    proved["_meta"] = json!({"acpmux": {"decisionNonce": nonce, "personDecision": proof}});
    let r = web.call(respond, proved.clone()).await;
    assert!(r.get("error").is_none(), "the person's proved allow: {r}");
    assert!(turns.reply(turn).await.get("error").is_none());
    wait_events(&mut local, &s, "chose yes").await;
    let r = web.call(respond, proved).await;
    assert!(r.get("error").is_some(), "used again: {r}");
    let info = local.call("_acpmux/info", json!({"sessionId": s})).await;
    assert_eq!(info["result"]["modes"]["currentModeId"], json!("normal"), "{info}");
    let turn = turns.send("session/prompt", ask("ask: git push")).await;
    let (pid, _, _) = pending_ask(&mut local, &s, 1).await;
    let r =
        web.call(respond, json!({"sessionId": s, "permissionId": pid, "optionId": "yes"})).await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    let r =
        local.call(respond, json!({"sessionId": s, "permissionId": pid, "optionId": "no"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(turns.reply(turn).await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn an_auto_approve_rule_refuses_web_control() {
    let d = dir("rules");
    let hub = hub(&d, None);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
    for rules in [json!({"autoApprove": ["read"]}), json!({"default": "approve"})] {
        let r = local.call("_acpmux/set_rules", json!({"sessionId": s, "rules": rules})).await;
        assert!(r.get("error").is_none(), "{r}");
        let r = web.prompt(&s, "with rules").await;
        assert_eq!(reason(&r), "remote.policy_not_asking", "{rules}: {r}");
    }
    // Rules that only deny or ask keep it asking.
    let rules = json!({"autoDeny": ["rm -rf"], "ask": ["bash"], "default": "ask"});
    let r = local.call("_acpmux/set_rules", json!({"sessionId": s, "rules": rules})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(web.prompt(&s, "asking rules").await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_queued_web_prompt_is_dropped_when_the_policy_stops_asking_before_dispatch() {
    let d = dir("policy-queue");
    let hub = hub(&d, None);
    let mut busy = Client::new(&hub, Origin::Local);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
    let fifo = d.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let gate = format!("gate: {}", fifo.display());
    let busy_id = busy
        .send("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": gate}]}))
        .await;
    wait_events(&mut local, &s, "before-gate").await;
    let queued = json!({"sessionId": s, "prompt": [{"type": "text", "text": "queued-web"}]});
    let web_id = web.send("session/prompt", queued).await;
    wait_events(&mut local, &s, "queued-web").await;
    // The policy stops asking while it waits.
    set_policy(&mut local, &s, "approve-all").await;
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    assert!(busy.reply(busy_id).await.get("error").is_none());
    let r = web.reply(web_id).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    let events = wait_events(&mut local, &s, "prompt_refused").await;
    assert!(!events.contains("echo: queued-web"), "the harness got the prompt: {events}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A guest's prompt the owner approves from the Web runs under the Web's rules, as a Web prompt
/// would: approved while the policy asked, it is dropped at dispatch once the policy stopped
/// asking (review of #26747: the approval left it the guest's Local control, so it ran).
#[tokio::test]
async fn a_held_prompt_approved_from_the_web_is_dropped_when_the_policy_stops_asking() {
    let d = dir("approve-web");
    let hub = hub(&d, None);
    let mut busy = Client::new(&hub, Origin::Local);
    let mut guest = Client::new(&hub, Origin::Local);
    let mut local = Client::person(&hub, Origin::Local).await;
    let mut web = Client::new(&hub, Origin::Web);
    let s = no_mode_session(&mut local, &d).await;
    let fifo = d.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let gate = format!("gate: {}", fifo.display());
    let busy_id = busy
        .send("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": gate}]}))
        .await;
    wait_events(&mut local, &s, "before-gate").await;
    let author = json!({"id": "guest:k3x9", "name": "Cy", "approval": "owner"});
    let held = json!({"sessionId": s, "prompt": [{"type": "text", "text": "guest-words"}],
                      "_meta": {"acpmux": {"promptId": "g-1", "author": author}}});
    let guest_id = guest.send("session/prompt", held).await;
    let events = wait_events(&mut local, &s, "guest-words").await;
    let events: Value = serde_json::from_str(&events).unwrap();
    let turn = events["result"]["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["kind"] == "queued" && e["msg"]["promptId"] == "g-1")
        .map(|e| e["msg"]["turnId"].clone())
        .expect("the held prompt's queued record");
    let approve = json!({"sessionId": s, "promptId": "g-1", "turnId": turn, "revision": 0});
    let r = web.call("_acpmux/queue_approve", approve).await;
    assert!(r.get("error").is_none(), "the Web approves while the policy asks: {r}");
    // The policy stops asking before the approved prompt's turn.
    set_policy(&mut local, &s, "approve-all").await;
    tokio::task::spawn_blocking(move || std::fs::write(fifo, "go")).await.unwrap().unwrap();
    assert!(busy.reply(busy_id).await.get("error").is_none());
    let r = guest.reply(guest_id).await;
    assert_eq!(reason(&r), "remote.policy_not_asking", "{r}");
    let events = wait_events(&mut local, &s, "prompt_refused").await;
    assert!(!events.contains("echo: guest-words"), "the harness got the prompt: {events}");
    let _ = std::fs::remove_dir_all(&d);
}
