//! `_acpmux/watch {rowPatch: true}` (`row_patch.rs`): a row change goes as only its changed fields,
//! and the rows a client builds from the patches are the full rows a plain watcher gets.
//!
//! An idle desktop, 2026-11-19: about 3.5 MB/s from acpmux to the app with nobody typing, each
//! chat pane's watch getting every row change as the whole ~4 KB row (`server::deliver`), where a
//! background command's update changed four counters of it.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// `rpc::method::MUX_SESSION_PATCH`.
const SESSION_PATCH: &str = "_acpmux/session_patch";

fn hub_of(n: usize) -> (Arc<crate::hub::Hub>, Vec<Arc<crate::hub::Session>>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let sessions = (0..n)
        .map(|i| {
            let meta: crate::store::SessionMeta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": format!("rp-{i:04}"),
                "name": format!("a chat about the row patch number {i}"), "harness": "claude",
                "family": "claude", "cwd": "/home/someone/Projects/checkouts/some-repo/lane",
                "status": "idle", "createdAt": 1, "updatedAt": i + 1,
                "preview": "A reply long enough to look like the last thing an agent said in a real chat, \
                            which the list row carries in full and a change of a counter does not touch.",
            }))
            .unwrap();
            hub.insert_test_session(meta)
        })
        .collect();
    (hub, sessions)
}

struct Watcher {
    input: mpsc::Sender<String>,
    out: mpsc::Receiver<String>,
    next_id: u64,
}

impl Watcher {
    async fn open(hub: &Arc<crate::hub::Hub>, watch: Value) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (output, out) = mpsc::channel(65_536);
        tokio::spawn(super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::Origin::Local,
        ));
        let mut w = Self { input, out, next_id: 1 };
        let hello =
            json!({"protocolVersion": 1, "clientInfo": {"name": "row-patch-test", "version": "0"}});
        w.call(method::INITIALIZE, hello).await;
        w.call(method::MUX_WATCH, watch).await;
        w
    }

    /// Sends a request and waits for its answer; every notice before it is dropped.
    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = self.out.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    assert!(reply.get("error").is_none(), "{reply}");
                    return reply;
                }
            }
        })
        .await
        .expect("the request is answered")
    }

    /// The row notices (`session_changed` and `session_patch`) that arrive until `want` of them
    /// did, as (line bytes, message).
    async fn rows(&mut self, want: usize) -> Vec<(usize, Value)> {
        let mut got = Vec::new();
        let waited = tokio::time::timeout(Duration::from_secs(30), async {
            while got.len() < want {
                let line = self.out.recv().await.unwrap();
                let msg: Value = serde_json::from_str(&line).unwrap();
                if msg["method"] == method::MUX_SESSION_CHANGED || msg["method"] == SESSION_PATCH {
                    got.push((line.len() + 1, msg));
                }
            }
        })
        .await;
        assert!(waited.is_ok(), "{want} row notices arrive (got {})", got.len());
        got
    }
}

/// A background command's update, as `hub/processes.rs` logs one.
fn command_update(hub: &crate::hub::Hub, s: &crate::hub::Session, round: usize) {
    hub.append(
        s,
        "mux",
        "process_update",
        json!({"process": {"id": format!("p-{}", s.id), "state": "running", "command": "cargo build", "bytes": round * 100}}),
    );
}

/// The client's side of the patches (`webviews/.../rowPatch.ts`): the last row it holds of each
/// chat, a patch laid over it.
#[derive(Default)]
struct Held(HashMap<String, Value>);

impl Held {
    /// The full row `msg` means, as the client builds it.
    fn take(&mut self, msg: &Value) -> Value {
        let p = &msg["params"];
        let key = format!(
            "{}\u{1}{}",
            p["peer"].as_str().unwrap_or(""),
            p["sessionId"].as_str().unwrap()
        );
        if msg["method"] == method::MUX_SESSION_CHANGED {
            let row = p["session"].clone();
            if p["kind"] == "purged" {
                self.0.remove(&key);
            } else {
                self.0.insert(key, row.clone());
            }
            return row;
        }
        let base = self.0.get(&key).unwrap_or_else(|| panic!("a patch of {key} with no row held"));
        let mut row: Map<String, Value> = base.as_object().unwrap().clone();
        for (k, v) in p["patch"].as_object().unwrap() {
            row.insert(k.clone(), v.clone());
        }
        for k in p["unset"].as_array().into_iter().flatten() {
            row.remove(k.as_str().unwrap());
        }
        let row = Value::Object(row);
        self.0.insert(key, row.clone());
        row
    }
}

/// The next `n` row notices of both watchers: the rows `patched` builds equal `plain`'s.
async fn check(
    plain: &mut Watcher,
    patched: &mut Watcher,
    held: &mut Held,
    patches: &mut usize,
    n: usize,
) {
    let want = plain.rows(n).await;
    let got = patched.rows(n).await;
    for ((_, whole), (_, part)) in want.iter().zip(&got) {
        assert_eq!(whole["params"]["sessionId"], part["params"]["sessionId"]);
        assert_eq!(whole["params"]["listSeq"], part["params"]["listSeq"]);
        assert_eq!(whole["params"]["kind"], part["params"]["kind"]);
        if part["method"] == SESSION_PATCH {
            *patches += 1;
            assert!(part["params"].get("session").is_none(), "{part}");
        }
        let built = held.take(part);
        assert_eq!(built, whole["params"]["session"], "row built from {part}");
    }
}

