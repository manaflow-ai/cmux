//! `bg_registry.rs`: the daemon's background tasks as process registry rows.

use super::*;
use crate::bg_run;

/// A hub with an idle chat named `name` and a fresh id (it ran turns before; no agent): a task
/// folder is keyed by the chat's id under the test home, which outlives a run.
fn hub_with_chat(name: &str) -> (Arc<Hub>, Arc<Session>) {
    let name = format!("{name}-{}", uuid::Uuid::new_v4().simple());
    let name = name.as_str();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": name, "name": name,
        "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve(name).unwrap();
    (hub, session)
}

/// The chat's only task: its folder, and its record with `edit` applied (written back).
fn only_task(
    hub: &Hub,
    session: &Session,
    edit: impl FnOnce(&mut bg_run::Record),
) -> (std::path::PathBuf, bg_run::Record) {
    let dir = hub.bg_dir(session);
    let mut record = hub.bg_records(&dir).tasks.first().expect("a task").record.clone();
    edit(&mut record);
    bg_run::write_record(&dir, &record).unwrap();
    (dir, record)
}

/// The chat's rows from `_acpmux/process/list`.
fn listed(hub: &Hub, session: &Session) -> Vec<Value> {
    let list = hub.list_processes_reply(Some(session));
    list["processes"].as_array().cloned().unwrap_or_default()
}

/// A task the daemon runs is a running row under the Bash call that started it, and stays out of
/// what the harness's processes decide: the chat's idle checks, and the harness's exit.
#[tokio::test]
async fn a_running_daemon_task_is_a_row_the_harness_exit_never_loses() {
    let (hub, session) = hub_with_chat("bg-row-running");
    let _lock = hub.bg_fake_running(&session, true).unwrap();
    let (dir, record) = only_task(&hub, &session, |r| {
        r.command = "codex exec review".into();
        r.description = Some("Review the commit".into());
        r.tool_call_id = Some("toolu_review".into());
        r.started_at = 1_000;
    });
    hub.bg_publish(&session, &dir, &record);
    let rows = listed(&hub, &session);
    assert_eq!(rows.len(), 1, "{rows:?}");
    let row = &rows[0];
    assert_eq!(row["id"], format!("{}/{}", session.id, record.id));
    assert_eq!(row["state"], "running");
    assert_eq!(row["toolCallId"], "toolu_review");
    assert_eq!(row["description"], "Review the commit");
    assert_eq!(row["daemonTask"], true);
    assert_eq!(row["origin"], "daemon");
    assert_eq!(hub.running_processes(&session), 0, "a daemon task never keeps the chat awake");
    hub.processes_lost(&session, crate::hub::processes::HARNESS_EXIT);
    assert_eq!(listed(&hub, &session)[0]["state"], "running", "it outlives the harness");
    // The same task again logs nothing new.
    let before = hub.process_table(&session).snapshot().len();
    hub.bg_publish(&session, &dir, &record);
    assert_eq!(hub.process_table(&session).snapshot().len(), before);
}

/// A runner that died without a word: the next listing ends its row `lost`, and the end is in the
/// chat's log, so a daemon that reads the log again (a restart) lists it ended too.
#[tokio::test]
async fn a_task_whose_runner_died_is_never_running_forever() {
    let (hub, session) = hub_with_chat("bg-row-lost");
    let lock = hub.bg_fake_running(&session, false).unwrap();
    let (dir, record) = only_task(&hub, &session, |r| r.command = "sleep 999".into());
    hub.bg_publish(&session, &dir, &record);
    assert_eq!(listed(&hub, &session)[0]["state"], "running");
    drop(lock);
    let row = listed(&hub, &session).remove(0);
    assert_eq!(row["state"], "lost", "{row}");
    assert!(row["endedAt"].as_u64().is_some(), "{row}");
    // Every later look (a watch, a daemon start) reads it `lost` at that time: it ended once.
    hub.bg_ended(&dir, &session.id, &record.id);
    hub.bg_publish(&session, &dir, &record);
    assert_eq!(listed(&hub, &session)[0]["endedAt"], row["endedAt"], "logged once");
    hub.rebuild_processes(&session);
    assert_eq!(listed(&hub, &session)[0]["state"], "lost", "the end was logged");
}

/// How a task ended reads as the registry's words: exit 0 finished, another exit failed, a stop
/// stopped (`killed`), with its summary.
#[tokio::test]
async fn an_ended_task_says_how_it_ended() {
    for (code, stopped, state) in
        [(0, false, "exited"), (2, false, "failed"), (143, true, "killed")]
    {
        let (hub, session) = hub_with_chat(&format!("bg-row-end-{code}"));
        let lock = hub.bg_fake_running(&session, false).unwrap();
        let (dir, record) = only_task(&hub, &session, |r| r.command = "make test".into());
        hub.bg_publish(&session, &dir, &record);
        let (_, record) = only_task(&hub, &session, |r| {
            r.ended_at = Some(r.started_at + 5_000);
            r.exit_code = Some(code);
            r.stopped = stopped;
        });
        drop(lock);
        hub.bg_ended(&dir, &session.id, &record.id);
        let row = listed(&hub, &session).remove(0);
        assert_eq!(row["state"], state, "{row}");
        assert_eq!(row["endedAt"], record.ended_at.unwrap());
        assert!(row["detail"].as_str().is_some_and(|d| !d.is_empty()), "{row}");
    }
}

