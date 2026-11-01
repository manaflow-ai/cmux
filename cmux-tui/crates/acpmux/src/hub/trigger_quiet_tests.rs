//! Verified trigger turns use the shared quiet renderer but never a person's notifications.
use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

async fn fixture() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    (hub, session)
}

fn options(trigger: bool) -> PromptOptions {
    // Internal hub seam: the dedicated RPC derives this from verified scope.
    // The public provenance parser rejects this kind from Local and Other senders.
    PromptOptions { provenance: trigger.then(|| json!({"kind":"trigger", "triggerId":"t", "deliveryId":"d", "owner":"u", "team":"team", "machine":"m"})), ..Default::default() }
}

fn blocks(text: &str) -> Vec<Value> {
    vec![json!({"type":"text", "text":text})]
}

#[tokio::test]
async fn trigger_quiet_long_completion_preserves_human_summary() {
    let (hub, session) = fixture().await;
    hub.prompt(&session, blocks("person's earlier message"), "test", false).await.unwrap();
    session.meta.lock().unwrap().unread = false;
    let before = session.meta();
    let start = session.seq.load(Ordering::SeqCst);
    let long = "completed background work ".repeat(100);
    hub.prompt_with(&session, blocks(&long), "trigger", false, options(true)).await.unwrap();
    let after = session.meta();
    assert_eq!(after.unread, before.unread);
    assert_eq!(after.preview, before.preview);
    assert_eq!(after.last_prompt, before.last_prompt);
    assert_eq!(after.last_turn, before.last_turn);
    let records = hub.events(&session.id, start, 10_000).unwrap();
    let marks: Vec<_> = records.iter().filter(|r| r.kind == background_turn::RECORD_KIND).collect();
    assert_eq!(marks.len(), 2);
    assert_eq!(marks[0].msg["trigger"], "system");
    assert_eq!(marks[1].msg["id"], marks[0].msg["id"]);
    assert_eq!(marks[1].msg["quiet"], false, "long text renders fully without pinging");
    let result = records.iter().find(|r| r.kind == "turn_result").unwrap();
    assert_eq!(result.msg["trigger"], true);
    assert_eq!(result.msg["unread"], false);
    session.meta.lock().unwrap().unread = true;
    let start = session.seq.load(Ordering::SeqCst);
    hub.prompt_with(&session, blocks("Nothing new."), "trigger", false, options(true))
        .await
        .unwrap();
    assert!(session.meta().unread, "background work must not clear a prior unread message");
    let records = hub.events(&session.id, start, 10_000).unwrap();
    let end = records
        .iter()
        .find(|r| r.kind == background_turn::RECORD_KIND && r.msg["state"] == "ended")
        .unwrap();
    assert_eq!(end.msg["quiet"], true, "the shared quiet rule makes a compact row");
    hub.prompt(&session, blocks("person's next message"), "test", false).await.unwrap();
    assert_ne!(session.meta().last_turn, before.last_turn, "next human turn stays ordinary");
}

#[tokio::test]
async fn trigger_quiet_human_and_trigger_prompts_never_steer_into_each_other() {
    for running_trigger in [true, false] {
        let (hub, session) = fixture().await;
        let dir = tempfile::tempdir().unwrap();
        let fifo = dir.path().join("gate");
        let path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: the test owns the valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        let mut events = hub.subscribe();
        let first = {
            let (hub, session) = (hub.clone(), session.clone());
            let text = format!("gate: {}", fifo.display());
            tokio::spawn(async move {
                hub.prompt_with(&session, blocks(&text), "first", false, options(running_trigger))
                    .await
            })
        };
        tokio::time::timeout(WAIT, async {
            loop {
                let event = events.recv().await.unwrap();
                if event.record.msg.pointer("/params/update/content/text").and_then(Value::as_str)
                    == Some("before-gate")
                {
                    break;
                }
            }
        })
        .await
        .unwrap();
        let (sent, accepted) = tokio::sync::oneshot::channel();
        let second = {
            let (hub, session) = (hub.clone(), session.clone());
            let mut opts = options(!running_trigger);
            opts.on_accepted = Some(Box::new(move |v| {
                let _ = sent.send(v);
            }));
            tokio::spawn(async move {
                hub.prompt_with(&session, blocks("separate prompt"), "second", true, opts).await
            })
        };
        let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
        assert_eq!(accepted["queued"], true, "{accepted}");
        assert_ne!(accepted["steer"], true, "{accepted}");
        tokio::task::spawn_blocking(move || std::fs::write(fifo, b"go")).await.unwrap().unwrap();
        let first = tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
        let second = tokio::time::timeout(WAIT, second).await.unwrap().unwrap().unwrap();
        assert_ne!(first.pointer("/_meta/acpmux/turnId"), second.pointer("/_meta/acpmux/turnId"));
    }
}

#[tokio::test]
async fn trigger_quiet_question_keeps_attention_visible() {
    let (hub, session) = fixture().await;
    let mut events = hub.subscribe();
    let task = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt_with(
                &session,
                blocks("question: Which option?"),
                "trigger",
                false,
                options(true),
            )
            .await
        })
    };
    tokio::time::timeout(WAIT, async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.kind == "permission_request" {
                break;
            }
        }
    })
    .await
    .unwrap();
    assert!(!session.permissions.lock().unwrap().pending.is_empty());
    // Cancellation settles the outstanding question; it never auto-approves it.
    hub.cancel(&session).await.unwrap();
    let _ = tokio::time::timeout(WAIT, task).await.unwrap().unwrap();
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    let ended = records
        .iter()
        .find(|r| r.kind == background_turn::RECORD_KIND && r.msg["state"] == "ended")
        .unwrap();
    assert_eq!(ended.msg["quiet"], false, "a question must not be collapsed");
    assert!(session.meta().last_turn.is_none());
}

#[tokio::test]
async fn trigger_quiet_restart_cut_fails_instead_of_resuming_as_human() {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id":"trigger-cut", "name":"cut", "harness":"fake",
        "cwd":"/tmp", "status":"idle", "createdAt":1, "updatedAt":1,
        "preview":"human preview", "lastTurn":{"turnId":"human", "status":"completed"}
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("trigger-cut").unwrap();
    hub.append(
        &session,
        "mux",
        "turn_started",
        json!({
            "turnId":"cut", "promptId":"delivery", "trigger":true,
            "control":"local", "trustGate":true
        }),
    );
    assert!(hub.log_restart_continuation(&session, "cut").is_none());
    *session.log_load.lock().unwrap() = false;
    session.log_loaded.store(false, Ordering::SeqCst);
    hub.load_session_log(&session);
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    let result = records.iter().find(|r| r.kind == "turn_result").unwrap();
    assert_eq!(result.msg["status"], "failed");
    assert_eq!(result.msg["detail"], "outcome_unknown");
    assert_eq!(result.msg["promptId"], "delivery");
    assert_eq!(result.msg["trigger"], true);
    assert!(result.msg["errorText"].as_str().unwrap().contains("inspect its outcome"));
    assert!(!records.iter().any(|r| r.kind == "auto_resume_scheduled" || r.kind == "queued"));
    assert_eq!(session.meta().last_turn, meta.last_turn);
    assert_eq!(session.meta().preview, meta.preview);
}
