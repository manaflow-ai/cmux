//! `_acpmux/session/auth` (`hub/session_auth.rs`; Leo: "you gotta re-authenticate. You gotta
//! log in again on the modal picker before the user even sends a prompt."): a chat's sign-in
//! from its own evidence, never a guess.

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
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "family": "claude"},
            // A harness whose own check passes only in the env its preset `checked-two` or the
            // chat's own env sets.
            "checked": {"argv": ["python3", FAKE], "family": "plain"},
            // A profile whose own route `acct` (an account home) its chats spawn on.
            "acct": {"argv": ["python3", FAKE], "family": "claude", "env": {"ACPMUX_PROFILE_ROUTE": "acct"}},
        },
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
