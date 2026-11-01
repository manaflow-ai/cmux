//! Background tasks the daemon owns (`hub/bg_tasks.rs`, `bg_run.rs`). Leo, 2026-10-27: "also
//! when it comes to hibernation...can't you hibernate the agent but not hibernate the bg tasks?"
//! A task an agent starts through `_acpmux/bg/start` (the `acpmux` MCP server's `bg_start`) runs
//! under its own runner: the chat hibernates with it running, it keeps running, and once a prompt
//! wakes the agent, `bg/output` reads what it wrote meanwhile. Its output is bounded.

use super::session_hibernate::{Rig, alive, rig};
use super::*;

/// The background-task runner: this hermetic process starts it with its own environment.
fn runner() -> std::path::PathBuf {
    crate::daemon_env::bin().into()
}

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
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
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
    r.hub.set_bg_runner(runner(), CAP);
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
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
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

/// A local connection that is neither the person nor the chat's own agent reaches no task.
#[cfg(unix)]
#[tokio::test]
async fn a_connection_that_proved_nothing_reaches_no_task() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "private").await;
    let (tx, in_rx) = tokio::sync::mpsc::channel(64);
    let (out_tx, rx) = tokio::sync::mpsc::channel(4096);
    tokio::spawn(serve_connection(r.hub.clone(), in_rx, out_tx));
    let mut anyone = TestClient { tx, rx, next: 0 };
    for (m, params) in [
        (method::MUX_BG_LIST, json!({"sessionId": id})),
        (method::MUX_BG_START, json!({"sessionId": id, "command": "true"})),
    ] {
        let refused = anyone.request(m, params).await.unwrap_err();
        assert!(refused.contains("only its own"), "{m}: {refused}");
    }
}

/// The task's whole output so far, as text.
fn text(r: &Rig, id: &str, task: &str) -> String {
    let s = r.hub.resolve(id).unwrap();
    let read = r.hub.bg_output(&s, task, Some(0), None).unwrap();
    read["text"].as_str().unwrap_or_default().to_owned()
}

/// Output a child writes after the leader exited is kept (the task runs until the pipe ends);
/// a task that ignores SIGTERM is killed after the grace; a purge stops the chat's tasks and
/// removes their folder.
#[cfg(unix)]
#[tokio::test]
async fn late_output_is_kept_a_stubborn_task_is_killed_and_a_purge_clears_the_folder() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "late").await;
    let late = start(&mut r, &id, "(sleep 0.5; echo late) & echo early").await;
    let late = late["id"].as_str().unwrap().to_owned();
    r.until("the task never ended", || state(&r, &id, &late) == "exited").await;
    let read = output(&mut r, &id, &late, Some(0)).await;
    assert_eq!(read["text"], "early\nlate\n", "{read}");
    let stubborn =
        start(&mut r, &id, "trap '' TERM; echo ready; while :; do sleep 0.1; done").await;
    let (task, pid) =
        (stubborn["id"].as_str().unwrap().to_owned(), stubborn["pid"].as_u64().unwrap());
    // Its trap is set before the stop, so only the SIGKILL can end it.
    r.until("the stubborn task never set its trap", || text(&r, &id, &task) == "ready\n").await;
    let stopped = r.c.request(method::MUX_BG_STOP, json!({"sessionId": id, "id": task})).await;
    let stopped = stopped.unwrap();
    assert_eq!(stopped["state"], "stopped");
    assert_eq!(stopped["signal"], libc::SIGKILL, "{stopped}");
    assert!(!alive(pid as u32), "a task that ignored SIGTERM outlived its stop");
    let running = start(&mut r, &id, "sleep 600").await["pid"].as_u64().unwrap();
    r.c.request(method::MUX_KILL, json!({"sessionId": id, "purge": true})).await.unwrap();
    r.until("a purge left its task running", || !alive(running as u32)).await;
    assert!(!acpmux::config::home().join("bg").join(&id).exists(), "a purge left the folder");
}

