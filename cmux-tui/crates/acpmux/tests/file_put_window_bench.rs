//! The upload bench for `hub/file_uploads/window.rs`: one file uploaded through
//! `cmux_fault::shaper::Shaper` to a real hub as `forward_put` sends it to a Linux peer (begin,
//! the chunks, the finish), one chunk per round trip (`FPW_WINDOWS=1`, the sender before
//! `filePutWindow`) or a window of them with the finish right behind (`8`). The chunks go
//! through the real sender (`file_put_window::send`). One `FILEPUT {...}` line per run.
//!
//! Loads: `idle` = 5 chats; `duress` = 50 chats, one at `FPW_DURESS_TURNS` (default 2000) turns
//! and streaming ticks while the uploads run (the round-trip audit's duress, fewer turns).
//! Env: `FPW_BYTES` (2097152,104857600), `FPW_PROFILES` (lte,lossy-3), `FPW_LOADS` (idle),
//! `FPW_WINDOWS` (1,8), `FPW_RUNS` (3).
//! `cargo test --release -p acpmux --test acpmux_all file_put_window_bench -- --ignored --nocapture`
#![cfg(unix)]

use crate::HERMETIC;
use crate::daemon_env;

#[path = "support/app_ws.rs"]
mod app_ws;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::hub::file_put_window as window;
use acpmux::rpc::{Message as RpcMessage, RpcError, method};
use acpmux::server::{AGENT_PANE_ORIGIN, Origin, serve_connection_with};
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const BOUND: Duration = Duration::from_secs(600);
const CHUNK: usize = 512 << 10;

/// A WebSocket client that keeps many requests in flight: answers matched by id.
#[derive(Clone)]
struct Link {
    out: mpsc::UnboundedSender<String>,
    waiting: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>>,
    next: Arc<std::sync::atomic::AtomicI64>,
}

impl Link {
    async fn dial(addr: std::net::SocketAddr) -> Self {
        let tcp = tokio::net::TcpStream::connect(addr).await.unwrap();
        let _ = tcp.set_nodelay(true);
        let mut req = format!("ws://{addr}/").into_client_request().unwrap();
        req.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
        req.headers_mut().insert("origin", AGENT_PANE_ORIGIN.parse().unwrap());
        let (ws, _) = tokio_tungstenite::client_async(req, tcp).await.unwrap();
        let (mut sink, mut stream) = ws.split();
        let (out, mut rx) = mpsc::unbounded_channel::<String>();
        tokio::spawn(async move {
            while let Some(text) = rx.recv().await {
                if sink.send(Message::Text(text.into())).await.is_err() {
                    break;
                }
            }
        });
        let waiting: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>> = Arc::default();
        let answers = waiting.clone();
        tokio::spawn(async move {
            while let Some(Ok(frame)) = stream.next().await {
                let Message::Text(t) = frame else { continue };
                let Ok(v) = serde_json::from_str::<Value>(&t) else { continue };
                if v.get("method").is_some() {
                    continue;
                }
                let Some(id) = v.get("id").and_then(Value::as_i64) else { continue };
                if let Some(tx) = answers.lock().unwrap().remove(&id) {
                    let _ = tx.send(v);
                }
            }
        });
        Self { out, waiting, next: Arc::default() }
    }

    async fn request(&self, m: &str, params: Value) -> Result<Value, RpcError> {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.waiting.lock().unwrap().insert(id, tx);
        let text = json!({"jsonrpc": "2.0", "id": id, "method": m, "params": params}).to_string();
        self.out.send(text).map_err(|_| RpcError::internal("link closed"))?;
        let v = tokio::time::timeout(BOUND, rx)
            .await
            .map_err(|_| RpcError::internal(format!("{m}: no answer in {BOUND:?}")))?
            .map_err(|_| RpcError::internal("link closed"))?;
        match v.get("error") {
            Some(e) => Err(serde_json::from_value(e.clone())
                .unwrap_or_else(|_| RpcError::internal(e.to_string()))),
            None => Ok(v["result"].clone()),
        }
    }
}

