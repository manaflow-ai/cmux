//! A second account of a subscription CLI (Leo, 2026-10-19: "two Claude, two
//! ChatGPT"): a direct-subscription route names an account home, the CLI's
//! own config folder for one login. Over the daemon socket: a chat on the
//! route runs its harness with `CLAUDE_CONFIG_DIR` (Codex: `CODEX_HOME`) set
//! to it; a new chat keeps the home it started in as its store, so a chat
//! that has started never moves to another account's folder: not when the
//! default changes, not in a fork, not by a switch.
//!
//! The RPC test is the only one that touches the environment (ACPMUX_HOME is
//! process-wide); the others are pure.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::route_account;
use acpmux::routes::{self, Route};
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::store::SessionMeta;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

fn route(params: Value) -> Result<Route, String> {
    routes::file_from_json(&params)
        .map(|file| Route { id: "r".into(), file, path: PathBuf::new() })
        .map_err(|e| e.to_string())
}

#[test]
fn an_account_route_points_its_cli_at_the_account_home() {
    let claude = route(json!({"kind": "direct-subscription", "families": ["claude"],
                              "accountHome": "/Users/x/.cmux/accounts/claude-work"}))
    .unwrap();
    let env = routes::env_for(&claude, "claude", Path::new("/nonexistent")).unwrap();
    assert_eq!(
        env.set.get("CLAUDE_CONFIG_DIR").map(String::as_str),
        Some("/Users/x/.cmux/accounts/claude-work")
    );
    assert!(!env.set.contains_key("ANTHROPIC_BASE_URL"), "the CLI's own login: {env:?}");
    assert_eq!(claude.view()["accountHome"], "/Users/x/.cmux/accounts/claude-work");

    let codex = route(json!({"kind": "direct-subscription", "families": ["codex"],
                             "accountHome": "/Users/x/.cmux/accounts/codex-2"}))
    .unwrap();
    let env = routes::env_for(&codex, "codex", Path::new("/nonexistent")).unwrap();
    assert_eq!(
        env.set.get("CODEX_HOME").map(String::as_str),
        Some("/Users/x/.cmux/accounts/codex-2")
    );
    assert!(!env.set.contains_key("CLAUDE_CONFIG_DIR"));

    // A route without one leaves the spawn's own folder alone.
    let plain = route(json!({"kind": "direct-subscription"})).unwrap();
    let env = routes::env_for(&plain, "claude", Path::new("/nonexistent")).unwrap();
    assert!(
        !env.set.contains_key("CLAUDE_CONFIG_DIR")
            && !env.unset.iter().any(|k| k == "CLAUDE_CONFIG_DIR")
    );
}

#[test]
fn an_account_home_is_one_clis_absolute_folder_on_a_subscription_route() {
    let bad = |params: Value| route(params).expect_err("accepted");
    assert!(bad(json!({"kind": "custom-anthropic", "anthropicBaseUrl": "http://x", "families": ["claude"],
                       "accountHome": "/a"}))
    .contains("direct-subscription"));
    assert!(
        bad(json!({"kind": "direct-subscription", "accountHome": "/a"})).contains("one family")
    );
    assert!(bad(json!({"kind": "direct-subscription", "families": ["claude", "codex"], "accountHome": "/a"}))
        .contains("one family"));
    assert!(
        bad(json!({"kind": "direct-subscription", "families": ["gemini"], "accountHome": "/a"}))
            .contains("one family")
    );
    assert!(
        bad(json!({"kind": "direct-subscription", "families": ["claude"], "accountHome": "work"}))
            .contains("absolute")
    );
    assert!(
        bad(json!({"kind": "direct-subscription", "families": ["claude"],
                       "accountHome": "/a/${HOME}"}))
        .contains("absolute")
    );
    // An empty or non-string home is refused, never the default login.
    let own = dirs::home_dir().unwrap().join(".claude");
    let params = json!({"kind": "direct-subscription", "families": ["claude"], "accountHome": own});
    assert!(bad(params).contains("own folder"));
    for empty in [json!(""), json!(7)] {
        let params = json!({"kind": "direct-subscription", "families": ["claude"],
                            "accountHome": empty});
        assert!(bad(params).contains("absolute"));
    }
    let none = json!({"kind": "direct-subscription", "families": ["claude"], "accountHome": null});
    assert_eq!(route(none).unwrap().file.account_home, None);
}

