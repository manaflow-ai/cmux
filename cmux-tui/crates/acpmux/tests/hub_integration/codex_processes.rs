//! The background-process registry over Codex's background terminals
//! (docs/background-processes.md): a `commandExecution` whose process still
//! runs when its turn ends, or when its item completes, is listed under its
//! chat with harness `codex`; `_acpmux/process/kill` calls the app-server's
//! `thread/backgroundTerminals/terminate`; the app-server's exit leaves it
//! lost. The fake app-server is tests/fake_codex_app_server.py.

use super::*;
use std::os::unix::fs::PermissionsExt;

const LIST: &str = "_acpmux/process/list";
const KILL: &str = "_acpmux/process/kill";
const UPDATE: &str = "_acpmux/process_update";
const TERMINATE: &str = "thread/backgroundTerminals/terminate";

/// A Codex hub: the in-process bridge over the fake app-server, run as a
/// program named `codex` under a fresh folder.
async fn codex_hub() -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    codex_hub_env(&[]).await
}

/// `codex_hub` with the fake's `env` (FAKE_CODEX_* switches).
async fn codex_hub_env(env: &[(&str, &str)]) -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-cxproc-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    let home = root.join("codex-home");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");
    let codex = bin.join("codex");
    std::fs::write(&codex, format!("#!/bin/sh\nexec python3 {fake} \"$@\"\n")).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: vec![codex.to_string_lossy().into_owned(), "app-server".into()],
        env: env
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .chain([("CODEX_HOME".to_owned(), home.to_string_lossy().into_owned())])
            .collect(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("codex".to_owned(), profile)]),
        default_harness: Some("codex".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    (hub, c, root)
}

/// A new chat that ran `said` as its first turn.
async fn chat(c: &mut TestClient, said: &str) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]});
    let r = c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    id
}

/// The chat's processes from `_acpmux/process/list`.
async fn listed(c: &mut TestClient, id: &str) -> Vec<Value> {
    let r = c.request(LIST, json!({"sessionId": id})).await.unwrap();
    r["processes"].as_array().cloned().unwrap_or_else(|| panic!("no processes array: {r}"))
}

/// The listed process `pid`.
async fn process(c: &mut TestClient, id: &str, pid: &str) -> Value {
    let list = listed(c, id).await;
    list.iter().find(|p| p["id"] == pid).cloned().unwrap_or_else(|| panic!("no {pid}: {list:?}"))
}

/// Poll until the process `pid` is in `state`.
async fn until_state(c: &mut TestClient, id: &str, pid: &str, state: &str) -> Value {
    for _ in 0..100 {
        let p = process(c, id, pid).await;
        if p["state"] == state {
            return p;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("{pid} never became {state}: {:?}", listed(c, id).await);
}

/// The terminate requests acpmux wrote to the app-server's stdin.
fn terminates(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "codex.stdin")
        .filter(|e| e.msg.pointer("/params/method") == Some(&json!(TERMINATE)))
        .map(|e| e.msg["params"].clone())
        .collect()
}

/// The chat's folder as acpmux recorded it.
fn chat_cwd(hub: &Arc<Hub>, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())["cwd"].clone()
}