fn hub(home: &Path) -> Arc<Hub> {
    acpmux::config::set_home_override(home.to_path_buf());
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

/// The hub's own unix-socket side, to make and seed chats.
struct Control {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Control {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(65536);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self { tx, rx, next: 0 }
    }

    async fn post(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(RpcMessage::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        loop {
            let line = tokio::time::timeout(BOUND, self.rx.recv()).await.unwrap().unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return v;
            }
        }
    }

    async fn new_session(&mut self, cwd: &Path, name: &str) -> String {
        let made = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned()
    }

    async fn seed(&mut self, session: &str, turns: u64) {
        let pad = "lorem ipsum dolor sit amet ".repeat(37);
        for n in 0..turns {
            let v = self
                .call(
                    method::SESSION_PROMPT,
                    json!({"sessionId": session,
                           "prompt": [{"type": "text", "text": format!("turn {n}: {pad}")}]}),
                )
                .await;
            assert!(v.get("error").is_none(), "seed turn {n}: {v}");
        }
    }
}

fn env_list(name: &str, default: &[&str]) -> Vec<String> {
    match std::env::var(name) {
        Ok(v) if !v.trim().is_empty() => {
            v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect()
        }
        _ => default.iter().map(|s| (*s).to_owned()).collect(),
    }
}

/// One upload of `bytes` through `link`, `windowed` chunks in flight: begin to finish, in ms.
async fn upload(
    link: &Link,
    chat: &str,
    bytes: usize,
    windowed: usize,
    run: u64,
) -> Result<f64, String> {
    use base64::Engine as _;
    let name = format!("fpw-{run}-{bytes}.bin");
    let started = Instant::now();
    let begun = link
        .request(
            method::MUX_FILE_PUT_BEGIN,
            json!({"sessionId": chat, "fileName": name, "size": bytes}),
        )
        .await
        .map_err(|e| format!("begin: {}", e.message))?;
    let up = begun["uploadId"].as_str().ok_or("no uploadId")?.to_owned();
    let base = json!({"sessionId": chat, "uploadId": up});
    let piece = vec![(run % 251) as u8; CHUNK];
    let mut offset = 0usize;
    let next = || {
        if offset >= bytes {
            return Ok(None);
        }
        let len = CHUNK.min(bytes - offset);
        let p = window::Piece {
            offset: offset as u64,
            len,
            data: base64::engine::general_purpose::STANDARD.encode(&piece[..len]),
        };
        offset += len;
        Ok(Some(p))
    };
    let finish = json!({"sessionId": chat, "uploadId": up, "fileName": name, "size": bytes});
    let l = link.clone();
    let send = move |m: &'static str, p: Value| {
        let l = l.clone();
        async move { l.request(m, p).await }
    };
    let answer = window::send(send, &base, windowed, next, Some(finish))
        .await
        .map_err(|e| format!("upload: {}", e.message))?
        .ok_or("no finish answer")?;
    let took = started.elapsed();
    if answer["size"].as_u64() != Some(bytes as u64) {
        return Err(format!("finish answered {answer}"));
    }
    if let Some(path) = answer["path"].as_str() {
        let _ = std::fs::remove_file(path);
    }
    Ok((took.as_secs_f64() * 10_000.0).round() / 10.0)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the upload bench: run with --ignored --nocapture"]
async fn file_put_window_bench() {
    let _ = HERMETIC;
    let file = ProfileFile::builtin();
    let sizes: Vec<usize> = env_list("FPW_BYTES", &["2097152", "104857600"])
        .iter()
        .map(|s| s.parse().unwrap())
        .collect();
    let profiles = env_list("FPW_PROFILES", &["lte", "lossy-3"]);
    let loads = env_list("FPW_LOADS", &["idle"]);
    let windows: Vec<usize> =
        env_list("FPW_WINDOWS", &["1", "8"]).iter().map(|s| s.parse().unwrap()).collect();
    let runs: u64 = std::env::var("FPW_RUNS").ok().and_then(|v| v.parse().ok()).unwrap_or(3);
    let duress_turns: u64 =
        std::env::var("FPW_DURESS_TURNS").ok().and_then(|v| v.parse().ok()).unwrap_or(2000);
    let trace = Trace::new();
    for load in &loads {
        let scratch = daemon_env::Scratch::new(&format!("fpw-{load}"));
        let hub = hub(&scratch.path().join("home"));
        let listener = app_ws::listen(&hub).await;
        let addr: std::net::SocketAddr =
            listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
        let mut control = Control::new(&hub);
        let cwd = scratch.path().join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let chat = control.new_session(&cwd, "fpw-send").await;
        let sessions = if load == "duress" { 50 } else { 5 };
        let big = control.new_session(&cwd, "fpw-big").await;
        for n in 2..sessions {
            control.new_session(&cwd, &format!("fpw-{n}")).await;
        }
        if load == "duress" {
            control.seed(&big, duress_turns).await;
            let _ = control
                .post(
                    method::SESSION_PROMPT,
                    json!({"sessionId": big, "prompt": [{"type": "text", "text": "ticking:36000:100"}]}),
                )
                .await;
        }
        for name in &profiles {
            let profile =
                file.get(name).unwrap_or_else(|| panic!("no link profile {name}")).clone();
            for &bytes in &sizes {
                for run in 0..runs {
                    for &w in &windows {
                        let (shaper, _) =
                            Shaper::start_through(addr, profile.clone(), None, run, &trace)
                                .await
                                .unwrap();
                        let link = Link::dial(shaper.addr()).await;
                        let init = link
                            .request(
                                "initialize",
                                json!({"protocolVersion": 1,
                                       "clientInfo": {"name": "fpw", "version": "1"},
                                       "clientCapabilities": {},
                                       "_meta": {"acpmux": {"localAppToken": listener.token}}}),
                            )
                            .await
                            .unwrap();
                        let lists = init.to_string().contains(window::FEATURE);
                        let measured = upload(&link, &chat, bytes, w, run).await;
                        let mut line = json!({"profile": name, "load": load, "bytes": bytes,
                            "window": w, "run": run, "hub_lists_window": lists});
                        match measured {
                            Ok(ms) => line["ms"] = json!(ms),
                            Err(e) => line["error"] = json!(e),
                        }
                        println!("FILEPUT {line}");
                        drop(shaper);
                    }
                }
            }
        }
    }
}
