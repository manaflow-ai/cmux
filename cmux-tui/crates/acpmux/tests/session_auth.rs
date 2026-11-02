//! `_acpmux/session/auth` (`hub/session_auth.rs`; Leo: "you gotta re-authenticate. You gotta
//! log in again on the modal picker before the user even sends a prompt."): a chat's sign-in
//! from its own evidence, by session or by target, never a guess.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::profiles::AuthNotes;
use acpmux::config::{Config, ProfileMeta, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const NOT_SIGNED_IN: &str = "Not logged in · Please run /login";

fn scratch(tag: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("acpmux-session-auth-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// A hub with the `fake` harness (Claude's family) and a preset `two` that runs it in another
/// Claude home, its routes and bindings under `root`.
fn hub(root: &Path) -> Arc<Hub> {
    let two = root.join("claude-two");
    let defaulted = root.join("claude-defaulted");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "claude": {"kind": "claude-stdio", "argv": ["claude"], "env": {"CLAUDE_CONFIG_DIR": root.join("canonical")}},
            "fake": {"argv": ["python3", FAKE], "family": "claude"},
            // A harness whose own check passes only in the env its preset `checked-two` or the
            // chat's own env sets.
            "checked": {"argv": ["python3", FAKE], "family": "plain"},
            // A profile whose own route `acct` (an account home) its chats spawn on.
            "acct": {"argv": ["python3", FAKE], "family": "claude", "env": {"ACPMUX_PROFILE_ROUTE": "acct"}},
            // A profile with its own route, which beats a family or global binding at spawn.
            "pinned": {"argv": ["python3", FAKE], "family": "claude", "env": {"ACPMUX_PROFILE_ROUTE": "busy"}},
            // A profile whose `defaults` entry pins its account home.
            "deflt": {"argv": ["python3", FAKE], "family": "claude"},
        },
        "defaults": {"deflt": {"env": {"CLAUDE_CONFIG_DIR": defaulted}}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "presets": {
            "two": {"harness": "fake", "env": {"CLAUDE_CONFIG_DIR": two}},
            "checked-two": {"harness": "checked", "env": {"WHO": "two"}},
        },
        // No automatic continuation runs behind a failed turn (`auto_resume.rs`).
        "autoResumeDelaysMs": [],
    }))
    .unwrap();
    let check = ["sh", "-c", "test \"$WHO\" = two || test -n \"$CMUX_WORKSPACE_ID\""]
        .map(String::from)
        .to_vec();
    let auth = AuthNotes { check, ..Default::default() };
    cfg.profile_meta
        .insert("checked".into(), ProfileMeta { auth: Some(auth), ..Default::default() });
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// Saving a key for an alternate-account chat changes that account only. The old failed
/// turn remains history, but cannot prevent the first prompt using the replacement credential.
#[tokio::test]
async fn agent_login_uses_the_chats_account_and_invalidates_only_its_old_evidence() {
    let root = scratch("login-account");
    let hub = hub(&root);
    let mut c = client(&hub);
    let other = c.new_session(None).await;
    let id = c.new_session(Some("two")).await;
    for session in [&id, &other] {
        c.prompt(session, &format!("fail-streamed: {NOT_SIGNED_IN}")).await;
    }
    let before = hub.resolve(&id).unwrap().meta().last_turn;
    // Merely refreshing the same failed account must not clear its failure.
    let unchanged = c.auth(json!({"sessionId": id, "refresh": true})).await;
    assert_eq!(state(&unchanged), ("signedOut", "turn"));
    let saved = c.call(method::MUX_AGENT_LOGIN_API_KEY,
        json!({"agent": "claude", "sessionId": id, "key": "sk-ant-test-replacement"})).await;
    assert!(saved.get("error").is_none(), "{saved}");
    assert!(root.join("claude-two/settings.json").is_file(), "the chat's account receives the key");
    assert!(!root.join("canonical/settings.json").exists(), "the default account is untouched");
    assert_eq!(hub.resolve(&id).unwrap().meta().last_turn, before, "history is preserved");
    let changed = c.auth(json!({"sessionId": id, "refresh": true})).await;
    assert_eq!(changed["state"], "unknown", "saving a key permits retry, not proof it works: {changed}");
    let untouched = c.auth(json!({"sessionId": other, "refresh": true})).await;
    assert_eq!(state(&untouched), ("signedOut", "turn"), "{untouched}");
    let ok = c.prompt(&id, "hello").await;
    assert!(ok.get("error").is_none(), "{ok}");
    let after = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&after), ("ready", "turn"), "{after}");
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no reply in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn new_session(&mut self, preset: Option<&str>) -> String {
        match preset {
            Some(p) => self.new_session_with(json!({"preset": p})).await,
            None => self.new_session_of("fake").await,
        }
    }

    async fn new_session_of(&mut self, harness: &str) -> String {
        self.new_session_with(json!({"harness": harness})).await
    }

    async fn new_session_with(&mut self, meta: Value) -> String {
        let v = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}}),
            )
            .await;
        v["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned()
    }

    async fn prompt(&mut self, id: &str, text: &str) -> Value {
        let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        self.call(method::SESSION_PROMPT, p).await
    }

    async fn auth(&mut self, params: Value) -> Value {
        let v = self.call(method::MUX_SESSION_AUTH, params).await;
        assert!(v.get("error").is_none(), "{v}");
        v["result"].clone()
    }
}

