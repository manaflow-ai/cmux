use super::*;

fn meta(id: &str) -> crate::store::SessionMeta {
    let mut m: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "fake",
        "cwd": "/tmp", "status": "idle",
        "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    m.remote_origin = true;
    m
}

fn hub_with(id: &str) -> (Arc<Hub>, Arc<Session>) {
    let store = crate::store::MemoryStore::default();
    crate::store::Store::save(&store, &meta(id)).unwrap();
    let hub = Hub::new(crate::config::Config::default(), Box::new(store));
    let session = hub.make_session(meta(id));
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    (hub, session)
}

/// A Claude child running `script`, spawned as a cold start spawns one, set as the chat's agent.
async fn spawn(hub: &Arc<Hub>, session: &Arc<Session>, script: &str) -> Arc<ChildAgent> {
    let tap = hub.session_tap(session);
    let profile: crate::config::HarnessProfile =
        serde_json::from_value(json!({"kind": "claude-stdio", "argv": ["sh"]})).unwrap();
    let tr = crate::claude_stdio::Translator::new(session.id.clone(), "default", "", "");
    let child = ChildAgent::spawn_with(
        "fake",
        &profile,
        std::path::Path::new("/tmp"),
        session.inbound_tx().clone(),
        tap,
        Some(("sh".into(), vec!["-c".into(), script.into()])),
        Some(tr),
        Some((&session.id, "fake")),
    )
    .await
    .unwrap();
    *session.child.lock().await = Some(child.clone());
    child
}

fn bound_events(hub: &Hub, id: &str) -> Vec<Value> {
    hub.events(id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|r| r.dir == "mux" && r.kind == "remote_start_bound")
        .map(|r| r.msg)
        .collect()
}

/// Whether process `pid` still runs (a zombie does not).
#[cfg(target_os = "linux")]
fn running(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()
        .and_then(|s| s.rsplit_once(") ").map(|(_, rest)| !rest.starts_with('Z')))
        .unwrap_or(false)
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_sandboxed_claude_that_writes_nothing_is_stopped_with_an_error() {
    let (hub, session) = hub_with("remote-start-silent");
    let child = spawn(&hub, &session, "exec sleep 600").await;
    let pid = child.pid.unwrap();
    assert!(running(pid));
    let tap = session.taps.load(Ordering::SeqCst);
    hub.watch_remote_start(&session, &child, tap, std::time::Duration::from_millis(300));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while (bound_events(&hub, &session.id).is_empty() || running(pid))
        && std::time::Instant::now() < deadline
    {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let events = bound_events(&hub, &session.id);
    assert_eq!(events.len(), 1, "{events:?}");
    let error = events[0]["error"].as_str().unwrap();
    assert!(error.contains("remote-chain sandbox (remote-chain.sb)"), "{error}");
    assert!(error.contains("next:"), "{error}");
    assert!(!running(pid), "acpmux stops the child it started");
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_sandboxed_claude_that_writes_a_line_is_left_running() {
    let (hub, session) = hub_with("remote-start-heard");
    let child =
        spawn(&hub, &session, r#"echo '{"type":"system","subtype":"status"}'; exec sleep 600"#)
            .await;
    let pid = child.pid.unwrap();
    let tap = session.taps.load(Ordering::SeqCst);
    hub.watch_remote_start(&session, &child, tap, std::time::Duration::from_millis(300));
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
    assert!(bound_events(&hub, &session.id).is_empty());
    assert!(running(pid));
    child.terminate(std::time::Duration::from_millis(200)).await;
}

#[test]
fn the_forced_answer_fails_the_turn_naming_the_sandbox() {
    let answer = json!({"stopReason": "cancelled",
                        "_meta": {"acpmux": {"remoteStartBoundMs": 60_000}}});
    let e = Hub::remote_start_bound_error(&answer).unwrap();
    assert!(e.message.starts_with("the sandboxed agent wrote nothing in 60s;"), "{}", e.message);
    assert!(e.message.contains("remote-chain.sb"));
    assert_eq!(e.data.as_ref().unwrap()["reason"], "remote.start_bound");
    assert!(Hub::remote_start_bound_error(&json!({"stopReason": "cancelled"})).is_none());
}
