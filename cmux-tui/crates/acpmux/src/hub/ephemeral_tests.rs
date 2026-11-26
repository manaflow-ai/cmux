use super::*;

#[test]
fn a_long_prompt_keeps_only_a_preview() {
    let body = "word ".repeat(700_000); // about 3.5 MB, a compactor node's prompt
    let mut msg = json!({"text": body, "promptId": "p", "turnId": "t",
        "pasted": [{"start": 3_000_000, "end": 3_000_010}],
        "inlineParts": [{"kind": "text", "text": body}, {"kind": "pasted", "text": "x"}]});
    leave_out_body(&mut msg);
    assert!(msg.to_string().len() < 1024, "{} bytes kept", msg.to_string().len());
    assert!(body_left_out(&msg));
    assert!(msg.get("inlineParts").is_none());
    assert!(msg.get("pasted").is_none(), "no range past the preview");
    assert_eq!(msg["promptId"], "p");
    assert_eq!(msg["turnId"], "t");
    assert!(msg["text"].as_str().unwrap().starts_with("word word"));
}

#[test]
fn a_short_prompt_stays() {
    let mut msg = json!({"text": "summarize this", "promptId": "p"});
    let before = msg.clone();
    leave_out_body(&mut msg);
    assert_eq!(msg, before);
    assert!(!body_left_out(&msg));
}

/// cmuxterm-hq#9636: a throwaway session's long prompt leaves its log as a preview, no retry
/// can rebuild it from that, and an ordinary session's prompt is kept whole.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_throwaway_session_logs_no_long_prompt_body() {
    use crate::config::{Config, StoreMode};
    use crate::hub::{Hub, NewRequest};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
                     "titles": {"generate": false}});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let body = "view ".repeat(200_000);
    let blocks = vec![json!({"type": "text", "text": body})];
    let mut kept = Vec::new();
    for throwaway in [true, false] {
        let req =
            NewRequest { cwd: Some(std::env::temp_dir()), throwaway, ..NewRequest::default() };
        let session = hub.new_session(req).await.unwrap();
        assert_eq!(session.meta().throwaway, throwaway);
        hub.append_prompt(
            &session,
            json!({"text": body, "promptId": "p", "turnId": "t"}),
            &blocks,
            None,
        );
        let records = hub.events(&session.id, 0, 100).unwrap();
        let prompt = records.iter().find(|e| e.kind == "user_message").unwrap();
        kept.push((
            prompt.msg.to_string().len(),
            hub.logged_prompt_blocks(&session, &prompt.msg).is_some(),
        ));
    }
    assert!(kept[0].0 < 1024, "a throwaway prompt kept {} bytes", kept[0].0);
    assert!(!kept[0].1, "no retry rebuilds a preview");
    assert!(kept[1].0 > body.len(), "an ordinary prompt is kept whole");
    assert!(kept[1].1);
}

/// 2026-11-15, Leo's laptop: every Chief compactor node asked the title model for a title,
/// about 55 haiku calls a minute for sessions no one sees. A throwaway session asks none; an
/// ordinary one still does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_throwaway_session_asks_for_no_title() {
    use crate::config::{Config, StoreMode};
    use crate::hub::{Hub, NewRequest};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
                     "titles": {"generate": false}});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut asked = Vec::new();
    for throwaway in [true, false] {
        let req =
            NewRequest { cwd: Some(std::env::temp_dir()), throwaway, ..NewRequest::default() };
        let session = hub.new_session(req).await.unwrap();
        {
            let mut m = session.meta.lock().unwrap();
            super::super::titles::set_fallback_title(&mut m, "Compaction: compress message 9");
        }
        hub.title_after_prompt(&session);
        asked.push(session.meta.lock().unwrap().title_asking);
    }
    assert_eq!(asked, [false, true]);
}
