//! Codex is the in-process bridge (`codex app-server`, `codex_app_server.rs`)
//! when codex is installed; the ACP adapter stays as `codex-acp`. The user's
//! configuration still decides: the profile's or family's `CODEX_PATH` is the
//! codex binary the bridge runs, and a family `prefer` list picks the profile.
#![cfg(unix)]

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("acc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::create_dir_all(d.join("bin")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// An executable `name` in `d/bin` that runs `script` with its arguments.
fn shim(d: &Path, name: &str, script: &str) -> PathBuf {
    let path = d.join("bin").join(name);
    std::fs::write(&path, format!("#!/bin/sh\nexec python3 {script} \"$@\"\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn hub_with(cfg: Value) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// The daemon's own socket (the CLI's proof: the owner-only file).
    fn local(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::Local,
            ConnAuth::LocalSocket,
        ));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

/// A new session on `head` (a profile or a family) and its harness.
async fn harness_of_new(c: &mut Client, d: &Path, head: &str) -> (String, String) {
    let r = c.call("session/new", json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": head}}})).await;
    let s = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let list = c.call("_acpmux/sessions", json!({})).await;
    let harness = list["result"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["sessionId"] == s.as_str())
        .and_then(|x| x["harness"].as_str())
        .unwrap()
        .to_owned();
    (s, harness)
}

#[tokio::test]
async fn the_bridge_runs_the_codex_path_the_family_configures() {
    let d = dir("path");
    let custom = shim(&d, "cmux-codex", FAKE_APP_SERVER);
    // The profile names a codex that does not exist: only CODEX_PATH can make it run.
    let hub = hub_with(json!({
        "harnesses": {"codex": {"argv": [d.join("bin").join("missing").join("codex"), "app-server"]}},
        "defaults": {"codex": {"env": {"CODEX_PATH": custom}}},
        "defaultHarness": "codex",
        "permissionPolicy": "ask",
    }));
    let mut c = Client::local(&hub);
    let (s, harness) = harness_of_new(&mut c, &d, "codex").await;
    assert_eq!(harness, "codex");
    let r = c
        .call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}))
        .await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_prefer_list_still_picks_the_codex_profile() {
    let d = dir("prefer");
    let codex = shim(&d, "codex", FAKE_APP_SERVER);
    let harnesses = json!({
        "codex": {"argv": [codex, "app-server"]},
        "mine": {"argv": ["python3", FAKE_AGENT], "family": "codex"},
    });
    let preferring = hub_with(json!({
        "harnesses": harnesses,
        "defaults": {"codex": {"prefer": ["mine", "codex"]}},
        "permissionPolicy": "ask",
    }));
    let (_, picked) = harness_of_new(&mut Client::local(&preferring), &d, "codex").await;
    assert_eq!(picked, "mine", "the prefer list's first profile");
    let plain = hub_with(json!({"harnesses": harnesses, "permissionPolicy": "ask"}));
    let (_, picked) = harness_of_new(&mut Client::local(&plain), &d, "codex").await;
    assert_eq!(picked, "codex", "without a preference, the profile named like the family");
    let _ = std::fs::remove_dir_all(&d);
}

/// The real daemon discovers its harnesses on its own PATH.
#[tokio::test]
async fn codex_on_path_is_the_bridge_and_the_adapter_becomes_codex_acp() {
    let d = dir("discover");
    shim(&d, "codex", FAKE_APP_SERVER);
    shim(&d, "codex-acp", FAKE_AGENT);
    let home = d.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let acp_home = d.join("acpmux");
    std::fs::create_dir_all(&acp_home).unwrap();
    let socket = acp_home.join("s.sock");
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
        .env("PATH", format!("{}:/usr/bin:/bin", d.join("bin").display()))
        .env("HOME", &home)
        .env("ACPMUX_HOME", &acp_home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("XPC_SERVICE_NAME")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start daemon");
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut ready = String::new();
    while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
        ready.clear();
    }
    let socket = serde_json::from_str::<Value>(&ready)
        .ok()
        .and_then(|v| v["socket"].as_str().map(PathBuf::from))
        .unwrap_or(socket);
    let stream = tokio::net::UnixStream::connect(&socket).await.expect("daemon socket");
    let (rd, mut wr) = stream.into_split();
    let mut lines = tokio::io::BufReader::new(rd).lines();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/harnesses", "params": {}});
    wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    let reply = loop {
        let l = tokio::time::timeout(Duration::from_secs(30), lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let v: Value = serde_json::from_str(&l).unwrap();
        if v["id"] == json!(1) {
            break v;
        }
    };
    let _ = child.kill();
    let _ = child.wait();
    let h = &reply["result"]["harnesses"];
    assert_eq!(h["codex"]["argv"][1], "app-server", "{h}");
    assert!(h["codex"]["argv"][0].as_str().unwrap_or("").ends_with("/codex"), "{h}");
    assert!(h["codex-acp"]["argv"][0].as_str().unwrap_or("").ends_with("/codex-acp"), "{h}");
    let _ = std::fs::remove_dir_all(&d);
}
