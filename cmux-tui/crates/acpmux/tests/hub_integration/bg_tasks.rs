//! Background tasks the daemon owns (`hub/bg_tasks.rs`, `bg_run.rs`). Leo, 2026-10-27: "also
//! when it comes to hibernation...can't you hibernate the agent but not hibernate the bg tasks?"
//! A task an agent starts through `_acpmux/bg/start` (the `acpmux` MCP server's `bg_start`) runs
//! under its own runner: the chat hibernates with it running, it keeps running, and once a prompt
//! wakes the agent, `bg/output` reads what it wrote meanwhile. Its output is bounded.

use super::session_hibernate::{Rig, alive, rig};
use super::*;

const RUNNER: &str = env!("CARGO_BIN_EXE_acpmux");

async fn start(r: &mut Rig, id: &str, command: &str) -> Value {
    let params = json!({"sessionId": id, "command": command});
    r.c.request(method::MUX_BG_START, params).await.unwrap()
}

async fn output(r: &mut Rig, id: &str, task: &str, from: Option<u64>) -> Value {
    let params = json!({"sessionId": id, "id": task, "fromByte": from});
    r.c.request(method::MUX_BG_OUTPUT, params).await.unwrap()
}

/// A connection that proved it runs in chat `id` (`hub/person.rs` (a)): its agent's tools.
async fn acpmux_caller(hub: &Arc<Hub>, id: &str) -> TestClient {
    let (tx, in_rx) = tokio::sync::mpsc::channel(64);
    let (out_tx, rx) = tokio::sync::mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx, rx, next: 0 };
    let token = acpmux::hub::person::caller_token(id);
    let caller = json!({"callerSession": {"sessionId": id, "token": token}});
    c.request("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}}))
        .await
        .unwrap();
    c
}

fn state(r: &Rig, id: &str, task: &str) -> String {
    let list = r.hub.bg_list(&r.hub.resolve(id).unwrap());
    let t = list["tasks"].as_array().unwrap().iter().find(|t| t["id"] == task).cloned();
    t.map(|t| t["state"].as_str().unwrap().to_owned()).unwrap_or_default()
}

/// The chat hibernates while its task runs (a daemon-owned task keeps no chat awake), the task
/// outlives the harness, and after a prompt wakes the agent it reads the lines the task wrote
/// while it slept. A stop then ends it.
#[cfg(unix)]
#[tokio::test]
async fn a_background_task_outlives_hibernation_and_the_woken_agent_reads_it() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(RUNNER.into(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "server").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    let ticks = "i=0; while :; do i=$((i+1)); echo tick-$i; sleep 0.1; done";
    let task = start(&mut r, &id, ticks).await;
    let (task_id, pid) = (task["id"].as_str().unwrap().to_owned(), task["pid"].as_u64().unwrap());
    assert_eq!(task["state"], "running", "{task}");
    r.hibernate(&id).await;
    assert!(alive(pid as u32), "hibernation ended the background task");
    assert_eq!(state(&r, &id, &task_id), "running");
    let slept = output(&mut r, &id, &task_id, None).await["totalBytes"].as_u64().unwrap();
    // It keeps writing while the agent sleeps.
    let hub = r.hub.clone();
    let grew = || {
        let s = hub.resolve(&id).unwrap();
        hub.bg_output(&s, &task_id, None, Some(1)).unwrap()["totalBytes"].as_u64() > Some(slept)
    };
    r.until("the task wrote nothing while the agent slept", grew).await;
    // A prompt wakes the agent: a new harness, and the task is the same one.
    r.c.request(method::SESSION_PROMPT, prompt(&id, "again", None)).await.unwrap();
    assert_eq!(r.pids("harness").len(), 2, "the prompt did not wake the agent");
    let read = output(&mut r, &id, &task_id, Some(slept)).await;
    assert!(read["text"].as_str().unwrap().contains("tick-"), "{read}");
    assert!(read["nextByte"].as_u64() > Some(slept), "{read}");
    assert_eq!(read["state"], "running");
    let stopped = r.c.request(method::MUX_BG_STOP, json!({"sessionId": id, "id": task_id})).await;
    assert_eq!(stopped.unwrap()["state"], "stopped");
    r.until("the stopped task still runs", || !alive(pid as u32)).await;
}