fn state(v: &Value) -> (&str, &str) {
    (v["state"].as_str().unwrap_or("?"), v["source"].as_str().unwrap_or("?"))
}

/// A chat's own turns: none is unknown, never signed out; a sign-in failure is signedOut (or
/// expired), with how to sign in; a later completed turn is ready; a connection error is
/// unknown, never a sign-in state.
#[tokio::test]
async fn session_auth_follows_the_chats_own_newest_turn() {
    let root = scratch("turns");
    let hub = hub(&root);
    let mut c = client(&hub);
    let id = c.new_session(None).await;

    let none = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&none), ("unknown", "none"), "{none}");
    assert_eq!(none["evidenceAt"], Value::Null, "{none}");
    assert!(none.get("login").is_none(), "{none}");
    // With refresh: this harness's sign-in may be in Claude's keychain item, which acpmux
    // never reads, so it stays unknown and says why.
    let refreshed = c.auth(json!({"sessionId": id, "refresh": true})).await;
    assert_eq!(state(&refreshed), ("unknown", "none"), "{refreshed}");
    assert!(refreshed["detail"].as_str().unwrap().contains("keychain"), "{refreshed}");

    let failed = c.prompt(&id, &format!("fail-streamed: {NOT_SIGNED_IN}")).await;
    assert_eq!(failed["error"]["data"]["errorKind"], "auth.signed_out", "{failed}");
    let out = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&out), ("signedOut", "turn"), "{out}");
    assert!(out["evidenceAt"].as_u64().is_some(), "{out}");
    assert_eq!(out["fromSessionId"], json!(id), "{out}");
    assert_eq!(out["harness"], "fake", "{out}");
    assert_eq!(out["host"], Value::Null, "{out}");
    assert_eq!(out["login"]["kind"], "terminal", "{out}");
    assert_eq!(out["login"]["command"], "claude auth login", "{out}");

    let ok = c.prompt(&id, "hello").await;
    assert!(ok.get("error").is_none(), "{ok}");
    let out = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&out), ("ready", "turn"), "a completed turn clears signedOut: {out}");
    assert!(out.get("login").is_none(), "{out}");

    c.prompt(&id, "fail-streamed: API Error: 401 OAuth token has expired.").await;
    let out = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&out), ("expired", "turn"), "{out}");

    let cut = c.prompt(&id, "fail-streamed: API Error: Connection error.").await;
    assert!(cut.get("error").is_some(), "{cut}");
    let out = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&out), ("unknown", "none"), "a connection error is no sign-in: {out}");

    // An unknown chat is the existing not-found error; neither or both forms are invalid.
    let missing = c.call(method::MUX_SESSION_AUTH, json!({"sessionId": "no-such-chat"})).await;
    assert_eq!(missing["error"]["code"], -32002, "{missing}");
    for bad in [json!({}), json!({"sessionId": id, "target": {"harness": "fake"}})] {
        let v = c.call(method::MUX_SESSION_AUTH, bad).await;
        assert_eq!(v["error"]["code"], -32602, "{v}");
    }
}

