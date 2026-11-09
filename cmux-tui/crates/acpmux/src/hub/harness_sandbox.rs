//! Part of `Hub`; see `hub/mod.rs`. Claude Code refuses every command once its own Bash
//! sandbox fails to start ("Sandbox is required but failed to initialize"): the session looks
//! alive, every other tool works, and nothing else says so. The first such refusal is recorded
//! once per session as a mux `harness_sandbox_failed` and read back as the summary's
//! `harnessSandboxFailed`, which `acpmux ls` shows as `harness sandbox`.
//!
//! Cheap: only a failed `tool_call_update` is read, only its first text blocks, and only their
//! first `SCAN` characters.

use super::*;

pub(super) const RECORD_KIND: &str = "harness_sandbox_failed";

/// Claude Code's own wording for a command it refuses because its sandbox did not start.
const REFUSALS: [&str; 2] =
    ["Sandbox is required but failed to initialize", "Sandbox is enabled but failed to initialize"];
const BLOCKS: usize = 4;
const SCAN: usize = 4096;
const MAX_ERROR: usize = 240;

/// The refusal line of `update` when it is a failed tool result carrying one, masked and
/// bounded; None for every other update.
pub(super) fn refusal(update: &Value) -> Option<String> {
    if update.get("sessionUpdate").and_then(Value::as_str) != Some("tool_call_update")
        || update.get("status").and_then(Value::as_str) != Some("failed")
    {
        return None;
    }
    let blocks = update.get("content").and_then(Value::as_array)?;
    blocks.iter().take(BLOCKS).find_map(|block| {
        let text = block.pointer("/content/text").and_then(Value::as_str)?;
        let head = text.char_indices().nth(SCAN).map_or(text, |(i, _)| &text[..i]);
        let at = REFUSALS.iter().filter_map(|r| head.find(r)).min()?;
        let line = head[at..].lines().next().unwrap_or_default();
        Some(super::session::masked_preview(line, MAX_ERROR))
    })
}

impl Hub {
    /// A tool update of `session`'s agent (`stalled_turn.rs`): the first sandbox refusal is
    /// recorded; every later one, and every other update, does nothing.
    pub(super) fn note_harness_sandbox(&self, session: &Session, update: &Value) {
        if session.harness_sandbox_failed.get().is_some() {
            return;
        }
        let Some(error) = refusal(update) else { return };
        if session.harness_sandbox_failed.set(crate::store::now_ms()).is_err() {
            return;
        }
        self.append(
            session,
            "mux",
            RECORD_KIND,
            json!({"error": error, "toolCallId": update.get("toolCallId")}),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result(status: &str, text: &str) -> Value {
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": status,
               "content": [{"type": "content", "content": {"type": "text", "text": text}}]})
    }

    #[test]
    fn a_failed_result_with_claudes_sandbox_refusal_is_found() {
        let text = "Sandbox is required but failed to initialize: EPERM: operation not permitted, listen '/tmp/srt-mux-2-2.sock'. Restart to retry.\nmore";
        let found = refusal(&result("failed", text)).expect("refusal");
        assert!(
            found.starts_with("Sandbox is required but failed to initialize: EPERM"),
            "{found}"
        );
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

    /// Every later Bash call fails the same way: one record, one summary change, never a flood.
    #[tokio::test]
    async fn the_first_refusal_is_recorded_once_and_shown_in_the_summary() {
        let hub = Hub::new(
            crate::config::Config::default(),
            Box::new(crate::store::MemoryStore::default()),
        );
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "sandbox-test", "name": "sandbox-test",
            "harness": "fake", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        let session = hub.make_session(meta);
        assert!(hub.session_summary(&session)["harnessSandboxFailed"].is_null());
        let before = session.state_seq.load(Ordering::SeqCst);
        let text = "Sandbox is required but failed to initialize: EPERM: operation not permitted, listen '/tmp/srt-mux-2-2.sock'";
        for _ in 0..5 {
            hub.note_harness_sandbox(&session, &result("failed", text));
        }
        assert_eq!(session.state_seq.load(Ordering::SeqCst), before + 1);
        assert!(hub.session_summary(&session)["harnessSandboxFailed"].is_u64());
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
}
