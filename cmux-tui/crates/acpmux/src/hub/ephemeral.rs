//! What a throwaway session's log keeps of its prompts (`SessionMeta::throwaway`).
//!
//! A throwaway session (`_meta.acpmux.throwaway`) is purged by its creator right after its work:
//! each node of a Chief's compactor (`optchat-chief` `compactor.rs`), purged minutes after its one
//! prompt. Unlike `_meta.acpmux.ephemeral` it does not tie the session to the connection (the
//! compactor's warm sessions outlive a reconnect), and an ephemeral run keeps its bodies so a
//! failed first send can still be resent. #41526 left one copy of each prompt in the log,
//! its `user_message`. For a compactor node that copy is about 3.1 MB, about 1,000 nodes an hour,
//! journaled and then purged: about 6 GB an hour written for nothing (Leo's laptop, 2026-11-11,
//! 549 GB in 23.6 h; cmuxterm-hq#9636). Leo, 2026-11-12: "what happened with the chief disk
//! thing? or chief memory? on compactions? can we just fix that?"
//!
//! So a throwaway session's `user_message` keeps a short preview of a long prompt, not its body:
//! the row still reads, and the record says how many bytes it left out (`bodyLeftOut`). A retry
//! or a restart never runs such a prompt again from that preview (`retry_turn.rs`
//! `prompt_blocks`, `unstarted_prompt.rs`).

use crate::claude_stdio::PROMPT_BODY_KEPT_UNDER;
use serde_json::{Value, json};

/// Characters of a long prompt's text a throwaway session's `user_message` keeps.
pub(crate) const PREVIEW_CHARS: usize = 200;

/// The field of a `user_message` that left its body out: the bytes left out.
pub(crate) const BODY_LEFT_OUT: &str = "bodyLeftOut";

/// Whether the `user_message` `msg` left its body out, so no retry or restart can run it again.
pub(crate) fn body_left_out(msg: &Value) -> bool {
    msg.get(BODY_LEFT_OUT).is_some()
}

/// `msg`, a throwaway session's `user_message` about to be logged, without a long body: its
/// `text` becomes a short preview and its `inlineParts` go. A short prompt stays as it is.
pub(crate) fn leave_out_body(msg: &mut Value) {
    let text_len = msg.get("text").and_then(Value::as_str).map_or(0, str::len);
    let parts_len = msg.get("inlineParts").map_or(0, |p| p.to_string().len());
    if text_len < PROMPT_BODY_KEPT_UNDER && parts_len < PROMPT_BODY_KEPT_UNDER {
        return;
    }
    let Some(fields) = msg.as_object_mut() else { return };
    // Only the head is read: the whole body is never copied again.
    let preview = fields
        .get("text")
        .and_then(Value::as_str)
        .map(|t| {
            let head: String = t.chars().take(PREVIEW_CHARS * 4).collect();
            super::session::short_text(&head, PREVIEW_CHARS)
        })
        .unwrap_or_default();
    fields.insert("text".into(), Value::String(preview));
    // Each of these names ranges or parts of the whole text (`session.rs` `mark_pasted`).
    for key in ["inlineParts", "pasted", "agentText"] {
        fields.remove(key);
    }
    fields.insert(BODY_LEFT_OUT.into(), json!(text_len.saturating_add(parts_len)));
}

#[cfg(test)]
mod tests {
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
}
