//! A Claude chat whose stored conversation is gone resumes cleanly (2026-11-03, Aziz's Mac).
//!
//! Thirteen chats lost the messages of their Claude Code transcripts while their processes still
//! ran; when the app restarted at 13:10 each process wrote only its exit metadata back
//! (`last-prompt`, `cost-state`, `pr-link`). Every later prompt then ran `claude --resume <id>`,
//! Claude answered "No conversation found with session ID", and the turn failed; the automatic
//! continuation and each Retry failed the same way, so one prompt showed "Claude Code quit before
//! it finished this turn." four times. acpmux now:
//!
//! - starts a fresh conversation with the restored transcript when the chat's file holds no
//!   conversation, before any turn fails (`claude_resume_refusal`);
//! - marks the chat when Claude says the conversation is not found, so the automatic continuation
//!   starts fresh and answers instead of failing again.
use super::*;

/// A hub with one Claude stdio profile on its own CLAUDE_CONFIG_DIR, as Claude Code lays it out
/// (`<dir>/projects/<project>/<id>.jsonl`), and the chat's first turn answered there.
async fn chat_with_a_stored_turn(
    config_dir: &std::path::Path,
) -> (Arc<Hub>, TestClient, String, std::path::PathBuf) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let agents = BTreeMap::from([(
        "direct".to_owned(),
        HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
            env: BTreeMap::from([(
                "CLAUDE_CONFIG_DIR".to_owned(),
                config_dir.to_string_lossy().into_owned(),
            )]),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    )]);
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("direct".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg.auto_resume_delays_ms = Some(vec![20, 20, 20, 20]);
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "lost"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let first = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await
        .expect("the first turn answers");
    assert_eq!(first["stopReason"], "end_turn");
    let session = hub.resolve(&id).unwrap();
    let sid = session.meta().agent_session_id.expect("the chat has a Claude conversation");
    let file = config_dir.join("projects").join("p").join(format!("{sid}.jsonl"));
    assert!(file.is_file(), "the fake stored the conversation at {}", file.display());
    (hub, c, id, file)
}

