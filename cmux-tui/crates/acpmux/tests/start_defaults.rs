//! A new chat starts on the catalog's default model and effort (Codex:
//! GPT-6.1 Sol, Claude Code: Opus 5.5, both medium), never on the harness
//! CLI's own default; the person's pick in a chat is saved in config.json
//! `defaults` and a new chat after a daemon restart starts on it (cx-qtmy2,
//! cx-fusxy). Driven through the protocol handler as the local app.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

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
    let dir =
        std::env::temp_dir().join(format!("acpmux-start-defaults-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let calls = dir.join("calls.jsonl");
    let profile = |extra: &Value| {
        let mut env = json!({"FAKE_PICKER": "1", "FAKE_CALLS": calls.to_str().unwrap()});
        for (k, v) in extra.as_object().unwrap() {
            env[k] = v.clone();
        }
        json!({"argv": ["python3", FAKE], "env": env})
    };
    let config = json!({
        "harnesses": {"codex": profile(&json!({})), "claude": profile(&claude_env)},
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

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

/// The app's agent pane.
fn client(hub: &Arc<Hub>) -> Client {
    client_as(hub, Origin::LocalApp)
}

fn client_as(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
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
        }
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
