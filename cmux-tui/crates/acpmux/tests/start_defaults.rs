//! A new chat starts on the catalog's default model and effort (Codex:
//! GPT-6.1 Sol, Claude Code: Opus 5.5, both medium), never on the harness
//! CLI's own default; the person's pick in a chat is saved in config.json
//! `defaults` and a new chat after a daemon restart starts on it (cx-qtmy2,
//! cx-fusxy). With nothing picked, the harness's own config (Codex's
//! config.toml `model` and `model_reasoning_effort`, Claude Code's
//! settings.json `model`) comes before the catalog (cx-uq9xi). Driven through
//! the protocol handler as the local app.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A home whose config.json has a fake `codex` and a fake `claude`, both
/// logging their model and effort sets to `calls`.
fn home(name: &str) -> (PathBuf, PathBuf) {
    home_with(name, json!({}), json!({}))
}

/// `home` with extra fake env for `claude` and a config.json `defaults` object.
fn home_with(name: &str, claude_env: Value, defaults: Value) -> (PathBuf, PathBuf) {
    home_env(name, json!({}), claude_env, defaults)
}

/// `home_with`, with extra fake env for `codex` too.
fn home_env(
    name: &str,
    codex_env: Value,
    claude_env: Value,
    defaults: Value,
) -> (PathBuf, PathBuf) {
    let dir =
        std::env::temp_dir().join(format!("acpmux-start-defaults-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let calls = dir.join("calls.jsonl");
    // Each fake reads its own config folder, empty unless a test writes one, never the
    // machine's ~/.codex or ~/.claude.
    let homes =
        json!({"CODEX_HOME": dir.join("codex-home"), "CLAUDE_CONFIG_DIR": dir.join("claude-home")});
    let profile = |extra: &Value| {
        let mut env = json!({"FAKE_PICKER": "1", "FAKE_CALLS": calls.to_str().unwrap()});
        for (k, v) in homes.as_object().unwrap() {
            env[k] = v.clone();
        }
        for (k, v) in extra.as_object().unwrap() {
            env[k] = v.clone();
        }
        json!({"argv": ["python3", FAKE], "env": env})
    };
    let config = json!({
        "harnesses": {"codex": profile(&codex_env), "claude": profile(&claude_env)},
        "defaultHarness": "codex",
        "permissionPolicy": "approve-all",
        "defaults": defaults,
    });
    std::fs::write(dir.join("config.json"), serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    (dir, calls)
}

/// The daemon as it starts: config.json read from disk.
fn hub(dir: &Path) -> Arc<Hub> {
    let mut cfg =
        Config::load_from_with(&dir.join("config.json"), &ProfileSources::none()).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The connection, its replies, the last request id, and the notifications it received.
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, Vec<Value>);

/// The app's agent pane.
fn client(hub: &Arc<Hub>) -> Client {
    client_as(hub, Origin::LocalApp)
}

fn client_as(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0, Vec::new())
}

impl Client {
    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m} {v}");
                return v["result"].clone();
            }
            if v.get("id").is_none() {
                self.3.push(v);
            }
        }
    }

    /// Whether a `_acpmux/harnesses_changed` came, after one more round trip
    /// (a notification sent before it has arrived by then).
    async fn told_harnesses_changed(&mut self) -> bool {
        self.call("_acpmux/status", json!({})).await;
        let told = self.3.iter().any(|n| n["method"] == "_acpmux/harnesses_changed");
        self.3.clear();
        told
    }

    async fn new_chat(&mut self, harness: &str) -> String {
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        self.call("session/new", params).await["sessionId"].as_str().unwrap().to_owned()
    }
}

/// The model and effort sets the fake harnesses received, in order, then cleared.
fn take_calls(calls: &Path) -> Vec<(String, String)> {
    let text = std::fs::read_to_string(calls).unwrap_or_default();
    let _ = std::fs::remove_file(calls);
    text.lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .map(|v| match v["method"].as_str().unwrap() {
            "session/set_model" => {
                ("model".to_owned(), v["params"]["modelId"].as_str().unwrap().to_owned())
            }
            _ => (
                v["params"]["configId"].as_str().unwrap().to_owned(),
                v["params"]["value"].as_str().unwrap().to_owned(),
            ),
        })
        .collect()
}

fn set(model: &str, effort: &str) -> Vec<(String, String)> {
    vec![("model".into(), model.into()), ("effort".into(), effort.into())]
}

