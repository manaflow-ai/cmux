//! Resumable uploads (`hub/file_uploads.rs`, `docs/prompt-uploads.md` sections 3 and 4): a sender
//! reads where an upload stands from `_acpmux/file_put_status` and resumes there, every refusal
//! says what to do (`upload.offset {offset}`, `upload.incomplete {offset}`, `upload.unknown`),
//! the finish checks the SHA-256, and a full disk is the one size failure, naming the host and
//! the path (Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE").
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use base64::Engine;
use serde_json::{Value, json};
use sha2::Digest;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const STATUS: &str = "_acpmux/file_put_status";
const CHUNK: usize = 512 << 10;

fn hub() -> Arc<Hub> {
    let home = std::env::temp_dir().join(format!("acpmux-upload-resume-{}", std::process::id()));
    acpmux::config::set_home_override(home);
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self { tx, rx, next: 0 }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.rx.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(self.next)) {
                return v;
            }
        }
    }

    async fn begin(&mut self, session: &str, name: &str, size: u64) -> Value {
        let p = json!({"sessionId": session, "fileName": name, "size": size});
        self.call(method::MUX_FILE_PUT_BEGIN, p).await
    }

    async fn chunk(&mut self, session: &str, upload: &str, offset: usize, bytes: &[u8]) -> Value {
        let data = base64::engine::general_purpose::STANDARD.encode(bytes);
        let p = json!({"sessionId": session, "uploadId": upload, "offset": offset, "data": data});
        self.call(method::MUX_FILE_PUT_CHUNK, p).await
    }

    async fn status(&mut self, session: &str, upload: &str) -> Value {
        self.call(STATUS, json!({"sessionId": session, "uploadId": upload})).await
    }
}

fn sha(bytes: &[u8]) -> String {
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or("none")
}

fn id_of(v: &Value) -> String {
    v["result"]["uploadId"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned()
}

#[tokio::test]
async fn an_upload_resumes_from_its_status_and_its_finish_is_checked() {
    let hub = hub();
    let mut c = Client::new(&hub, Origin::Local);
    let init = c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await;
    let features = &init["result"]["_meta"]["acpmux"]["features"];
    assert!(features.as_array().unwrap().contains(&json!("uploadResume")), "{features}");
    let made =
        c.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let session = made["result"]["sessionId"].as_str().unwrap().to_owned();
    let file: Vec<u8> = (0..3 * CHUNK + 11).map(|i| (i % 251) as u8).collect();
    let upload = id_of(&c.begin(&session, "data.bin", file.len() as u64).await);
    let parts: Vec<&[u8]> = file.chunks(CHUNK).collect();
    c.chunk(&session, &upload, 0, parts[0]).await;

    // After a disconnect, the sender asks where the upload stands and resumes there.
    let at = c.status(&session, &upload).await;
    assert_eq!(at["result"]["offset"], json!(CHUNK), "{at}");
    assert_eq!(at["result"]["finished"], false, "{at}");
    assert_eq!(at["result"]["fileName"], "data.bin", "{at}");
    let stale = c.chunk(&session, &upload, 0, parts[0]).await;
    assert_eq!(reason(&stale), "upload.offset", "{stale}");
    assert_eq!(stale["error"]["data"]["offset"], json!(CHUNK), "{stale}");
    c.chunk(&session, &upload, CHUNK, parts[1]).await;
    let finish = json!({"sessionId": session, "uploadId": upload, "fileName": "data.bin",
        "size": file.len(), "sha256": sha(&file)});
    let early = c.call(method::MUX_FILE_PUT_FINISH, finish.clone()).await;
    assert_eq!(reason(&early), "upload.incomplete", "{early}");
    assert_eq!(early["error"]["data"]["offset"], json!(2 * CHUNK), "{early}");
    for (n, part) in parts.iter().enumerate().skip(2) {
        c.chunk(&session, &upload, n * CHUNK, part).await;
    }
    let done = c.call(method::MUX_FILE_PUT_FINISH, finish.clone()).await;
    let path = done["result"]["path"].as_str().unwrap_or_else(|| panic!("{done}")).to_owned();
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&file));
    // A finish whose answer was lost is answered again, and status says it is done.
    let again = c.call(method::MUX_FILE_PUT_FINISH, finish).await;
    assert_eq!(again["result"]["path"], json!(path), "{again}");
    let at = c.status(&session, &upload).await;
    assert_eq!(at["result"]["finished"], true, "{at}");
    assert_eq!(at["result"]["path"], json!(path), "{at}");

    // Bytes that are not the sender's: refused at finish, and the upload is gone.
    let bad = id_of(&c.begin(&session, "bad.bin", 3).await);
    c.chunk(&session, &bad, 0, b"abc").await;
    let finish = json!({"sessionId": session, "uploadId": bad, "fileName": "bad.bin", "size": 3,
        "sha256": sha(b"xyz")});
    let corrupt = c.call(method::MUX_FILE_PUT_FINISH, finish).await;
    assert_eq!(reason(&corrupt), "upload.corrupt", "{corrupt}");
    assert_eq!(corrupt["error"]["data"]["sha256"], sha(b"abc"), "{corrupt}");
    assert_eq!(reason(&c.status(&session, &bad).await), "upload.unknown");
    let unknown = c.chunk(&session, &bad, 0, b"a").await;
    assert_eq!(reason(&unknown), "upload.unknown", "{unknown}");

    // The only failure about size: no room on the disk, with the host and the path.
    let huge = 1u64 << 62;
    let full = c.begin(&session, "huge.bin", huge).await;
    assert_eq!(reason(&full), "upload.diskFull", "{full}");
    let data = &full["error"]["data"];
    assert_eq!(data["host"], json!(acpmux::host_pressure::host_name()), "{full}");
    assert!(data["path"].as_str().unwrap().contains(&session), "{full}");
    assert_eq!(data["needed"], json!(huge), "{full}");
    assert!(data["free"].as_u64().unwrap() < huge, "{full}");

    // A remote web client reads no upload's state.
    let mut web = Client::new(&hub, Origin::Web);
    let refused = web.status(&session, &upload).await;
    let why = reason(&refused);
    assert!(why == "filePut.remote" || why.starts_with("remote."), "{refused}");
}
