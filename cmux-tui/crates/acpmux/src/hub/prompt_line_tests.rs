//! A prompt's turn, end to end (`turns.rs`): another agent's message leaves its sender and
//! first line on the summary and titles a new chat by its words, never by its envelope (Leo,
//! 2026-10-30, on his sidebar: "a lot of these subtitles are bad").

use super::*;

/// A hub on the stand-in agent, which titles no chat itself, with no generated titles.
fn hub() -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
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
