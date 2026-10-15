//! The background-process registry (docs/background-processes.md):
//! `_acpmux/process/list` shows the background shells Claude Code runs and
//! how each ended, `_acpmux/process/kill` stops one with Claude Code's
//! `stop_task`, and `_acpmux/process_update` tells attached clients.

use super::*;
use acpmux::server::{Origin, serve_connection_with};

const LIST: &str = "_acpmux/process/list";
const KILL: &str = "_acpmux/process/kill";
const UPDATE: &str = "_acpmux/process_update";

/// A Claude hub (fake_claude.py) under a fresh folder, with `env`.
async fn claude_hub(env: &[(&str, &str)]) -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-proc-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, c) = claude_setup(&claude, env).await;
    (hub, c, root)
}

/// A new chat that ran `said` as its first turn.
async fn chat(c: &mut TestClient, said: &str) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    id
}

/// The chat's processes from `_acpmux/process/list`.
async fn listed(c: &mut TestClient, id: &str) -> Vec<Value> {
    let r = c.request(LIST, json!({"sessionId": id})).await.unwrap();
    r["processes"].as_array().cloned().unwrap_or_else(|| panic!("no processes array: {r}"))
}

/// A process without its times, which are checked for their type.
fn shape(p: &Value) -> Value {
    assert!(p["startedAt"].is_u64(), "{p}");
    let ended = &p["endedAt"];
    assert_eq!(ended.is_u64(), p["state"] != "running", "{p}");
    let mut p = p.clone();
    let o = p.as_object_mut().unwrap();
    o.remove("startedAt");
    o.remove("endedAt");
    p
}

/// The chat's folder as acpmux recorded it.
fn chat_cwd(hub: &Arc<Hub>, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())["cwd"].clone()
}

/// The `stop_task` control requests acpmux wrote to Claude Code's stdin.
fn stop_tasks(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "claude.stdin")
        .filter(|e| e.msg.pointer("/request/subtype") == Some(&json!("stop_task")))
        .map(|e| e.msg)
        .collect()
}

