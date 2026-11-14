//! Part of `Hub`; see `hub/mod.rs`. Claude Code refuses every command once its own Bash
//! sandbox fails to start ("Sandbox is required but failed to initialize"): the session looks
//! alive, every other tool works, and nothing else says so. The first refusal of a failure is
//! recorded as a mux `harness_sandbox_failed`; later ones add nothing. It ends with a
//! `harness_sandbox_recovered` when a command completes or a new harness process starts.
//! The session's `harness_sandbox` (`session_liveness::HarnessSandbox`) projects both, is
//! saved with it and caught up from the log after a hard stop: the summary's
//! `harnessSandboxFailed` (the first refusal, kept) and `harnessSandboxFailing` (now), which
//! `acpmux ls` shows as `harness sandbox` while it lasts.
//!
//! Cheap: only a failed `tool_call_update` is read, only its first text blocks, and only their
//! first `SCAN` characters; command calls are remembered only while it fails, at most `CALLS`.

use super::*;

use crate::session_liveness::HarnessSandbox;

pub(super) const RECORD_KIND: &str = HarnessSandbox::FAILED;

/// Claude Code's own wording for a command it refuses because its sandbox did not start.
const REFUSALS: [&str; 2] =
    ["Sandbox is required but failed to initialize", "Sandbox is enabled but failed to initialize"];
const BLOCKS: usize = 4;
const SCAN: usize = 4096;
const MAX_ERROR: usize = 240;
const CALLS: usize = 8;

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
        let head =
            text.char_indices().nth(SCAN).map_or(text, |(i, _)| text.get(..i).unwrap_or(text));
        let at = REFUSALS.iter().filter_map(|r| head.find(r)).min()?;
        let line = head.get(at..)?.lines().next().unwrap_or_default();
        Some(super::session::masked_preview(line, MAX_ERROR))
    })
}

impl Hub {
    /// A tool update of `session`'s agent (`stalled_turn.rs`): the first refusal of a failure
    /// is recorded, and a command that completes while it fails ends it. Every other update,
    /// and every later refusal, does nothing.
    pub(super) fn note_harness_sandbox(&self, session: &Session, update: &Value) {
        let failing =
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).harness_sandbox.clone();
        if !failing.failing {
            let Some(error) = refusal(update) else { return };
            let first = failing.first_at.unwrap_or_else(crate::store::now_ms);
            self.append(
                session,
                "mux",
                RECORD_KIND,
                json!({"error": error, "toolCallId": update.get("toolCallId"), "firstAt": first}),
            );
            return;
        }
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
        let mut calls = session.harness_sandbox_calls.lock().unwrap_or_else(|e| e.into_inner());
        match (update.get("sessionUpdate").and_then(Value::as_str), update.get("status")) {
            (Some("tool_call"), _)
                if update.get("kind").and_then(Value::as_str) == Some("execute") =>
            {
                if calls.len() == CALLS {
                    calls.pop_front();
                }
                calls.push_back(id.to_owned());
            }
            (Some("tool_call_update"), Some(status))
                if status == "completed" && calls.iter().any(|c| c == id) =>
            {
                calls.clear();
                drop(calls);
                self.harness_sandbox_recovered(session, "command");
            }
            _ => {}
        }
    }

    /// `session`'s harness runs commands again (`why`: one completed, or a new harness process
    /// started, `lifecycle.rs`): a failure it had ends. None, nothing.
    pub(super) fn harness_sandbox_recovered(&self, session: &Session, why: &str) {
        let state = session.meta.lock().unwrap_or_else(|e| e.into_inner()).harness_sandbox.clone();
        if !state.failing {
            return;
        }
        session.harness_sandbox_calls.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.append(
            session,
            "mux",
            HarnessSandbox::RECOVERED,
            json!({"why": why, "firstAt": state.first_at}),
        );
    }

    /// A restored `session` whose log ran past its saved metadata (a hard stop): the newest
    /// sandbox record in that unsaved tail, if any, sets its state (`catch_up_locked`). Reads
    /// only the tail.
    pub(super) fn catch_up_harness_sandbox(&self, session: &Session, saved_seq: u64) {
        let mut newest = None;
        let _ = self.store.scan_back(
            &session.id,
            saved_seq,
            u64::MAX,
            &|dir, kind| {
                dir != b"mux"
                    || (kind != HarnessSandbox::FAILED.as_bytes()
                        && kind != HarnessSandbox::RECOVERED.as_bytes())
            },
            &mut |record| {
                newest = Some(record);
                false
            },
        );
        if let Some(record) = newest {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.harness_sandbox.observe(&record.kind, &record.msg, record.at);
        }
    }
}

#[cfg(test)]
mod tests;