/// A chat in its own Claude home signs in there.
#[tokio::test]
async fn session_auth_names_the_chats_own_account_home() {
    let root = scratch("home");
    let hub = hub(&root);
    let mut c = client(&hub);
    let id = c.new_session(Some("two")).await;
    c.prompt(&id, &format!("fail-streamed: {NOT_SIGNED_IN}")).await;
    let out = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&out), ("signedOut", "turn"), "{out}");
    let home = root.join("claude-two");
    assert_eq!(
        out["login"]["command"],
        format!("CLAUDE_CONFIG_DIR={} claude auth login", home.display()),
        "{out}"
    );
}

/// With refresh, the harness's own check runs in the chat's env (its preset's over the
/// profile's), so a chat signed in by its preset is not reported signed out.
#[tokio::test]
async fn session_auth_checks_in_the_chats_own_env() {
    let root = scratch("check-env");
    let hub = hub(&root);
    let mut c = client(&hub);
    let preset = c.new_session(Some("checked-two")).await;
    let out = c.auth(json!({"sessionId": preset, "refresh": true})).await;
    assert_eq!(state(&out), ("ready", "authCheck"), "{out}");
    let plain = c.new_session_of("checked").await;
    let out = c.auth(json!({"sessionId": plain, "refresh": true})).await;
    assert_eq!(state(&out), ("signedOut", "authCheck"), "{out}");
    // The chat's own env (`_meta.acpmux.env`) is in its check's env too, as at its spawn.
    let workspace = "0b3c5d1e-2f40-4a6b-8c9d-0e1f2a3b4c5d";
    let meta = json!({"harness": "checked", "env": {"CMUX_WORKSPACE_ID": workspace}});
    let own = c.new_session_with(meta).await;
    let out = c.auth(json!({"sessionId": own, "refresh": true})).await;
    assert_eq!(state(&out), ("ready", "authCheck"), "{out}");
}

/// A chat whose profile names its own route (`ACPMUX_PROFILE_ROUTE`) is reported on that
/// route and signs in to its account home, as its spawn runs it.
#[tokio::test]
async fn session_auth_names_the_route_the_chat_spawns_on() {
    let root = scratch("profile-route");
    let hub = hub(&root);
    let mut c = client(&hub);
    let home = root.join("acct");
    let params = json!({"id": "acct", "kind": "direct-subscription", "families": ["claude"],
                        "accountHome": home});
    let added = c.call("_acpmux/route/add", params).await;
    assert!(added.get("error").is_none(), "{added}");
    let id = c.new_session_of("acct").await;
    c.prompt(&id, &format!("fail-streamed: {NOT_SIGNED_IN}")).await;
    let out = c.auth(json!({"sessionId": id})).await;
    assert_eq!(state(&out), ("signedOut", "turn"), "{out}");
    assert_eq!(out["routeId"], "acct", "{out}");
    assert_eq!(
        out["login"]["command"],
        format!("CLAUDE_CONFIG_DIR={} claude auth login", home.display()),
        "{out}"
    );
}

