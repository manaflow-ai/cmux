//! A 2 GB file of no known type reaches a busy chat (Leo, 2026-10-26: "I ALREADY SAID WE NEED
//! ARBITARRILY LARGE FILES OF ANY TYPE"): streamed as the app streams it, raw bytes in binary
//! frames of 1 MiB on its own WebSocket, 4 in flight (`server/upload_frames.rs`, no size cap),
//! checked by SHA-256 at the finish, named in a prompt that is accepted in under a second, and handed to
//! the agent as its path, its bytes intact. Neither side ever holds the file: the test streams it
//! and checks the process's peak memory. Its own test binary, so the peak is this test's.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

#[path = "support/app_ws.rs"]
mod app_ws;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use sha2::Digest;
use std::io::Read;
use std::path::Path;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// One data frame's bytes.
const CHUNK: usize = 1 << 20;
/// Frames in flight (`upload_frames::WINDOW`).
const WINDOW: usize = 4;
/// 2 GB, past the 1 GiB the uploads were capped at.
const SIZE: u64 = 2_000_000_000;

/// The kernel's peak resident size of this process, in bytes.
fn peak_rss() -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let line = status.lines().find(|l| l.starts_with("VmHWM:")).unwrap();
    line.split_whitespace().nth(1).unwrap().parse::<u64>().unwrap() * 1024
}

/// Byte `n` of the file: no known type (no image, PDF or archive magic), different everywhere.
fn fill(offset: u64, out: &mut [u8]) {
    for (i, b) in out.iter_mut().enumerate() {
        let n = offset + i as u64;
        *b = (n.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 56) as u8 ^ (n >> 20) as u8;
    }
    if offset == 0 {
        out[0] = 0;
    }
}

/// One connection: requests, and the agent text streamed so far.
struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
    text: String,
}

impl Client {
    async fn post(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    async fn until(&mut self, want: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if let Some(chunk) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                self.text.push_str(chunk);
            }
            if want(&v) {
                return v;
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        self.until(|v| v.get("id") == Some(&json!(id))).await
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_two_gigabyte_file_of_any_type_reaches_a_busy_chat_by_path() {
    let home = std::env::temp_dir().join(format!("acpmux-uploads-2g-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    acpmux::config::set_home_override(home.clone());
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, rx) = mpsc::channel::<String>(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = Client { tx, rx, next: 0, text: String::new() };
    let made = c
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "big"}}}),
        )
        .await;
    let session = made["result"]["sessionId"].as_str().unwrap().to_owned();
    let l = app_ws::listen(&hub).await;
    let mut app = app_ws::AppWs::open(&l, true).await;
    let started = Instant::now();
    let begin = json!({"sessionId": session, "fileName": "data.bin", "size": SIZE});
    let begun = app.call(method::MUX_FILE_PUT_BEGIN, begin).await;
    let upload = begun["result"]["uploadId"].as_str().unwrap_or_else(|| panic!("{begun}"));
    let upload = upload.to_owned();
    let (mut sent, mut hash, mut buf) = (0u64, sha2::Sha256::new(), vec![0u8; CHUNK]);
    let mut flight = std::collections::VecDeque::new();
    while sent < SIZE || !flight.is_empty() {
        if sent < SIZE && flight.len() < WINDOW {
            let n = CHUNK.min((SIZE - sent) as usize);
            fill(sent, &mut buf[..n]);
            hash.update(&buf[..n]);
            flight.push_back(app.frame(&session, &upload, sent, &buf[..n]).await);
            sent += n as u64;
            continue;
        }
        let id = flight.pop_front().unwrap();
        let put = app.answer(id).await;
        assert!(put.get("error").is_none(), "at {sent}: {put}");
    }
    let sha: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    let finish = json!({"sessionId": session, "uploadId": upload, "fileName": "data.bin",
        "size": SIZE, "sha256": sha});
    let done = app.call(method::MUX_FILE_PUT_FINISH, finish).await;
    assert!(done.get("error").is_none(), "{done}");
    let uploaded = started.elapsed();

    // A turn runs (the stand-in's `until-cancel` lasts 30 s at most): the prompt waits behind it.
    let busy = json!({"sessionId": session, "prompt": [{"type": "text", "text": "until-cancel"}],
        "_meta": {"acpmux": {"promptId": "busy"}}});
    c.post(method::SESSION_PROMPT, busy).await;
    c.until(|v| v.pointer("/params/update/content/text").is_some()).await;

    let reference = json!({"type": "resource_link", "name": "data.bin",
        "uri": format!("acpmux-upload:{upload}"),
        "_meta": {"acpmux": {"upload": {"uploadId": upload, "fileName": "data.bin"}}}});
    let p = json!({"sessionId": session, "prompt": [{"type": "text", "text": "read it"}, reference],
        "_meta": {"acpmux": {"promptId": "big"}}});
    let asked = Instant::now();
    let id = c.post(method::SESSION_PROMPT, p).await;
    let accepted = c
        .until(|v| {
            (v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "big")
                || v.get("id") == Some(&json!(id))
        })
        .await;
    let took = asked.elapsed();
    assert_eq!(accepted["params"]["queued"], true, "{accepted}");
    assert!(took < Duration::from_secs(1), "accepted after {took:?}");
    c.post(method::SESSION_CANCEL, json!({"sessionId": session})).await;
    let answer = c.until(|v| v.get("id") == Some(&json!(id))).await;
    assert!(answer.get("error").is_none(), "{answer}");
    // The agent got the file as its path, not its bytes.
    let link = c
        .text
        .split_whitespace()
        .find_map(|w| w.strip_prefix("resource_link:data.bin:application/octet-stream:"))
        .unwrap_or_else(|| panic!("{}", c.text));
    let path = reqwest::Url::parse(link).unwrap().to_file_path().unwrap();
    let mut file = std::fs::File::open(&path).unwrap();
    assert_eq!(file.metadata().unwrap().len(), SIZE);
    let mut read = sha2::Sha256::new();
    loop {
        let n = file.read(&mut buf).unwrap();
        if n == 0 {
            break;
        }
        read.update(&buf[..n]);
    }
    let read: String = read.finalize().iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(read, sha, "the file's bytes changed");
    let peak = peak_rss();
    eprintln!(
        "2 GB: uploaded in {uploaded:?}, accepted in {took:?}, sha256 {sha}, peak RSS {} MiB",
        peak >> 20
    );
    assert!(peak < 512 << 20, "peak RSS {} MiB: something held the file", peak >> 20);
    let _ = std::fs::remove_dir_all(&home);
}