/// A dev server left running when the turn ended, and a watcher whose item
/// completed while its process ran, are listed running under the chat with
/// harness codex; a command that finished in the turn is not listed.
#[tokio::test]
async fn codex_process_list_shows_running_background_terminals() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex").await;
    let list = listed(&mut c, &id).await;
    assert_eq!(list.len(), 2, "{list:?}");
    let dev = process(&mut c, &id, &format!("{id}/1001")).await;
    let mut dev = dev.clone();
    assert!(dev["startedAt"].is_u64(), "{dev}");
    dev.as_object_mut().unwrap().remove("startedAt");
    assert_eq!(
        dev,
        json!({"id": format!("{id}/1001"), "sessionId": id, "subagentSessionId": null,
               "toolCallId": "call_dev", "taskId": "1001", "harness": "codex",
               "command": "npm run dev", "cwd": chat_cwd(&hub, &id), "endedAt": null,
               "state": "running", "exitCode": null, "signal": null, "reason": null,
               "detail": null, "origin": "background", "outputBytes": null})
    );
    let watch = process(&mut c, &id, &format!("{id}/1003")).await;
    assert_eq!(watch["state"], "running", "{watch}");
    assert_eq!(watch["toolCallId"], "call_watch");
    assert_eq!(watch["harness"], "codex");
    assert!(list.iter().all(|p| p["toolCallId"] != "call_ls"), "{list:?}");
    let all = c.request(LIST, json!({})).await.unwrap();
    let all = all["processes"].as_array().cloned().unwrap_or_default();
    assert!(all.iter().any(|p| p["id"] == format!("{id}/1001")), "{all:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A background terminal that exits on its own ends with its exit code.
#[tokio::test]
async fn codex_a_background_terminal_that_exits_keeps_its_exit_code() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex-exit").await;
    let watch = until_state(&mut c, &id, &format!("{id}/1003"), "failed").await;
    assert_eq!(watch["exitCode"], 1, "{watch}");
    assert_eq!(watch["reason"], Value::Null, "{watch}");
    assert!(watch["endedAt"].is_u64(), "{watch}");
    assert_eq!(process(&mut c, &id, &format!("{id}/1001")).await["state"], "running");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Codex moves long commands to the background itself: Ctrl-B
/// (`_acpmux/process/background`) on its chat is refused, and its terminal
/// is left alone.
#[tokio::test]
async fn codex_background_is_refused() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex").await;
    let refused =
        c.request("_acpmux/process/background", json!({"sessionId": id})).await.unwrap_err();
    assert!(refused.contains("only Claude Code"), "{refused}");
    assert_eq!(process(&mut c, &id, &format!("{id}/1001")).await["state"], "running");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Killing a running background terminal calls the app-server's
/// `thread/backgroundTerminals/terminate` for its thread and process; it
/// ends killed by the person, once, and attached clients hear it.
#[tokio::test]
async fn codex_kill_terminates_the_background_terminal_and_it_ends_killed_by_the_person() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex").await;
    let pid = format!("{id}/1001");
    let mut other = connect(&hub).await;
    assert_eq!(other.request(KILL, json!({"processId": pid})).await.unwrap(), json!({}));
    let sent = terminates(&hub, &id);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["params"], json!({"threadId": "fake-thread-1", "processId": "1001"}));
    let note = c.wait_for(UPDATE, |p| p["process"]["state"] == "killed").await;
    assert_eq!(note["process"]["id"], pid.as_str());
    assert_eq!(note["process"]["reason"], "person");
    let ended = until_state(&mut c, &id, &pid, "killed").await;
    assert_eq!(ended["reason"], "person");
    // The other one still runs.
    assert_eq!(process(&mut c, &id, &format!("{id}/1003")).await["state"], "running");
    // A turn after the kill: the app-server's lines before it are all read.
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let ends: Vec<_> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "process_update" && e.msg["process"]["id"] == pid.as_str())
        .filter(|e| e.msg["process"]["state"] != "running")
        .collect();
    assert_eq!(ends.len(), 1, "{ends:?}");
    // Killing it again sends nothing.
    assert_eq!(c.request(KILL, json!({"processId": pid})).await.unwrap(), json!({}));
    assert_eq!(terminates(&hub, &id).len(), 1);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The app-server's exit ends its background terminals without anyone
/// seeing how: each running one becomes lost, and a kill sends nothing.
#[tokio::test]
async fn codex_a_harness_exit_marks_running_background_terminals_lost() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "codex-die"}]}),
        )
        .await;
    let pid = format!("{id}/1001");
    let lost = until_state(&mut c, &id, &pid, "lost").await;
    assert_eq!(lost["reason"], "harness_exit");
    assert_eq!(process(&mut c, &id, &format!("{id}/1003")).await["state"], "lost");
    assert_eq!(c.request(KILL, json!({"processId": pid})).await.unwrap(), json!({}));
    assert_eq!(terminates(&hub, &id), Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A chat of a harness that is neither Claude Code nor Codex has nothing to
/// stop: its kill is refused naming both.
#[tokio::test]
async fn codex_kill_on_a_chat_that_is_neither_claude_nor_codex_is_refused() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "acp").await;
    let refused = c.request(KILL, json!({"processId": format!("{id}/t1")})).await.unwrap_err();
    assert!(refused.contains("Claude Code") && refused.contains("Codex"), "{refused}");
    hub.shutdown_all().await;
}

