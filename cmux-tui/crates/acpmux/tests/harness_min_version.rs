//! An agent CLI older than acpmux supports (cmux#42212): an old Claude Code lists the
//! models of its own release, so the picker, which offers the curated models the CLI
//! lists, had no Opus 5.5. Its health row now names the minimum and says `unsupported`;
//! one `_acpmux/harness/update` updates it, even with no newest-version lookup, and the
//! models are listed again at once (before, the old list stayed until it aged out).
//!
//! The stand-in CLI answers as the measured releases do: Claude Code 2.1.278's
//! `list_models` (`opus[1m]` for Opus 5, Sonnet 5, Haiku 4.5) and 2.1.300's (Opus,
//! Sonnet and Haiku 5.5). It is laid out as Claude's native installer, whose
//! `claude update` is the update plan.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs a stand-in Claude Code (a Python script).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::harness_health::Settings;
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// Claude Code as installed: `--version`, `update` (to 2.1.300) and the stream-json
/// `initialize` / `list_models` control requests, by the version in `installed`.
const STAND_IN: &str = r#"#!/usr/bin/env python3
import json, pathlib, sys
state = pathlib.Path(__file__).resolve().with_name("installed")
version = state.read_text().strip()
args = sys.argv[1:]
if args[:1] == ["--version"]:
    print(f"{version} (Claude Code)")
    sys.exit(0)
if args[:1] == ["update"]:
    state.write_text("2.1.300")
    print("Successfully updated")
    sys.exit(0)
if version == "2.1.278":
    models = [
        {"value": "default", "resolvedModel": "claude-opus-5[1m]"},
        {"value": "opus[1m]", "resolvedModel": "claude-opus-5[1m]", "displayName": "Opus (1M context)"},
        {"value": "claude-fable-5-1", "resolvedModel": "claude-fable-5-1", "displayName": "Fable 5.1"},
        {"value": "sonnet", "resolvedModel": "claude-sonnet-5", "displayName": "Sonnet"},
        {"value": "haiku", "resolvedModel": "claude-haiku-4-5-20251001", "displayName": "Haiku"},
    ]
else:
    models = [
        {"value": "default", "resolvedModel": "claude-opus-5-5"},
        {"value": "opus", "resolvedModel": "claude-opus-5-5", "displayName": "Opus"},
        {"value": "fable", "resolvedModel": "claude-fable-5-1", "displayName": "Fable"},
        {"value": "sonnet", "resolvedModel": "claude-sonnet-5-5", "displayName": "Sonnet"},
        {"value": "haiku", "resolvedModel": "claude-haiku-5-5", "displayName": "Haiku"},
    ]
for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("type") != "control_request":
        continue
    reply = {"subtype": "success", "request_id": message["request_id"], "response": {"models": models}}
    sys.stdout.write(json.dumps({"type": "control_response", "response": reply}) + "\n")
    sys.stdout.flush()
"#;

fn scratch(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("acpmux-min-version-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("home")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// Claude's native installer layout: `~/.local/bin/claude` -> `versions/current`.
fn install_claude(home: &Path, version: &str) -> PathBuf {
    let versions = home.join(".local/share/claude/versions");
    std::fs::create_dir_all(&versions).unwrap();
    let real = versions.join("current");
    std::fs::write(&real, STAND_IN).unwrap();
    std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(versions.join("installed"), version).unwrap();
    let link = home.join(".local/bin/claude");
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    symlink(&real, &link).unwrap();
    link
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    id: i64,
    notes: Vec<String>,
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
            Message::Notification { method, .. } => {
                self.notes.push(method);
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
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            if let Some(v) = self.take(&line)
                && v.get("id") == Some(&json!(id))
            {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }

    /// Waits for a `method` notification (one that came during a call counts).
    async fn note(&mut self, m: &str, wait: Duration) -> bool {
        let end = Instant::now() + wait;
        loop {
            if let Some(at) = self.notes.iter().position(|got| got == m) {
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

fn claude_models(models: &Value) -> Vec<String> {
    models["harnesses"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|h| h["harness"] == "claude")
        .unwrap_or_else(|| panic!("no claude row: {models}"))["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| m["id"].as_str().map(str::to_owned))
        .collect()
}

fn health_row(reply: &Value) -> Value {
    reply["harnesses"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| r["id"] == "claude")
        .cloned()
        .unwrap_or_else(|| panic!("no claude health row: {reply}"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unsupported_claude_code_is_flagged_and_one_update_brings_its_models() {
    let root = scratch("claude");
    let home = root.join("home");
    let claude = install_claude(&home, "2.1.278");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"argv": [claude], "kind": "claude-stdio"}},
        "defaultHarness": "claude",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    // No newest-version lookup: being below the minimum alone makes the update due.
    hub.health.attach(Settings { sources: None, home: home.clone(), ..Settings::default() });
    let mut c = Client::local(&hub);
    c.call(method::MUX_WATCH, json!({"enabled": true})).await;

    // The old CLI's own list has no Opus 5.5, so the picker has none.
    let before = claude_models(&c.call("_acpmux/models", json!({"refresh": true})).await);
    assert!(!before.iter().any(|id| id == "claude-opus-5-5"), "{before:?}");

    let row = health_row(&c.call(method::MUX_HARNESS_HEALTH, json!({"refresh": true})).await);
    assert_eq!(row["version"], "2.1.278", "{row}");
    assert_eq!(row["minimum"], "2.1.293", "{row}");
    assert_eq!(row["unsupported"], true, "{row}");
    assert_eq!(row["outdated"], false, "no newer release is known: {row}");
    c.notes.clear();

    // One update: the CLI's own updater runs, and the answer is the new version.
    let reply = c.call(method::MUX_HARNESS_UPDATE, json!({"ids": ["claude"]})).await;
    assert_eq!(reply["results"], json!([{"id": "claude", "ok": true, "version": "2.1.300"}]));
    let row = health_row(&c.call(method::MUX_HARNESS_HEALTH, json!({})).await);
    assert_eq!(
        (row["version"].as_str(), row["unsupported"].as_bool()),
        (Some("2.1.300"), Some(false))
    );

    // The models are listed again without a chat or a daemon restart, and watchers hear it.
    assert!(
        c.note(method::MUX_HARNESSES_CHANGED, Duration::from_secs(30)).await,
        "the updated CLI's models were never listed again"
    );
    let after = claude_models(&c.call("_acpmux/models", json!({})).await);
    assert!(after.iter().any(|id| id == "claude-opus-5-5"), "{after:?}");

    let _ = std::fs::remove_dir_all(&root);
}
