//! Part of the queue restore (`queue.rs` `restore_queue`): a prompt that started its own turn at
//! once (no `queued` record) and was accepted, but whose turn had not started when the daemon
//! stopped, goes back at the head of the queue.
//!
//! A direct prompt logs its `user_message` and answers `prompt_accepted` before it starts the
//! agent (`turns.rs` `run_prompt`), and its `turn_started` comes only once the agent is up, which
//! takes seconds for a cold harness. A daemon that stopped in between left an accepted prompt with
//! no queue entry, no open turn for the restart's continuation (`restart_resume.rs` reads
//! `turn_started`), and no result: the client was told it was taken, so it did not send it again,
//! and nothing ran it (HQ#6740, "no prompt or steer can be lost"). `turn_started` is logged before
//! the prompt goes to the agent, so such a prompt never reached it: running it after the restart
//! runs it once.
//!
//! It goes back as an ordinary `queued` record under its own prompt and turn ids, written once
//! here, so the restored queue runs it, a crash before it ran restores it again as any queued
//! prompt (`lost_start.rs`), and a client's resend of its id joins that run (the ledger entry
//! the restore makes). It keeps what the prompt came with that the run checks again: its
//! control and `cloudMobile` (the mobile asking-mode rule, `turns.rs`).
//! What settles it first: its turn's start, result or removal, a refusal, a copy queued or run
//! under another turn id, and a Stop (`logged_prompt`, checked when it would go back).

use crate::store::EventRecord;
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};

/// The direct prompts whose turn has not started, read in log order.
#[derive(Default)]
pub(super) struct Unstarted {
    /// Turns that came out of the queue: their prompts are `lost_start.rs`'s.
    queued_turns: HashSet<String>,
    /// Turns already started: a watched conversation logs `turn_started` before the prompt's
    /// `user_message` (`watch.rs`), so that prompt is never this restore's.
    started_turns: HashSet<String>,
    /// By turn id: the prompt's `user_message`, in log order of `seq`.
    by_turn: BTreeMap<String, EventRecord>,
}

fn field<'a>(e: &'a EventRecord, k: &str) -> Option<&'a str> {
    e.msg.get(k).and_then(Value::as_str).filter(|v| !v.is_empty())
}

impl Unstarted {
    /// One record of the restore's scan.
    pub(super) fn read(&mut self, e: &EventRecord) {
        if e.dir != "mux" {
            return;
        }
        let (turn, prompt) = (field(e, "turnId"), field(e, "promptId"));
        match e.kind.as_str() {
            "queued" => {
                if let Some(t) = turn {
                    self.queued_turns.insert(t.to_owned());
                }
                self.settle_prompt(prompt);
            }
            "user_message" => {
                // A steer goes into a running turn; it starts none (`steer_end.rs`).
                if e.msg.get("steer") == Some(&Value::Bool(true)) {
                    return;
                }
                let (Some(t), Some(p)) = (turn, prompt) else { return };
                // Run again under another turn id: that copy is the prompt's.
                self.by_turn.retain(|other, q| other == t || field(q, "promptId") != Some(p));
                if self.queued_turns.contains(t) || self.started_turns.contains(t) {
                    return;
                }
                let provenance = crate::prompt_provenance::recorded(&e.msg);
                // A trigger's turn is authorized again by its dispatcher (`restart_resume.rs`);
                // an inbox notice is never run again (`queue.rs`).
                if crate::prompt_provenance::is_trigger(provenance.as_ref())
                    || super::super::inbox::is_notice(provenance.as_ref())
                {
                    return;
                }
                self.by_turn.entry(t.to_owned()).or_insert_with(|| e.clone());
            }
            "turn_started" | "turn_result" | "queue_removed" | "prompt_refused" | "dequeued" => {
                if let Some(t) = turn {
                    self.by_turn.remove(t);
                    if e.kind == "turn_started" {
                        self.started_turns.insert(t.to_owned());
                    }
                }
                if e.kind != "dequeued" {
                    self.settle_prompt(prompt);
                }
            }
            _ => {}
        }
    }

    fn settle_prompt(&mut self, prompt: Option<&str>) {
        if let Some(p) = prompt {
            self.by_turn.retain(|_, q| field(q, "promptId") != Some(p));
        }
    }

    /// The `user_message` records of the prompts left unstarted, oldest first.
    pub(super) fn finish(self) -> Vec<EventRecord> {
        let mut left: Vec<EventRecord> = self.by_turn.into_values().collect();
        left.sort_by_key(|e| e.seq);
        left
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rec(seq: u64, kind: &str, msg: Value) -> EventRecord {
        EventRecord { seq, at: 0, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
    }

    fn left(records: &[EventRecord]) -> Vec<String> {
        let mut u = Unstarted::default();
        records.iter().for_each(|e| u.read(e));
        u.finish().iter().map(|e| e.msg["promptId"].as_str().unwrap().to_owned()).collect()
    }

    #[test]
    fn only_an_accepted_direct_prompt_whose_turn_never_started_is_left() {
        let um =
            |seq, p: &str, t: &str| rec(seq, "user_message", json!({"promptId": p, "turnId": t}));
        assert_eq!(left(&[um(1, "a", "ta")]), ["a"]);
        // Started, ended, refused: settled.
        assert!(
            left(&[
                um(1, "a", "ta"),
                rec(2, "turn_started", json!({"turnId": "ta", "promptId": "a"}))
            ])
            .is_empty()
        );
        assert!(
            left(&[um(1, "a", "ta"), rec(2, "turn_result", json!({"turnId": "ta"}))]).is_empty()
        );
        assert!(
            left(&[um(1, "a", "ta"), rec(2, "prompt_refused", json!({"promptId": "a"}))])
                .is_empty()
        );
        // A watched conversation's turn starts before its prompt is logged: not left.
        assert!(
            left(&[rec(1, "turn_started", json!({"turnId": "tw"})), um(2, "w", "tw")]).is_empty()
        );
        // Out of the queue: `lost_start.rs`'s.
        assert!(
            left(&[rec(1, "queued", json!({"promptId": "a", "turnId": "ta"})), um(2, "a", "ta")])
                .is_empty()
        );
        // A steer starts no turn.
        assert!(
            left(&[rec(1, "user_message", json!({"promptId": "s", "turnId": "t", "steer": true}))])
                .is_empty()
        );
        // Run again under another turn id, which started: settled.
        assert!(
            left(&[
                um(1, "a", "t1"),
                um(2, "a", "t2"),
                rec(3, "turn_started", json!({"turnId": "t2", "promptId": "a"}))
            ])
            .is_empty()
        );
        // A trigger's prompt is its dispatcher's to send again.
        let trigger =
            json!({"promptId": "x", "turnId": "tx", "_meta": {"provenance": {"kind": "trigger"}}});
        assert!(left(&[rec(1, "user_message", trigger)]).is_empty());
        // Two left, oldest first.
        assert_eq!(left(&[um(1, "b", "tb"), um(2, "a", "ta")]), ["b", "a"]);
    }
}
