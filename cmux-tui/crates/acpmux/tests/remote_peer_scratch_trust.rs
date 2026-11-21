//! A remote chat with no folder (the app's composer: Remote, a machine, "No folder") reaches the
//! host's acpmux as a proven peer's `session/new` with no `cwd`, forwarded for the app's pane
//! (`via: app`). The host makes the chat a scratch folder of its own (`remote_guard.rs`
//! `peer_scratch`), and that folder is trusted the way the Mac's agent-home folder is: acpmux made
//! it, empty and owner-only, for a chat the person gave no folder, so nobody is asked
//! (cmux#13742, decision A). Before, the trust gate refused the start with `trust.pending` for a
//! fresh `session-<id>` folder the pane could never record an answer for, and the chat waited on
//! "Waiting for folder trust" forever.
//!
//! What still holds: a peer forwarding for its own Web client (`via: web`) gets no folderless start
//! at all; a person's explicit "Don't trust" for the folder still refuses; and a folder someone
//! else put under the scratch root, without acpmux's marker, is asked about as any folder is.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
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
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A hub with the folder-trust gate on (as the daemon runs it), no Web roots, the stand-in's
/// asking modes, and the user's own
/// trust files (none yet: every folder starts unknown).
fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        // The stand-in's asking modes, so a remote start is judged by its folder alone.
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(acpmux::trust::Paths::current().expect("a home folder")));
    hub
}

async fn call(hub: &Arc<Hub>, origin: Origin, m: &str, params: Value) -> Value {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    in_tx.send(Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(20), out_rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

fn reason(v: &Value) -> String {
    v["error"]["data"]["reason"].as_str().unwrap_or_default().to_owned()
}

/// A folderless start from the owner's daemon for its app pane (`via: app`), named `name` when
/// given (the scratch folder is named after it; else `session-<id>`, as the app's is).
fn folderless(via: &str, name: Option<&str>) -> Value {
    let mut acpmux = json!({"via": via});
    if let Some(name) = name {
        acpmux["name"] = json!(name);
    }
    json!({"mcpServers": [], "_meta": {"acpmux": acpmux}})
}

#[tokio::test]
async fn a_folderless_remote_chat_from_the_app_starts_with_no_trust_question() {
    let hub = hub();

    // The app's own shape: no name, so the host names the folder `session-<id>`.
    let r = call(&hub, Origin::Peer, "session/new", folderless("app", None)).await;
    let id = r["result"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("a folderless start from the app must not wait on trust: {r}"));
    let cwd = hub.resolve(id).unwrap().meta().cwd.clone();
    assert!(
        cwd.file_name().unwrap().to_string_lossy().starts_with("session-"),
        "the app's folderless chat gets the host's session scratch folder: {}",
        cwd.display()
    );
    assert!(
        cwd.parent()
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("acpmux-peer-scratch-"),
        "{}",
        cwd.display()
    );

    // The pane reads the folder as answered (no "Trust session-<id>?" card).
    let got = call(&hub, Origin::Local, "acp.trust.get", json!({"cwd": cwd})).await;
    assert_eq!(got["result"]["level"], "trusted", "{got}");
    assert_eq!(got["result"]["decided"], true, "{got}");

    let _ = std::fs::remove_dir_all(&cwd);
}

#[tokio::test]
async fn a_folderless_start_forwarded_for_the_web_is_still_refused() {
    let hub = hub();
    let r = call(&hub, Origin::Peer, "session/new", folderless("web", None)).await;
    assert!(r.get("error").is_some(), "a Web caller gets no scratch folder: {r}");
    assert!(r["error"]["message"].as_str().unwrap_or_default().contains("cwd"), "{r}");
    let r = call(&hub, Origin::Web, "session/new", json!({"mcpServers": []})).await;
    assert!(r.get("error").is_some(), "{r}");
}

#[tokio::test]
async fn an_explicit_dont_trust_for_the_scratch_folder_still_refuses() {
    let hub = hub();
    let name = format!("dont-trust-{}", std::process::id());
    let r = call(&hub, Origin::Peer, "session/new", folderless("app", Some(&name))).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}"));
    let cwd = hub.resolve(id).unwrap().meta().cwd.clone();

    // The person says "Don't trust" in the CLI: their answer wins over the folder's rule.
    let set =
        call(&hub, Origin::Local, "acp.trust.set", json!({"cwd": cwd, "level": "untrusted"})).await;
    assert!(set.get("error").is_none(), "{set}");
    let got = call(&hub, Origin::Local, "acp.trust.get", json!({"cwd": cwd})).await;
    assert_eq!(got["result"]["level"], "untrusted", "{got}");

    // The same name lands in the same folder, which is now refused.
    let again = call(&hub, Origin::Peer, "session/new", folderless("app", Some(&name))).await;
    assert_eq!(reason(&again), "trust.untrusted", "{again}");

    // A folder under the scratch root that acpmux did not make (no marker) is asked about.
    let stray = cwd.parent().unwrap().join(format!("stray-{}", std::process::id()));
    std::fs::create_dir_all(&stray).unwrap();
    let got = call(&hub, Origin::Local, "acp.trust.get", json!({"cwd": stray})).await;
    assert_eq!(got["result"]["level"], "unknown", "{got}");
    let _ = std::fs::remove_dir_all(&stray);
    let _ = std::fs::remove_dir_all(&cwd);
}
