//! A quiet watched transcript costs the daemon nothing per watch (Leo 2026-11-04: "never ...
//! acceptable ... linear time growth degradation"): the timer wakeups and blocking hops of a quiet
//! minute are the same for 1 and for 100 watched chats, and a line the other app appends after the
//! quiet minute still shows within a few seconds.

use super::super::Hub;
use super::idle_cost;
use crate::store::Watching;
use serde_json::json;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

fn home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("acpmux-watch-idle-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

/// A hub holding `n` idle chats, `w0` to `w{n-1}`.
fn hub(home: &Path, n: usize) -> Arc<Hub> {
    let cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"codex": {"argv": ["codex"]}},
        "defaultHarness": "codex", "store": {"mode": "memory"}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, home).unwrap();
    for i in 0..n {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("w{i}"), "name": format!("w{i}"),
            "harness": "codex", "cwd": home, "status": "idle",
            "createdAt": 1, "updatedAt": 1, "agentSessionId": format!("s{i}")
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    Hub::new(cfg, store)
}

fn offset(hub: &Hub, id: &str) -> u64 {
    hub.resolve(id).unwrap().meta().watching.map_or(0, |w| w.offset)
}

/// (wakeups, blocking hops) of `n` watches over a quiet minute; asserts that a line appended
/// after it shows within 3 s.
async fn quiet_minute(n: usize) -> (u64, u64) {
    let home = home(&format!("n{n}"));
    let hub = hub(&home, n);
    let line = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"noop\"}}\n";
    for i in 0..n {
        let file = home.join(format!("rollout-{i}.jsonl"));
        std::fs::write(&file, line).unwrap();
        let session = hub.resolve(&format!("w{i}")).unwrap();
        session.meta.lock().unwrap().watching = Some(Watching {
            family: "codex".to_owned(),
            file,
            offset: 0,
            codex_items: false,
            open: None,
        });
        hub.start_watch(&session);
    }
    // Every watch reads its transcript, then waits for more.
    tokio::time::timeout(Duration::from_secs(20), async {
        while (0..n).any(|i| offset(&hub, &format!("w{i}")) < line.len() as u64) {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the watches read their transcripts");
    tokio::time::sleep(Duration::from_secs(5)).await;
    idle_cost::take();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let cost = idle_cost::take();

    // The other app appends a line: it still shows promptly after the quiet minute.
    let file = home.join("rollout-0.jsonl");
    std::fs::OpenOptions::new()
        .append(true)
        .open(&file)
        .unwrap()
        .write_all(line.as_bytes())
        .unwrap();
    let len = std::fs::metadata(&file).unwrap().len();
    let appended = tokio::time::Instant::now();
    tokio::time::timeout(Duration::from_secs(3), async {
        while offset(&hub, "w0") < len {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("a line appended after a quiet minute shows within 3 s");
    eprintln!("{n} watches: appended line shown after {:?}", appended.elapsed());

    for i in 0..n {
        hub.resolve(&format!("w{i}")).unwrap().meta.lock().unwrap().watching = None;
    }
    // The watches see they ended and stop.
    tokio::time::sleep(Duration::from_secs(5)).await;
    let after = idle_cost::take();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let ended = idle_cost::take();
    assert_eq!(ended, (0, 0), "{n} ended watches still wake: {ended:?} (stopping: {after:?})");
    let _ = std::fs::remove_dir_all(home);
    cost
}

#[tokio::test(start_paused = true)]
async fn quiet_watches_cost_the_same_for_1_and_100() {
    let one = quiet_minute(1).await;
    let hundred = quiet_minute(100).await;
    eprintln!("quiet minute (wakeups, blocking hops): 1 watch {one:?}, 100 watches {hundred:?}");
    assert!(
        hundred.0 <= one.0 + 2 && hundred.1 <= one.1 + 2,
        "a quiet minute's cost grows with the watched chats: 1 watch {one:?}, 100 watches \
         {hundred:?} (wakeups, blocking hops)"
    );
}
