//! The background-process registry (docs/background-processes.md):
//! `_acpmux/process/list` shows the background shells Claude Code runs and
//! how each ended, `_acpmux/process/kill` stops one with Claude Code's
//! `stop_task`, `_acpmux/process/background` (Ctrl-B) moves running work
//! there with Claude Code's `background_tasks`, and `_acpmux/process_update`
//! tells attached clients.

use super::*;
use acpmux::server::{Origin, serve_connection_with};

const LIST: &str = "_acpmux/process/list";
const KILL: &str = "_acpmux/process/kill";
const TAIL: &str = "_acpmux/process/tail";
const UPDATE: &str = "_acpmux/process_update";
const BACKGROUND: &str = "_acpmux/process/background";

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
    control_requests(hub, id, "stop_task")
}

/// The control requests of `subtype` acpmux wrote to Claude Code's stdin.
fn control_requests(hub: &Arc<Hub>, id: &str, subtype: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "claude.stdin")
        .filter(|e| e.msg.pointer("/request/subtype") == Some(&json!(subtype)))
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
    for m in [LIST, KILL, TAIL, BACKGROUND] {
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

/// A kill that names its chat (the agent pane names it, and its host allows
/// only a chat in the pane's scope) stops only a process of that chat: one of
/// another chat is refused, and its Claude Code is asked nothing.
#[tokio::test]
async fn a_kill_that_names_another_chat_is_refused() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "bg-running").await;
    let other_chat = chat(&mut c, "bg-probe").await;
    let pid = format!("{id}/r1");
    let refused = c.request(KILL, json!({"processId": pid, "sessionId": other_chat})).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("not a process of")), "{refused:?}");
    assert_eq!(stop_tasks(&hub, &id), Vec::<Value>::new());
    let named = json!({"processId": pid, "sessionId": id});
    assert_eq!(c.request(KILL, named).await.unwrap(), json!({}));
    assert_eq!(stop_tasks(&hub, &id).len(), 1);
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
/// or a peer daemon can neither list, tail nor kill; the local app can list.
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
            (TAIL, json!({"processId": pid})),
            (BACKGROUND, json!({"sessionId": id})),
        ] {
            let refused = remote.request(m, params.clone()).await;
            assert!(refused.is_err(), "{origin:?} {m} {params}: {refused:?}");
        }
    }
    assert_eq!(stop_tasks(&hub, &id), Vec::<Value>::new());
    assert_eq!(control_requests(&hub, &id, "background_tasks"), Vec::<Value>::new());
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

/// A new chat running fake_claude.py's "fg-shell" turn, a Bash call in the
/// foreground until Ctrl-B moves it; returns the chat and the prompt's
/// request id once the call is on screen.
async fn fg_shell(c: &mut TestClient) -> (String, i64) {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "fg-shell"}]});
    let turn = c.send(method::SESSION_PROMPT, prompt).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["toolCallId"] == "toolu_fg").await;
    (id, turn)
}