/// A target (a new tab with no session yet) reads the newest turn of a chat here with the same
/// harness, account home and route: none is unknown, a sibling's sign-in failure counts, and a
/// chat in another account home never does.
#[tokio::test]
async fn session_auth_for_a_target_reads_only_its_own_account() {
    let root = scratch("target");
    let hub = hub(&root);
    let mut c = client(&hub);
    let target = json!({"target": {"harness": "fake"}});
    let none = c.auth(target.clone()).await;
    assert_eq!(state(&none), ("unknown", "none"), "{none}");

    let other_home = c.new_session(Some("two")).await;
    c.prompt(&other_home, &format!("fail-streamed: {NOT_SIGNED_IN}")).await;
    let out = c.auth(target.clone()).await;
    assert_eq!(state(&out), ("unknown", "none"), "another account home leaked: {out}");
    let theirs = c.auth(json!({"sessionId": other_home})).await;
    assert_eq!(state(&theirs), ("signedOut", "turn"), "{theirs}");

    let sibling = c.new_session(None).await;
    c.prompt(&sibling, &format!("fail-streamed: {NOT_SIGNED_IN}")).await;
    let out = c.auth(target.clone()).await;
    assert_eq!(state(&out), ("signedOut", "turn"), "{out}");
    assert_eq!(out["fromSessionId"], json!(sibling), "{out}");

    let unknown = c.call(method::MUX_SESSION_AUTH, json!({"target": {"harness": "nope"}})).await;
    assert_eq!(unknown["error"]["code"], -32602, "{unknown}");
}

/// A home the harness's `defaults` env pins is the home its chats run in, as at spawn (the
/// defaults' env under the profile's): a chat's and a target's sign-in names it.
#[tokio::test]
async fn session_auth_reads_the_home_the_defaults_pin() {
    let root = scratch("defaults-home");
    let hub = hub(&root);
    let mut c = client(&hub);
    let home = root.join("claude-defaulted");
    let login = format!("CLAUDE_CONFIG_DIR={} claude auth login", home.display());
    let chat = c.new_session_of("deflt").await;
    c.prompt(&chat, &format!("fail-streamed: {NOT_SIGNED_IN}")).await;
    let out = c.auth(json!({"sessionId": chat})).await;
    assert_eq!(state(&out), ("signedOut", "turn"), "{out}");
    assert_eq!(out["login"]["command"], login, "{out}");
    let out = c.auth(json!({"target": {"harness": "deflt"}})).await;
    assert_eq!(state(&out), ("signedOut", "turn"), "{out}");
    assert_eq!(out["fromSessionId"], json!(chat), "{out}");
    assert_eq!(out["login"]["command"], login, "{out}");
}

/// A route's health endpoint: every request gets the status `status` holds at the time.
async fn endpoint(status: Arc<std::sync::Mutex<&'static str>>) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/health", l.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = l.accept().await {
            let mut buf = [0u8; 4096];
            let _ = tcp.read(&mut buf).await;
            let status = *status.lock().unwrap();
            let reply =
                format!("HTTP/1.1 {status}\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}");
            let _ = tcp.write_all(reply.as_bytes()).await;
        }
    });
    url
}