/// A child that ignores SIGTERM and sends its output elsewhere holds no pipe, so the pipe ends
/// when the stop's SIGTERM ends the shell: the stop still SIGKILLs the child.
#[cfg(unix)]
#[tokio::test]
async fn a_stop_kills_a_child_that_ignores_sigterm_and_holds_no_pipe() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "quiet").await;
    // The subshell's own pid, also in macOS's /bin/bash 3.2, which has no $BASHPID: the
    // substitution's process becomes `sh`, whose parent is the subshell.
    let quiet = "(trap '' TERM; echo child-$(exec sh -c 'echo $PPID'); exec >/dev/null 2>&1; \
        while :; do sleep 0.1; done) & wait";
    let task = start(&mut r, &id, quiet).await["id"].as_str().unwrap().to_owned();
    r.until("the child never said its pid", || text(&r, &id, &task).ends_with('\n')).await;
    let said = text(&r, &id, &task);
    let child: u32 = said.trim().strip_prefix("child-").unwrap().parse().unwrap();
    let stopped = r.c.request(method::MUX_BG_STOP, json!({"sessionId": id, "id": task})).await;
    assert_eq!(stopped.unwrap()["state"], "stopped");
    r.until("a child that ignored SIGTERM outlived the stop", || !alive(child)).await;
}

/// A task runs in the environment the chat's agent runs with, built by the daemon from the
/// agent's launch (or, before one, as a launch would build it), not from whatever its MCP server
/// was passed: here the session's own id, which the start request never carried.
#[cfg(unix)]
#[tokio::test]
async fn a_task_sees_the_agents_environment() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "env").await;
    for launched in [false, true] {
        if launched {
            r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
        }
        let task = start(&mut r, &id, "echo \"$ACPMUX_SESSION_ID\"").await;
        let task = task["id"].as_str().unwrap().to_owned();
        r.until("the task never ended", || state(&r, &id, &task) == "exited").await;
        assert_eq!(text(&r, &id, &task), format!("{id}\n"), "launched: {launched}");
    }
}

/// A record of another generation of the chat's folder (a runner that outlived a purge, writing
/// under the old path) is neither listed nor reached.
#[cfg(unix)]
#[tokio::test]
async fn a_record_from_an_earlier_folder_of_the_id_is_not_the_chats() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "generations").await;
    let task = start(&mut r, &id, "true").await["id"].as_str().unwrap().to_owned();
    r.until("the task never ended", || state(&r, &id, &task) == "exited").await;
    let dir = acpmux::config::home().join("bg").join(&id);
    let mut old = acpmux::bg_run::read_record(&dir, &task).unwrap();
    old.id = "bg-0ld0ld0ld0ld".into();
    old.generation = "an-earlier-folder".into();
    acpmux::bg_run::write_record(&dir, &old).unwrap();
    let list = r.hub.bg_list(&r.hub.resolve(&id).unwrap());
    let ids: Vec<_> = list["tasks"].as_array().unwrap().iter().map(|t| t["id"].clone()).collect();
    assert_eq!(ids, [json!(task)], "{list}");
    let stop = r.c.request(method::MUX_BG_STOP, json!({"sessionId": id, "id": old.id})).await;
    assert!(stop.is_err(), "an earlier folder's task was reached");
}

/// A purge never waits for a task that ignores SIGTERM: the chat is gone at once, the task is
/// killed after the grace, and its moved folder goes once it exited.
#[cfg(unix)]
#[tokio::test]
async fn a_purge_does_not_wait_for_a_stubborn_task_and_clears_its_files_after() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "stubborn-purge").await;
    let task = start(&mut r, &id, "trap '' TERM; echo ready; while :; do sleep 0.1; done").await;
    let (task_id, pid) = (task["id"].as_str().unwrap().to_owned(), task["pid"].as_u64().unwrap());
    r.until("the task never set its trap", || text(&r, &id, &task_id) == "ready\n").await;
    let at = std::time::Instant::now();
    r.c.request(method::MUX_KILL, json!({"sessionId": id, "purge": true})).await.unwrap();
    assert!(at.elapsed() < acpmux::bg_run::GRACE, "the purge waited for the task");
    let home = acpmux::config::home().join("bg");
    assert!(!home.join(&id).exists(), "a purge left the folder");
    r.until("the stubborn task outlived the purge", || !alive(pid as u32)).await;
    let moved = || {
        std::fs::read_dir(home.join(".purged"))
            .into_iter()
            .flatten()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().starts_with(&format!("{id}-")))
    };
    r.until("the moved folder stayed after its task exited", || !moved()).await;
}

