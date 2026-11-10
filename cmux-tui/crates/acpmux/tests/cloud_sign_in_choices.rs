//! A Cloud chat whose Claude has no credential never ends in a bare "Not logged in · Please run
//! /login" (Leo, 2026-11-10: "if someone had a normal account or if someone had an API, presumably
//! we have normal ways for people to just do that ... the stuff does of course go through our
//! gateway"). The failed turn's card offers three ways, each run here end to end in a hub on a
//! stand-in cmux Cloud machine, with `fake_claude.py` (FAKE_CLAUDE_AUTH=1) as Claude Code, which
//! looks for a sign-in the way Claude Code does:
//!
//! 1. Sign in with Claude: `_acpmux/agent_login/start` runs a stand-in `claude auth login
//!    --claudeai` (a fake OAuth page and code), `finish` hands it the code, and the chat's next
//!    turn is signed in.
//! 2. Use an API key: `_acpmux/agent_login/api_key` writes it to Claude's settings.json (0600, never
//!    answered back), and the chat's next turn finds it.
//! 3. Use cmux's gateway: offered on the failed turn (`signInGateway`) only where the image's
//!    `cmux_agent_gateway_available` says so; `start {agent: "gateway:claude"}` records `team` as
//!    `cr use team claude` does, and is refused (`no_gateway`) where the gateway does not serve.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The hub runs the stand-in Claude Code (fake_claude.py) in process.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE_PY: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

