//! A registered chat a stop closed while its app ran on follows the app again
//! (`Hub::revive_registered_watch`): a coordinator chat, 2026-11-25, took one delivery per
//! 30 minutes for hours, since nothing read its transcript and no delivered prompt's turn showed.

use super::super::Hub;
use crate::store::{SessionStatus, Watching};
use serde_json::json;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const LINE: &str = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"noop\"}}\n";

fn home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("acpmux-watch-revive-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

/// A hub holding one closed watched chat `r0` at `offset` of `file`.
fn hub(home: &Path, id: &str, file: &Path, offset: u64) -> Arc<Hub> {
    let cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"codex": {"argv": ["codex"]}},
        "defaultHarness": "codex", "store": {"mode": "memory"}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, home).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "interim-coord",
        "harness": "codex", "cwd": home, "status": "closed",
        "createdAt": 1, "updatedAt": 1, "agentSessionId": "s0"
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve(id).unwrap();
    session.meta.lock().unwrap().watching = Some(Watching {
        family: "codex".to_owned(),
        file: file.to_owned(),
        offset,
        codex_items: false,
        open: None,
        ..Default::default()
    });
    hub
}

fn offset(hub: &Hub, id: &str) -> u64 {
    hub.resolve(id).unwrap().meta().watching.map_or(0, |w| w.offset)
}

async fn reads_to(hub: &Hub, id: &str, end: u64) {
    tokio::time::timeout(Duration::from_secs(20), async {
        while offset(hub, id) < end {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the revived watch reads what the app appends");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_closed_registered_chat_follows_its_app_again_from_the_transcript_end() {
    let home = home("revive");
    let file = home.join("rollout.jsonl");
    // Hours the chat missed while closed: far more than one read.
    let missed = LINE.repeat(usize::try_from(2 * super::MAX_READ).unwrap() / LINE.len());
    std::fs::write(&file, format!("{LINE}{missed}")).unwrap();
    let id = "01a1d28c-revive-closed-registered";
    let hub = hub(&home, id, &file, LINE.len() as u64);
    let session = hub.resolve(id).unwrap();

    // Not registered: a closed watch stays closed (a person's stop of a plain watch holds).
    assert!(!hub.revive_registered_watch(&session));
    assert_eq!(session.status(), SessionStatus::Closed);

    super::super::register::mark_registered_for_test(id);
    assert!(hub.revive_registered_watch(&session), "a closed registered chat revives");
    assert_ne!(session.status(), SessionStatus::Closed);
    let end = std::fs::metadata(&file).unwrap().len();
    assert_eq!(offset(&hub, id), end, "the missed backlog is skipped, not replayed");

    // What the app writes now shows: the delivered prompt's turn can end.
    std::fs::OpenOptions::new()
        .append(true)
        .open(&file)
        .unwrap()
        .write_all(LINE.as_bytes())
        .unwrap();
    reads_to(&hub, id, end + LINE.len() as u64).await;

    // Open already: nothing to revive, and one reader, never two.
    assert!(!hub.revive_registered_watch(&session));
    assert!(super::following().contains(id));
    hub.start_watch(&session);
    std::fs::OpenOptions::new()
        .append(true)
        .open(&file)
        .unwrap()
        .write_all(LINE.as_bytes())
        .unwrap();
    reads_to(&hub, id, end + 2 * LINE.len() as u64).await;
    assert_eq!(session.meta().watching.unwrap().offset, end + 2 * LINE.len() as u64);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_short_close_replays_what_the_chat_missed() {
    let home = home("short");
    let file = home.join("rollout.jsonl");
    std::fs::write(&file, LINE.repeat(3)).unwrap();
    let id = "01a1d28c-revive-short-close";
    let hub = hub(&home, id, &file, LINE.len() as u64);
    let session = hub.resolve(id).unwrap();
    super::super::register::mark_registered_for_test(id);
    assert!(hub.revive_registered_watch(&session));
    // Under one read behind: read from where it stopped, so nothing it missed is lost.
    reads_to(&hub, id, 3 * LINE.len() as u64).await;
}
