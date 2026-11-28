//! `_acpmux/agent_login/*` (`agent_login.rs`, `server/agent_login.rs`) end to
//! end over a connection, with stand-in `claude`, `codex`, `grok` and `cursor-agent` scripts that
//! print what the real CLIs print and read the code or key the way they do.
//! They check the env they got (no model-plane values, no browser) and write
//! their sign-in where the real CLIs do.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts here; the sign-in CLIs are the stand-ins below. ACPMUX_HOT_MODULE and
// ACPMUX_HOT_SWAP_TO pass through so crates/acpmux-hot/bench.sh can run this sign-in with the parser
// from a dev module and swap it live (they do nothing unless the `hot-modules` feature is on).
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["ACPMUX_HOT_MODULE", "ACPMUX_HOT_SWAP_TO"]);

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
if [ "$1 $2 $3" = "auth status --json" ]; then
  if [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
    printf '{"loggedIn":true,"authMethod":"claude.ai"}\n'
  else
    printf '{"loggedIn":false}\n'
  fi
  exit 0
fi
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

/// `grok login --device-auth` (alias `--device-code`) as the grok CLI may print it: a link on
/// accounts.x.ai and a code, then the sign-in in `$GROK_HOME/auth.json` once the person approved
/// (a moment later here). Its exact words are not pinned (`parse::grok_code`).
const FAKE_GROK: &str = r#"#!/bin/sh
for v in XAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY OPENAI_API_KEY DISPLAY; do
  eval "x=\${$v-}"; [ -z "$x" ] || { echo "leaked $v" >&2; exit 65; }
done
[ "$BROWSER" = true ] || exit 66
[ "$CMUX_GROK_AUTH" = own ] || exit 67
[ -d "$GROK_HOME" ] || exit 68
case "$*" in
  "login --device-auth"|"login --device-code")
    # grok 1.0.77's own words on Linux.
    printf 'To sign in, open this URL in your browser:\n  https://accounts.x.ai/oauth2/device?user_code=WDJB-MJHT\nConfirm this code in your browser:\n  WDJB-MJHT\n\033[90mOnly continue with a code you requested. Don'"'"'t share it with anyone.\033[0m\nWaiting for authorization...\n'
    sleep 1
    printf '{"https://auth.x.ai::fixture":{"access_token":"t","refresh_token":"r"}}' > "$GROK_HOME/auth.json"
    echo 'Logged in.'
    ;;
  *) exit 64 ;;
esac
"#;

/// Cursor writes its sign-in to the configured test home after approving the browser link.
const FAKE_CURSOR: &str = r#"#!/bin/sh
[ "$*" = "login" ] && [ "$NO_OPEN_BROWSER" = 1 ] || exit 64
printf 'Open in your browser: https://cursor.com/loginDeepControl?challenge=fixture&uuid=1&mode=login\n'
case "$(uname -s)" in
  Darwin) store="$HOME/.cursor" ;;
  *) store="$XDG_CONFIG_HOME/cursor" ;;