#[test]
fn a_started_chat_stays_in_the_account_it_started_in() {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": "acpmux.session.v1", "id": "s", "name": "s", "harness": "fake",
        "family": "claude", "cwd": "/tmp", "status": "ready", "createdAt": 0, "updatedAt": 0,
    }))
    .unwrap();
    // A new chat has no home yet; a failed start records none.
    assert!(!route_account::has_home(&meta));
    assert!(!route_account::record(&mut meta, Some(Path::new("/a"))));
    // Once it started, the account home it started in is its store.
    meta.agent_session_id = Some("conversation".into());
    assert!(route_account::has_home(&meta));
    assert!(route_account::record(&mut meta, Some(Path::new("/a"))));
    assert_eq!(meta.chat_store.as_deref(), Some(Path::new("/a")));
    assert!(!route_account::record(&mut meta, Some(Path::new("/b"))), "never moves");
    let none = std::collections::BTreeMap::new();
    let home = route_account::current_home(&meta, "claude", &none);
    assert_eq!(home.as_deref(), Some(Path::new("/a")));
    // A profile's `~/work` is the folder it expands to at spawn.
    let mut fresh = meta.clone();
    fresh.chat_store = None;
    let profile =
        std::collections::BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), "~/work".to_owned())]);
    let expanded = dirs::home_dir().unwrap().join("work");
    let home = route_account::current_home(&fresh, "claude", &profile);
    assert_eq!(home.as_deref(), Some(expanded.as_path()));

    // A route's home does not move a chat that has one; its folder stays.
    let mut env =
        std::collections::BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), "/b".to_owned())]);
    route_account::keep_home("claude", Some("/a".into()), &mut env);
    assert_eq!(env["CLAUDE_CONFIG_DIR"], "/a");
    route_account::keep_home("claude", None, &mut env);
    assert!(!env.contains_key("CLAUDE_CONFIG_DIR"), "the CLI's default folder");

    // A switch to another account's route is refused; a route without one,
    // or the same folder written another way, is not.
    let account = |home: &str| {
        route(json!({"kind": "direct-subscription", "families": ["claude"], "accountHome": home}))
            .unwrap()
    };
    let plain = route(json!({"kind": "direct-subscription"})).unwrap();
    assert!(route_account::switch_allowed(Some(Path::new("/a")), &account("/a/")).is_ok());
    assert!(route_account::switch_allowed(Some(Path::new("/a")), &plain).is_ok());
    assert!(route_account::switch_allowed(None, &plain).is_ok());
    assert!(route_account::switch_allowed(Some(Path::new("/a")), &account("/b")).is_err());
    assert!(route_account::switch_allowed(None, &account("/b")).is_err());
}

