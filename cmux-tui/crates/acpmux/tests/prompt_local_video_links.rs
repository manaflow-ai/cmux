//! A prompt that names large files on this machine is taken in constant time (Leo, 2026-11-17: two
//! 1:12 screen recordings dragged into a chat went unanswered for five minutes, "WHAT THE *** COULD
//! TAKE SO LONG ABOUT LINKING A *** VIDEO"). The app sends a dropped video as a `resource_link` to its
//! path with key frames as small JPEG `image` blocks (webviews composer/videoPrompt.ts); acpmux must
//! never read, hash or copy the linked file before it accepts the prompt. Two 500 MB sparse files
//! here: a full read of either would take far past the bound.
#![cfg(unix)]

use crate::HERMETIC;
use crate::daemon_env;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use base64::Engine;
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const SIZE: u64 = 500_000_000;

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
async fn a_prompt_linking_two_large_local_videos_is_accepted_at_once() {
    let _ = &HERMETIC;
    let scratch = daemon_env::Scratch::new("acpmux-video-links");
    let home = scratch.to_path_buf();
    acpmux::config::set_home_override(home.clone());
    // Two sparse recordings: 500 MB each, no disk used, a read of either is slow.
    let movies = home.join("Movies");
    std::fs::create_dir_all(&movies).unwrap();
    let mut links = Vec::new();
    for n in 1..=2 {
        let path = movies.join(format!("Screen Recording {n}.mov"));
        let file = std::fs::File::create(&path).unwrap();
        file.set_len(SIZE).unwrap();
        links.push(path);
    }
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
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "videos"}}}),
        )
        .await;
    let session = made["result"]["sessionId"].as_str().unwrap().to_owned();

    // A turn runs: the prompt waits behind it, so its acceptance is the queue's, not the agent's.
    let busy = json!({"sessionId": session, "prompt": [{"type": "text", "text": "until-cancel"}],
        "_meta": {"acpmux": {"promptId": "busy"}}});
    c.post(method::SESSION_PROMPT, busy).await;
    c.until(|v| v.pointer("/params/update/content/text").is_some()).await;

    // The app's shape: the text, then each video's link, its frames note and its frames.
    let jpeg = base64::engine::general_purpose::STANDARD.encode(b"\xff\xd8\xff\xe0frame\xff\xd9");
    let mut prompt = vec![json!({"type": "text", "text": "x".repeat(801)})];
    for path in &links {
        let name = path.file_name().unwrap().to_str().unwrap().to_owned();
        let uri = reqwest::Url::from_file_path(path).unwrap().to_string();
        prompt.push(json!({"type": "resource_link", "uri": uri, "name": name}));
        prompt.push(json!({"type": "text", "text": format!("Frames from the video {name} (1:12, 2560×1600), in order, at: 0:00.0.")}));
        for at in 0..16 {
            prompt.push(json!({"type": "text", "text": format!("{name} frame at 0:{at:02}.0")}));
            prompt.push(json!({"type": "image", "mimeType": "image/jpeg", "data": jpeg,
                "name": format!("{name} frame at 0:{at:02}.0")}));
        }
    }
    let p = json!({"sessionId": session, "prompt": prompt, "_meta": {"acpmux": {"promptId": "videos"}}});
    let asked = Instant::now();
    let id = c.post(method::SESSION_PROMPT, p).await;
    let accepted = c
        .until(|v| {
            (v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "videos")
                || v.get("id") == Some(&json!(id))
        })
        .await;
    let took = asked.elapsed();
    assert_eq!(accepted["params"]["queued"], true, "{accepted}");
    assert!(took < Duration::from_secs(1), "accepted after {took:?}");
    c.post(method::SESSION_CANCEL, json!({"sessionId": session})).await;
    let answer = c.until(|v| v.get("id") == Some(&json!(id))).await;
    assert!(answer.get("error").is_none(), "{answer}");
    // The files were left as they were: never copied into the chat's uploads.
    for path in &links {
        assert_eq!(std::fs::metadata(path).unwrap().len(), SIZE);
    }
    let uploads = home.join("uploads");
    let copied = walk(&uploads).into_iter().filter(|p| p.metadata().is_ok_and(|m| m.len() >= SIZE));
    assert_eq!(copied.count(), 0, "a linked video was copied into the uploads");
    eprintln!("two 500 MB linked videos: accepted in {took:?}");
}

fn walk(dir: &Path) -> Vec<std::path::PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(walk(&path));
        } else {
            out.push(path);
        }
    }
    out
}
