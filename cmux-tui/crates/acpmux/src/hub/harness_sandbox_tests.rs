use super::*;

fn result(status: &str, text: &str) -> Value {
    json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": status,
           "content": [{"type": "content", "content": {"type": "text", "text": text}}]})
}

#[test]
fn a_failed_result_with_claudes_sandbox_refusal_is_found() {
    let text = "Sandbox is required but failed to initialize: EPERM: operation not permitted, listen '/tmp/srt-mux-2-2.sock'. Restart to retry.\nmore";
    let found = refusal(&result("failed", text)).expect("refusal");
    assert!(found.starts_with("Sandbox is required but failed to initialize: EPERM"), "{found}");
    assert!(!found.contains("more"), "{found}");
    let enabled = "```\nSandbox is enabled but failed to initialize. Until the sandbox can start, commands that would run in it are refused.\n```";
    assert!(refusal(&result("failed", enabled)).is_some());
}

#[test]
fn anything_but_a_failed_result_with_the_refusal_is_ignored() {
    let text = "Sandbox is required but failed to initialize: EPERM";
    // A completed call that printed the words (a grep of this file) is no refusal.
    assert_eq!(refusal(&result("completed", text)), None);
    assert_eq!(refusal(&result("failed", "exit code 1")), None);
    let start = json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "status": "failed",
                       "content": [{"type": "content", "content": {"type": "text", "text": text}}]});
    assert_eq!(refusal(&start), None);
    // Past the scanned head of a long output.
    let late = format!("{}{text}", "x".repeat(SCAN));
    assert_eq!(refusal(&result("failed", &late)), None);
}

const REFUSED: &str = "Sandbox is required but failed to initialize: EPERM: operation not permitted, listen '/tmp/srt-mux-2-2.sock'";

#[tokio::test]
async fn remote_repository_refusal_is_visible_and_reaches_the_starters_watch() {
    let mut m = meta("remote-refusal");
    m.remote_origin = true;
    let (hub, session) = restored(m, &[]);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    let mut watch = super::super::watches::Watch {
        id: "starter-report".into(),
        to: "starter".into(),
        sessions: vec![session.id.clone()],
        until: vec!["blocked".into()],
        match_text: None,
        once: true,
        caller: None,
        active: true,
        cursors: [(session.id.clone(), Default::default())].into_iter().collect(),
        offline: Default::default(),
        ..Default::default()
    };
    hub.append(
        &session,
        "mux",
        "turn_result",
        json!({"turnId": "early-progress", "status": "completed"}),
    );
    assert!(
        super::super::watch_events::collect(&hub, &mut watch, &session.id)
            .await
            .unwrap()
            .0
            .is_empty()
    );
    let denied = "fatal: Unable to create '/tmp/work/.git/index.lock': Permission denied";
    hub.note_harness_sandbox(&session, &result("failed", denied));
    let summary = hub.session_summary(&session);
    assert_eq!(summary["indicator"], "failed");
    assert_eq!(summary["lane"]["state"], "failed");
    assert!(summary["lane"]["error"].as_str().unwrap().contains("index.lock"));
    assert!(summary["lane"]["error"].as_str().unwrap().contains("Full access"));

    let (rows, _) =
        super::super::watch_events::collect(&hub, &mut watch, &session.id).await.unwrap();
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert!(rows[0].contains("blocked") && rows[0].contains("index.lock"), "{rows:?}");
    assert!(rows[0].contains("Full access"), "{rows:?}");
    assert!(
        super::super::watch_events::collect(&hub, &mut watch, &session.id)
            .await
            .unwrap()
            .0
            .is_empty()
    );

    hub.note_harness_sandbox(&session, &execute("unrelated-command"));
    hub.note_harness_sandbox(&session, &done("unrelated-command", "completed"));
    assert_eq!(hub.session_summary(&session)["harnessSandboxFailing"], true);
    hub.harness_sandbox_recovered(&session, "respawn");
    assert_eq!(hub.session_summary(&session)["harnessSandboxFailing"], false);
}