fn kinds(hub: &Hub, id: &str) -> Vec<(String, Value)> {
    hub.events(id, 0, 10_000).unwrap().into_iter().map(|e| (e.kind, e.msg)).collect()
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-{name}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The transcript holds only what a Claude process writes as it exits: the next start begins a
/// fresh conversation with the restored transcript, and the prompt answers the first time.
#[tokio::test]
async fn a_transcript_reduced_to_exit_metadata_starts_fresh_instead_of_failing_the_turn() {
    let dir = scratch("claude-stub");
    let (hub, mut c, id, file) = chat_with_a_stored_turn(&dir).await;
    let session = hub.resolve(&id).unwrap();
    let sid = session.meta().agent_session_id.unwrap();

    // A respawn of a stored conversation still resumes it: no false refusal.
    hub.detach_child(&session).await;
    let again = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "again"}]}),
        )
        .await
        .expect("a stored conversation resumes");
    assert_eq!(again["stopReason"], "end_turn");
    assert!(
        !kinds(&hub, &id).iter().any(|(k, _)| k == "resume_failed"),
        "a conversation with messages is resumed"
    );

    // Its messages go; only the exit metadata is written back, as on 2026-11-02.
    hub.detach_child(&session).await;
    std::fs::write(
        &file,
        format!(
            "{{\"type\":\"last-prompt\",\"lastPrompt\":\"again\",\"sessionId\":\"{sid}\"}}\n\
             {{\"type\":\"cost-state\",\"sessionId\":\"{sid}\",\"totalCostUSD\":1.0}}\n"
        ),
    )
    .unwrap();
    let after = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "has this been pushed yet"}]}),
        )
        .await
        .expect("the turn answers on a fresh conversation");
    assert_eq!(after["stopReason"], "end_turn");
    let events = kinds(&hub, &id);
    let failed: Vec<_> = events.iter().filter(|(k, _)| k == "resume_failed").collect();
    assert_eq!(failed.len(), 1, "{events:?}");
    let why = failed[0].1["error"].as_str().unwrap_or_default();
    assert!(why.contains(&sid) && why.contains("has no messages"), "{why}");
    let new_sid = session.meta().agent_session_id.unwrap();
    assert_ne!(new_sid, sid, "a fresh conversation took its place");
    assert!(
        !events.iter().any(|(k, m)| k == "turn_result" && m["status"] == "failed"),
        "no turn failed: {events:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The transcript is gone altogether: the turn that tried `--resume` fails once, and its automatic
/// continuation starts a fresh conversation and answers. It never fails again with the same line.
#[tokio::test]
async fn no_conversation_found_fails_one_turn_and_its_continuation_answers_fresh() {
    let dir = scratch("claude-gone");
    let (hub, mut c, id, file) = chat_with_a_stored_turn(&dir).await;
    let session = hub.resolve(&id).unwrap();
    let sid = session.meta().agent_session_id.unwrap();
    hub.detach_child(&session).await;
    std::fs::remove_file(&file).unwrap();

    let failed = c
        .request(
            method::SESSION_PROMPT,
            json!({
                "sessionId": id,
                "prompt": [{"type": "text", "text": "has this been pushed yet"}],
                "_meta": {"acpmux": {"promptId": "p-lost"}}
            }),
        )
        .await;
    let error = failed.expect_err("Claude finds no conversation to resume");
    assert!(error.contains("No conversation found"), "{error}");

    // The continuation (`p-lost~resume-1`) starts fresh and completes.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    let completed = loop {
        let events = kinds(&hub, &id);
        let done = events.iter().any(|(k, m)| {
            k == "turn_result"
                && m["status"] == "completed"
                && m["promptId"].as_str().is_some_and(|p| p.starts_with("p-lost~resume-"))
        });
        if done || std::time::Instant::now() > deadline {
            break events;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    };
    let results: Vec<_> = completed
        .iter()
        .filter(|(k, m)| {
            k == "turn_result" && m["promptId"].as_str().is_some_and(|p| p.starts_with("p-lost"))
        })
        .map(|(_, m)| (m["promptId"].clone(), m["status"].clone()))
        .collect();
    assert_eq!(
        results,
        [(json!("p-lost"), json!("failed")), (json!("p-lost~resume-1"), json!("completed"))],
        "one failure, then the continuation answers: {completed:?}"
    );
    assert_ne!(session.meta().agent_session_id.as_deref(), Some(sid.as_str()));
    assert!(!session.meta().claude_conversation_lost, "the fresh start clears the mark");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Claude Code keeps one folder per working directory: a stub of the id in one folder beside the
/// real conversation in another is no lost conversation. Only a store where no copy holds one is.
#[test]
fn a_stub_beside_the_real_conversation_in_another_folder_is_not_empty() {
    let dir = scratch("claude-two-folders");
    let sid = "0193a1c2-7b2e-7c3d-9e4f-5a6b7c8d9e0f";
    let stub = format!("{{\"type\":\"last-prompt\",\"sessionId\":\"{sid}\"}}\n");
    let real = format!(
        "{{\"type\":\"user\",\"sessionId\":\"{sid}\",\"message\":{{\"role\":\"user\",\"content\":\"hi\"}}}}\n"
    );
    let write = |project: &str, body: &str| {
        let folder = dir.join("projects").join(project);
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(format!("{sid}.jsonl")), body).unwrap();
    };
    assert!(!acpmux::adopt::claude_transcript_is_empty(&dir, sid), "no file is nothing to judge");
    write("a-stub", &stub);
    assert!(
        acpmux::adopt::claude_transcript_is_empty(&dir, sid),
        "a lone stub is a lost conversation"
    );
    write("b-real", &real);
    assert!(
        !acpmux::adopt::claude_transcript_is_empty(&dir, sid),
        "the real conversation in another folder counts"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
