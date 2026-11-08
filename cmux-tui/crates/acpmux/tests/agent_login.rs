//! `_acpmux/agent_login/*` (`agent_login.rs`, `server/agent_login.rs`) end to
//! end over a connection, with stand-in `claude` and `codex` scripts that
//! print what the real CLIs print and read the code or key the way they do.
//! They check the env they got (no model-plane values, no browser) and write
//! their sign-in where the real CLIs do.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts here; the sign-in CLIs are the stand-ins below.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// `claude auth login --claudeai` as Claude Code 2.1.312 runs it: the manual
/// link printed under a terminal (OSC-8), then the automatic link (its
/// redirect is the CLI's own listener) handed to `$BROWSER`, then either a
/// code on stdin (`good-code#state` signs in) or the approve reaching the
/// listener, which `$FAKE_DIR/approve` stands for here. `$FAKE_DIR/no-listener`
/// leaves the browser out (a CLI with no listener).
const FAKE_CLAUDE: &str = r#"#!/bin/sh
[ "$1 $2 $3" = "auth login --claudeai" ] || exit 64
for v in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY DISPLAY; do
  eval "x=\${$v-}"; [ -z "$x" ] || { echo "leaked $v" >&2; exit 65; }
done
[ "$BROWSER" != true ] && [ -x "$BROWSER" ] || exit 66
[ "$CMUX_CLAUDE_AUTH" = own ] || exit 67
url='https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=abc'
auto='https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=abc'
printf 'Opening browser to sign in\342\200\246\nIf the browser did not open, visit: \033]8;;%s\033\\%s\033]8;;\033\\\nPaste code here if prompted > ' "$url" "$url"
[ -f "$FAKE_DIR/no-listener" ] || "$BROWSER" "$auto" || exit 68
signed_in() {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"claudeAiOauth":{"accessToken":"t"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  echo 'Login successful.'
  exit 0
}
exec 3<&0
{ read code <&3; printf '%s' "$code" > ./pasted.tmp && mv ./pasted.tmp ./pasted; } &
i=0
while [ $i -lt 600 ]; do
  if [ -f ./pasted ]; then
    [ "$(cat ./pasted)" = 'good-code#state' ] && signed_in
    echo 'OAuth error: invalid code' >&2
    exit 1
  fi
  if [ -f "$FAKE_DIR/approve" ]; then rm -f "$FAKE_DIR/approve"; signed_in; fi
  sleep 0.1
  i=$((i+1))
done
exit 1
"#;

/// `codex login --device-auth` and `--with-api-key` as codex-cli 0.162.1.
const FAKE_CODEX: &str = r#"#!/bin/sh
for v in OPENAI_API_KEY OPENAI_BASE_URL CODEX_API_KEY DISPLAY; do
  eval "x=\${$v-}"; [ -z "$x" ] || { echo "leaked $v" >&2; exit 65; }
done
[ -d "$CODEX_HOME" ] || exit 66
case "$*" in
  "login --device-auth")
    printf '\033[1m1. Open this link in your browser and sign in to your account\033[0m\n   \033[94mhttps://auth.openai.com/codex/device\033[0m\n\n2. Enter this one-time code \033[90m(expires in 15 minutes)\033[0m\n   \033[94mABCD-EFGHI\033[0m\n'
    sleep 1
    printf '{"tokens":{"id_token":"t"}}' > "$CODEX_HOME/auth.json"
    echo 'Successfully logged in'
    ;;
  "login --with-api-key")
    read key
    [ "$key" = sk-test-123456 ] || { echo 'bad key' >&2; exit 1; }
    printf '{"OPENAI_API_KEY":"%s"}' "$key" > "$CODEX_HOME/auth.json"
    ;;
  *) exit 64 ;;
