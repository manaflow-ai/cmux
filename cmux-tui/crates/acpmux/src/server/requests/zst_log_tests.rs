//! A closed chat whose log a host's disk cleanup compressed opens as it did before: the app's
//! own requests (`_acpmux/attach`, `_acpmux/events` back and forward, the prompt index) answer
//! the same records from `events/NNNNNN.ndjson.zst` as from the plain segments.
//!
//! The cleanup compresses each segment with plain `zstd` (`zstd -q -10 --long=27 -T1 FILE -o
//! FILE.zst`, then the plain file goes, its time kept), as this test does when the tool is there.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn config() -> Config {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    // Small segments: the log is several of them, as a long chat's is.
    cfg.store.segment_bytes = 64 * 1024;
    cfg
}

/// A closed chat of `turns` prompts and answers, written through the store.
fn write_chat(root: &Path, id: &str, turns: u64) {
    let cfg = config();
    let store = crate::store::open(&cfg.store, root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "archived chat",
        "harness": "claude", "cwd": "/tmp", "status": "closed", "createdAt": 1,
        "updatedAt": 2, "lastSeq": turns * 2, "eventCount": turns * 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    for turn in 0..turns {
        let prompt = crate::store::EventRecord {
            seq: turn * 2 + 1,
            at: 1_000 + turn * 2 + 1,
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: json!({"text": format!("question {turn} {}", "q".repeat(300 + (turn as usize % 7) * 40))}),
            host_seq: None,
        };
        let answer = crate::store::EventRecord {
            seq: turn * 2 + 2,
            at: 1_000 + turn * 2 + 2,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": {"sessionUpdate": "agent_message_chunk", "messageId": format!("m{turn}"), "content": {"type": "text", "text": format!("answer {turn} {}", "a".repeat(200))}}}}),
            host_seq: None,
        };
        store.append(id, &prompt).unwrap();
        store.append(id, &answer).unwrap();
    }
    store.close_log(id);
    store.flush().unwrap();
}

/// Compresses every plain segment of chat `id` as the host cleanup does: `zstd` to `FILE.zst`
/// with the plain file's time, then the plain file goes. The `zstd` tool when it is on the
/// PATH, else the same frame through the library.
fn compress_like_cleanup(root: &Path, id: &str) -> usize {
    let events = root.join("sessions").join(id).join("events");
    let mut done = 0;
    let mut names: Vec<_> = std::fs::read_dir(&events)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "ndjson"))
        .collect();
    names.sort();
    let tool = std::process::Command::new("zstd").arg("--version").output().is_ok();
    eprintln!(
        "compressing {} segments with {}",
        names.len(),
        if tool { "zstd" } else { "the zstd library" }
    );
    for plain in names {
        let zst = PathBuf::from(format!("{}.zst", plain.display()));
        let modified = std::fs::metadata(&plain).unwrap().modified().unwrap();
        if tool {
            let status = std::process::Command::new("zstd")
                .args(["-q", "-f", "-T1", "-10", "--long=27"])
                .arg(&plain)
                .arg("-o")
                .arg(&zst)
                .status()
                .unwrap();
            assert!(status.success(), "zstd {}", plain.display());
        } else {
            let bytes = std::fs::read(&plain).unwrap();
            let out = std::fs::File::create(&zst).unwrap();
            let mut encoder = zstd::stream::write::Encoder::new(out, 10).unwrap();
            encoder.long_distance_matching(true).unwrap();
            encoder.window_log(27).unwrap();
            encoder.include_checksum(true).unwrap();
            encoder.set_pledged_src_size(Some(bytes.len() as u64)).unwrap();
            std::io::Write::write_all(&mut encoder, &bytes).unwrap();
            encoder.finish().unwrap();
        }
        let file = std::fs::OpenOptions::new().write(true).open(&zst).unwrap();
        file.set_modified(modified).unwrap();
        file.sync_all().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&zst, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        std::fs::remove_file(&plain).unwrap();
        done += 1;
    }
    done
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(32);
        let (output, outgoing) = mpsc::channel(256);
        tokio::spawn(super::super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::super::Origin::Local,
        ));
        let mut client = Self { input, outgoing, next: 1 };
        let hello = json!({
            "protocolVersion": 1,
            "clientInfo": {"name": "zst-log-test", "version": "0"}
        });
        let init = client.call(method::INITIALIZE, hello).await;
        assert!(init.get("error").is_none(), "{init}");
        client
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = self.outgoing.recv().await.expect("connection remains open");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == json!(id) {
                    return reply;
                }
            }
        })
        .await
        .expect("request answers")
    }

    async fn result(&mut self, m: &str, params: Value) -> Value {
        let reply = self.call(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }
}

