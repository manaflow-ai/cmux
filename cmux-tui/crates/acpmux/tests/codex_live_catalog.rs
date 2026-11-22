//! A Codex updated behind the same launcher (#38044): the picker listed GPT-6.1 Sol under
//! Legacy and GPT-5.6 Terra/Luna and GPT-5.5 as current, because the daemon kept the old
//! Codex's live model list (its cache key is the launcher, which an update leaves as it was).
//! The next Codex chat reports the new catalog, which probes the list again, and current
//! versus legacy follows the catalog's `upgrade` targets. Against tests/fake_codex_app_server.py,
//! whose catalog file stands in for the installed Codex.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

/// `model/list` rows as Codex answers them: `id` and `model` both name the model.
fn rows(models: Value) -> Value {
    let mut models = models;
    for row in models.as_array_mut().unwrap() {
        row["id"] = row["model"].clone();
    }
    models
}

/// The catalog an older Codex answers: no GPT-6 yet.
fn old_catalog() -> Value {
    rows(json!([
        {"model": "gpt-5.6-terra", "displayName": "GPT-5.6-Terra", "isDefault": true},
        {"model": "gpt-5.6-luna", "displayName": "GPT-5.6-Luna"},
        {"model": "gpt-5.5", "displayName": "GPT-5.5"},
    ]))
}

/// The catalog the updated Codex answers: GPT-6.1 Sol first, and each older model with the
/// `upgrade` Codex's own catalog gives it.
fn new_catalog() -> Value {
    rows(json!([
        {"model": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "isDefault": true, "upgrade": null},
        {"model": "gpt-6-sol", "displayName": "GPT-6-Sol", "upgrade": null},
        {"model": "gpt-6-luna", "displayName": "GPT-6-Luna", "upgrade": null},
        {"model": "gpt-5.6-terra", "displayName": "GPT-5.6-Terra", "upgrade": "gpt-6-sol"},
        {"model": "gpt-5.6-luna", "displayName": "GPT-5.6-Luna",
         "upgrade": null, "upgradeInfo": {"model": "gpt-6-luna"}},
        {"model": "gpt-5.5", "displayName": "GPT-5.5", "upgrade": "gpt-6-sol"},
    ]))
}

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("acl-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::create_dir_all(d.join("bin")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// The `codex` launcher: a script that runs the real program, as npm's `codex.js` or a
/// `cmux-codex` wrapper does. A Codex update leaves this file as it was.
fn launcher(d: &Path) -> PathBuf {
    let path = d.join("bin").join("codex");
    let script = daemon_env::sh_quote(FAKE_APP_SERVER);
    std::fs::write(&path, format!("#!/bin/sh\nexec python3 {script} \"$@\"\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    id: i64,
    notes: Vec<(String, Value)>,
}

impl Client {
    fn local(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::Local,
            ConnAuth::LocalSocket,
        ));
        Client { tx, rx, id: 0, notes: Vec::new() }
    }

    fn take(&mut self, line: &str) -> Option<Value> {
        match Message::parse(line).ok()? {
            Message::Notification { method, params } => {
                self.notes.push((method, params.unwrap_or(Value::Null)));
                None
            }
            _ => serde_json::from_str(line).ok(),
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.id += 1;
        let id = self.id;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.rx.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            if let Some(v) = self.take(&line)
                && v.get("id") == Some(&json!(id))
            {
                return v;
            }
        }
    }

    /// Waits for a `method` notification (one that came during a call counts).
    async fn note(&mut self, m: &str, wait: Duration) -> bool {
        let end = Instant::now() + wait;
        loop {
            if let Some(at) = self.notes.iter().position(|(got, _)| got == m) {
                self.notes.remove(at);
                return true;
            }
            let Some(left) = end.checked_duration_since(Instant::now()) else { return false };
            match tokio::time::timeout(left, self.rx.recv()).await {
                Ok(Some(line)) => {
                    self.take(&line);
                }
                _ => return false,
            }
        }
    }
}

fn codex_row(models: &Value) -> Value {
    models["result"]["harnesses"]
        .as_array()
        .unwrap_or_else(|| panic!("{models}"))
        .iter()
        .find(|h| h["harness"] == "codex")
        .cloned()
        .unwrap_or_else(|| panic!("no codex row: {models}"))
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect()
}

fn model_ids(row: &Value) -> Vec<String> {
    row["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| m["id"].as_str())
        .map(str::to_owned)
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_codex_updated_behind_its_launcher_refreshes_the_models_and_their_legacy_split() {
    let d = dir("update");
    let catalog = d.join("catalog.json");
    std::fs::write(&catalog, old_catalog().to_string()).unwrap();
    let codex = launcher(&d);
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"codex": {
            "argv": [codex, "app-server"],
            "env": {"FAKE_CODEX_CATALOG": catalog, "CODEX_PATH": codex},
        }},
        "defaultHarness": "codex",
        "permissionPolicy": "ask",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut c = Client::local(&hub);
    let watch = c.call(method::MUX_WATCH, json!({"enabled": true})).await;
    assert!(watch.get("error").is_none(), "{watch}");

    // The older Codex: its three models are current.
    let row = codex_row(&c.call("_acpmux/models", json!({"refresh": true})).await);
    assert_eq!(strings(&row["topModels"]), ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]);
    // The first list's announcement came during the refresh.
    c.notes.clear();
    // A chat on the same Codex reports nothing the list lacks: no second probe.
    let params =
        json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "codex"}}});
    let same = c.call("session/new", params).await;
    assert!(same["result"]["sessionId"].is_string(), "{same}");
    assert!(
        !c.note(method::MUX_HARNESSES_CHANGED, Duration::from_secs(2)).await,
        "a chat on an unchanged Codex probed its list again"
    );

    // Codex is updated in place: the launcher (path, size, modification time) is unchanged.
    std::fs::write(&catalog, new_catalog().to_string()).unwrap();
    // The daemon still holds the old Codex's list: this is the stale state of #38044.
    let row = codex_row(&c.call("_acpmux/models", json!({})).await);
    assert_eq!(strings(&row["topModels"]), ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]);

    // A Codex chat starts on the updated Codex and reports its catalog: the live list is
    // probed again and watchers hear that the models changed.
    let params =
        json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "codex"}}});
    let started = c.call("session/new", params).await;
    assert!(started["result"]["sessionId"].is_string(), "{started}");
    assert!(
        c.note(method::MUX_HARNESSES_CHANGED, Duration::from_secs(20)).await,
        "the stale Codex list was never probed again after a chat reported the new catalog"
    );

    // Current and legacy follow the live catalog: a model with an `upgrade` target is legacy.
    let row = codex_row(&c.call("_acpmux/models", json!({})).await);
    assert_eq!(strings(&row["topModels"]), ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"]);
    let ids = model_ids(&row);
    for legacy in ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"] {
        assert!(ids.iter().any(|id| id == legacy), "{legacy} stays listed (as legacy): {ids:?}");
    }

    // Choosing GPT-6.1 Sol starts a chat on it, and its turn completes.
    let params = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "codex", "model": "gpt-6.1-sol"}}});
    let chat = c.call("session/new", params).await;
    let s = chat["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{chat}")).to_owned();
    let options = chat["result"]["configOptions"].as_array().cloned().unwrap_or_default();
    let model = options.iter().find(|o| o["id"] == "model" || o["category"] == "model");
    if let Some(model) = model {
        assert_eq!(model["currentValue"], "gpt-6.1-sol", "{model}");
    }
    let r = c
        .call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}))
        .await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}