esac
"#;

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("agent-login-it-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[cfg(unix)]
fn script(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A hub whose `claude` and `codex` harnesses are the stand-ins, keeping
/// their sign-ins under `d`, and whose `/etc/cmux` is `d/root/etc/cmux`.
fn hub(d: &Path) -> Arc<Hub> {
    let bin = d.join("bin");
    script(&bin.join("claude"), FAKE_CLAUDE);
    script(&bin.join("codex"), FAKE_CODEX);
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "claude": {
                "kind": "claude-stdio",
                "argv": [bin.join("claude")],
                "env": {"CLAUDE_CONFIG_DIR": d.join("claude-home"), "FAKE_DIR": d},
            },
            "codex": {
                "argv": [bin.join("codex"), "app-server"],
                "env": {"CODEX_HOME": d.join("codex-home")},
            },
        },
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.path = Some(d.join("acpmux/config.json"));
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_vm_marker_root(d.join("root"));
    hub
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn new(hub: Arc<Hub>, origin: Origin) -> (C, Value) {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        drop(tokio::spawn(serve_connection_with(hub, in_rx, out_tx, origin)));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        let init = c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
        (c, init)
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
}

fn reason(e: &Value) -> &str {
    e.pointer("/data/reason").and_then(Value::as_str).unwrap_or_default()
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_login_over_the_wire() {
    let d = dir("wire");
    let hub = hub(&d);
    let (mut c, init) = C::new(hub.clone(), Origin::Local).await;
    let features = init.pointer("/_meta/acpmux/features").and_then(Value::as_array).unwrap();
    assert!(features.contains(&json!("agent_login")), "{features:?}");
    let caps = init.pointer("/_meta/acpmux/capabilities").and_then(Value::as_array).unwrap();
    assert!(caps.contains(&json!("agent-login-v1")), "{caps:?}");

    // An agent this does not sign in.
    let e = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "gemini"})).await.unwrap_err();
    assert_eq!(reason(&e), "unsupported_agent");

    // Claude: the link from the OSC-8 hyperlink, and the automatic link its
    // BROWSER got; a wrong code is bad_code.
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    assert_eq!(s["url"], "https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=abc");
    assert_eq!(s["autoUrl"], AUTO_URL);
    assert_eq!(s["callbackPort"], 54545);
    assert_eq!(s["needsCode"], true);
    assert!(s.get("userCode").is_none());
    assert!(s["expiresAtMs"].as_u64().unwrap() > 0);
    let id = s["loginId"].as_str().unwrap().to_owned();
    let e = c
        .call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": id, "code": "wrong"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "bad_code", "{e}");
    // The sign-in ended with it.
    let e = c
        .call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": id, "code": "x"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "unknown_login");

    // A new start stops the one before it.
    let first = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    let e = c
        .call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": first["loginId"], "code": "x"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "unknown_login");
    // Not a cmux Cloud image yet: no own-choice file.
    let r = c
        .call(
            method::MUX_AGENT_LOGIN_FINISH,
            json!({"loginId": s["loginId"], "code": "good-code#state"}),
        )
        .await
        .unwrap();
    assert_eq!(r, json!({"signedIn": true, "restarted": false}));
    assert!(d.join("claude-home/.credentials.json").is_file());
    let home = dirs::home_dir().unwrap();
    assert!(!home.join(".config/cmux/agent-auth/claude").exists());

    claude_with_no_code(&hub, &mut c, &d).await;

    // Cancel stops a sign-in, whatever chat it names; a second cancel is a no-op.
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    assert_eq!(
        c.call(
            method::MUX_AGENT_LOGIN_CANCEL,
            json!({"loginId": s["loginId"], "sessionId": "stale"})
        )
        .await
        .unwrap(),
        json!({})
    );
    assert_eq!(
        c.call(method::MUX_AGENT_LOGIN_CANCEL, json!({"loginId": s["loginId"]})).await.unwrap(),
        json!({})
    );

    // A cmux Cloud owner machine: the image's launcher is told to use the own sign-in.
    std::fs::create_dir_all(d.join("root/etc/cmux")).unwrap();
    std::fs::write(d.join("root/etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    std::fs::write(d.join("root/etc/cmux/vm-kind"), "owner\n").unwrap();

    // Codex: the device link and code; finish waits for the device flow.
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "codex"})).await.unwrap();
    assert_eq!(s["url"], "https://auth.openai.com/codex/device");
    assert_eq!(s["userCode"], "ABCD-EFGHI");
    assert_eq!(s["needsCode"], false);
    // A chat this daemon does not have: refused, never signed in here in its place.
    let e = c
        .call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": s["loginId"], "sessionId": "nope"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "unknown_session");
    let r = c.call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": s["loginId"]})).await.unwrap();
    assert_eq!(r, json!({"signedIn": true, "restarted": false}));
    // This chat uses an alternate Codex home, so its sign-in stays scoped to
    // the chat and does not change the machine-wide canonical choice.
    assert!(!home.join(".config/cmux/agent-auth/codex").exists());

    // API keys: Codex through its own CLI, Claude into its settings.json.
    let e = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "codex", "key": "sk-wrong-000000"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "bad_code");
    let r = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "codex", "key": "sk-test-123456"}))
        .await
        .unwrap();
    assert_eq!(r, json!({"saved": true, "restarted": false}));
    let r = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "claude", "key": "sk-ant-test-1"}))
        .await
        .unwrap();
    assert_eq!(r, json!({"saved": true, "restarted": false}));
    let settings: Value =
        serde_json::from_slice(&std::fs::read(d.join("claude-home/settings.json")).unwrap())
            .unwrap();
    assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], "sk-ant-test-1");
    // The Claude profile also uses an alternate account home, so its API key
    // save must leave the canonical machine choice untouched.
    assert!(!home.join(".config/cmux/agent-auth/claude").exists());

    // A team machine: refused before anything runs.
    std::fs::write(d.join("root/etc/cmux/vm-kind"), "team\n").unwrap();
    let e = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "codex"})).await.unwrap_err();
    assert_eq!(reason(&e), "shared_machine");
    let e = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "claude", "key": "sk-ant-test-2"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "shared_machine");

    // A remote WebSocket page never runs a sign-in.
    let (mut web, _) = C::new(hub.clone(), Origin::Web).await;
    web.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap_err();

    let _ = std::fs::remove_dir_all(&d);
}