/// Poll the chat's list until its first process is in `state`.
async fn until_state(c: &mut TestClient, id: &str, state: &str) -> Value {
    for _ in 0..100 {
        let list = listed(c, id).await;
        if list.first().is_some_and(|p| p["state"] == state) {
            return list[0].clone();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the process never became {state}: {:?}", listed(c, id).await);
}

/// A connection from `origin` (a remote device, a peer, the local app).
fn connection(hub: &Arc<Hub>, origin: Origin) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    TestClient { tx: in_tx, rx: out_rx, next: 0 }
}

#[tokio::test]
async fn initialize_advertises_the_process_methods() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let init = c
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    let acpmux = &init["_meta"]["acpmux"];
    let extensions = acpmux["extensions"].as_array().cloned().unwrap_or_default();
    for m in [LIST, KILL] {
        assert!(extensions.iter().any(|e| e == m), "{m} not in {extensions:?}");
    }
    let features = acpmux["features"].as_array().cloned().unwrap_or_default();
    assert!(features.iter().any(|f| f == "processes"), "{features:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A dev server Claude Code started in the background is listed running,
/// under the chat that started it and in the daemon-wide list.
#[tokio::test]
async fn process_list_shows_a_running_background_shell() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-running").await;
    let list = listed(&mut c, &id).await;
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(
        shape(&list[0]),
        json!({"id": format!("{id}/r1"), "sessionId": id, "subagentSessionId": null,
               "toolCallId": "toolu_run", "taskId": "r1", "harness": "claude",
               "command": "npm run dev", "cwd": chat_cwd(&hub, &id), "state": "running",
               "exitCode": null, "signal": null, "reason": null, "detail": null,
               "origin": "background", "outputBytes": null})
    );
    let all = c.request(LIST, json!({})).await.unwrap();
    let all = all["processes"].as_array().cloned().unwrap_or_default();
    assert!(all.iter().any(|p| p["id"] == list[0]["id"]), "{all:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Shells that ended stay listed with how they ended; a foreground shell
/// was never a background process.
#[tokio::test]
async fn process_list_shows_how_each_shell_ended() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-probe").await;
    let list: Vec<Value> = listed(&mut c, &id).await.iter().map(shape).collect();
    let common = json!({"sessionId": id, "subagentSessionId": null, "harness": "claude",
                        "cwd": chat_cwd(&hub, &id), "exitCode": null, "signal": null,
                        "origin": "background", "outputBytes": null});
    let with = |fields: Value| {
        let mut p = common.clone();
        p.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
        p
    };
    assert_eq!(
        list,
        vec![
            with(json!({"id": format!("{id}/b1"), "toolCallId": "toolu_bg1", "taskId": "b1",
                        "command": "npm run dev", "state": "killed", "reason": "agent",
                        "detail": "Stopped by the agent"})),
            with(json!({"id": format!("{id}/b2"), "toolCallId": "toolu_bg2", "taskId": "b2",
                        "command": "cargo test", "state": "exited", "reason": null,
                        "detail": "Tests passed"})),
        ]
    );
    let moved = chat(&mut c, "bg-moved").await;
    let list: Vec<Value> = listed(&mut c, &moved).await.iter().map(shape).collect();
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(list[0]["state"], "exited");
    assert_eq!(list[0]["origin"], "auto_backgrounded");
    assert_eq!(list[0]["detail"], "Build finished");
    let foreground = chat(&mut c, "fg-probe").await;
    assert_eq!(listed(&mut c, &foreground).await, Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A subagent's background shell belongs to the chat that runs the
/// subagent, and names the subagent.
#[tokio::test]
async fn a_subagents_background_shell_is_listed_under_its_chat() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "agent-bg-running").await;
    let list = listed(&mut c, &id).await;
    assert_eq!(list.len(), 1, "{list:?}");
    let p = &list[0];
    assert_eq!(p["id"], format!("{id}/r2"));
    assert_eq!(p["sessionId"], id.as_str());
    assert_eq!(p["state"], "running");
    assert_eq!(p["toolCallId"], "toolu_agrun");
    let subagent = p["subagentSessionId"].as_str().unwrap_or_else(|| panic!("{p}"));
    assert!(subagent.ends_with("/toolu_agbg"), "{subagent}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Killing a running process sends Claude Code's `stop_task` for its task;
/// the process ends killed by the person, and attached clients hear it.
#[tokio::test]
async fn kill_sends_stop_task_and_the_process_ends_killed_by_the_person() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-running").await;
    let pid = format!("{id}/r1");
    let mut other = connect(&hub).await;
    assert_eq!(other.request(KILL, json!({"processId": pid})).await.unwrap(), json!({}));
    let sent = stop_tasks(&hub, &id);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["type"], "control_request");
    assert_eq!(sent[0]["request"], json!({"subtype": "stop_task", "task_id": "r1"}));
    assert!(sent[0]["request_id"].as_str().is_some_and(|r| r.starts_with("stop-")), "{sent:?}");
    let note = c.wait_for(UPDATE, |p| p["process"]["state"] == "killed").await;
    assert_eq!(note["process"]["id"], pid.as_str());
    assert_eq!(note["process"]["reason"], "person");
    let ended = until_state(&mut c, &id, "killed").await;
    assert_eq!(ended["reason"], "person");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Claude Code may report a stopped task twice (its task_updated and its
/// task_notification): the process ends once.
#[tokio::test]
async fn a_stop_reported_twice_ends_the_process_once() {
    let (hub, mut c, root) = claude_hub(&[("FAKE_CLAUDE_STOP_NOTIFY", "1")]).await;
    let id = chat(&mut c, "bg-running").await;
    c.request(KILL, json!({"processId": format!("{id}/r1"), "signal": "term"})).await.unwrap();
    until_state(&mut c, &id, "killed").await;
    // A turn after the stop: Claude Code's lines before it are all read.
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let events = hub.events(&id, 0, 10_000).unwrap();
    let process_ends: Vec<_> = events
        .iter()
        .filter(|e| e.kind == "process_update" && e.msg["process"]["state"] != "running")
        .collect();
    assert_eq!(process_ends.len(), 1, "{process_ends:?}");
    let shell_ends: Vec<_> = events
        .iter()
        .filter(|e| e.kind == "background_task_update")
        .filter(|e| e.msg.pointer("/params/update/state") != Some(&json!("running")))
        .collect();
    assert_eq!(shell_ends.len(), 1, "{shell_ends:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A shell that finished is reported by its task_updated and then by its
/// task_notification: it ends once, with the notification's summary.
#[tokio::test]
async fn a_finished_shell_ends_once_with_its_notifications_summary() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-done-twice").await;
    let list = listed(&mut c, &id).await;
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(list[0]["state"], "exited");
    assert_eq!(list[0]["detail"], "Tests passed");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let ends: Vec<_> = events
        .iter()
        .filter(|e| e.kind == "process_update" && e.msg["process"]["state"] != "running")
        .collect();
    assert_eq!(ends.len(), 1, "{ends:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A process that already ended is not stopped again: the kill answers and
/// nothing goes to Claude Code.
#[tokio::test]
async fn killing_an_ended_process_sends_nothing() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-probe").await;
    assert_eq!(c.request(KILL, json!({"processId": format!("{id}/b2")})).await.unwrap(), json!({}));
    assert_eq!(stop_tasks(&hub, &id), Vec::<Value>::new());
    assert_eq!(listed(&mut c, &id).await[1]["state"], "exited");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn an_unknown_or_malformed_process_id_is_refused() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-running").await;
    for params in [
        json!({"processId": format!("{id}/nope")}),
        json!({"processId": "no-such-chat/r1"}),
        json!({"processId": "r1"}),
        json!({"processId": 7}),
        json!({}),
        json!({"processId": format!("{id}/r1"), "signal": "hup"}),
    ] {
        let refused = c.request(KILL, params.clone()).await;
        assert!(refused.is_err(), "{params} was not refused: {refused:?}");
    }
    assert!(c.request(LIST, json!({"sessionId": 7})).await.is_err());
    assert_eq!(stop_tasks(&hub, &id), Vec::<Value>::new());
    assert_eq!(listed(&mut c, &id).await[0]["state"], "running");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Claude Code's exit ends the shells it ran without anyone seeing how:
/// each running process becomes lost.
#[tokio::test]
async fn a_harness_exit_marks_running_processes_lost() {
    let die = std::env::temp_dir().join(format!("acpmux-proc-die-{}", uuid::Uuid::now_v7()));
    let (hub, mut c, root) = claude_hub(&[("FAKE_CLAUDE_DIE_IF", &die.to_string_lossy())]).await;
    let id = chat(&mut c, "bg-running").await;
    std::fs::write(&die, "").unwrap();
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "lost"}]}),
        )
        .await;
    let lost = until_state(&mut c, &id, "lost").await;
    assert_eq!(lost["reason"], "harness_exit");
    // With no harness left, a kill has nothing to stop.
    assert_eq!(c.request(KILL, json!({"processId": format!("{id}/r1")})).await.unwrap(), json!({}));
    assert_eq!(stop_tasks(&hub, &id), Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(&die);
    let _ = std::fs::remove_dir_all(&root);
}

/// The registry is served to this machine's clients only: a remote device
/// or a peer daemon can neither list nor kill; the local app can list.
#[tokio::test]
async fn a_web_or_peer_connection_cannot_list_or_kill_processes() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-running").await;
    let pid = format!("{id}/r1");
    for origin in [Origin::Web, Origin::Peer] {
        let mut remote = connection(&hub, origin);
        let init = json!({"protocolVersion": 1, "clientInfo": {"name": "remote"}});
        remote.request(method::INITIALIZE, init).await.unwrap();
        for (m, params) in [
            (LIST, json!({"sessionId": id})),
            (LIST, json!({})),
            (KILL, json!({"processId": pid, "sessionId": id})),
        ] {
            let refused = remote.request(m, params.clone()).await;
            assert!(refused.is_err(), "{origin:?} {m} {params}: {refused:?}");
        }
    }
    assert_eq!(stop_tasks(&hub, &id), Vec::<Value>::new());
    let mut app = connection(&hub, Origin::LocalApp);
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "app"}});
    app.request(method::INITIALIZE, init).await.unwrap();
    let r = app.request(LIST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(r["processes"][0]["id"], pid.as_str(), "{r}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Only Claude Code's processes are in the registry: a kill for a chat of
/// another harness is refused, and its list is empty.
#[tokio::test]
async fn kill_on_a_chat_that_is_not_claude_is_refused() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "acp").await;
    let refused = c.request(KILL, json!({"processId": format!("{id}/t1")})).await.unwrap_err();
    assert!(refused.contains("Claude Code"), "{refused}");
    assert_eq!(c.request(LIST, json!({"sessionId": id})).await.unwrap(), json!({"processes": []}));
    hub.shutdown_all().await;
}
