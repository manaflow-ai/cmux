//! A prompt's turn, end to end (`turns.rs`): another agent's message leaves its sender and
//! first line on the summary and titles a new chat by its words, never by its envelope (Leo,
//! 2026-10-30, on his sidebar: "a lot of these subtitles are bad").

use super::*;

/// A hub on the stand-in agent, which titles no chat itself, with no generated titles.
fn hub() -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake], "env": {"FAKE_ECHO_GUIDANCE": "1"}}}, "defaultHarness": "fake",
                     "titles": {"generate": false}});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A new chat's first prompt, from `client`; with `provenance`, from another session `from`, as
/// a peer's forward of its message queues it (`first_work_tests.rs`).
async fn prompted(text: &str, client: &str, provenance: Option<Value>) -> SessionMeta {
    let hub = hub();
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let blocks = vec![json!({"type": "text", "text": text})];
    let agent = provenance.as_ref().and_then(|p| p.get("fromName")?.as_str()).map(str::to_owned);
    let class = agent.as_ref().map(|_| crate::prompt_class::PromptClass::Block);
    let opts = PromptOptions { provenance, agent, class, ..PromptOptions::default() };
    hub.prompt_with(&s, blocks, client, false, opts).await.unwrap();
    s.meta()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_shell_sends_first_prompt_titles_the_chat_by_its_words() {
    let m = prompted("[coord] Fix the grid spacing\nmore below", "acpmux-cli#7", None).await;
    assert_eq!(m.title.as_deref(), Some("Fix the grid spacing"));
    assert_eq!(m.last_prompt.as_deref(), Some("coord: Fix the grid spacing"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn another_agents_first_message_titles_the_chat_by_its_words() {
    let text = "Merged #23727\nMore below";
    let p = json!({"kind": "session_message", "from": "acp:s1", "fromName": "coord-deputy", "to": "acp:s2"});
    let m = prompted(text, "test", Some(p)).await;
    assert_eq!(m.title.as_deref(), Some("Merged #23727"));
    assert_eq!(m.last_prompt.as_deref(), Some("coord-deputy: Merged #23727"));
    // The person's own first prompt titles it as before.
    let m = prompted("Fix the sidebar spinner", "acpmux-cli#7", None).await;
    assert_eq!(m.title.as_deref(), Some("Fix the sidebar spinner"));
}

/// The sidebar hover card's History lists what was asked, not acpmux's notices (Leo
/// 2026-11-01: "the details aren't even very useful"): an inbox notice and a digest are notices;
/// another agent's message and the person's prompt are not.
#[test]
fn inbox_notices_and_digests_are_notices_and_messages_are_not() {
    use super::prompt_line::is_notice;
    assert!(is_notice(Some(&json!({"kind": super::inbox::NOTICE_KIND}))));
    assert!(is_notice(Some(&json!({"kind": super::digest::DIGEST_KIND}))));
    assert!(is_notice(Some(&json!({"kind": super::digest::inbox_digest::KIND}))));
    assert!(!is_notice(Some(&json!({"kind": "session_message", "fromName": "coord"}))));
    assert!(!is_notice(None), "the person's own prompt");
}

/// A tool's notice (`prompt_provenance::notice`) leaves its sender and title on the summary, not
/// the `[notice from …]` line its agent got.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tools_notice_reads_as_its_sender_and_title() {
    let notice =
        json!({"sender": "base-red-watch", "severity": "fire", "title": "fast tier failed"});
    let text = crate::prompt_provenance::notice_text(&notice, "3 PRs red");
    let p = crate::prompt_provenance::notice(&notice, "s2");
    let m = prompted(&text, "test", Some(p)).await;
    assert_eq!(m.last_prompt.as_deref(), Some("base-red-watch: fast tier failed"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn context_inventory_overrides_reach_only_the_first_turn_and_new_sessions_pick_up_edits() {
    let hub = hub();
    hub.config.write().await.context_overrides.user = Some("old instruction".into());
    let req = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let original = hub.new_session(req()).await.unwrap();
    // A failed startup can advance the turn count without writing context.
    original.meta.lock().unwrap().turn_count = 1;
    hub.config.write().await.context_overrides.user = Some("new instruction".into());
    let next = hub.new_session(req()).await.unwrap();
    for session in [&original, &next] {
        for text in ["first words", "second words"] {
            hub.prompt(session, vec![json!({"type":"text", "text":text})], "test", false)
                .await
                .unwrap();
        }
    }
    for (session, expected, absent) in [
        (&original, "old instruction", "new instruction"),
        (&next, "new instruction", "old instruction"),
    ] {
        assert!(session.meta().cmux_context_delivered);
        let records = hub.events(&session.id, 0, 1_000).unwrap();
        let replies: String = records
            .iter()
            .filter(|e| e.kind == "agent_message_chunk")
            .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
            .collect();
        assert_eq!(replies.matches(expected).count(), 1, "{replies}");
        assert!(!replies.contains(absent), "{replies}");
        let prompts: Vec<_> = records.iter().filter(|e| e.kind == "user_message").collect();
        assert_eq!(prompts.len(), 2);
        assert_eq!(prompts[0].msg["text"], "first words");
        assert_ne!(prompts[0].msg["hiddenContext"], true);
        assert_eq!(
            hub.logged_prompt_blocks(session, &prompts[0].msg).unwrap(),
            vec![json!({"type":"text", "text":"first words"})],
            "saved snapshot context must not prevent Retry or restart replay"
        );
        assert_ne!(prompts[1].msg["hiddenContext"], true);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn context_inventory_keeps_unrecorded_client_context_unreplayable() {
    let hub = hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let blocks = vec![
        json!({"type":"text", "text":"first words"}),
        json!({"type":"text", "text":"unrecorded client context", "_meta":{"acpmux":{"context":true}}}),
    ];
    hub.append_prompt(&session, json!({"text":"first words"}), &blocks, None);
    let records = hub.events(&session.id, 0, 100).unwrap();
    let prompt = records.iter().find(|e| e.kind == "user_message").unwrap();
    assert_eq!(prompt.msg["hiddenContext"], true);
    assert!(hub.logged_prompt_blocks(&session, &prompt.msg).is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn context_inventory_fresh_fork_of_a_legacy_chat_captures_local_guidance() {
    let hub = hub();
    hub.config.write().await.context_overrides.user = Some("LEGACY-FORK-GUIDANCE".into());
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"first"})], "test", false).await.unwrap();
    {
        let mut meta = parent.meta.lock().unwrap();
        meta.cmux_context = None;
        meta.cmux_context_delivered = true;
        meta.status = SessionStatus::Running;
        // A working adapter without native forking reconstructs from the mux log.
        meta.agent_capabilities = Some(json!({}));
    }
    let fork = hub.fork(&parent, None, None, Default::default(), None, None, true).await.unwrap();
    let meta = fork.meta();
    assert!(!meta.cmux_context_delivered);
    assert!(
        meta.cmux_context
            .as_ref()
            .unwrap()
            .iter()
            .any(|part| part.text.as_deref() == Some("LEGACY-FORK-GUIDANCE"))
    );
    hub.prompt(&fork, vec![json!({"type":"text", "text":"next"})], "test", false).await.unwrap();
    assert!(fork.meta().cmux_context_delivered);
    let records = hub.events(&fork.id, 0, 1_000).unwrap();
    let replies: String = records
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    assert!(replies.contains("LEGACY-FORK-GUIDANCE"), "{replies}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn context_inventory_a_fork_into_another_folder_sends_that_folders_instructions() {
    let hub = hub();
    let parent_dir = tempfile::tempdir().unwrap();
    std::fs::write(parent_dir.path().join("AGENTS.md"), "PARENT-FOLDER-WORDS").unwrap();
    let child_dir = tempfile::tempdir().unwrap();
    std::fs::write(child_dir.path().join("GEMINI.md"), "CHILD-FOLDER-WORDS").unwrap();
    let parent = hub
        .new_session(NewRequest { cwd: Some(parent_dir.path().into()), ..Default::default() })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"first"})], "test", false).await.unwrap();
    {
        let mut meta = parent.meta.lock().unwrap();
        assert!(meta.cmux_context_delivered);
        meta.status = SessionStatus::Running;
        meta.agent_capabilities = Some(json!({}));
    }
    let fork = hub
        .fork(&parent, None, Some(child_dir.path().into()), Default::default(), None, None, true)
        .await
        .unwrap();
    // The parent had sent its first-turn context; the fork into another folder sends its own.
    assert!(!fork.meta().cmux_context_delivered);
    hub.prompt(&fork, vec![json!({"type":"text", "text":"next"})], "test", false).await.unwrap();
    let records = hub.events(&fork.id, 0, 1_000).unwrap();
    let replies: String = records
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    assert!(replies.contains("CHILD-FOLDER-WORDS"), "{replies}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn context_inventory_requeues_an_unstarted_request_once_from_its_log() {
    let hub = hub();
    hub.config.write().await.context_overrides.user = Some("saved guidance".into());
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let mut blocks = vec![json!({"type":"text", "text":"original request"})];
    crate::context_inventory::append_snapshot(session.meta().cmux_context.as_deref(), &mut blocks);
    hub.append_prompt(
        &session,
        json!({"text":"original request", "promptId":"accepted", "turnId":"unstarted", "control":"local"}),
        &blocks,
        None,
    );
    // Restart recovery reads these saved records before a turn ever starts.
    hub.restore_queue(&session);
    hub.restore_queue(&session);
    let records = hub.events(&session.id, 0, 100).unwrap();
    let queued: Vec<_> = records.iter().filter(|e| e.kind == "queued").collect();
    assert_eq!(queued.len(), 1);
    assert_eq!(queued[0].msg["restored"], "unstarted");
    assert_eq!(queued[0].msg["prompt"], json!([{"type":"text", "text":"original request"}]));
}