const AUTO_URL: &str = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=abc";

/// Claude signed in with no code pasted: the approve reaches the CLI's own
/// listener and it exits; a paste still works while that finish waits; a new
/// start is never held up by it; a CLI that gave no automatic link still
/// needs the code.
#[cfg(unix)]
async fn claude_with_no_code(hub: &Arc<Hub>, c: &mut C, d: &Path) {
    let creds = d.join("claude-home/.credentials.json");
    let finish = |id: &Value| json!({"loginId": id.clone()});

    // The approve: finish with no code ends when the CLI does.
    let _ = std::fs::remove_file(&creds);
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    let approve = d.join("approve");
    let approving = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        std::fs::write(approve, "").unwrap();
    });
    let r = c.call(method::MUX_AGENT_LOGIN_FINISH, finish(&s["loginId"])).await.unwrap();
    approving.await.unwrap();
    assert_eq!(r, json!({"signedIn": true, "restarted": false}));
    assert!(creds.is_file());

    // A paste while that wait runs: both finishes see the one sign-in.
    let _ = std::fs::remove_file(&creds);
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    let (mut other, _) = C::new(hub.clone(), Origin::Local).await;
    let params = finish(&s["loginId"]);
    let waiting =
        tokio::spawn(async move { other.call(method::MUX_AGENT_LOGIN_FINISH, params).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let r = c
        .call(
            method::MUX_AGENT_LOGIN_FINISH,
            json!({"loginId": s["loginId"], "code": "good-code#state"}),
        )
        .await
        .unwrap();
    assert_eq!(r["signedIn"], true);
    assert_eq!(waiting.await.unwrap().unwrap()["signedIn"], true);
    assert!(creds.is_file());

    // Starting again while a finish waits for the approve: the old one stops.
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    let (mut other, _) = C::new(hub.clone(), Origin::Local).await;
    let params = finish(&s["loginId"]);
    let waiting =
        tokio::spawn(async move { other.call(method::MUX_AGENT_LOGIN_FINISH, params).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let again = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    assert!(waiting.await.unwrap().is_err());
    c.call(method::MUX_AGENT_LOGIN_CANCEL, json!({"loginId": again["loginId"]})).await.unwrap();

    // No automatic link (the CLI handed its BROWSER nothing): the code is needed.
    std::fs::write(d.join("no-listener"), "").unwrap();
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    assert!(s.get("autoUrl").is_none(), "{s}");
    let e = c.call(method::MUX_AGENT_LOGIN_FINISH, finish(&s["loginId"])).await.unwrap_err();
    assert_eq!(reason(&e), "bad_code");
    c.call(method::MUX_AGENT_LOGIN_CANCEL, json!({"loginId": s["loginId"]})).await.unwrap();
    std::fs::remove_file(d.join("no-listener")).unwrap();
}
