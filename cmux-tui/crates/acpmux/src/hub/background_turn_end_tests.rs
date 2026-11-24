//! A turn the agent runs on its own (`background_turn.rs`) always gets its `ended` record: when
//! its agent process exits (a direct agent's exit, not only a hosted one's), and when its chat
//! closes. Without it the pane's background line spun on in an idle or closed chat.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

/// A hub with one open chat whose stand-in agent is running.
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

async fn send(session: &Session, item: Inbound) {
    session.inbound_tx.send(item).await.unwrap();
    let (done, applied) = tokio::sync::oneshot::channel();
    session.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
    applied.await.unwrap();
}

fn last_seq(hub: &Hub, session: &Session) -> u64 {
    hub.events(&session.id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq)
}

/// The background-turn records logged after `seq`.
fn marks(hub: &Hub, session: &Session, seq: u64) -> Vec<Value> {
    hub.events(&session.id, seq, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == background_turn::RECORD_KIND)
        .map(|e| e.msg)
        .collect()
}

/// The agent starts work with no acpmux turn: a background turn starts.
fn start_background(hub: &Hub, session: &Session) {
    hub.background_turn_update(
        session,
        &json!({"sessionUpdate": "agent_message_chunk", "messageId": "m1",
                "content": {"type": "text", "text": "Checking the deploy"}}),
    );
}

#[tokio::test]
async fn a_direct_agents_exit_ends_its_background_turn() {
    let (hub, session) = chat().await;
    let child = session.child.lock().await.clone().expect("the stand-in agent runs");
    let seq = last_seq(&hub, &session);
    start_background(&hub, &session);
    session.harness_turn.store(true, Ordering::SeqCst);
    send(&session, Inbound::Exited { pid: child.pid, code: None, host_seq: None }).await;

    let logged = marks(&hub, &session, seq);
    assert_eq!(logged.len(), 2, "a started and an ended record: {logged:?}");
    assert_eq!(logged[0]["state"], "started");
    assert_eq!(logged[1]["state"], "ended");
    assert_eq!(logged[1]["id"], logged[0]["id"]);
    assert_eq!(logged[1]["reason"], "exit");
    assert!(!session.harness_turn.load(Ordering::SeqCst), "no turn of its own runs after its exit");
}

#[tokio::test]
async fn closing_a_chat_ends_its_background_turn_once() {
    let (hub, session) = chat().await;
    let seq = last_seq(&hub, &session);
    start_background(&hub, &session);
    hub.kill(&session, false).await.unwrap();
    // The killed agent's own exit may land after the close: it ends nothing more.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let logged = marks(&hub, &session, seq);
    let ended: Vec<_> = logged.iter().filter(|m| m["state"] == "ended").collect();
    assert_eq!(ended.len(), 1, "one ended record: {logged:?}");
    assert_eq!(ended[0]["id"], logged[0]["id"]);
    assert_eq!(session.status(), SessionStatus::Closed);
}

#[tokio::test]
async fn an_exit_with_no_background_turn_logs_none() {
    let (hub, session) = chat().await;
    let child = session.child.lock().await.clone().expect("the stand-in agent runs");
    let seq = last_seq(&hub, &session);
    send(&session, Inbound::Exited { pid: child.pid, code: None, host_seq: None }).await;
    assert!(marks(&hub, &session, seq).is_empty());
}

/// A background command's end starts a turn whose `started` record carries the command as every
/// surface draws it (`command_end.rs`): its line, its exit code and the end of its output, read
/// from the file Claude Code named, so the chat row opens to them with no read (Leo, 2026-11-24,
/// on a card that showed only "Finished": "but i couldnt... do anything?").
#[tokio::test]
async fn a_background_commands_turn_carries_its_command_exit_and_output() {
    let (hub, session) = chat().await;
    let dir = std::env::temp_dir().join(format!("acpmux-cmd-end-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("t1.output");
    std::fs::write(&file, "compiling\n12 passed\n").unwrap();
    let gone = dir.join("t2.output");
    let seq = last_seq(&hub, &session);
    let note = |id: &str, tool: &str, out: &Path, code: i64| {
        hub.background_turn_line(
            &session,
            "claude.system.task_started",
            &json!({"subtype": "task_started", "task_id": id, "tool_use_id": tool,
                    "description": format!("cargo test {id}"), "task_type": "local_bash"}),
        );
        hub.background_turn_line(
            &session,
            "claude.system.task_notification",
            &json!({"subtype": "task_notification", "task_id": id, "tool_use_id": tool,
                    "status": if code == 0 { "completed" } else { "failed" },
                    "output_file": out.to_str().unwrap(),
                    "summary": format!("Background command \"cargo test {id}\" completed (exit code {code})")}),
        );
        hub.background_turn_line(&session, "claude.system.init", &json!({}));
        start_background(&hub, &session);
        hub.background_turn_line(&session, "claude.result", &json!({}));
    };
    note("t1", "toolu_1", &file, 0);
    note("t2", "toolu_2", &gone, 3);
    let started: Vec<Value> =
        marks(&hub, &session, seq).into_iter().filter(|m| m["state"] == "started").collect();
    assert_eq!(started.len(), 2, "{started:?}");
    let end = &started[0]["cause"]["command"];
    assert_eq!(end["command"], "cargo test t1");
    assert_eq!(end["state"], "completed");
    assert_eq!(end["exitCode"], 0);
    assert_eq!(end["outputState"], "printed");
    assert_eq!(end["output"], "compiling\n12 passed");
    // Its file is gone: the command and exit still come, with nothing passed off as output.
    let end = &started[1]["cause"]["command"];
    assert_eq!(end["command"], "cargo test t2");
    assert_eq!(end["state"], "failed");
    assert_eq!(end["exitCode"], 3);
    assert_eq!(end["outputState"], "gone");
    assert!(end.get("output").is_none());
    std::fs::remove_file(file).ok();
}