/// A workflow's machine task (a stable id and its claim) shows in its workflow, never as a row.
#[tokio::test]
async fn a_workflow_machine_task_is_no_row() {
    let (hub, session) = hub_with_chat("bg-row-workflow");
    let _lock = hub.bg_fake_running(&session, false).unwrap();
    let (dir, record) = only_task(&hub, &session, |_| {});
    std::fs::write(dir.join(format!("{}.claim", record.id)), b"cmd").unwrap();
    hub.bg_publish(&session, &dir, &record);
    assert!(listed(&hub, &session).is_empty());
}

/// The harness's own shell under the same tool call keeps a row of its own: its updates never
/// change the daemon task's.
#[tokio::test]
async fn a_harness_shell_never_takes_a_daemon_tasks_row() {
    let (hub, session) = hub_with_chat("bg-row-shared-call");
    let _lock = hub.bg_fake_running(&session, false).unwrap();
    let (dir, record) = only_task(&hub, &session, |r| r.tool_call_id = Some("toolu_x".into()));
    hub.bg_publish(&session, &dir, &record);
    let params = json!({"update": {"toolCallId": "toolu_x", "taskId": "b1", "state": "completed",
        "command": "ls"}});
    let changed = hub.process_table(&session).fold(&session, &params, 5, None);
    assert!(changed.is_some());
    let rows = listed(&hub, &session);
    assert_eq!(rows.len(), 2, "{rows:?}");
    let daemon = rows.iter().find(|r| r["daemonTask"] == true).unwrap();
    assert_eq!(daemon["state"], "running");
}

/// The runner writes its end, then lets go of its lock: a look between the two read it `lost`.
/// The end it wrote replaces that `lost`, and nothing replaces the end.
#[tokio::test]
async fn a_written_end_replaces_a_lost_read_before_it() {
    let (hub, session) = hub_with_chat("bg-row-late-end");
    let lock = hub.bg_fake_running(&session, false).unwrap();
    let (dir, record) = only_task(&hub, &session, |r| r.command = "true".into());
    hub.bg_publish(&session, &dir, &record);
    drop(lock);
    assert_eq!(listed(&hub, &session)[0]["state"], "lost");
    let (_, record) = only_task(&hub, &session, |r| {
        r.ended_at = Some(r.started_at + 10);
        r.exit_code = Some(0);
    });
    hub.bg_ended(&dir, &session.id, &record.id);
    let row = listed(&hub, &session).remove(0);
    assert_eq!(row["state"], "exited", "{row}");
    assert_eq!(row["endedAt"], record.ended_at.unwrap());
    let (_, record) = only_task(&hub, &session, |r| r.exit_code = Some(9));
    hub.bg_ended(&dir, &session.id, &record.id);
    assert_eq!(listed(&hub, &session)[0]["state"], "exited", "an end never changes");
}

/// A row whose record is gone (its folder purged away) while its row says running ends `lost` at
/// the next listing; a record that is there keeps it running.
#[tokio::test]
async fn a_listing_ends_a_row_whose_task_is_gone() {
    let (hub, session) = hub_with_chat("bg-row-gone");
    let _lock = hub.bg_fake_running(&session, false).unwrap();
    let (dir, record) = only_task(&hub, &session, |_| {});
    hub.bg_publish(&session, &dir, &record);
    assert_eq!(listed(&hub, &session)[0]["state"], "running");
    std::fs::remove_file(dir.join(format!("{}.json", record.id))).unwrap();
    assert_eq!(listed(&hub, &session)[0]["state"], "lost");
}

/// `process/tail` of a daemon task reads its spool, in the tail's shape; while it runs the read
/// is never the end.
#[tokio::test]
async fn a_daemon_tasks_tail_reads_its_spool() {
    let (hub, session) = hub_with_chat("bg-row-tail");
    let _lock = hub.bg_fake_running(&session, false).unwrap();
    let (dir, record) = only_task(&hub, &session, |_| {});
    hub.bg_publish(&session, &dir, &record);
    let id = format!("{}/{}", session.id, record.id);
    let tail = hub.tail_process(&id, None, None).await.unwrap();
    assert_eq!(tail["eof"], false, "{tail}");
    assert!(tail["data"].is_string() && tail["nextByte"].is_u64(), "{tail}");
}
