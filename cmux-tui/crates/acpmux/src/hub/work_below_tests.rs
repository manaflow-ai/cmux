//! The work below a session's turn follows its subagent tree whatever update changed it.

use super::*;
use crate::agent::Direction;
use crate::config::{Config, StoreMode};
use crate::rpc::Message;
use std::path::Path;

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

fn update(update: Value) -> Message {
    Message::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "acp-root", "update": update})),
    }
}

/// A Codex echo of the chat's own thread, before the session metadata names that thread, reads
/// as a running background subagent, so the chat works below its turn. When the metadata names
/// the root, the next update drops that phantom, and the work below ends with it even when the
/// update carries no subagent event: no end event ever comes for the root.
#[tokio::test]
async fn a_root_learned_late_ends_the_work_below_it_held() {
    let (hub, session) = chat().await;
    let root = "root-native-thread";
    session.meta.lock().unwrap().agent_session_id = None;
    let tap = hub.session_tap(&session);
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
            "_meta": {"codex": {"subagent": {"threadId": root,
              "path": "/root", "activity": "working"}}}})),
        None,
    );
    assert!(hub.work_below_since(&session).is_some(), "the echo reads as background work");

    session.meta.lock().unwrap().agent_session_id = Some(root.to_owned());
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "hi"}})),
        None,
    );
    assert_eq!(
        session.subagents.lock().unwrap().background_running(),
        0,
        "the root is not background work"
    );
    assert_eq!(hub.work_below_since(&session), None, "the phantom still holds the chat working");
    let summary = hub.session_summary(&session);
    assert!(summary["subagentsWorkingSince"].is_null(), "{summary}");
    hub.shutdown_all().await;
}

/// The sidebar hover card's count (Leo 2026-11-01: "this hover preview being able to see the #
/// of associated subagents"): the summary says how many subagents run and names the first, and
/// every change of the count is a `subagents_running` record, which watchers hear as
/// `session_changed`. Without a running turn only a background subagent still counts.
#[tokio::test]
async fn running_subagents_reach_the_summary_and_each_change_is_recorded() {
    let (hub, session) = chat().await;
    session.meta.lock().unwrap().agent_session_id = Some("acp-root".to_owned());
    let tap = hub.session_tap(&session);
    let spawn = |id: &str, name: &str, background: bool| {
        update(json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id,
            "name": name, "background": background}))
    };
    tap(Direction::In, &spawn("a", "Review the sidebar", true), None);
    tap(Direction::In, &spawn("b", "Fix the build", true), None);
    tap(Direction::In, &spawn("c", "Gallery shots", true), None);
    let summary = hub.session_summary(&session);
    assert_eq!(summary["subagentsRunning"], json!(3), "{summary}");
    assert_eq!(
        summary["subagentNames"],
        json!(["Review the sidebar", "Fix the build", "Gallery shots"]),
        "{summary}"
    );
    assert_eq!(summary["commandsRunning"], json!(0), "{summary}");

    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "b",
            "state": "completed"})),
        None,
    );
    let summary = hub.session_summary(&session);
    assert_eq!(summary["subagentsRunning"], json!(2), "{summary}");
    assert_eq!(summary["subagentNames"], json!(["Review the sidebar", "Gallery shots"]));

    let counts: Vec<Value> = hub
        .events(&session.id, 0, 256)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == super::views::SUBAGENTS_RUNNING)
        .map(|e| e.msg["count"].clone())
        .collect();
    assert_eq!(counts, vec![json!(1), json!(2), json!(3), json!(2)], "one record per change");
    hub.shutdown_all().await;
}