#[tokio::test]
async fn remote_harness_sandbox_recovers_after_its_command_succeeds() {
    let mut m = meta("remote-harness-recovery");
    m.remote_origin = true;
    let (hub, session) = restored(m, &[]);
    hub.note_harness_sandbox(&session, &result("failed", REFUSED));
    hub.note_harness_sandbox(&session, &execute("recovered-command"));
    hub.note_harness_sandbox(&session, &done("recovered-command", "completed"));
    assert_eq!(hub.session_summary(&session)["harnessSandboxFailing"], false);
}

#[test]
fn remote_refusal_does_not_infer_a_sandbox_from_an_arbitrary_command_error() {
    assert!(remote_refusal(&result("failed", "test failed: assertion mismatch")).is_none());
    let denied = "mkdir .git: Permission denied";
    assert!(remote_refusal(&result("completed", denied)).is_none());
    assert!(remote_refusal(&result("failed", denied)).is_some());
    assert!(
        remote_refusal(&result("failed", "Read-only file system: /home/user/.cache/state"))
            .is_some()
    );
}

fn meta(id: &str) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "fake", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap()
}

/// A hub whose memory store holds `meta` and `records` (the memory store keeps the records
/// of a session it holds), and the session made from them, as a daemon start makes it.
fn restored(
    meta: crate::store::SessionMeta,
    records: &[crate::store::EventRecord],
) -> (Arc<Hub>, Arc<Session>) {
    let store = crate::store::MemoryStore::default();
    crate::store::Store::save(&store, &meta).unwrap();
    for record in records {
        crate::store::Store::append(&store, &meta.id, record).unwrap();
    }
    let hub = Hub::new(crate::config::Config::default(), Box::new(store));
    let session = hub.make_session(meta);
    // As a daemon start restores it: its log is caught up when it loads.
    session.caught_up.store(false, Ordering::SeqCst);
    (hub, session)
}

fn kinds(hub: &Hub, id: &str) -> Vec<String> {
    hub.events(id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|r| r.dir == "mux" && r.kind.starts_with("harness_sandbox"))
        .map(|r| r.kind)
        .collect()
}

fn execute(id: &str) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute",
           "rawInput": {"command": "true"}, "status": "pending"})
}

fn done(id: &str, status: &str) -> Value {
    json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": status})
}

/// Every later Bash call fails the same way: one record, one summary change, never a flood.
#[tokio::test]
async fn the_first_refusal_is_recorded_once_and_shown_in_the_summary() {
    let (hub, session) = restored(meta("sandbox-test"), &[]);
    let summary = hub.session_summary(&session);
    assert!(summary["harnessSandboxFailed"].is_null());
    assert_eq!(summary["harnessSandboxFailing"], false);
    let before = session.state_seq.load(Ordering::SeqCst);
    for _ in 0..5 {
        hub.note_harness_sandbox(&session, &result("failed", REFUSED));
    }
    assert_eq!(session.state_seq.load(Ordering::SeqCst), before + 1);
    let summary = hub.session_summary(&session);
    assert!(summary["harnessSandboxFailed"].is_u64());
    assert_eq!(summary["harnessSandboxFailing"], true);
    let records: Vec<_> = hub
        .events("sandbox-test", 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == RECORD_KIND)
        .collect();
    assert_eq!(records.len(), 1, "{records:?}");
    assert_eq!(records[0].dir, "mux");
    assert_eq!(records[0].msg["toolCallId"], "t1");
    assert!(records[0].msg["error"].as_str().unwrap().contains("srt-mux-2-2.sock"));
}