fn saved(dir: &Path, harness: &str) -> Value {
    let config: Value =
        serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    config["defaults"][harness].clone()
}

#[tokio::test]
async fn a_new_chat_starts_on_the_catalog_default_then_on_the_persons_pick_after_a_restart() {
    let (dir, calls) = home("pick");
    let daemon = hub(&dir);
    let mut app = client(&daemon);

    // Nothing picked yet: the catalog's defaults, set by acpmux on the new chat.
    let codex = app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-6.1-sol", "medium"));
    app.new_chat("claude").await;
    assert_eq!(take_calls(&calls), set("claude-opus-5-5", "medium"));
    let harnesses = app.call("_acpmux/harnesses", json!({})).await;
    assert_eq!(
        harnesses["harnesses"]["codex"]["start"],
        json!({"model": "gpt-6.1-sol", "modelSource": "catalog", "effort": "medium", "effortSource": "catalog"})
    );

    // The chip naming the model the chat already runs is no pick and is not sent again.
    app.call("session/set_model", json!({"sessionId": codex, "modelId": "gpt-6.1-sol"})).await;
    assert_eq!(take_calls(&calls), vec![]);
    assert_eq!(saved(&dir, "codex"), Value::Null);

    // The person picks another model and effort: both are saved for the next new chat.
    app.call("session/set_model", json!({"sessionId": codex, "modelId": "gpt-6-astra"})).await;
    app.call(
        "session/set_config_option",
        json!({"sessionId": codex, "configId": "effort", "value": "high"}),
    )
    .await;
    assert_eq!(take_calls(&calls), set("gpt-6-astra", "high"));
    assert_eq!(saved(&dir, "codex"), json!({"model": "gpt-6-astra", "effort": "high"}));
    drop(app);
    drop(daemon);

    // After a restart (config.json read again), a new Codex chat starts on the pick;
    // Claude Code, never picked, still starts on its catalog default.
    let daemon = hub(&dir);
    let mut app = client(&daemon);
    app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-6-astra", "high"));
    app.new_chat("claude").await;
    assert_eq!(take_calls(&calls), set("claude-opus-5-5", "medium"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// Leo 2026-10-18: a New Tab prewarmed before a pick drew the old start effort (Medium) and the chat
/// then started on the pick (Low). A saved pick changes `_acpmux/harnesses` `start`, so watchers
/// are told to read it again; a pick that saves nothing new tells nobody.
#[tokio::test]
async fn a_saved_pick_is_announced_to_watchers_so_open_pages_read_the_new_start() {
    let (dir, calls) = home("pick-notice");
    let daemon = hub(&dir);
    let mut app = client(&daemon);
    app.call("_acpmux/watch", json!({"enabled": true})).await;
    let claude = app.new_chat("claude").await;
    take_calls(&calls);
    app.3.clear();

    app.call("session/set_model", json!({"sessionId": claude, "modelId": "claude-haiku-5-5"}))
        .await;
    assert!(app.told_harnesses_changed().await, "a saved model pick is announced");
    app.call(
        "session/set_config_option",
        json!({"sessionId": claude, "configId": "effort", "value": "low"}),
    )
    .await;
    assert!(app.told_harnesses_changed().await, "a saved effort pick is announced");
    let start = &app.call("_acpmux/harnesses", json!({})).await["harnesses"]["claude"]["start"];
    assert_eq!((&start["model"], &start["effort"]), (&json!("claude-haiku-5-5"), &json!("low")));

    // The same effort again saves nothing new: no notice.
    app.call(
        "session/set_config_option",
        json!({"sessionId": claude, "configId": "effort", "value": "low"}),
    )
    .await;
    assert!(!app.told_harnesses_changed().await, "an unchanged pick is not announced");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_model_named_in_the_request_wins_and_its_effort_follows_the_catalog() {
    let (dir, calls) = home("explicit");
    let daemon = hub(&dir);
    let mut app = client(&daemon);
    let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "codex", "model": "gpt-6-luna"}}});
    app.call("session/new", params).await;
    assert_eq!(take_calls(&calls), set("gpt-6-luna", "medium"));
    // A model the request names is not the person's saved pick.
    assert_eq!(saved(&dir, "codex"), Value::Null);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_refused_start_model_is_skipped_and_a_saved_effort_the_model_lacks_gives_way() {
    // Claude refuses the catalog default (a model the account cannot run); Codex has a saved
    // default whose effort (max) its saved model (gpt-5.5) does not offer.
    let (dir, calls) = home_with(
        "refused",
        json!({"FAKE_REFUSE_ID": "claude-opus-5-5"}),
        json!({"codex": {"model": "gpt-5.5", "effort": "max"}}),
    );
    let daemon = hub(&dir);
    let mut app = client(&daemon);
    // The chat still starts (on the harness's own model), with the effort set.
    app.new_chat("claude").await;
    assert_eq!(take_calls(&calls), set("claude-opus-5-5", "medium"));
    app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-5.5", "medium"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_model_set_from_the_cli_is_no_saved_pick() {
    let (dir, calls) = home("cli");
    let daemon = hub(&dir);
    let mut cli = client_as(&daemon, Origin::Local);
    let codex = cli.new_chat("codex").await;
    take_calls(&calls);
    cli.call("session/set_model", json!({"sessionId": codex, "modelId": "gpt-6-astra"})).await;
    assert_eq!(take_calls(&calls), vec![("model".to_owned(), "gpt-6-astra".to_owned())]);
    assert_eq!(saved(&dir, "codex"), Value::Null);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A home whose fake `codex` reads `codex_toml` as its `$CODEX_HOME/config.toml` and whose fake
/// `claude` reads `claude_settings` as its `$CLAUDE_CONFIG_DIR/settings.json` (None: no file).
fn home_with_harness_config(
    name: &str,
    codex_toml: Option<&str>,
    claude_settings: Option<&str>,
) -> (PathBuf, PathBuf) {
    let (dir, calls) = home(name);
    let (codex_home, claude_home) = (dir.join("codex-home"), dir.join("claude-home"));
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::create_dir_all(&claude_home).unwrap();
    if let Some(t) = codex_toml {
        std::fs::write(codex_home.join("config.toml"), t).unwrap();
    }
    if let Some(t) = claude_settings {
        std::fs::write(claude_home.join("settings.json"), t).unwrap();
    }
    (dir, calls)
}

#[tokio::test]
async fn with_nothing_picked_a_new_chat_starts_on_the_harness_own_config_then_on_the_pick() {
    let (dir, calls) = home_with_harness_config(
        "harness-config",
        Some("model = \"gpt-6-astra\"\nmodel_reasoning_effort = \"high\"\n"),
        Some(r#"{"model": "sonnet", "permissions": {"allow": []}}"#),
    );
    let daemon = hub(&dir);
    let mut app = client(&daemon);

    // Codex: its config.toml's model and effort. Claude Code: its settings.json model (the
    // `sonnet` alias, as the catalog names it), with that model's catalog effort.
    let codex = app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-6-astra", "high"));
    app.new_chat("claude").await;
    assert_eq!(take_calls(&calls), set("claude-sonnet-5-5", "medium"));
    let harnesses = app.call("_acpmux/harnesses", json!({})).await;
    assert_eq!(
        harnesses["harnesses"]["codex"]["start"],
        json!({"model": "gpt-6-astra", "modelSource": "harness", "effort": "high", "effortSource": "harness"})
    );
    assert_eq!(
        harnesses["harnesses"]["claude"]["start"],
        json!({"model": "claude-sonnet-5-5", "modelSource": "harness", "effort": "medium", "effortSource": "catalog"})
    );

    // The person's pick beats the harness's config for the next new chat.
    app.call("session/set_model", json!({"sessionId": codex, "modelId": "gpt-6-luna"})).await;
    take_calls(&calls);
    app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-6-luna", "high"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_broken_or_unknown_harness_config_falls_back_to_the_catalog() {
    // Codex's config.toml does not parse; Claude Code names a model the catalog does not list
    // (a retired one).
    let (dir, calls) = home_with_harness_config(
        "harness-config-broken",
        Some("model = \"gpt-6-astra\n[[broken"),
        Some(r#"{"model": "claude-retired-1"}"#),
    );
    let daemon = hub(&dir);
    let mut app = client(&daemon);
    app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-6.1-sol", "medium"));
    app.new_chat("claude").await;
    assert_eq!(take_calls(&calls), set("claude-opus-5-5", "medium"));
    let harnesses = app.call("_acpmux/harnesses", json!({})).await;
    // A config.toml that does not parse names no model: the catalog default.
    assert_eq!(harnesses["harnesses"]["codex"]["start"]["modelSource"], "catalog");
    assert_eq!(harnesses["harnesses"]["claude"]["start"]["modelSource"], "catalog");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_claude_model_with_a_context_suffix_starts_on_its_catalog_model() {
    // Claude Code's settings.json names the 1M-context variant (`sonnet[1m]`): the catalog lists
    // the model without the suffix.
    let (dir, calls) =
        home_with_harness_config("harness-config-1m", None, Some(r#"{"model": "sonnet[1m]"}"#));
    let daemon = hub(&dir);
    let mut app = client(&daemon);
    app.new_chat("claude").await;
    assert_eq!(take_calls(&calls), set("claude-sonnet-5-5", "medium"));
    let harnesses = app.call("_acpmux/harnesses", json!({})).await;
    assert_eq!(harnesses["harnesses"]["claude"]["start"]["modelSource"], "harness");

    // A full model id with the suffix names its model too.
    std::fs::write(
        dir.join("claude-home").join("settings.json"),
        r#"{"model": "claude-haiku-5-5[1m]"}"#,
    )
    .unwrap();
    app.new_chat("claude").await;
    assert_eq!(take_calls(&calls), set("claude-haiku-5-5", "medium"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn codex_runs_the_model_its_config_names_even_one_the_catalog_does_not_list() {
    // Codex's config.toml names a model the catalog snapshot does not list (a provider's own
    // model, or one newer than the snapshot): the chat runs that model with the config's
    // effort, as raw `codex` does, never the catalog default (user 2026-10-20: acpmux ran
    // gpt-6.1-sol where the config named another model).
    let (dir, calls) = home_with_harness_config(
        "harness-config-effort",
        Some("model = \"gpt-unlisted-1\"\nmodel_reasoning_effort = \"high\"\n"),
        None,
    );
    let daemon = hub(&dir);
    let mut app = client(&daemon);
    app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-unlisted-1", "high"));
    let harnesses = app.call("_acpmux/harnesses", json!({})).await;
    assert_eq!(
        harnesses["harnesses"]["codex"]["start"],
        json!({"model": "gpt-unlisted-1", "modelSource": "harness", "effort": "high", "effortSource": "harness"})
    );

    // An effort with no model is Codex's effort for whatever model runs.
    std::fs::write(
        dir.join("codex-home").join("config.toml"),
        "model_reasoning_effort = \"high\"\n",
    )
    .unwrap();
    app.new_chat("codex").await;
    assert_eq!(take_calls(&calls), set("gpt-6.1-sol", "high"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// cnx-ios full verify D4 (2026-10-19): an account whose Codex does not offer
/// the catalog default (GPT-6.1 Sol) failed every prompt of a new chat. The
/// catalog default applies only when the harness lists it; otherwise the chat
/// starts on the harness's own default (its config's model).
#[tokio::test]
async fn a_catalog_default_the_harness_does_not_offer_is_not_used() {
    let (dir, calls) = home("not-offered");
    let mut config: Value =
        serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    config["harnesses"]["codex"]["env"]["FAKE_MODELS"] = json!("gpt-5.5,gpt-6-astra");
    // Claude Code lists aliases, not the catalog's ids: the catalog default still applies.
    config["harnesses"]["claude"]["env"]["FAKE_MODELS"] = json!("default,opus");
    std::fs::write(dir.join("config.json"), serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    let daemon = hub(&dir);
    let mut app = client(&daemon);

    // The first chat learns the list; it never sets the model the account lacks.
    app.new_chat("codex").await;
    assert!(!take_calls(&calls).iter().any(|(k, v)| k == "model" && v == "gpt-6.1-sol"));
    // Now the list is known: New Agent Chat says no start model, and none is set.
    let harnesses = app.call("_acpmux/harnesses", json!({})).await;
    assert!(
        harnesses["harnesses"]["codex"]["start"]["model"].is_null(),
        "{}",
        harnesses["harnesses"]["codex"]["start"]
    );
    app.new_chat("codex").await;
    assert!(!take_calls(&calls).iter().any(|(k, _)| k == "model"));
    // A harness whose ids are not the catalog's (Claude Code's aliases) still starts on the catalog default.
    app.new_chat("claude").await;
    app.new_chat("claude").await;
    assert_eq!(
        take_calls(&calls).first(),
        Some(&("model".to_owned(), "claude-opus-5-5".to_owned()))
    );
    let _ = std::fs::remove_dir_all(&dir);
}
