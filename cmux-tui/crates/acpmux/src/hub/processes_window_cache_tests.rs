//! Session Info's process windows come from the tag cache (`WindowCache`): a reopen reads the
//! cached window, not the whole history, and each process record the chat logs makes it stale.
use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

fn ended(index: usize) -> Process {
    serde_json::from_value(json!({
        "id": format!("chat/task-{index}"),
        "sessionId": "chat",
        "toolCallId": format!("call-{index}"),
        "taskId": format!("task-{index}"),
        "harness": "claude",
        "command": format!("cargo test -p crate-{index}"),
        "cwd": "/tmp",
        "startedAt": index,
        "endedAt": index + 1,
        "state": "exited",
        "origin": "background"
    }))
    .unwrap()
}

/// A hub with one chat on the fake agent.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn ids(reply: &Value) -> Vec<String> {
    reply["processes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap().to_owned())
        .collect()
}

fn median_ms(mut runs: Vec<f64>) -> f64 {
    runs.sort_by(f64::total_cmp);
    runs[runs.len() / 2]
}

/// The god chat's shape (28,408 shells): the first read walks the table, a reopen reads the
/// cached window, and a logged process update makes the next read take the table again.
#[tokio::test(flavor = "multi_thread")]
async fn a_reopen_reads_the_cached_window_and_a_logged_process_makes_it_stale() {
    const SHELLS: usize = 28_408;
    let (hub, session) = chat().await;
    {
        let mut table = ProcessTable { loaded: true, ..ProcessTable::default() };
        for index in 0..SHELLS {
            table.upsert(ended(index));
        }
        *session.processes.lock().unwrap() = table;
    }
    let within = Some(60_000);
    let mut cold = Vec::new();
    let mut warm = Vec::new();
    let mut first = Value::Null;
    for _ in 0..9 {
        hub.process_windows.invalidate(InfoTag::Processes(session.id.clone()));
        let start = std::time::Instant::now();
        first = hub.list_recent_processes(&session, 500, within).unwrap();
        cold.push(start.elapsed().as_secs_f64() * 1e3);
        let start = std::time::Instant::now();
        let again = hub.list_recent_processes(&session, 500, within).unwrap();
        warm.push(start.elapsed().as_secs_f64() * 1e3);
        assert_eq!(again, first, "the cached window answers as the table does");
    }
    let (cold, warm) = (median_ms(cold), median_ms(warm));
    eprintln!("Session Info window at {SHELLS} shells: cold {cold:.2} ms, warm {warm:.2} ms");
    assert_eq!(first["omitted"], json!(SHELLS - 500));
    assert_eq!(ids(&first).len(), 500);
    assert!(
        warm < cold,
        "a cached read is cheaper than a walk: cold {cold:.2} ms, warm {warm:.2} ms"
    );

    // One more shell ends, logged as the daemon logs it: the cached window is stale.
    let next = ended(SHELLS);
    let logged = {
        let mut table = session.processes.lock().unwrap();
        table.upsert(next);
        let at = table.processes.len() - 1;
        table.log(at)
    };
    hub.append(&session, "mux", "process_update", json!({"process": logged}));
    let after = hub.list_recent_processes(&session, 500, within).unwrap();
    assert!(ids(&after).contains(&format!("chat/task-{SHELLS}")), "the logged shell is read");
    assert_eq!(after["omitted"], json!(SHELLS + 1 - 500));

    // An older page is cached the same way, and the same record kinds make it stale.
    let before = first["endedBefore"].as_u64().unwrap();
    let older = hub.list_older_processes(&session, 200, before).unwrap();
    assert_eq!(hub.list_older_processes(&session, 200, before), older).unwrap();
    assert_eq!(ids(&older).len(), 200);
}

/// A host move reads the table again from the log: the cached windows of that chat are stale.
#[tokio::test(flavor = "multi_thread")]
async fn a_rebuilt_table_makes_its_windows_stale() {
    let (hub, session) = chat().await;
    {
        let mut table = ProcessTable { loaded: true, ..ProcessTable::default() };
        table.upsert(ended(0));
        *session.processes.lock().unwrap() = table;
    }
    assert_eq!(ids(&hub.list_recent_processes(&session, 500, None).unwrap()), ["chat/task-0"]);
    // The log holds none of them: the table read again from it is empty.
    hub.rebuild_processes(&session);
    assert!(ids(&hub.list_recent_processes(&session, 500, None).unwrap()).is_empty());
}