esac
mkdir -p "$store"
printf '{"accessToken":"fixture"}' > "$store/auth.json"
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
#[cfg(unix)]
fn hub(d: &Path) -> Arc<Hub> {
    let bin = d.join("bin");
    script(&bin.join("claude"), FAKE_CLAUDE);
    script(&bin.join("codex"), FAKE_CODEX);
    script(&bin.join("grok"), FAKE_GROK);
    script(&bin.join("cursor-agent"), FAKE_CURSOR);
    // Gemini signs in here with a key only: its CLI never runs, it only has to be configured.
    script(&bin.join("gemini"), "#!/bin/sh\nexit 70\n");
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
            "grok": {
                "argv": [bin.join("grok"), "agent", "stdio"],
                "env": {"GROK_HOME": d.join("grok-home"), "XAI_API_KEY": "xai-team-key"},
            },
            "cursor": {
                "kind": "acp",
                "argv": [bin.join("cursor-agent"), "acp"],
                "env": {"XDG_CONFIG_HOME": d.join("cursor-user"), "HOME": d.join("cursor-home")},
            },
            "gemini": {
                "argv": [bin.join("gemini"), "--experimental-acp"],
                "env": {"GEMINI_CLI_HOME": d.join("gemini-user"), "GEMINI_API_KEY": "team-key"},
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
    let e = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "pi"})).await.unwrap_err();
    assert_eq!(reason(&e), "unsupported_agent");
    // OpenCode signs in with a key only: no sign-in page to start.
    let e = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "opencode"})).await.unwrap_err();
    assert_eq!(reason(&e), "unsupported");

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

    // A different Settings connection cannot replace the pending approval.
    let first = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    let (mut other, _) = C::new(hub.clone(), Origin::Local).await;
    let e =
        other.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap_err();
    assert_eq!(reason(&e), "busy");
    let e = other
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude", "reuseExisting": true}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "busy");
    // Not a cmux Cloud image yet: no own-choice file.
    let r = c
        .call(
            method::MUX_AGENT_LOGIN_FINISH,
            json!({"loginId": first["loginId"], "code": "good-code#state"}),
        )
        .await
        .unwrap();
    assert_eq!(r, json!({"signedIn": true, "restarted": false, "agent": "claude"}));
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

    // cmux's gateway, the card's third way in: refused where the machine is no cmux Cloud image,
    // and nothing recorded.
    let e = c
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude@gateway"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "no_gateway", "{e}");
    assert!(!home.join(".config/cmux/agent-auth/claude").exists());
    let e = c
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "gemini@gateway"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "unsupported_agent", "{e}");

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
    assert_eq!(r, json!({"signedIn": true, "restarted": false, "agent": "codex"}));
    // The device-auth card is complete only when the CLI's own auth.json landed in the
    // configured Codex home; a signedIn RPC result alone would miss a broken copy path.
    let auth: Value =
        serde_json::from_slice(&std::fs::read(d.join("codex-home/auth.json")).unwrap())
            .expect("Codex auth.json is JSON");
    assert_eq!(auth["tokens"]["id_token"], "t");
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
    // Write-only: the reply above never carries the key, the file is the agent user's alone, and
    // it reaches the agent: Claude's own sign-in check finds it in the env Claude starts with.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode =
            std::fs::metadata(d.join("claude-home/settings.json")).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0, "{mode:o}");
    }
    let env = std::collections::BTreeMap::from([(
        "CLAUDE_CONFIG_DIR".to_owned(),
        d.join("claude-home").display().to_string(),
    )]);
    let found = acpmux::claude_auth::find(&env);
    assert!(found.signed_in(), "{found:?}");
    assert!(found.sources.iter().any(|s| s.contains("ANTHROPIC_API_KEY")), "{:?}", found.sources);
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

/// Gemini (an API key into `.gemini/.env` and `settings.json`) and Grok (its device flow) over the
/// wire, with the ways each does not sign in answered `unsupported`, and a team machine refusing.
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn gemini_and_grok_login_over_the_wire() {
    let d = dir("gemini-grok");
    let hub = hub(&d);
    let (mut c, _) = C::new(hub.clone(), Origin::Local).await;

    // Gemini: no browser start; the key is saved where Gemini CLI reads it with no shell env.
    let e = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "gemini"})).await.unwrap_err();
    assert_eq!(reason(&e), "unsupported", "{e}");
    let gemini = d.join("gemini-user/.gemini");
    std::fs::create_dir_all(&gemini).unwrap();
    std::fs::write(gemini.join(".env"), "GOOGLE_CLOUD_PROJECT=p\nGEMINI_API_KEY=old\n").unwrap();
    std::fs::write(gemini.join("settings.json"), r#"{"theme":"Dracula"}"#).unwrap();
    let r = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "gemini", "key": "AIzaTest123"}))
        .await
        .unwrap();
    assert_eq!(r, json!({"saved": true, "restarted": false}));
    assert_eq!(
        std::fs::read_to_string(gemini.join(".env")).unwrap(),
        "GOOGLE_CLOUD_PROJECT=p\nGEMINI_API_KEY=AIzaTest123\n"
    );
    let settings: Value =
        serde_json::from_slice(&std::fs::read(gemini.join("settings.json")).unwrap()).unwrap();
    assert_eq!(
        settings,
        json!({"theme": "Dracula", "security": {"auth": {"selectedType": "gemini-api-key"}}})
    );
    let e = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "gemini", "key": "bad key"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "bad_code");

    // Grok: the device link and code; finish waits for the CLI to save its sign-in.
    let e = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "grok", "key": "xai-test-1"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "unsupported", "{e}");
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "grok"})).await.unwrap();
    assert_eq!(s["url"], "https://accounts.x.ai/oauth2/device?user_code=WDJB-MJHT");
    assert_eq!(s["userCode"], "WDJB-MJHT");
    assert_eq!(s["needsCode"], false);
    assert!(s.get("autoUrl").is_none());
    let r = c.call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": s["loginId"]})).await.unwrap();
    assert_eq!(r, json!({"signedIn": true, "restarted": false, "agent": "grok"}));
    assert!(d.join("grok-home/auth.json").is_file());
    let state = c.call(method::MUX_CONNECTIONS, json!({})).await.unwrap();
    assert_native_connection(&state, "grok");
    // A new start stops the one before it.
    let first = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "grok"})).await.unwrap();
    let again = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "grok"})).await.unwrap();
    let e = c
        .call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": first["loginId"]}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "unknown_login");
    c.call(method::MUX_AGENT_LOGIN_CANCEL, json!({"loginId": again["loginId"]})).await.unwrap();

    // A team machine: refused before anything runs.
    std::fs::create_dir_all(d.join("root/etc/cmux")).unwrap();
    std::fs::write(d.join("root/etc/cmux/vm-kind"), "team\n").unwrap();
    let e = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "grok"})).await.unwrap_err();
    assert_eq!(reason(&e), "shared_machine");
    let e = c
        .call(method::MUX_AGENT_LOGIN_API_KEY, json!({"agent": "gemini", "key": "AIzaTeam"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "shared_machine");
    assert!(!std::fs::read_to_string(gemini.join(".env")).unwrap().contains("AIzaTeam"));

    // A remote WebSocket page never runs one.
    let (mut web, _) = C::new(hub.clone(), Origin::Web).await;
    web.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "grok"})).await.unwrap_err();
    let _ = std::fs::remove_dir_all(&d);
}

