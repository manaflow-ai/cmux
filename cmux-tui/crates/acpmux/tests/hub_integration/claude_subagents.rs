//! Claude's Agent tool as a native subagent session (Lawrence 2026-10-12,
//! native subagents for Claude Code and Codex in the agent pane): the
//! subagent model names the kind of agent it is, and the child's own lines
//! arrive under it.

use super::*;

/// A Claude subagent's model names the kind of agent it is (its Agent call's
/// subagent_type), and its own read arrives under it.
#[tokio::test]
async fn claude_subagents_carry_their_kind() {
    let root = std::env::temp_dir().join(format!("acpmux-agent-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "agent-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let events = hub.events(&id, 0, 10_000).unwrap();
    let mux: Vec<Value> =
        events.iter().filter_map(|e| e.msg.pointer("/params/_meta/acpmux").cloned()).collect();
    let spawn = mux
        .iter()
        .filter_map(|m| m.get("subagents").and_then(Value::as_array))
        .flatten()
        .find(|s| s["state"] == "running")
        .cloned()
        .unwrap_or_else(|| panic!("no subagent spawned: {mux:?}"));
    assert_eq!(spawn["kind"], "Explore");
    assert_eq!(spawn["name"], "Find the tests");
    assert!(mux.iter().any(|m| m.get("subagent") == Some(&spawn["id"])), "{mux:?}");
    let _ = std::fs::remove_dir_all(root);
}

/// A background Claude subagent still running after its parent's turn ended
/// asks for permission: the ask reaches the person and the answer reaches the
/// subagent (cx-jo8yo).
#[tokio::test]
async fn a_claude_subagent_asking_after_the_turn_ended_reaches_the_person() {
    let root = std::env::temp_dir().join(format!("acpmux-late-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    hub.set_policy(&hub.resolve(&id).unwrap(), PermissionPolicy::Ask).await;
    // Subscribed before the prompt, so no log line after it is missed.
    let mut events = hub.subscribe();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "late-agent-ask"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    // The fake agent sends its late ask only after the turn's result, so the
    // prompt's response can come before the ask is in the session's log: the
    // test waits for the log line. The chat then waits on the person after
    // its turn ended, not ready.
    let session = hub.resolve(&id).unwrap();
    let last =
        |kind: &str| hub.events(&id, 0, 10_000).unwrap().into_iter().rfind(|e| e.kind == kind);
    let status = || hub.session_summary(&session)["status"].clone();
    wait_for(&mut events, "the late ask never reached the person", || {
        last("permission_request").is_some() && status() == "waiting"
    })
    .await;
    let asked = last("permission_request").unwrap();
    let pid = asked.msg["permissionId"].as_str().unwrap().to_owned();
    // This client is not the person, so it rejects (an allow needs the app's
    // decision proof): the person's answer, not a cancel, reaches the subagent.
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "reject_once"}),
    )
    .await
    .unwrap();
    wait_for(&mut events, "no decision", || last("permission_decision").is_some()).await;
    let decision = last("permission_decision").unwrap();
    assert_eq!(decision.msg["outcome"]["outcome"], "selected", "{}", decision.msg);
    assert_eq!(decision.msg["outcome"]["optionId"], "reject_once");
    let said = super::super::transcript_events::late_chunk(&hub, &id, |m| {
        m.pointer("/params/_meta/acpmux/subagent").is_some()
    })
    .await;
    assert_eq!(said["params"]["update"]["content"]["text"], "late deny", "{said}");
    wait_for(&mut events, "the chat is not ready after the answer", || status() == "ready").await;
    let _ = std::fs::remove_dir_all(root);
}

/// manaflow-ai/cmux#25230: a chat whose turn ended while a background subagent it started still
/// runs is working (its status dot, its lane) until that subagent ends between turns, and
/// watchers hear both changes; then it is done. A background launch that fails never holds it.
#[cfg(unix)]
#[tokio::test]
async fn a_chat_works_until_its_background_subagent_ends() {
    let root = std::env::temp_dir().join(format!("acpmux-bgwork-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let gate = root.join("gate");
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    let records = || {
        hub.events(&id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "subagents_working")
            .count()
    };
    let mut events = hub.subscribe();

    let said = format!("bg-agent-gate: {}", gate.display());
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let s = hub.session_summary(&session);
    assert!(s["turn"].is_null(), "its own turn ended: {s}");
    assert_eq!(s["lastTurn"]["status"], "completed", "{s}");
    assert!(s["subagentsWorkingSince"].is_u64(), "{s}");
    assert_eq!(s["indicator"], "working", "the subagent still runs: {s}");
    assert_eq!(s["lane"]["state"], "working", "{s}");
    assert_eq!(s["lane"]["since"], s["subagentsWorkingSince"], "{s}");
    assert_eq!(records(), 1, "watchers heard it start");

    // The subagent ends while the chat is idle.
    let g = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(g, b"go")).await.unwrap().unwrap();
    wait_for(&mut events, "the subagent never ended", || records() == 2).await;
    let s = hub.session_summary(&session);
    assert!(s["subagentsWorkingSince"].is_null(), "{s}");
    assert_eq!(s["indicator"], "done", "its subagent ended: {s}");
    assert_eq!(s["lane"]["state"], "idle", "{s}");

    // A background launch that fails never ran: the chat is done after its turn.
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "bg-agent-fail"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let s = hub.session_summary(&session);
    assert!(s["subagentsWorkingSince"].is_null(), "{s}");
    assert_eq!(s["indicator"], "done", "{s}");
    let _ = std::fs::remove_dir_all(root);
}

/// manaflow-ai/cmux#25563: a hidden chat whose turn ended while its background Claude subagent
/// still runs is not unread yet (the task is not done); it turns unread, and its tab hears
/// "finished", when that subagent ends.
#[tokio::test]
async fn a_hidden_chat_turns_unread_when_its_background_subagent_ends() {
    let root = std::env::temp_dir().join(format!("acpmux-bgunread-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let gate = root.join("gate");
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    c.request("_acpmux/view", json!({"sessionId": id, "visible": false})).await.unwrap();
    let mut events = hub.subscribe();

    let said = format!("bg-agent-gate: {}", gate.display());
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let s = hub.session_summary(&session);
    assert_eq!(s["lastTurn"]["status"], "completed", "{s}");
    assert!(s["subagentsWorkingSince"].is_u64(), "{s}");
    assert_eq!(s["unread"], false, "its background subagent still runs: {s}");

    let g = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(g, b"go")).await.unwrap().unwrap();
    wait_for(&mut events, "never turned unread", || {
        hub.session_summary(&session)["unread"] == true
    })
    .await;
    let s = hub.session_summary(&session);
    assert!(s["subagentsWorkingSince"].is_null(), "{s}");
    let read: Vec<_> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "status" && e.msg.get("read").is_some())
        .map(|e| e.msg["read"].clone())
        .collect();
    assert_eq!(read, [json!(false)], "watchers heard it turn unread once");

    // Shown, then a turn that ends in view while nothing runs below it: seen, no dot.
    c.request("_acpmux/view", json!({"sessionId": id, "visible": true})).await.unwrap();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    assert_eq!(hub.session_summary(&session)["unread"], false);
    let _ = std::fs::remove_dir_all(root);
}

/// Waits until `done` holds: checked now and again after each log line the
/// hub broadcasts (no polling); panics with `what` after 10 s.
async fn wait_for(
    events: &mut tokio::sync::broadcast::Receiver<acpmux::hub::HubEvent>,
    what: &str,
    mut done: impl FnMut() -> bool,
) {
    use tokio::sync::broadcast::error::RecvError;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while !done() {
        match tokio::time::timeout_at(deadline, events.recv()).await {
            Err(_) => panic!("{what}"),
            Ok(Err(RecvError::Closed)) => panic!("{what}: the hub stopped"),
            // A new line, or lines lost to lag: check again.
            Ok(Ok(_) | Err(RecvError::Lagged(_))) => {}
        }
    }
}