/// The bound route's probe comes before the turn: auth_needed is routeAuthNeeded (sign in to
/// the route), while a rate-limited answer says nothing of the sign-in and falls through.
#[tokio::test]
async fn session_auth_reads_the_routes_probe_and_a_rate_limit_falls_through() {
    let root = scratch("route");
    let hub = hub(&root);
    let mut c = client(&hub);
    let locked = Arc::new(std::sync::Mutex::new("401 Unauthorized"));
    let busy = Arc::new(std::sync::Mutex::new("429 Too Many Requests"));
    for (id, status) in [("locked", &locked), ("busy", &busy)] {
        let url = endpoint(status.clone()).await;
        let added = c
            .call(
                "_acpmux/route/add",
                json!({"id": id, "kind": "custom-anthropic", "anthropicBaseUrl": url, "healthUrl": url}),
            )
            .await;
        assert!(added.get("error").is_none(), "{added}");
    }
    let set =
        c.call("_acpmux/route/default.set", json!({"scope": "global", "routeId": "locked"})).await;
    assert!(set.get("error").is_none(), "{set}");

    // Without refresh and no probe yet: nothing to read.
    let out = c.auth(json!({"target": {"harness": "fake"}})).await;
    assert_eq!(state(&out), ("unknown", "none"), "{out}");
    assert_eq!(out["routeId"], "locked", "the default route applies: {out}");
    let out = c.auth(json!({"target": {"harness": "fake"}, "refresh": true})).await;
    assert_eq!(state(&out), ("routeAuthNeeded", "routeProbe"), "{out}");
    assert_eq!(out["login"], json!({"kind": "route", "routeId": "locked"}), "{out}");
    // The probe is reused without refresh.
    let again = c.auth(json!({"target": {"harness": "fake"}})).await;
    assert_eq!(state(&again), ("routeAuthNeeded", "routeProbe"), "{again}");

    // Refresh probes again: the route now answers.
    *locked.lock().unwrap() = "200 OK";
    let out = c.auth(json!({"target": {"harness": "fake"}, "refresh": true})).await;
    assert_eq!(state(&out), ("unknown", "none"), "a fresh probe replaces the old one: {out}");

    let rate_limited = json!({"target": {"harness": "fake", "routeId": "busy"}, "refresh": true});
    let out = c.auth(rate_limited).await;
    assert_eq!(state(&out), ("unknown", "none"), "a rate limit is no sign-in: {out}");
    assert_eq!(out["routeId"], "busy", "{out}");

    // A profile's own route beats the global default, as at spawn.
    let out = c.auth(json!({"target": {"harness": "pinned"}})).await;
    assert_eq!(out["routeId"], "busy", "the profile's route applies: {out}");
    assert_eq!(state(&out), ("unknown", "none"), "{out}");

    // A route that does not serve the harness is refused, as a spawn refuses it.
    let added = c
        .call(
            "_acpmux/route/add",
            json!({"id": "codex-only", "kind": "custom-openai", "openaiBaseUrl": "http://127.0.0.1:9/v1", "families": ["codex"]}),
        )
        .await;
    assert!(added.get("error").is_none(), "{added}");
    let other = json!({"target": {"harness": "fake", "routeId": "codex-only"}});
    let refused = c.call(method::MUX_SESSION_AUTH, other).await;
    assert_eq!(refused["error"]["code"], -32602, "{refused}");
}

/// A fake peer daemon: lists the session `session`, answers `_acpmux/session/auth` as signed
/// out when `features` lists `sessionAuth`, and serves one connection only, which it closes
/// after `close_after` session/auth requests (0: on the first, without answering it).
async fn fake_peer(features: Value, session: &'static str, close_after: usize) -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        let Ok((tcp, _)) = l.accept().await else { return };
        let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { return };
        let mut asked = 0;
        while let Some(Ok(Ws::Text(text))) = ws.next().await {
            let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                continue;
            };
            let result = match m.as_str() {
                method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                    "build": "older", "origin": "peer", "features": features}}}),
                method::MUX_WATCH => {
                    json!({"sessions": [{"sessionId": session, "harness": "fake"}]})
                }
                method::MUX_SESSION_AUTH if close_after == 0 => {
                    let _ = ws.close(None).await;
                    return;
                }
                method::MUX_SESSION_AUTH => {
                    asked += 1;
                    json!({"state": "signedOut", "source": "turn", "evidenceAt": 5,
                           "detail": "its last turn failed", "harness": "fake", "host": null,
                           "routeId": null, "fromSessionId": session,
                           "login": {"kind": "terminal", "command": "claude auth login"}})
                }
                _ => json!({}),
            };
            let reply = Message::ok(id, result).to_line();
            if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                return;
            }
            if close_after > 0 && asked >= close_after {
                let _ = ws.close(None).await;
                return;
            }
        }
    });
    port
}