fn assert_native_connection(state: &Value, provider: &str) {
    let id = format!("{provider}-native-login");
    let row = state["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == id)
        .expect("native sign-in appears in connections");
    assert_eq!(row["kind"], "native-login");
    assert_eq!(row["provider"], provider);
    assert_eq!(row["signed_in"], true);
    assert_eq!(row["serves_cloud"], false);
    assert!(row.get("endpoint_credentials").is_none());
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cursor_login_without_a_chat_uses_the_local_cli_store() {
    let d = dir("cursor");
    let hub = hub(&d);
    let (mut c, _) = C::new(hub, Origin::Local).await;
    let start = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "cursor"})).await.unwrap();
    assert_eq!(
        start["url"],
        "https://cursor.com/loginDeepControl?challenge=fixture&uuid=1&mode=login"
    );
    assert_eq!(start["needsCode"], false);
    assert!(start.get("userCode").is_none());
    let finish =
        c.call(method::MUX_AGENT_LOGIN_FINISH, json!({"loginId": start["loginId"]})).await.unwrap();
    assert_eq!(finish, json!({"signedIn": true, "restarted": false, "agent": "cursor"}));
    if cfg!(target_os = "macos") {
        assert!(d.join("cursor-home/.cursor/auth.json").is_file());
    } else {
        assert!(d.join("cursor-user/cursor/auth.json").is_file());
    }
    let state = c.call(method::MUX_CONNECTIONS, json!({})).await.unwrap();
    assert_native_connection(&state, "cursor");
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(unix)]
#[tokio::test]
async fn native_sign_in_rows_are_read_and_announced_but_not_returned_by_mutations() {
    let d = tempfile::tempdir().unwrap();
    let hub = hub(d.path());
    let profiles = d.path().join("harnesses");
    std::fs::create_dir_all(&profiles).unwrap();
    hub.config.write().await.profile_sources.user_dir = Some(profiles.clone());
    let (mut caller, _) = C::new(hub.clone(), Origin::Local).await;
    let (mut watcher, _) = C::new(hub, Origin::Local).await;
    watcher.call(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    let auth = d.path().join("grok-home/auth.json");
    std::fs::create_dir(auth.parent().unwrap()).unwrap();
    std::fs::write(&auth, "{}").unwrap();
    let signed_out = caller.call(method::MUX_CONNECTIONS, json!({})).await.unwrap();
    assert!(
        signed_out["connections"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["kind"] != "native-login")
    );

    std::fs::write(&auth, r#"{"https://auth.x.ai::fixture":{"refresh_token":"r"}}"#).unwrap();
    let reply = caller
        .call(
            method::MUX_CONNECTIONS_ORDER_SET,
            json!({"ids": ["grok-native-login", "codex-login", "cursor-native-login"]}),
        )
        .await
        .unwrap();
    assert!(
        reply["connections"].as_array().unwrap().iter().all(|row| row["kind"] != "native-login")
    );
    let note = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let message: Value = serde_json::from_str(&watcher.rx.recv().await.unwrap()).unwrap();
            if message["method"] == method::MUX_CONNECTIONS_CHANGED {
                break message["params"].clone();
            }
        }
    })
    .await
    .unwrap();
    assert_native_connection(&note, "grok");

    // A person's endpoint with the same id takes precedence over the detected row.
    use acpmux::byo_endpoint::{Endpoint, Kind, profile_text};
    let profile = profile_text(&Endpoint {
        cloud_enabled: None,
        preset: None,
        kind: Kind::OpenAi,
        id: "grok-native-login",
        name: "My endpoint",
        base_url: "https://models.example.com/v1",
        models: &["model".into()],
        keychain_item: None,
    });
    std::fs::write(profiles.join("grok-native-login.toml"), profile).unwrap();
    let state = caller.call(method::MUX_CONNECTIONS, json!({})).await.unwrap();
    let found: Vec<_> = state["connections"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["id"] == "grok-native-login")
        .collect();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0]["kind"], "endpoint");
}

