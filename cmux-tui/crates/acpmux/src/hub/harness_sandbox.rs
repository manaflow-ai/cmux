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

    const REFUSED: &str = "Sandbox is required but failed to initialize: EPERM: operation not permitted, listen '/tmp/srt-mux-2-2.sock'";

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
}