/// A task that writes past its spool's cap keeps only its newest output, in two segments of at
/// most the cap each; the list's tail and a read from byte 0 say where the kept output starts.
#[cfg(unix)]
#[tokio::test]
async fn a_task_that_writes_past_the_cap_keeps_its_newest_output() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    const CAP: u64 = 1024;
    r.hub.set_bg_runner(RUNNER.into(), CAP);
    let id = new_session(&mut r.c, "noisy").await;
    let lines = "i=0; while [ $i -lt 2000 ]; do echo line-$i; i=$((i+1)); done";
    let task_id = start(&mut r, &id, lines).await["id"].as_str().unwrap().to_owned();
    r.until("the task never exited", || state(&r, &id, &task_id) == "exited").await;
    let whole: usize = (0..2000).map(|i| format!("line-{i}\n").len()).sum();
    let list = r.hub.bg_list(&r.hub.resolve(&id).unwrap());
    let t = &list["tasks"][0];
    assert_eq!(t["exitCode"], 0, "{t}");
    assert_eq!(t["totalBytes"], whole as u64, "{t}");
    assert!(t["tail"].as_str().unwrap().ends_with("line-1999\n"), "{t}");
    let kept_from = t["keptFromByte"].as_u64().unwrap();
    assert!(kept_from >= whole as u64 - 2 * CAP, "{t}");
    let read = output(&mut r, &id, &task_id, Some(0)).await;
    assert_eq!(read["fromByte"], kept_from, "{read}");
    assert_eq!(read["skippedBytes"], kept_from, "{read}");
    assert!(read["text"].as_str().unwrap().ends_with("line-1999\n"));
    let dir = acpmux::config::home().join("bg").join(&id);
    let segments: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .filter(|f| f.file_name().to_string_lossy().contains(".out."))
        .collect();
    assert_eq!(segments.len(), 2, "{segments:?}");
    for file in segments {
        assert!(file.metadata().unwrap().len() <= CAP, "{:?} passed the cap", file.path());
    }
}

/// A stopped chat starts no task; another chat's caller-token connection cannot reach this
/// chat's tasks; a stop of a task that already ended signals nothing and says how it ended; and
/// output that is not text comes back exactly in `data`.
#[cfg(unix)]
#[tokio::test]
async fn a_task_is_its_chats_only_and_a_stopped_chat_starts_none() {
    use base64::Engine;
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(RUNNER.into(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "owner").await;
    let task_id =
        start(&mut r, &id, "printf '\\377\\000ok'").await["id"].as_str().unwrap().to_owned();
    r.until("the task never exited", || state(&r, &id, &task_id) == "exited").await;
    let read = output(&mut r, &id, &task_id, Some(0)).await;
    let bytes = base64::engine::general_purpose::STANDARD.decode(read["data"].as_str().unwrap());
    assert_eq!(bytes.unwrap(), b"\xff\x00ok", "{read}");
    let stopped = r.c.request(method::MUX_BG_STOP, json!({"sessionId": id, "id": task_id})).await;
    assert_eq!(stopped.unwrap()["state"], "exited", "a stop after the end changed nothing");
    let other = new_session(&mut r.c, "other").await;
    let mut caller = acpmux_caller(&r.hub, &other).await;
    let refused = caller.request(method::MUX_BG_LIST, json!({"sessionId": id})).await;
    assert!(refused.unwrap_err().contains("only its own"), "another chat read this chat's tasks");
    r.c.request(method::MUX_KILL, json!({"sessionId": id})).await.unwrap();
    let refused =
        r.c.request(method::MUX_BG_START, json!({"sessionId": id, "command": "true"})).await;
    assert!(refused.unwrap_err().contains("stopped"), "a stopped chat started a task");
}