const AUTO_URL: &str = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=abc";

/// Claude signed in with no code pasted: the approve reaches the CLI's own
/// listener and it exits; a paste still works while that finish waits; a new
/// start is refused while an approval is pending; a CLI without an automatic link
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
    assert_eq!(r, json!({"signedIn": true, "restarted": false, "agent": "claude"}));
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

    // Reusing the signed-in account is refused during reauthentication too.
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    let (mut other, _) = C::new(hub.clone(), Origin::Local).await;
    let e = other
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude", "reuseExisting": true}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "busy");
    c.call(method::MUX_AGENT_LOGIN_CANCEL, finish(&s["loginId"])).await.unwrap();
    let reused = other
        .call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude", "reuseExisting": true}))
        .await
        .unwrap();
    assert_eq!(reused["signedIn"], true);

    // No automatic link (the CLI handed its BROWSER nothing): the code is needed.
    std::fs::write(d.join("no-listener"), "").unwrap();
    let s = c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "claude"})).await.unwrap();
    assert!(s.get("autoUrl").is_none(), "{s}");
    let e = c.call(method::MUX_AGENT_LOGIN_FINISH, finish(&s["loginId"])).await.unwrap_err();
    assert_eq!(reason(&e), "bad_code");
    c.call(method::MUX_AGENT_LOGIN_CANCEL, json!({"loginId": s["loginId"]})).await.unwrap();
    std::fs::remove_file(d.join("no-listener")).unwrap();
}

/// A module swapped under a running daemon (crates/acpmux-hot/bench.sh, `hot-modules` feature only):
/// the daemon reads Codex's sign-in link with the module at `ACPMUX_HOT_MODULE`, the file is replaced
/// by `ACPMUX_HOT_SWAP_TO` (a module that never finds an offer), and the same daemon, with no
/// restart, stops finding the link; the first module put back finds it again. Skipped unless both
/// are set, and bench.sh runs it alone: the swap changes the process's one module for every test.
#[cfg(all(unix, feature = "hot-modules"))]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hot_module_swaps_under_a_running_daemon() {
    let (Some(live), Some(swap_to)) =
        (std::env::var_os("ACPMUX_HOT_MODULE"), std::env::var_os("ACPMUX_HOT_SWAP_TO"))
    else {
        eprintln!("acpmux-hot: ACPMUX_HOT_MODULE and ACPMUX_HOT_SWAP_TO unset; nothing to swap");
        return;
    };
    let live = PathBuf::from(live);
    let first = std::fs::read(&live).unwrap();
    let other = std::fs::read(&swap_to).unwrap();
    // Replaced whole by a rename in the same folder, as a build's copy step would.
    let put = |bytes: &[u8]| {
        let tmp = live.with_extension("swap-tmp");
        std::fs::write(&tmp, bytes).unwrap();
        std::fs::rename(&tmp, &live).unwrap();
    };
    let d = dir("hot-swap");
    let (mut c, _) = C::new(hub(&d), Origin::Local).await;
    // Ok(user code) when the daemon found the offer, Err(reason) when it did not.
    let mut codex = async || -> Result<String, String> {
        match c.call(method::MUX_AGENT_LOGIN_START, json!({"agent": "codex"})).await {
            Ok(s) => {
                c.call(method::MUX_AGENT_LOGIN_CANCEL, json!({"loginId": s["loginId"]}))
                    .await
                    .unwrap();
                Ok(s["userCode"].as_str().unwrap_or_default().to_owned())
            }
            Err(e) => Err(reason(&e).to_owned()),
        }
    };
    // Each attempt runs the stand-in CLI (about 1 s when no offer is found); the watcher polls
    // every 100 ms, so 15 s is many times what a swap takes.
    let deadline = Duration::from_secs(15);

    assert_eq!(codex().await, Ok("ABCD-EFGHI".to_owned()), "the first module finds the offer");

    put(&other);
    let swapped = std::time::Instant::now();
    loop {
        match codex().await {
            Err(r) if r == "no_url" => break,
            Ok(_) if swapped.elapsed() < deadline => {}
            got => panic!("the swapped-in module was never asked: {got:?}"),
        }
    }
    eprintln!(
        "acpmux-hot: swap seen by the running daemon after {} ms",
        swapped.elapsed().as_millis()
    );

    put(&first);
    let back = std::time::Instant::now();
    loop {
        match codex().await {
            Ok(code) => {
                assert_eq!(code, "ABCD-EFGHI");
                break;
            }
            Err(r) if r == "no_url" && back.elapsed() < deadline => {}
            got => panic!("the first module never came back: {got:?}"),
        }
    }
    eprintln!("acpmux-hot: swap back seen after {} ms", back.elapsed().as_millis());
    let _ = std::fs::remove_dir_all(&d);
}