#[test]
fn adding_an_account_route_makes_its_folder_owner_only() {
    let root = scratch("account-home-add");
    let home = root.join("accounts").join("codex-2");
    let file =
        routes::file_from_json(&json!({"kind": "direct-subscription", "families": ["codex"],
                                               "accountHome": home}))
        .unwrap();
    routes::add(Some(&root.join("routes")), "codex-2", &file, false).unwrap();
    assert!(home.is_dir());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&home).unwrap().permissions().mode() & 0o777, 0o700);
    }
    let text = std::fs::read_to_string(root.join("routes").join("codex-2.toml")).unwrap();
    assert!(text.contains("account_home"), "{text}");
    // A refused add (the id is taken) makes no folder.
    let other = root.join("accounts").join("codex-3");
    let file =
        routes::file_from_json(&json!({"kind": "direct-subscription", "families": ["codex"],
                                               "accountHome": other}))
        .unwrap();
    assert!(routes::add(Some(&root.join("routes")), "codex-2", &file, false).is_err());
    assert!(!other.exists());
    let _ = std::fs::remove_dir_all(&root);
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no reply in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    async fn err(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        reply.get("error").cloned().unwrap_or_else(|| panic!("{m} did not fail: {reply}"))
    }

    async fn env_of(&mut self, session: &str, name: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]});
        let (reply, mut text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        // The reply can overtake the turn's last streamed update.
        while !text.contains(&format!("{name}=")) {
            let line = tokio::time::timeout(Duration::from_secs(10), self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no env text: reply {reply}, text {text:?}"))
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
        let at = text.rfind(&format!("{name}=")).unwrap_or(0);
        text[at..].to_owned()
    }

    async fn new_chat(&mut self) -> String {
        let new =
            self.ok("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
        new["sessionId"].as_str().unwrap().to_owned()
    }
}

fn hub(root: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "family": "claude"},
            "pinned": {"argv": ["python3", FAKE], "family": "claude",
                       "env": {"CLAUDE_CONFIG_DIR": "/tmp/acpmux-pinned-home"}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_on_a_second_claude_account_keeps_that_account() {
    let root = scratch("account-home-rpc");
    // SAFETY: the only test in this binary that reads or writes the env.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::remove_var("CLAUDE_CONFIG_DIR");
    }
    let hub = hub(&root);
    let mut local = client(&hub, Origin::Local);
    let work = root.join("accounts").join("claude-work");
    let added = local
        .ok(
            "_acpmux/route/add",
            json!({"id": "claude-work", "name": "Claude (work)", "kind": "direct-subscription",
                   "families": ["claude"], "accountHome": work}),
        )
        .await;
    assert_eq!(added["accountHome"], json!(work), "{added}");
    assert!(work.is_dir(), "the folder exists before the CLI's login runs");

    // A chat that started before the default changed stays on its login.
    let before = local.new_chat().await;
    assert_eq!(local.env_of(&before, "CLAUDE_CONFIG_DIR").await, "CLAUDE_CONFIG_DIR=");

    // The family default reaches a new chat, which keeps that account.
    local
        .ok(
            "_acpmux/route/default.set",
            json!({"scope": "family:claude", "routeId": "claude-work"}),
        )
        .await;
    // A profile that pins its own home keeps it under a family default.
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"harness": "pinned"}}});
    let pinned = local.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&pinned, "CLAUDE_CONFIG_DIR").await,
        "CLAUDE_CONFIG_DIR=/tmp/acpmux-pinned-home"
    );
    let chat = local.new_chat().await;
    assert_eq!(
        local.env_of(&chat, "CLAUDE_CONFIG_DIR").await,
        format!("CLAUDE_CONFIG_DIR={}", work.display())
    );
    // So does its fork, which resumes the conversation from that folder.
    let fork = local.ok("session/fork", json!({"sessionId": chat, "mcpServers": []})).await;
    let fork = fork["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&fork, "CLAUDE_CONFIG_DIR").await,
        format!("CLAUDE_CONFIG_DIR={}", work.display())
    );

    // Restarting both: the earlier chat does not move into the account.
    let ids = json!({"sessions": [before, chat]});
    local.ok("_acpmux/sessions/restart_harness", ids).await;
    assert_eq!(local.env_of(&before, "CLAUDE_CONFIG_DIR").await, "CLAUDE_CONFIG_DIR=");

    // Clearing the default leaves the chat on its account.
    local.ok("_acpmux/route/default.set", json!({"scope": "family:claude"})).await;
    local.ok("_acpmux/sessions/restart_harness", json!({"sessions": [chat]})).await;
    assert_eq!(
        local.env_of(&chat, "CLAUDE_CONFIG_DIR").await,
        format!("CLAUDE_CONFIG_DIR={}", work.display())
    );

    // A route without an account home keeps the chat's folder; another
    // account's route is refused.
    local
        .ok(
            "_acpmux/route/add",
            json!({"id": "claude-own", "kind": "direct-subscription", "families": ["claude"]}),
        )
        .await;
    local.ok("_acpmux/chat/route.set", json!({"sessionId": chat, "routeId": "claude-own"})).await;
    let refused = local
        .err("_acpmux/chat/route.set", json!({"sessionId": before, "routeId": "claude-work"}))
        .await;
    assert!(refused["message"].as_str().unwrap_or("").contains("another account"), "{refused}");
    assert_eq!(
        local.env_of(&chat, "CLAUDE_CONFIG_DIR").await,
        format!("CLAUDE_CONFIG_DIR={}", work.display())
    );

    let _ = std::fs::remove_dir_all(&root);
}