/// Claude Code: `claude auth login --claudeai` prints its sign-in page (a fake OAuth page, the way
/// Claude Code 2.1.312 prints it under a terminal) and signs in on the code that page gives
/// (`good-code#state`); anything else is the stand-in Claude Code.
fn wrapper() -> String {
    format!(
        r#"#!/bin/sh
if [ "$1 $2 $3" = "auth login --claudeai" ]; then
  [ "$CMUX_CLAUDE_AUTH" = own ] || exit 67
  url='https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=abc'
  printf 'If the browser did not open, visit: \033]8;;%s\033\\%s\033]8;;\033\\\nPaste code here if prompted > ' "$url" "$url"
  read code
  [ "$code" = 'good-code#state' ] || {{ echo 'OAuth error: invalid code' >&2; exit 1; }}
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{{"claudeAiOauth":{{"accessToken":"t"}}}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  echo 'Login successful.'
  exit 0
fi
exec python3 {FAKE_CLAUDE_PY} "$@"
"#
    )
}

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("cloud-sign-in-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    d
}

fn write(path: &Path, text: &str, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

/// A hub on a cmux Cloud machine (`cloud_host`) whose `claude` is the stand-in, keeping its sign-in
/// under `d/claude-home`, with the machine's `etc/cmux` under `d/root`.
fn hub(d: &Path) -> Arc<Hub> {
    let bin = d.join("bin/claude");
    write(&bin, &wrapper(), 0o755);
    let mut cfg: Config = serde_json::from_value(json!({
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
        "harnesses": {
            "claude": {
                "kind": "claude-stdio",
                "argv": [bin],
                "env": {"CLAUDE_CONFIG_DIR": d.join("claude-home"), "FAKE_CLAUDE_AUTH": "1"},
            },
        },
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.path = Some(d.join("acpmux/config.json"));
    cfg.cloud_host = true;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_vm_marker_root(d.join("root"));
    hub
}

/// The image: `vm-kind` owner, and an `agent-auth.sh` whose gateway check says yes for Claude
/// while `d/gateway-ok` exists (the real check is pinned in web/tests/vm-devbox-agent-auth.test.ts).
fn image(d: &Path) {
    let etc = d.join("root/etc/cmux");
    write(&etc.join("vm-kind"), "owner\n", 0o644);
    let ok = d.join("gateway-ok");
    write(
        &etc.join("agent-auth.sh"),
        &format!(
            "cmux_agent_gateway_available() {{ [ \"$1\" = claude ] && [ -f '{}' ]; }}\n",
            ok.display()
        ),
        0o644,
    );
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn new(hub: Arc<Hub>) -> C {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        drop(tokio::spawn(serve_connection_with(hub, in_rx, out_tx, Origin::Local)));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
        c
    }

    /// The result, or the error object.
    async fn call(&mut self, m: &str, p: Value) -> Result<Value, Value> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .expect("a reply")
                .expect("open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    async fn chat(&mut self, d: &Path, name: &str) -> String {
        let made = self
            .call(
                "session/new",
                json!({"cwd": d.join("work"), "mcpServers": [],
                       "_meta": {"acpmux": {"harness": "claude", "name": name}}}),
            )
            .await
            .unwrap();
        made["sessionId"].as_str().unwrap().to_owned()
    }

    /// One prompt in chat `id`: its newest `turn_result` record.
    async fn turn(&mut self, id: &str) -> Value {
        let _ = self
            .call(
                "session/prompt",
                json!({"sessionId": id, "prompt": [{"type": "text", "text": "auth?"}]}),
            )
            .await;
        let events = self
            .call("_acpmux/events", json!({"sessionId": id, "kinds": ["turn_result"]}))
            .await
            .unwrap();
        events["events"].as_array().and_then(|e| e.last()).map(|e| e["msg"].clone()).unwrap()
    }
}

fn reason(e: &Value) -> &str {
    e.pointer("/data/reason").and_then(Value::as_str).unwrap_or_default()
}

fn signed_out(turn: &Value) {
    assert_eq!(turn["status"], "failed", "{turn}");
    let text = turn["errorText"].as_str().unwrap_or_default();
    // Never the bare words: what this machine had, and the way to sign it in, with Claude's own
    // words kept at the end.
    assert!(text.starts_with("Claude is not signed in here."), "{turn}");
    assert!(text.ends_with("(Claude said: Not logged in · Please run /login)"), "{turn}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_gateway_is_offered_only_where_it_serves_and_an_api_key_reaches_claude() {
    let d = dir("gateway-key");
    let hub = hub(&d);
    let mut c = C::new(hub.clone()).await;
    let chat = c.chat(&d, "cloud-key").await;

    // Not a cmux Cloud image: no gateway to offer.
    let turn = c.turn(&chat).await;
    signed_out(&turn);
    assert!(turn.get("signInGateway").is_none(), "{turn}");

    // An image whose gateway does not serve this team (no account): still none.
    image(&d);
    let turn = c.turn(&chat).await;
    signed_out(&turn);
    assert!(turn.get("signInGateway").is_none(), "{turn}");
    let e = c
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "gateway:claude", "sessionId": chat}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "no_gateway", "{e}");
    let home = dirs::home_dir().unwrap();
    let choice = home.join(".config/cmux/agent-auth/claude");
    assert!(!choice.exists());

    // The gateway serves it: the failed turn says so, and the choice puts Claude on it.
    write(&d.join("gateway-ok"), "", 0o644);
    let turn = c.turn(&chat).await;
    signed_out(&turn);
    assert_eq!(turn["signInGateway"], true, "{turn}");
    let r = c
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "gateway:claude", "sessionId": chat}))
        .await
        .unwrap();
    assert_eq!(r["gateway"], true, "{r}");
    assert_eq!(r["signedIn"], true, "{r}");
    assert_eq!(std::fs::read_to_string(&choice).unwrap(), "team\n");
    // Another agent's gateway is not a thing this names.
    let e = c
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "gateway:gemini", "sessionId": chat}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "unsupported_agent", "{e}");
    let _ = std::fs::remove_file(&choice);
    std::fs::remove_file(d.join("gateway-ok")).unwrap();

    // Use an API key: saved where Claude reads it, owner-only, never answered back; the chat's
    // next turn signs in with it.
    let key = "sk-ant-cloud-card-test";
    let r = c
        .call(
            method::MUX_AGENT_LOGIN_API_KEY,
            json!({"agent": "claude", "key": key, "sessionId": chat}),
        )
        .await
        .unwrap();
    assert_eq!(r["saved"], true, "{r}");
    assert!(!r.to_string().contains(key), "the key came back: {r}");
    let settings = d.join("claude-home/settings.json");
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&settings).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let saved: Value = serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
    assert_eq!(saved["env"]["ANTHROPIC_API_KEY"], key);
    let turn = c.turn(&chat).await;
    assert_eq!(turn["status"], "completed", "{turn}");
    assert!(!turn.to_string().contains(key), "the key is in the turn record: {turn}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sign_in_with_claude_signs_the_cloud_chat_in() {
    let d = dir("claude-login");
    let hub = hub(&d);
    image(&d);
    let mut c = C::new(hub.clone()).await;
    let chat = c.chat(&d, "cloud-login").await;
    signed_out(&c.turn(&chat).await);

    // The card's one click: the page to open, and a code to paste back (no automatic page from
    // this CLI). A wrong code is bad_code and ends that sign-in.
    let s = c
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude", "sessionId": chat}))
        .await
        .unwrap();
    assert_eq!(s["url"], "https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=abc");
    assert_eq!(s["needsCode"], true, "{s}");
    let e = c
        .call(
            method::MUX_AGENT_LOGIN_FINISH,
            json!({"loginId": s["loginId"], "code": "wrong", "sessionId": chat}),
        )
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "bad_code", "{e}");
    let s = c
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude", "sessionId": chat}))
        .await
        .unwrap();
    let r = c
        .call(
            method::MUX_AGENT_LOGIN_FINISH,
            json!({"loginId": s["loginId"], "code": "good-code#state", "sessionId": chat}),
        )
        .await
        .unwrap();
    assert_eq!(r["signedIn"], true, "{r}");
    assert!(d.join("claude-home/.credentials.json").is_file());
    let turn = c.turn(&chat).await;
    assert_eq!(turn["status"], "completed", "{turn}");
    let _ = std::fs::remove_dir_all(&d);
}