/// The sidebar nests a chat's subagents under its row (Leo 2026-11-19: "the nested sessions"): the
/// summary lists the latest with their states and counts every one started, and a change of the
/// list that keeps the running count (a subagent whose turn ended says it completed) is still a
/// `subagents_running` record, so watchers redraw the row.
#[tokio::test]
async fn the_latest_subagents_reach_the_summary_and_a_list_change_is_recorded() {
    let (hub, session) = chat().await;
    session.meta.lock().unwrap().agent_session_id = Some("acp-root".to_owned());
    let summary = hub.session_summary(&session);
    assert!(
        summary.get("recentSubagents").is_none() && summary.get("subagentsSeen").is_none(),
        "a chat that started none carries neither key, so its row costs what it did: {summary}"
    );
    let tap = hub.session_tap(&session);
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "a",
            "name": "Review the sidebar"})),
        None,
    );
    let summary = hub.session_summary(&session);
    assert_eq!(
        summary["recentSubagents"],
        json!([{"id": "a", "parent": null, "title": "Review the sidebar", "state": "stopped"}]),
        "no turn runs, so a foreground subagent runs no more: {summary}"
    );
    assert_eq!(summary["subagentsSeen"], json!(1), "{summary}");

    session.subagents.lock().unwrap().end_foreground();
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "a",
            "state": "completed"})),
        None,
    );
    let summary = hub.session_summary(&session);
    assert_eq!(summary["recentSubagents"][0]["state"], json!("done"), "{summary}");
    let counts: Vec<Value> = hub
        .events(&session.id, 0, 256)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == super::views::SUBAGENTS_RUNNING)
        .map(|e| e.msg["count"].clone())
        .collect();
    assert_eq!(counts, vec![json!(1), json!(0)], "the end is recorded though the count kept");
    hub.shutdown_all().await;
}

/// cmux#32727: a chat whose turn ended while a background command it started still ran (a Claude
/// background shell fetching and test-merging a branch) showed its running command and no
/// spinner in the sidebar: the summary read `done`. The status dot stays `working` while the
/// command runs. Only the dot: the command is not work below the turn, so the turn's unread mark
/// and its end notice do not wait for a dev server to exit.
#[tokio::test]
async fn a_background_command_left_running_keeps_the_dot_working() {
    let (hub, session) = chat().await;
    let shell = |state: &str| {
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "acp-root",
            "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg",
                "state": state, "command": "git fetch origin && git merge --no-commit origin/main"}}})
    };
    assert!(hub.session_summary(&session)["indicator"].is_null(), "nothing runs yet");

    let rec = hub.append(&session, "in", "background_task_update", shell("running"));
    hub.note_process(&session, &rec, None);
    let summary = hub.session_summary(&session);
    assert_eq!(summary["commandsRunning"], json!(1), "{summary}");
    assert_eq!(summary["indicator"], json!("working"), "the row spins while the command runs");
    assert_eq!(hub.work_below_since(&session), None, "the unread mark does not wait on it");
    assert!(
        hub.events(&session.id, 0, 10_000).unwrap().iter().any(|e| e.kind == "process_update"),
        "watchers hear the change as session_changed (`process_update`)"
    );

    let rec = hub.append(&session, "in", "background_task_update", shell("completed"));
    hub.note_process(&session, &rec, None);
    let summary = hub.session_summary(&session);
    assert_eq!(summary["commandsRunning"], json!(0), "{summary}");
    assert_ne!(summary["indicator"], json!("working"), "no spinner once the command ends");
    hub.shutdown_all().await;
}

/// Leo's relaunch (2026-11-22 21:40Z): a daemon rebuilding a chat's subagents from its log ended
/// every helper a harness exit had left running as `disconnected`, now, though Claude's logged
/// notification said it completed. It ends as notified, dated when it ended, marked recovered,
/// and a later rebuild of the same log writes no second end.
#[tokio::test]
async fn a_rebuild_ends_a_notified_helper_completed_at_its_notification_once() {
    let (hub, session) = chat().await;
    session.meta.lock().unwrap().agent_session_id = Some("acp-root".to_owned());
    let rpc = |u: Value| {
        json!({"jsonrpc": "2.0", "method": crate::rpc::method::SESSION_UPDATE,
            "params": {"sessionId": "acp-root", "update": u}})
    };
    // A day before the relaunch.
    let day_ago = now_ms() - 86_400_000;
    let (spawned, notified) = (day_ago, day_ago + 60_000);
    let log = |dir: &str, kind: &str, msg: Value, at: u64| {
        hub.append_at(&session, dir, kind, msg, None, Some(at));
    };
    log(
        "in",
        "subagent_spawned",
        rpc(json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "h",
            "name": "Helper", "background": true})),
        spawned,
    );
    log(
        "in",
        "subagent_progress",
        rpc(json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "h",
            "agentId": "agent-h"})),
        spawned + 1_000,
    );
    log(
        "in",
        "claude.system.task_notification",
        json!({"type": "system", "subtype": "task_notification", "task_id": "agent-h",
            "status": "completed"}),
        notified,
    );
    log("mux", "exited", json!({}), notified + 1_000);

    let tree = hub.subagents_from_log(&session, "inc");
    hub.seed_subagents(&session, tree);
    let ends: Vec<Value> = hub
        .events(&session.id, 0, 256)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "subagent_state_update")
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .collect();
    assert_eq!(ends.len(), 1, "{ends:?}");
    assert_eq!(ends[0]["state"], json!("completed"), "{ends:?}");
    assert_eq!(ends[0]["reason"], json!("harness_exit"));
    assert_eq!(ends[0]["recovered"], json!(true));
    assert_eq!(ends[0]["endedAt"], json!(notified));
    assert_eq!(ends[0]["startedAt"], json!(spawned));

    assert!(
        hub.subagents_from_log(&session, "inc").take_orphans().is_empty(),
        "a rebuild ends it once"
    );
    hub.shutdown_all().await;
}