/// A command that completes, or a new harness process, ends the failure; the first refusal's
/// time stays. Another tool completing, or a command that fails, does not. A refusal after
/// recovery starts a new failure that keeps that same first time.
#[tokio::test]
async fn a_completed_command_or_a_respawn_ends_the_failure_and_keeps_the_first_time() {
    let (hub, session) = restored(meta("recover-test"), &[]);
    hub.note_harness_sandbox(&session, &result("failed", REFUSED));
    let first = hub.session_summary(&session)["harnessSandboxFailed"].as_u64().unwrap();

    hub.note_harness_sandbox(&session, &done("read-1", "completed"));
    hub.note_harness_sandbox(&session, &execute("bash-1"));
    hub.note_harness_sandbox(&session, &done("bash-1", "failed"));
    assert_eq!(hub.session_summary(&session)["harnessSandboxFailing"], true);

    hub.note_harness_sandbox(&session, &execute("bash-2"));
    hub.note_harness_sandbox(&session, &done("bash-2", "completed"));
    let summary = hub.session_summary(&session);
    assert_eq!(summary["harnessSandboxFailing"], false);
    assert_eq!(summary["harnessSandboxFailed"], first);

    hub.note_harness_sandbox(&session, &result("failed", REFUSED));
    assert_eq!(hub.session_summary(&session)["harnessSandboxFailing"], true);
    hub.harness_sandbox_recovered(&session, "respawn");
    hub.harness_sandbox_recovered(&session, "respawn");
    let summary = hub.session_summary(&session);
    assert_eq!(summary["harnessSandboxFailing"], false);
    assert_eq!(summary["harnessSandboxFailed"], first);
    assert_eq!(
        kinds(&hub, "recover-test"),
        [RECORD_KIND, HarnessSandbox::RECOVERED, RECORD_KIND, HarnessSandbox::RECOVERED]
    );
    let records = hub.events("recover-test", 0, 1000).unwrap();
    assert!(
        records
            .iter()
            .filter(|r| r.kind.starts_with("harness_sandbox"))
            .all(|r| r.msg["firstAt"] == first)
    );
}

/// A restart keeps it: from the saved session, and after a hard stop from the log's unsaved
/// tail, with the first refusal's original time. No second "first" record follows.
#[tokio::test]
async fn a_restart_restores_the_failure_with_its_original_time() {
    let (hub, session) = restored(meta("restart-test"), &[]);
    hub.note_harness_sandbox(&session, &result("failed", REFUSED));
    let first = hub.session_summary(&session)["harnessSandboxFailed"].as_u64().unwrap();
    let records = hub.events("restart-test", 0, 1000).unwrap();

    // Saved after the refusal.
    let (hub2, again) = restored(session.meta(), &records);
    hub2.catch_up(&again);
    let summary = hub2.session_summary(&again);
    assert_eq!(summary["harnessSandboxFailing"], true);
    assert_eq!(summary["harnessSandboxFailed"], first);
    hub2.note_harness_sandbox(&again, &result("failed", REFUSED));
    assert_eq!(kinds(&hub2, "restart-test"), [RECORD_KIND]);

    // A hard stop: the saved session predates the refusal, the log holds it.
    let (hub3, hard) = restored(meta("restart-test"), &records);
    assert_eq!(hub3.session_summary(&hard)["harnessSandboxFailing"], false);
    hub3.catch_up(&hard);
    let summary = hub3.session_summary(&hard);
    assert_eq!(summary["harnessSandboxFailing"], true);
    assert_eq!(summary["harnessSandboxFailed"], first);

    // A recovery in that tail restores as recovered, the first time kept.
    hub.harness_sandbox_recovered(&session, "respawn");
    let records = hub.events("restart-test", 0, 1000).unwrap();
    let (hub4, recovered) = restored(meta("restart-test"), &records);
    hub4.catch_up(&recovered);
    let summary = hub4.session_summary(&recovered);
    assert_eq!(summary["harnessSandboxFailing"], false);
    assert_eq!(summary["harnessSandboxFailed"], first);
}