/// What the app reads of chat `id`: the page that opens it, its scrollback paged back from the
/// newest record, a resync from a seq, and its prompt index.
async fn app_reads(root: &Path, id: &str) -> Value {
    let cfg = config();
    let hub = crate::hub::Hub::new(cfg.clone(), crate::store::open(&cfg.store, root).unwrap());
    let mut client = Client::connect(&hub).await;
    let open = client
        .result(
            method::MUX_ATTACH,
            json!({"sessionId": id, "limit": 60, "eventStream": true, "waitLogs": false}),
        )
        .await;
    let mut scrollback = Vec::new();
    let mut before = open["events"][0]["seq"].as_u64().expect("the open page holds records");
    loop {
        let page = client
            .result(method::MUX_EVENTS, json!({"sessionId": id, "beforeSeq": before, "limit": 50}))
            .await;
        let events = page["events"].as_array().cloned().unwrap_or_default();
        let Some(first) = events.first().and_then(|e| e["seq"].as_u64()) else { break };
        scrollback.push(json!(events));
        before = first;
    }
    let resync = client
        .result(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 123, "limit": 100}))
        .await;
    let resync_late = client
        .result(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 777, "limit": 5000}))
        .await;
    let prompts =
        client.result(method::MUX_EVENTS, json!({"sessionId": id, "promptIndex": true})).await;
    hub.shutdown_all().await;
    json!({
        "open": {"events": open["events"], "hasMore": open["hasMore"], "lastSeq": open["lastSeq"]},
        "scrollback": scrollback,
        "resync": resync["events"],
        "resyncLate": resync_late["events"],
        "prompts": prompts["events"],
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_log_compressed_by_plain_zstd_opens_as_the_plain_log_did() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-zst-open-{}", uuid::Uuid::now_v7())));
    let id = "archived-zst";
    write_chat(&root.0, id, 450);
    let plain = app_reads(&root.0, id).await;
    assert_eq!(plain["resync"].as_array().map(Vec::len), Some(100), "{}", plain["resync"]);
    assert!(plain["scrollback"].as_array().is_some_and(|p| p.len() > 3));

    let compressed = compress_like_cleanup(&root.0, id);
    assert!(compressed >= 3, "the log is several segments: {compressed}");
    let after = app_reads(&root.0, id).await;
    assert_eq!(after["open"], plain["open"], "the page that opens the chat");
    assert_eq!(after["scrollback"], plain["scrollback"], "its scrollback");
    assert_eq!(after["resync"], plain["resync"], "a resync from seq 123");
    assert_eq!(after["resyncLate"], plain["resyncLate"], "a resync from seq 777");
    assert_eq!(after["prompts"], plain["prompts"], "its prompt index");
    // Read only: the compressed segments are as the cleanup left them.
    let events = root.0.join("sessions").join(id).join("events");
    let names: Vec<String> = std::fs::read_dir(&events)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".ndjson") || n.ends_with(".ndjson.zst"))
        .collect();
    assert!(names.iter().all(|n| n.ends_with(".zst")), "{names:?}");
}
