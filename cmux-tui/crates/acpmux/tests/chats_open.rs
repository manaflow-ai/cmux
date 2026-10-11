//! ALL-CHATS-ON-DEVICE S5: how a chat opens again. Synthetic temp homes only.
//!
//! - A Claude/Codex chat in the store of a configured profile resumes
//!   through acpmux adopt with that profile (`session/new` params).
//! - A chat in a store no profile uses, and every harness without adopt,
//!   opens a terminal tab with the resume argv (and the store env).
//! - A chat whose recorded folder is gone or guarded asks for a folder; it
//!   never falls back to the home folder.
//! - Adopt finds a chat in the store of the profile that resumes it.

use acpmux::adopt::HarnessHomes;
use acpmux::chats::ChatSources;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const CODEX_ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home(tag: &str) -> Home {
    let base = std::env::temp_dir().join(format!("acpmux-open-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).unwrap();
    Home(std::fs::canonicalize(&base).unwrap())
}

fn mkdir(path: &Path) -> PathBuf {
    std::fs::create_dir_all(path).unwrap();
    path.to_path_buf()
}

fn config(harnesses: Value) -> Config {
    serde_json::from_value(json!({"harnesses": harnesses})).unwrap()
}

fn homes(h: &Path) -> HarnessHomes {
    HarnessHomes { claude: h.join(".claude"), codex: h.join(".codex") }
}

fn codex_profile(env: &[(&str, &Path)]) -> Value {
    let env: HashMap<&str, String> =
        env.iter().map(|(k, v)| (*k, v.display().to_string())).collect();
    json!({"argv": ["python3", FAKE], "family": "codex", "env": env})
}

fn write_rollout(codex_home: &Path, cwd: &Path) {
    let rollout = codex_home
        .join(format!("sessions/2026/10/02/rollout-2026-10-02T09-00-00-{CODEX_ID}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": CODEX_ID, "cwd": cwd, "timestamp": "2026-10-02T09:00:00Z"}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    // Written an hour ago: a transcript written in the last minutes is a
    // chat live in another process, which adopt refuses (adopt_live.rs).
    let hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options().write(true).open(&rollout).unwrap().set_modified(hour_ago).unwrap();
}

async fn call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> Value {
    tx.send(Message::request(id, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            return v;
        }
    }
}

/// The open plan's `sessionNew` params create the adopted session through
/// the profile whose store holds the chat (not the daemon's default store).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn chat_open_then_session_new_adopts_from_the_profile_store() {
    let h = home("rpc");
    let project = mkdir(&h.0.join("work/api"));
    let alt = mkdir(&h.0.join("codex-alt"));
    write_rollout(&alt, &project);
    let mut cfg = config(json!({"fakecodex": codex_profile(&[("CODEX_HOME", &alt)])}));
    cfg.default_harness = Some("fakecodex".into());
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_harness_homes(homes(&h.0)); // the default stores hold nothing
    let mut sources = ChatSources {
        home: h.0.clone(),
        acpmux_home: h.0.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    sources.launch_roots = acpmux::chats::launch_roots(&*hub.config.read().await);
    hub.start_chats(sources).await.unwrap();

    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    call(
        &tx,
        &mut rx,
        1,
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}),
    )
    .await;

    let key = format!("codex:{CODEX_ID}");
    let plan = call(&tx, &mut rx, 2, "_acpmux/chat_open", json!({"key": key})).await;
    let plan = &plan["result"];
    assert_eq!(plan["kind"], "adopt", "{plan}");
    assert_eq!(plan["adopt"]["harness"], "fakecodex");
    let created = call(&tx, &mut rx, 3, method::SESSION_NEW, plan["sessionNew"].clone()).await;
    assert!(created.get("error").is_none(), "{created}");
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(CODEX_ID));
    assert_eq!(session.meta().cwd, project);

    let unknown = call(&tx, &mut rx, 4, "_acpmux/chat_open", json!({"key": "codex:nope"})).await;
    assert!(unknown["error"].is_object(), "{unknown}");
    let bad = call(&tx, &mut rx, 5, "_acpmux/chat_open", json!({"key": "no-colon"})).await;
    assert!(bad["error"]["message"].as_str().unwrap().contains("key"), "{bad}");
}