/// The idle gate: N chats each with a background command that updates once a second. A watcher
/// that asked for patches hears each update in a few hundred bytes, not the whole row; a plain
/// watcher on the same daemon still gets the whole row.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_idle_command_update_costs_a_patch_watcher_a_few_hundred_bytes() {
    const CHATS: usize = 40;
    const SECONDS: usize = 5;
    // Per update: the patch's envelope (kind, seq, listSeq, the id) and the counters it changes.
    // The whole row here is ~1.5 KB; ~4 KB on a real desktop.
    const PATCH_BYTES_PER_UPDATE: usize = 450;
    let (hub, sessions) = hub_of(CHATS);
    let mut plain = Watcher::open(&hub, json!({"enabled": true, "limit": 1})).await;
    let mut patched =
        Watcher::open(&hub, json!({"enabled": true, "limit": 1, "rowPatch": true})).await;
    // The first sight of each chat is its whole row, on both.
    for s in &sessions {
        command_update(&hub, s, 0);
    }
    plain.rows(CHATS).await;
    patched.rows(CHATS).await;
    for round in 1..=SECONDS {
        for s in &sessions {
            command_update(&hub, s, round);
        }
    }
    let n = CHATS * SECONDS;
    let full: usize = plain.rows(n).await.iter().map(|(b, _)| b).sum();
    let bytes: usize = patched.rows(n).await.iter().map(|(b, _)| b).sum();
    let per_second = bytes / SECONDS;
    eprintln!(
        "ROW-PATCH idle chats={CHATS} full_per_update={} patch_per_update={} patch_B_per_s={per_second} full_B_per_s={}",
        full / n,
        bytes / n,
        full / SECONDS
    );
    assert!(
        bytes / n <= PATCH_BYTES_PER_UPDATE,
        "a command update cost a patch watcher {} bytes (whole row {}); at most {PATCH_BYTES_PER_UPDATE}",
        bytes / n,
        full / n
    );
    assert!(per_second <= CHATS * PATCH_BYTES_PER_UPDATE, "{per_second} B/s for {CHATS} chats");
    assert!(bytes * 3 <= full, "patches {bytes} B against whole rows {full} B");
}

/// The rows a patch watcher builds equal the whole rows a plain watcher gets after every change:
/// counters, a field that comes and goes (`title`), a status, a new chat, and a watch asked again
/// mid-way (its rows start whole again). A lag's whole rows: `row_patch.rs` unit tests.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rows_built_from_patches_equal_the_whole_rows() {
    let (hub, sessions) = hub_of(4);
    let mut plain = Watcher::open(&hub, json!({"enabled": true, "limit": 1})).await;
    let mut patched =
        Watcher::open(&hub, json!({"enabled": true, "limit": 1, "rowPatch": true})).await;
    let mut held = Held::default();
    let mut patches = 0;
    let (a, b) = (&sessions[0], &sessions[1]);
    command_update(&hub, a, 1);
    command_update(&hub, b, 1);
    check(&mut plain, &mut patched, &mut held, &mut patches, 2).await;
    command_update(&hub, a, 2);
    hub.append(a, "mux", "status", json!({"status": "running"}));
    // A field that comes: the title.
    hub.edit_test_meta(b, |m| m.title = Some("A title the namer gave".into()));
    hub.list_cursor();
    check(&mut plain, &mut patched, &mut held, &mut patches, 3).await;
    // ... and goes again: the patch names it in `unset`.
    hub.edit_test_meta(b, |m| m.title = None);
    hub.list_cursor();
    hub.append(a, "mux", "status", json!({"status": "idle"}));
    check(&mut plain, &mut patched, &mut held, &mut patches, 2).await;
    // The client asks for whole rows again (a reconnect's or a lag's reread): the next row of
    // each chat is whole.
    patched.call(method::MUX_WATCH, json!({"enabled": true, "limit": 1, "rowPatch": true})).await;
    plain.call(method::MUX_WATCH, json!({"enabled": true, "limit": 1})).await;
    command_update(&hub, a, 3);
    let whole_again = patched.rows(1).await;
    assert_eq!(whole_again[0].1["method"], method::MUX_SESSION_CHANGED, "{:?}", whole_again[0]);
    held.take(&whole_again[0].1);
    plain.rows(1).await;
    command_update(&hub, a, 4);
    command_update(&hub, b, 4);
    check(&mut plain, &mut patched, &mut held, &mut patches, 2).await;
    // A new chat: its first row is whole.
    let c = hub.insert_test_session(
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "rp-new", "name": "new", "harness": "claude",
            "cwd": "/w", "status": "idle", "createdAt": 2, "updatedAt": 99,
        }))
        .unwrap(),
    );
    command_update(&hub, &c, 1);
    command_update(&hub, &c, 2);
    check(&mut plain, &mut patched, &mut held, &mut patches, 2).await;
    assert!(patches >= 5, "the test saw {patches} patches");
}
