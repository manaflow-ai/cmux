//! A full disk on the machine that runs acpmux (a Mac mini serving chats to the user's other
//! Macs): the daemon keeps running and refuses new prompts with `storage.full`, instead of
//! taking a message it cannot save. Writes that fail with "no space left" mark the store full;
//! once space is free again the next prompt runs.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::store::{EventRecord, SessionMeta, Store};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// The disk as the test sets it: free bytes, and whether appends fail with ENOSPC.
#[derive(Default)]
struct Disk {
    free: AtomicU64,
    full: AtomicBool,
}

/// A memory store on a disk the test controls.
struct OnDisk {
    inner: Box<dyn Store>,
    disk: Arc<Disk>,
}

fn no_space() -> anyhow::Error {
    // ENOSPC as std reports it.
    std::io::Error::from_raw_os_error(28).into()
}

impl Store for OnDisk {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        if self.disk.full.load(Ordering::SeqCst) {
            return Err(no_space());
        }
        self.inner.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
    fn free_bytes(&self) -> Option<u64> {
        Some(self.disk.free.load(Ordering::SeqCst))
    }
    fn probe_write(&self) -> anyhow::Result<()> {
        if self.disk.full.load(Ordering::SeqCst) { Err(no_space()) } else { Ok(()) }
    }
}

fn hub(disk: Arc<Disk>) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let inner = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, Box::new(OnDisk { inner, disk }))
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0)
    }

    async fn reply(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    async fn new_session(&mut self) -> String {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        let created = self.reply("session/new", new).await;
        assert!(created.get("error").is_none(), "{created}");
        created["result"]["sessionId"].as_str().unwrap().to_owned()
    }

    async fn prompt(&mut self, session: &str, text: &str) -> Value {
        self.reply(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
    }
}

const PLENTY: u64 = 50 << 30;

fn assert_storage_full(reply: &Value) {
    let error = reply.get("error").unwrap_or_else(|| panic!("the prompt was taken: {reply}"));
    assert_eq!(error["data"]["reason"], "storage.full", "{reply}");
    assert_eq!(error["data"]["retryable"], true, "{reply}");
    let message = error["message"].as_str().unwrap_or_default();
    assert!(message.contains("disk") && message.contains("full"), "{message}");
}

#[tokio::test]
async fn a_nearly_full_disk_refuses_the_prompt_and_the_daemon_keeps_answering() {
    let disk = Arc::new(Disk::default());
    disk.free.store(PLENTY, Ordering::SeqCst);
    let hub = hub(disk.clone());
    let mut c = Client::open(&hub);
    let session = c.new_session().await;

    disk.free.store(1 << 20, Ordering::SeqCst);
    let refused = c.prompt(&session, "hello").await;
    assert_storage_full(&refused);
    assert_eq!(refused["error"]["data"]["freeBytes"], 1 << 20, "{refused}");

    // Still serving: the status answers and the chat is still listed.
    let status = c.reply("_acpmux/status", json!({})).await;
    assert!(status.get("error").is_none(), "{status}");

    // Space freed: the next prompt runs.
    disk.free.store(PLENTY, Ordering::SeqCst);
    let ran = c.prompt(&session, "hello again").await;
    assert!(ran.get("error").is_none(), "{ran}");
}

#[tokio::test]
async fn a_write_that_found_the_disk_full_refuses_the_next_prompt() {
    let disk = Arc::new(Disk::default());
    disk.free.store(PLENTY, Ordering::SeqCst);
    let hub = hub(disk.clone());
    let mut c = Client::open(&hub);
    let session = c.new_session().await;

    // The free-space probe still reads plenty (a quota, another writer), but writes fail.
    disk.full.store(true, Ordering::SeqCst);
    let first = c.prompt(&session, "lost?").await;
    let second = c.prompt(&session, "lost too?").await;
    // The first may have been taken before its record failed; the next never is.
    assert_storage_full(&second);
    let _ = first;

    let status = c.reply("_acpmux/status", json!({})).await;
    assert!(status.get("error").is_none(), "{status}");

    // Space freed: the test write passes and the next prompt runs.
    disk.full.store(false, Ordering::SeqCst);
    let ran = c.prompt(&session, "saved now").await;
    assert!(ran.get("error").is_none(), "{ran}");
}

#[tokio::test]
async fn a_new_chat_on_a_full_disk_is_refused_as_storage_full() {
    let disk = Arc::new(Disk::default());
    disk.free.store(4096, Ordering::SeqCst);
    let hub = hub(disk);
    let mut c = Client::open(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let refused = c.reply("session/new", new).await;
    assert_storage_full(&refused);
}

#[test]
fn enospc_and_quota_errors_read_as_disk_full() {
    assert!(acpmux::storage_full::is_disk_full(&no_space()));
    // EDQUOT (macOS 69, Linux 122) is a full disk to the user too.
    let quota = if cfg!(target_os = "macos") { 69 } else { 122 };
    assert!(acpmux::storage_full::is_disk_full(&std::io::Error::from_raw_os_error(quota).into()));
    let wrapped = no_space().context("append session.ndjson");
    assert!(acpmux::storage_full::is_disk_full(&wrapped));
    assert!(!acpmux::storage_full::is_disk_full(&std::io::Error::from_raw_os_error(13).into()));
}