/// A purge stops a task whose record cannot be read: it finds tasks by their files.
#[cfg(unix)]
#[tokio::test]
async fn a_purge_stops_a_task_whose_record_is_unreadable() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "unreadable").await;
    let task = start(&mut r, &id, "sleep 600").await;
    let (task_id, pid) = (task["id"].as_str().unwrap().to_owned(), task["pid"].as_u64().unwrap());
    let dir = acpmux::config::home().join("bg").join(&id);
    std::fs::write(dir.join(format!("{task_id}.json")), "not json").unwrap();
    r.c.request(method::MUX_KILL, json!({"sessionId": id, "purge": true})).await.unwrap();
    r.until("a purge left a task with an unreadable record running", || !alive(pid as u32)).await;
}

/// A runner of an earlier folder of the chat id, whose stop FIFO sits in a later folder of that
/// id (a purge moved its folder aside while it started), is never stopped by the later chat: its
/// stops carry the later folder's generation, which the runner ignores. A stop that carries the
/// runner's own generation still ends it.
#[cfg(unix)]
#[tokio::test]
async fn a_purge_never_stops_a_runner_of_another_generation() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    r.hub.set_bg_runner(runner(), acpmux::bg_run::SEGMENT);
    let id = new_session(&mut r.c, "other-generation").await;
    let task = start(&mut r, &id, "sleep 600").await;
    let (task_id, pid) = (task["id"].as_str().unwrap().to_owned(), task["pid"].as_u64().unwrap());
    let dir = acpmux::config::home().join("bg").join(&id);
    let own = acpmux::bg_run::read_record(&dir, &task_id).unwrap().generation;
    // The folder is now a later one of this id; the runner still belongs to the earlier one.
    std::fs::write(dir.join(".generation"), "a-later-folder").unwrap();
    assert!(acpmux::bg_run::request_stop(&dir, &task_id, "a-later-folder"));
    r.c.request(method::MUX_KILL, json!({"sessionId": id, "purge": true})).await.unwrap();
    let aside = acpmux::config::home().join("bg").join(".purged");
    let moved = std::fs::read_dir(&aside)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .find(|p| p.file_name().unwrap().to_string_lossy().starts_with(&format!("{id}-")))
        .expect("the purge moved no folder aside");
    // The runner's one reader took both stops off the FIFO, and a stop it acted on would have
    // sent SIGTERM right then (a plain `sleep` ends at once); the margin covers that.
    let ctl = acpmux::bg_run::ctl_path(&moved, &task_id);
    r.until("the runner never read the stops", || unread(&ctl) == Some(0)).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(alive(pid as u32), "a stop of another generation ended the task");
    // Its own generation stops it, in the folder the purge moved aside.
    assert!(acpmux::bg_run::request_stop(&moved, &task_id, &own), "the runner left its FIFO");
    r.until("a stop of the runner's own generation did not end it", || !alive(pid as u32)).await;
}

/// The bytes written to the FIFO at `path` that its reader has not read yet (`None`: no reader).
#[cfg(unix)]
fn unread(path: &std::path::Path) -> Option<usize> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let f =
        std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(path).ok()?;
    let mut n: libc::c_int = 0;
    // SAFETY: FIONREAD into a c_int this function owns, on a descriptor it holds.
    let r = unsafe { libc::ioctl(f.as_raw_fd(), libc::FIONREAD as _, &mut n) };
    (r == 0).then_some(n as usize)
}