/// Measures a relaunch over a real chat's log (scrubbed to its subagent records, Claude's task
/// lines and the harness starts and exits): `ACPMUX_EXPIRY_FIXTURE` names its gzipped ndjson
/// (`{at, dir, kind, msg}` per line), `ACPMUX_EXPIRY_ROOT` its agent session id. Prints the ends a
/// daemon rebuilding its subagents writes: how many, how many read `disconnected` though Claude's
/// notification said the run ended (`false_disconnected`), and how many are dated now.
#[tokio::test]
#[ignore = "measurement over a fixture named by ACPMUX_EXPIRY_FIXTURE"]
async fn measure_relaunch_expiry_ends() {
    use std::io::BufRead;
    let Ok(path) = std::env::var("ACPMUX_EXPIRY_FIXTURE") else { return };
    let (hub, session) = chat().await;
    session.meta.lock().unwrap().agent_session_id = std::env::var("ACPMUX_EXPIRY_ROOT").ok();
    let file = std::fs::File::open(&path).unwrap();
    let reader = std::io::BufReader::new(flate2::read::GzDecoder::new(file));
    let mut notified = HashSet::new();
    for line in reader.lines() {
        let r: Value = serde_json::from_str(&line.unwrap()).unwrap();
        let (at, dir, kind) =
            (r["at"].as_u64().unwrap(), r["dir"].as_str().unwrap(), r["kind"].as_str().unwrap());
        if kind == "claude.system.task_notification"
            && let Some(task) = r["msg"]["task_id"].as_str()
        {
            notified.insert(task.to_owned());
        }
        hub.append_at(&session, dir, kind, r["msg"].clone(), None, Some(at));
    }
    let seq = hub.events(&session.id, 0, usize::MAX).unwrap().last().map(|e| e.seq).unwrap_or(0);
    let now = now_ms();
    let tree = hub.subagents_from_log(&session, "inc");
    hub.seed_subagents(&session, tree);
    let ends: Vec<Value> = hub
        .events(&session.id, seq, usize::MAX)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "subagent_state_update")
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .collect();
    let disconnected = ends.iter().filter(|e| e["state"] == json!("disconnected")).count();
    let false_disconnected = ends
        .iter()
        .filter(|e| e["state"] == json!("disconnected"))
        .filter(|e| e["agentId"].as_str().is_some_and(|a| notified.contains(a)))
        .count();
    let dated_now =
        ends.iter().filter(|e| e["endedAt"].as_u64().is_none_or(|at| at + 60_000 >= now)).count();
    let zero = ends
        .iter()
        .filter(|e| e["endedAt"].as_u64().zip(e["startedAt"].as_u64()).is_none_or(|(a, b)| a <= b))
        .count();
    let mut by_state = std::collections::BTreeMap::<String, usize>::new();
    for e in &ends {
        *by_state.entry(format!("{}/{}", e["state"], e["reason"])).or_default() += 1;
    }
    let again = hub.subagents_from_log(&session, "inc").take_orphans().len();
    println!(
        "EXPIRY_MEASURE fixture={path} relaunch_ends={} false_disconnected={false_disconnected} \
         disconnected={disconnected} dated_now={dated_now} zero_or_unknown_duration={zero} \
         second_rebuild_orphans={again} by={by_state:?}",
        ends.len(),
    );
    hub.shutdown_all().await;
}