/// A subagent's background terminal is listed under the chat, naming the
/// subagent; its kill terminates it on the subagent's own thread.
#[tokio::test]
async fn codex_a_subagents_background_terminal_is_killed_on_its_thread() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex-sub").await;
    let pid = format!("{id}/2001");
    let p = process(&mut c, &id, &pid).await;
    assert_eq!(p["state"], "running", "{p}");
    assert_eq!(p["harness"], "codex", "{p}");
    assert_eq!(p["toolCallId"], "call_sub", "{p}");
    assert_eq!(p["subagentSessionId"], "fake-sub-1", "{p}");
    assert_eq!(c.request(KILL, json!({"processId": pid})).await.unwrap(), json!({}));
    let sent = terminates(&hub, &id);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["params"], json!({"threadId": "fake-sub-1", "processId": "2001"}));
    let ended = until_state(&mut c, &id, &pid, "killed").await;
    assert_eq!(ended["reason"], "person");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Codex no longer has the process (terminated: false): the kill is refused
/// with that, and the process is no longer listed running.
#[tokio::test]
async fn codex_a_kill_of_a_terminal_codex_no_longer_has_is_refused_and_ends_it() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex-gone").await;
    let pid = format!("{id}/1001");
    let refused = c.request(KILL, json!({"processId": pid})).await.unwrap_err();
    assert!(refused.contains("no longer"), "{refused}");
    let ended = until_state(&mut c, &id, &pid, "exited").await;
    assert_eq!(ended["reason"], Value::Null, "{ended}");
    assert!(ended["detail"].as_str().is_some_and(|d| d.contains("no longer")), "{ended}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Codex may complete a terminated item before it answers the terminate:
/// the end is still the kill's, by the person.
#[tokio::test]
async fn codex_an_item_end_before_the_terminate_answer_is_the_persons_kill() {
    let (hub, mut c, root) = codex_hub_env(&[("FAKE_CODEX_END_FIRST", "1")]).await;
    let id = chat(&mut c, "bg-codex").await;
    let pid = format!("{id}/1001");
    assert_eq!(c.request(KILL, json!({"processId": pid})).await.unwrap(), json!({}));
    let ended = until_state(&mut c, &id, &pid, "killed").await;
    assert_eq!(ended["reason"], "person", "{ended}");
    let ends: Vec<_> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "process_update" && e.msg["process"]["id"] == pid.as_str())
        .filter(|e| e.msg["process"]["state"] != "running")
        .collect();
    assert_eq!(ends.len(), 1, "{ends:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A command still open when its turn is interrupted was not handed to the
/// background: nothing is listed.
#[tokio::test]
async fn codex_an_interrupted_turn_lists_no_background_terminal() {
    let (hub, mut c, root) = codex_hub().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt =
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "bg-codex-interrupt"}]});
    let _ = c.request(method::SESSION_PROMPT, prompt).await;
    assert_eq!(listed(&mut c, &id).await, Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Tail reads the output file Claude Code names; a Codex process has none
/// yet, so its tail is refused rather than empty.
#[tokio::test]
async fn codex_tail_on_a_codex_process_is_refused() {
    let (hub, mut c, root) = codex_hub().await;
    let id = chat(&mut c, "bg-codex").await;
    let tail = c.request("_acpmux/process/tail", json!({"processId": format!("{id}/1001")})).await;
    let refused = tail.unwrap_err();
    assert!(refused.contains("tail is Claude Code only for now"), "{refused}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