/// Ctrl-B with no tool call sends Claude Code's `background_tasks` for
/// every foreground task; the shell it moved runs on past the turn, listed
/// as sent to the background by the person.
#[tokio::test]
async fn background_moves_the_running_work_and_lists_it_as_the_persons() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let (id, turn) = fg_shell(&mut c).await;
    let mut other = connect(&hub).await;
    let r = other.request(BACKGROUND, json!({"sessionId": id})).await.unwrap();
    assert_eq!(r, json!({"backgrounded": true}));
    let sent = control_requests(&hub, &id, "background_tasks");
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["request"], json!({"subtype": "background_tasks"}));
    assert!(sent[0]["request_id"].as_str().is_some_and(|r| r.starts_with("bg-")), "{sent:?}");
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let list = listed(&mut c, &id).await;
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(
        (&list[0]["toolCallId"], &list[0]["taskId"], &list[0]["state"], &list[0]["origin"]),
        (&json!("toolu_fg"), &json!("f1"), &json!("running"), &json!("user_backgrounded")),
        "{list:?}"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// With a tool call, only its task is asked for (`tool_use_id`); a call
/// that runs nothing in the foreground answers `backgrounded: false`.
#[tokio::test]
async fn background_of_one_tool_call_names_it() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let (id, turn) = fg_shell(&mut c).await;
    let mut other = connect(&hub).await;
    let r = other.request(BACKGROUND, json!({"sessionId": id, "toolCallId": "toolu_other"})).await;
    assert_eq!(r.unwrap(), json!({"backgrounded": false}));
    let r = other.request(BACKGROUND, json!({"sessionId": id, "toolCallId": "toolu_fg"})).await;
    assert_eq!(r.unwrap(), json!({"backgrounded": true}));
    let sent: Vec<Value> = control_requests(&hub, &id, "background_tasks")
        .iter()
        .map(|r| r["request"].clone())
        .collect();
    assert_eq!(
        sent,
        vec![
            json!({"subtype": "background_tasks", "tool_use_id": "toolu_other"}),
            json!({"subtype": "background_tasks", "tool_use_id": "toolu_fg"}),
        ]
    );
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert_eq!(listed(&mut c, &id).await[0]["origin"], "user_backgrounded");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// With no turn running nothing runs in the foreground: the answer is
/// `backgrounded: false` and Claude Code is not asked.
#[tokio::test]
async fn background_with_no_turn_running_moves_nothing() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let id = chat(&mut c, "hi").await;
    let r = c.request(BACKGROUND, json!({"sessionId": id})).await.unwrap();
    assert_eq!(r, json!({"backgrounded": false}));
    assert_eq!(control_requests(&hub, &id, "background_tasks"), Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Claude Code's refusal is the request's error, and the shell stays in the
/// foreground.
#[tokio::test]
async fn background_refused_by_claude_code_is_an_error() {
    let (hub, mut c, root) = claude_hub(&[("FAKE_CLAUDE_BACKGROUND_ERROR", "no task")]).await;
    let (id, turn) = fg_shell(&mut c).await;
    let mut other = connect(&hub).await;
    let refused = other.request(BACKGROUND, json!({"sessionId": id})).await.unwrap_err();
    assert!(refused.contains("no task"), "{refused}");
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "cancelled");
    assert_eq!(listed(&mut c, &id).await, Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The `origin` of every `running` update the chat logged for shell `tool`,
/// in order.
fn running_origins(hub: &Arc<Hub>, id: &str, tool: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "background_task_update")
        .filter_map(|e| e.msg.pointer("/params/update").cloned())
        .filter(|u| u["toolCallId"] == tool && u["state"] == "running")
        .map(|u| u["origin"].clone())
        .collect()
}

/// Ctrl-B that Claude Code never answers times out and leaves no mark: the
/// shell Claude Code then moves to the background by itself is its own
/// (`auto_backgrounded`), not the person's.
#[tokio::test]
async fn background_claude_code_never_answered_leaves_no_mark() {
    let (hub, mut c, root) = claude_hub(&[("FAKE_CLAUDE_BACKGROUND_SILENT_MS", "1500")]).await;
    hub.set_background_timeout(Duration::from_millis(300));
    let (id, turn) = fg_shell(&mut c).await;
    let mut other = connect(&hub).await;
    let refused = other.request(BACKGROUND, json!({"sessionId": id})).await.unwrap_err();
    assert!(refused.contains("in time"), "{refused}");
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert_eq!(running_origins(&hub, &id, "toolu_fg"), vec![json!("auto_backgrounded")]);
    assert_eq!(listed(&mut c, &id).await[0]["origin"], "auto_backgrounded");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A turn that ends with Ctrl-B still unanswered takes the mark with it: the
/// shell Claude Code moves to the background after the turn is its own.
#[tokio::test]
async fn background_unanswered_when_the_turn_ends_leaves_no_mark() {
    let env =
        [("FAKE_CLAUDE_BACKGROUND_SILENT_MS", "300"), ("FAKE_CLAUDE_BACKGROUND_SILENT_END", "1")];
    let (hub, mut c, root) = claude_hub(&env).await;
    // The request still waits when the shell moves: only the turn's end clears its mark.
    hub.set_background_timeout(Duration::from_secs(60));
    let (id, turn) = fg_shell(&mut c).await;
    let mut other = connect(&hub).await;
    other.send(BACKGROUND, json!({"sessionId": id})).await;
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let moved = until_state(&mut c, &id, "running").await;
    assert_eq!(moved["origin"], "auto_backgrounded", "{moved}");
    assert_eq!(running_origins(&hub, &id, "toolu_fg"), vec![json!("auto_backgrounded")]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Two Ctrl-Bs close together: Claude Code moves the shell for one and
/// answers the other `backgrounded: false`, as nothing is left in the
/// foreground. That answer leaves the moved shell the person's, whether it
/// comes after the shell moved ("moved") or before ("answered"), and so does
/// the update that names the shell's output file.
#[tokio::test]
async fn background_twice_keeps_the_moved_shell_the_persons() {
    for order in ["moved", "answered"] {
        let (hub, mut c, root) = claude_hub(&[("FAKE_CLAUDE_BACKGROUND_TWICE", order)]).await;
        let (id, turn) = fg_shell(&mut c).await;
        let (mut a, mut b) = (connect(&hub).await, connect(&hub).await);
        let first = a.send(BACKGROUND, json!({"sessionId": id})).await;
        let second = b.send(BACKGROUND, json!({"sessionId": id})).await;
        let mut answers =
            vec![a.response(first).await.0.unwrap(), b.response(second).await.0.unwrap()];
        answers.sort_by_key(Value::to_string);
        let want = vec![json!({"backgrounded": false}), json!({"backgrounded": true})];
        assert_eq!(answers, want, "{order}");
        let (answer, _) = c.response(turn).await;
        assert_eq!(answer.unwrap()["stopReason"], "end_turn", "{order}");
        let user = json!("user_backgrounded");
        assert_eq!(running_origins(&hub, &id, "toolu_fg"), vec![user.clone(), user], "{order}");
        assert_eq!(listed(&mut c, &id).await[0]["origin"], "user_backgrounded", "{order}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }
}

/// Only Claude Code has a Ctrl-B: another agent's chat is refused, and so
/// are bad params.
#[tokio::test]
async fn background_on_a_chat_that_is_not_claude_is_refused() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "acp").await;
    let refused = c.request(BACKGROUND, json!({"sessionId": id})).await.unwrap_err();
    assert!(refused.contains("Claude Code"), "{refused}");
    for params in [json!({}), json!({"sessionId": 7}), json!({"sessionId": id, "toolCallId": 7})] {
        let refused = c.request(BACKGROUND, params.clone()).await;
        assert!(refused.is_err(), "{params} was not refused: {refused:?}");
    }
    hub.shutdown_all().await;
}

/// A hub whose default harness is `cmux`, the model router's profile: Claude
/// Code (claude-stdio, fake_claude.py) under a name that is not `claude*`,
/// beside `claude-acp`, an ACP agent.
async fn router_hub() -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-proc-{}", uuid::Uuid::now_v7()));
    let claude_home = root.join("claude");
    std::fs::create_dir_all(&claude_home).unwrap();
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let fake_agent = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "cmux": {"argv": ["python3", fake_claude], "kind": "claude-stdio",
                "env": {"CLAUDE_CONFIG_DIR": claude_home}},
            "claude-acp": {"argv": ["python3", fake_agent]},
        },
        "defaultHarness": "cmux",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let c = connect(&hub).await;
    (hub, c, root)
}

/// Whether Ctrl-B can move a chat's work goes by its harness's kind, not its
/// name, and every chat's summary says so (`backgroundsWork`), so a client
/// offers Ctrl-B only where acpmux takes it. `cmux`, the model router's
/// profile, is Claude Code (claude-stdio) under a name that is not
/// `claude*`: it says yes and Ctrl-B moves its work. An ACP agent a user's
/// config named `claude-acp` says no and is refused.
#[tokio::test]
async fn a_chats_summary_says_whether_ctrl_b_moves_its_work() {
    let (hub, mut c, root) = router_hub().await;
    let new_on = |harness: &str| json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});

    let acp = c.request(method::SESSION_NEW, new_on("claude-acp")).await.unwrap();
    assert_eq!(acp["_meta"]["acpmux"]["backgroundsWork"], json!(false), "{acp}");
    let acp = acp["sessionId"].as_str().unwrap().to_owned();
    let refused = c.request(BACKGROUND, json!({"sessionId": acp})).await.unwrap_err();
    assert!(refused.contains("Claude Code"), "{refused}");

    let router = c.request(method::SESSION_NEW, new_on("cmux")).await.unwrap();
    assert_eq!(router["_meta"]["acpmux"]["backgroundsWork"], json!(true), "{router}");
    let router = router["sessionId"].as_str().unwrap().to_owned();
    for (id, moves) in [(&router, true), (&acp, false)] {
        let summary = hub.session_summary(&hub.resolve(id).unwrap());
        assert_eq!(summary["backgroundsWork"], json!(moves), "{summary}");
    }

    // The router's chat (the default harness) runs a foreground shell, and
    // Ctrl-B moves it.
    let (id, turn) = fg_shell(&mut c).await;
    assert_eq!(hub.resolve(&id).unwrap().meta().harness, "cmux");
    let mut other = connect(&hub).await;
    let r = other.request(BACKGROUND, json!({"sessionId": id})).await.unwrap();
    assert_eq!(r, json!({"backgrounded": true}));
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert_eq!(listed(&mut c, &id).await[0]["origin"], "user_backgrounded");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A chat's Ctrl-B is decided by the kind its harness started as. A config
/// being written (a mode or model pick saves it) does not turn its summary's
/// `backgroundsWork` off mid-turn, and a reload that changes its profile's
/// kind flips neither the summary nor what Ctrl-B takes.
#[tokio::test]
async fn a_chats_ctrl_b_goes_by_the_kind_it_started_as() {
    let (hub, mut c, root) = router_hub().await;
    let (id, turn) = fg_shell(&mut c).await;
    let says =
        |hub: &Arc<Hub>| hub.session_summary(&hub.resolve(&id).unwrap())["backgroundsWork"].clone();
    {
        let _saving = hub.config.write().await;
        assert_eq!(says(&hub), json!(true), "a config write hid Ctrl-B");
    }
    hub.config.write().await.harnesses.get_mut("cmux").unwrap().kind =
        acpmux::config::HarnessKind::Acp;
    assert_eq!(says(&hub), json!(true), "a reload flipped a running chat's Ctrl-B");
    let mut other = connect(&hub).await;
    let r = other.request(BACKGROUND, json!({"sessionId": id})).await.unwrap();
    assert_eq!(r, json!({"backgrounded": true}));
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// What fake_claude.py's "bg-output" shell writes to its output file.
fn shell_output() -> String {
    (0..100).map(|i| format!("line {i}\n")).collect()
}

/// A chat whose background shell writes to a file under `root`; returns the
/// chat, the process id and the file.
async fn output_chat(
    c: &mut TestClient,
    root: &std::path::Path,
) -> (String, String, std::path::PathBuf) {
    let file = root.join("tasks").join("o1.output");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let id = chat(c, &format!("bg-output: {}", file.display())).await;
    let pid = format!("{id}/o1");
    (id, pid, file)
}

/// `_acpmux/process/tail` with `params` added to the process id; the reply
/// with its data decoded.
async fn tail(c: &mut TestClient, pid: &str, params: Value) -> (Vec<u8>, Value) {
    use base64::Engine;
    let mut p = json!({"processId": pid});
    p.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let r = c.request(TAIL, p).await.unwrap();
    let data = r["data"].as_str().unwrap_or_else(|| panic!("no data: {r}"));
    let data = base64::engine::general_purpose::STANDARD.decode(data).unwrap();
    (data, r)
}

/// Tail reads the output file Claude Code names for the shell: from a byte
/// on, in pages of maxBytes, and by default the end of it; the list says
/// how long the output is.
#[tokio::test]
async fn tail_reads_the_shells_output_file_in_pages() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let (id, pid, _file) = output_chat(&mut c, &root).await;
    let out = shell_output();
    let len = out.len() as u64;
    let (data, r) = tail(&mut c, &pid, json!({})).await;
    assert_eq!(String::from_utf8(data).unwrap(), out);
    assert_eq!((r["fromByte"].clone(), r["nextByte"].clone()), (json!(0), json!(len)), "{r}");
    assert_eq!(r["eof"], false, "a running shell may write more: {r}");
    let (data, r) = tail(&mut c, &pid, json!({"fromByte": 7, "maxBytes": 7})).await;
    assert_eq!(data, b"line 1\n");
    assert_eq!((r["fromByte"].clone(), r["nextByte"].clone()), (json!(7), json!(14)), "{r}");
    let (data, r) = tail(&mut c, &pid, json!({"fromByte": r["nextByte"], "maxBytes": 7})).await;
    assert_eq!(data, b"line 2\n");
    assert_eq!(r["nextByte"], 21);
    // Without fromByte, the last maxBytes.
    let (data, r) = tail(&mut c, &pid, json!({"maxBytes": 8})).await;
    assert_eq!(data, b"line 99\n");
    assert_eq!((r["fromByte"].clone(), r["nextByte"].clone()), (json!(len - 8), json!(len)), "{r}");
    // Past the end: nothing, at the end.
    let (data, r) = tail(&mut c, &pid, json!({"fromByte": len + 50})).await;
    assert!(data.is_empty(), "{r}");
    assert_eq!(r["nextByte"], len);
    assert_eq!(listed(&mut c, &id).await[0]["outputBytes"], len);
    // The path stays in the registry: the session update, which every
    // client of the chat gets, a remote one too, does not carry it.
    let updates: Vec<_> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "background_task_update")
        .collect();
    assert!(!updates.is_empty());
    for e in &updates {
        let text = e.msg.to_string();
        assert!(!text.contains("outputFile") && !text.contains("o1.output"), "{text}");
    }
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The default is the last 64 KiB, and no page is over 1 MiB.
#[tokio::test]
async fn tail_defaults_to_the_last_64_kib_and_caps_a_page_at_1_mib() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let (_id, pid, file) = output_chat(&mut c, &root).await;
    let big = vec![b'x'; 3 << 20];
    std::fs::write(&file, &big).unwrap();
    let len = big.len() as u64;
    let (data, r) = tail(&mut c, &pid, json!({})).await;
    assert_eq!(data.len(), 64 << 10, "{r}");
    assert_eq!(
        (r["fromByte"].clone(), r["nextByte"].clone()),
        (json!(len - (64 << 10)), json!(len))
    );
    let (data, r) = tail(&mut c, &pid, json!({"fromByte": 0, "maxBytes": 10u64 << 20})).await;
    assert_eq!(data.len(), 1 << 20, "{r}");
    assert_eq!(r["nextByte"], 1u64 << 20);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Once the shell ended, tail reaches eof at the end of its output.
#[tokio::test]
async fn tail_says_eof_once_the_shell_ended_and_its_output_is_read() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let (id, pid, file) = output_chat(&mut c, &root).await;
    let ended = format!("bg-output-end: {}", file.display());
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": ended}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    until_state(&mut c, &id, "exited").await;
    let out = shell_output() + "done\n";
    let len = out.len() as u64;
    let (data, r) = tail(&mut c, &pid, json!({"fromByte": 0, "maxBytes": 7})).await;
    assert_eq!(data, b"line 0\n");
    assert_eq!(r["eof"], false, "more output is left: {r}");
    let (data, r) = tail(&mut c, &pid, json!({})).await;
    assert_eq!(String::from_utf8(data).unwrap(), out);
    assert_eq!(r["nextByte"], len);
    assert_eq!(r["eof"], true, "{r}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// An output file that is gone, or a shell Claude Code named none for, has
/// no output yet: empty, not an error.
#[tokio::test]
async fn tail_of_a_missing_output_file_is_empty() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let (_id, pid, file) = output_chat(&mut c, &root).await;
    std::fs::remove_file(&file).unwrap();
    let (data, r) = tail(&mut c, &pid, json!({})).await;
    assert!(data.is_empty(), "{r}");
    assert_eq!(
        (r["fromByte"].clone(), r["nextByte"].clone(), r["eof"].clone()),
        (json!(0), json!(0), json!(false)),
        "{r}"
    );
    let none = chat(&mut c, "bg-running").await;
    let (data, r) = tail(&mut c, &format!("{none}/r1"), json!({})).await;
    assert!(data.is_empty(), "{r}");
    assert_eq!(r["nextByte"], 0);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// An output file that is not a regular file (a FIFO no one writes) is
/// never opened: tail answers at once, empty.
#[tokio::test]
async fn tail_of_a_fifo_answers_at_once_and_empty() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let file = root.join("tasks").join("o1.output");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let made = std::process::Command::new("mkfifo").arg(&file).status().unwrap();
    assert!(made.success());
    let id = chat(&mut c, &format!("bg-output: {}", file.display())).await;
    let pid = format!("{id}/o1");
    let tailed = tokio::time::timeout(Duration::from_secs(5), tail(&mut c, &pid, json!({})));
    let tailed = tailed.await;
    if tailed.is_err() {
        // Free the read that hangs, so the test ends.
        let _ = std::fs::OpenOptions::new().write(true).open(&file);
    }
    let (data, r) = tailed.expect("tail of a FIFO hung");
    assert!(data.is_empty(), "{r}");
    assert_eq!(r["nextByte"], 0);
    assert_eq!(listed(&mut c, &id).await[0]["outputBytes"], 0);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn tail_of_an_unknown_or_malformed_process_is_refused() {
    let (hub, mut c, root) = claude_hub(&[]).await;
    let (id, pid, _file) = output_chat(&mut c, &root).await;
    for params in [
        json!({"processId": format!("{id}/nope")}),
        json!({"processId": "no-such-chat/o1"}),
        json!({"processId": "o1"}),
        json!({"processId": 7}),
        json!({}),
        json!({"processId": pid, "fromByte": -1}),
        json!({"processId": pid, "maxBytes": "lots"}),
    ] {
        let refused = c.request(TAIL, params.clone()).await;
        assert!(refused.is_err(), "{params} was not refused: {refused:?}");
    }
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
