//! A harness that writes a line that is not UTF-8 (a tool's binary output, a log line in another
//! encoding) keeps working when the daemon runs it as its own child (a memory store: no agent
//! host). Its first stdout line and a stderr line here hold a byte that is not UTF-8; the daemon
//! took that for the end of the pipe and stopped reading it, so the agent never answered.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub(work: &Path) -> Arc<Hub> {
    // The stand-in agent, after one stdout line and one stderr line that are not UTF-8.
    let script = format!(
        "printf '\\377binary\\n'; printf 'warn \\377\\n' >&2; exec python3 {}",
        daemon_env::sh_quote(FAKE)
    );
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["/bin/sh", "-c", script]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "webRoots": [work],
        "autoResumeDelaysMs": [],
    }))
    .unwrap();
    cfg.path = Some(work.join("config.json"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The reply to one call, and the agent text streamed before it; `None` when none comes.
async fn call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    method: &str,
    params: Value,
) -> Option<(Value, String)> {
    tx.send(Message::request(id, method, params).to_line()).await.unwrap();
    let mut text = String::new();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), rx.recv()).await.ok()??;
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            return Some((v, text));
        }
        if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
            text.push_str(t);
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_direct_harness_that_writes_a_line_that_is_not_utf8_still_answers() {
    let _ = HERMETIC;
    let work = std::env::temp_dir().join(format!("acpmux-bytes-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).unwrap();
    let work = std::fs::canonicalize(&work).unwrap();
    let hub = hub(&work);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let created =
        call(&in_tx, &mut out_rx, 1, "session/new", json!({"cwd": work, "mcpServers": []}))
            .await
            .map(|(v, _)| v);
    let id = created
        .as_ref()
        .and_then(|v| v["result"]["sessionId"].as_str())
        .map(str::to_owned)
        .unwrap_or_else(|| panic!("no session: {created:?}"));
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "after the bytes"}]});
    let answered = call(&in_tx, &mut out_rx, 2, "session/prompt", prompt).await;
    let _ = std::fs::remove_dir_all(&work);
    let (reply, text) = answered.expect("the agent never answered");
    assert_eq!(reply["result"]["stopReason"], "end_turn", "{reply}");
    assert!(text.contains("after the bytes"), "{text:?}");
}