/// A peer's chat or target is the peer's answer, naming the peer; a peer whose link is down is
/// peerUnreachable from the link, and a peer on an acpmux without the method is unknown.
#[tokio::test]
async fn session_auth_asks_the_peer_and_answers_for_a_peer_that_is_down() {
    let root = scratch("peers");
    let hub = hub(&root);
    let port = fake_peer(json!(["sessionAuth"]), "far-1", 1).await;
    hub.add_peer("far", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let old = fake_peer(json!(["filePutChunks"]), "old-1", usize::MAX).await;
    hub.add_peer("old", &format!("ws://127.0.0.1:{old}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let drop = fake_peer(json!(["sessionAuth"]), "drop-1", 0).await;
    hub.add_peer("drop", &format!("ws://127.0.0.1:{drop}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    // Nothing listens on port 9: never reached.
    hub.add_peer("gone", "ws://127.0.0.1:9", Some("tok".into()), None, false).await.unwrap();
    let mut c = client(&hub);

    let out = c.auth(json!({"sessionId": "far-1"})).await;
    assert_eq!(state(&out), ("signedOut", "turn"), "{out}");
    assert_eq!(out["host"], "far", "{out}");
    assert_eq!(out["login"]["host"], "far", "sign in on the peer: {out}");

    // The peer closed its only connection: the link is down, and the chat's row stays.
    let far = hub.peer_by_name("far").unwrap();
    for _ in 0..200 {
        if !far.connected.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let out = c.auth(json!({"sessionId": "far-1"})).await;
    assert_eq!(state(&out), ("peerUnreachable", "peerLink"), "{out}");
    assert_eq!(out["host"], "far", "{out}");
    assert!(out.get("login").is_none(), "{out}");

    // The link drops under the request: peerUnreachable, not an error.
    let out = c.auth(json!({"sessionId": "drop-1"})).await;
    assert_eq!(state(&out), ("peerUnreachable", "peerLink"), "{out}");
    assert_eq!(out["host"], "drop", "{out}");

    let out = c.auth(json!({"target": {"harness": "fake", "host": "gone"}})).await;
    assert_eq!(state(&out), ("peerUnreachable", "peerLink"), "{out}");
    assert!(out["evidenceAt"].as_u64().is_some(), "{out}");
    // A target's own route stays named when the peer cannot answer for it.
    let routed = json!({"target": {"harness": "fake", "host": "gone", "routeId": "far-route"}});
    let out = c.auth(routed).await;
    assert_eq!(state(&out), ("peerUnreachable", "peerLink"), "{out}");
    assert_eq!(out["routeId"], "far-route", "{out}");

    for old in
        [json!({"sessionId": "old-1"}), json!({"target": {"harness": "fake", "host": "old"}})]
    {
        let out = c.auth(old).await;
        assert_eq!(state(&out), ("unknown", "none"), "{out}");
        assert_eq!(out["host"], "old", "{out}");
        assert!(out["detail"].as_str().unwrap().contains("acpmux host update old"), "{out}");
    }
    let routed = json!({"target": {"harness": "fake", "host": "old", "routeId": "old-route"}});
    let out = c.auth(routed).await;
    assert_eq!((state(&out), &out["routeId"]), (("unknown", "none"), &json!("old-route")), "{out}");
}

/// `initialize` lists the feature a client checks before it asks.
#[tokio::test]
async fn session_auth_is_listed_in_initialize() {
    let root = scratch("init");
    let mut c = client(&hub(&root));
    let v = c
        .call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
        .await;
    let features = v.pointer("/result/_meta/acpmux/features").cloned().unwrap_or_default();
    assert!(features.as_array().unwrap().contains(&json!("sessionAuth")), "{v}");
    let methods = v.pointer("/result/_meta/acpmux/extensions").cloned().unwrap_or_default();
    assert!(methods.as_array().unwrap().contains(&json!(method::MUX_SESSION_AUTH)), "{v}");
}
