//! A chat that outgrew its model's context window is compacted, then continued, by itself (Leo,
//! 2026-11-03, on a Claude chat whose turn failed with Claude Code's "Prompt is too long" and sat
//! failed: "this should not have happened. this should have just started compacting").
//!
//! A turn that fails with reason `context` ([`super::super::turn_errors::is_context_overflow`])
//! gets one attempt, with no wait ([`waits`]), and only in a chat whose harness can compact
//! ([`Hub::can_compact`]: Claude Code, directly or through its ACP adapter); any other harness's
//! chat settles `not_retried`, as before. The attempt has two turns, both acpmux's
//! (`provenance.kind = "auto_resume"`):
//!
//! 1. `/compact` in the same chat, prompt id `P~compact-n` (the cut prompt `P`'s attempt `n`, so it
//!    runs once across restarts too; its provenance says `step: "compact"`), after the cut turn.
//! 2. Once that turn ends and its compaction did not fail, the usual continuation `P~resume-n`
//!    after the compaction's turn ([`Hub::auto_resume`]), with no wait.
//!
//! Between them the chat's mark waits on the compaction's turn ([`Mark::Waiting`]), so Stop,
//! close or a person's prompt in between cancel the continuation the way they cancel any
//! (`auto_resume_skipped`). A Stop while it compacts records `auto_resume_skipped` `stopped`. A
//! compaction that fails (its turn failed, or the harness reported a `compaction` that `failed`)
//! records `auto_resume_exhausted` and nothing more: a chat compacting cannot help is never asked
//! again. A continuation that outgrows the window again is exhausted the same way (one attempt).

use super::{Control, CutTurn, Hub, Mark, PendingGuard, PromptOptions, Session, SessionStatus};
use super::{TurnInfo, Wake};
use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::Notify;

/// The prompt-id suffix of an attempt's compaction, before its attempt number.
pub(super) const SUFFIX: &str = "~compact-";

/// The waits of a `context` attempt: one, of none, while retries are on at all (`[]` turns
/// them off for every cause).
pub(super) fn waits(delays: &[u64]) -> Vec<u64> {
    if delays.is_empty() { Vec::new() } else { vec![0] }
}

/// The compaction an attempt runs, from its start until its turn ends.
pub(super) struct Compaction {
    /// `P~compact-n`.
    prompt_id: String,
    /// The compaction's turn, once it started.
    turn: Option<String>,
    root: String,
    cut_turn: String,
    attempt: usize,
    error: String,
    from: Option<String>,
    control: Control,
    trust_gate: bool,
}

/// Whether the compaction turn `turn` reported a failed compaction, from the chat's log back to
/// that turn's start.
fn compaction_failed(hub: &Hub, session: &Session, turn: &str) -> bool {
    let mut failed = false;
    let _ = hub.store.scan_back(
        &session.id,
        0,
        u64::MAX,
        &|_, kind| kind != b"compaction" && kind != b"turn_started",
        &mut |e| {
            if e.kind == "turn_started" {
                return e.msg.get("turnId").and_then(Value::as_str) != Some(turn);
            }
            failed = e.kind == "compaction"
                && e.msg.pointer("/params/update/state").and_then(Value::as_str) == Some("failed");
            !failed
        },
    );
    failed
}

impl Hub {
    /// Whether `session`'s harness can compact its chat: Claude Code, which takes `/compact`.
    pub(super) async fn can_compact(&self, session: &Session) -> bool {
        let harness = session.meta().harness;
        let config = self.config.read().await;
        config
            .harnesses
            .get(&harness)
            .is_some_and(|p| crate::agent_tools::is_claude_code(&harness, p))
    }

    /// Attempt `attempt` of a cut turn: compacted first when it outgrew its context, else the
    /// continuation alone.
    pub(super) async fn resume_or_compact(
        self: &Arc<Self>,
        session: &Arc<Session>,
        cut: CutTurn<'_>,
        attempt: usize,
    ) {
        if super::super::turn_errors::resume_cause(cut.error, cut.error) == Some("context") {
            self.compact_first(session, cut, attempt).await;
        } else {
            self.auto_resume(session, cut, attempt).await;
        }
    }

    /// Starts the chat's turn `turn`: the compaction's, when its prompt is the one that waits.
    pub(super) fn compaction_started(session: &Session, turn: &TurnInfo) {
        let mut step = session.auto_resume.compacting.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(step) = step.as_mut().filter(|s| s.prompt_id == turn.prompt_id) {
            step.turn = Some(turn.turn_id.clone());
        }
    }

    /// The compaction whose turn `turn_id` is, taken (`schedule_auto_resume`, before the mark).
    pub(super) fn take_compaction(session: &Session, turn_id: &str) -> Option<Compaction> {
        let mut step = session.auto_resume.compacting.lock().unwrap_or_else(|e| e.into_inner());
        if step.as_ref().is_some_and(|s| s.turn.as_deref() == Some(turn_id)) {
            step.take()
        } else {
            None
        }
    }

    /// Settles the ended turn `turn_id` of compaction `step` (`schedule_auto_resume`): `ending`
    /// as that reads the chat's mark (`Some(true)` ended, `Some(false)` stopped), `failed`
    /// whether the turn failed.
    pub(super) fn compaction_ended(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mut pending: PendingGuard<'_>,
        turn_id: &str,
        ending: Option<bool>,
        failed: bool,
        step: Compaction,
    ) {
        match ending {
            Some(true) if failed || compaction_failed(self, session, turn_id) => {
                pending.take();
                drop(pending);
                let msg = json!({"promptId": step.root, "attempts": step.attempt, "turnId": step.cut_turn, "reason": "context", "compactTurnId": turn_id});
                self.append_retry(session, "auto_resume_exhausted", msg);
                self.settled_unretried(session, turn_id, "not_retried");
            }
            Some(true) => {
                // The continuation answers for the compaction's turn now: whatever ends that
                // (Stop, close, a prompt that took the chat) ends it, as for any continuation.
                let wake = Wake(Arc::new(Notify::new()));
                pending.replace(Mark::Waiting {
                    turn: turn_id.to_owned(),
                    retry: None,
                    _wake: wake,
                });
                drop(pending);
                let (hub, session, turn) = (self.clone(), session.clone(), turn_id.to_owned());
                // Off the turn's path: the turn lock is still held here.
                tokio::spawn(async move {
                    let cut = CutTurn {
                        from: step.from.as_deref(),
                        prompt_id: &step.root,
                        turn_id: &turn,
                        control: step.control,
                        trust_gate: step.trust_gate,
                        error: &step.error,
                        not_before: None,
                    };
                    hub.auto_resume(&session, cut, step.attempt).await;
                });
            }
            // Stop or close came while it compacted: they settled the turn.
            Some(false) => {
                pending.take();
                drop(pending);
                let msg = json!({"promptId": step.root, "attempt": step.attempt, "turnId": step.cut_turn, "skipped": "stopped"});
                self.append_retry(session, "auto_resume_skipped", msg);
            }
            None => {}
        }
    }

    /// Runs attempt `attempt`'s compaction when the chat still ends on the cut turn and its
    /// harness can compact; [`Hub::compaction_ended`] sends the continuation after it.
    async fn compact_first(
        self: &Arc<Self>,
        session: &Arc<Session>,
        cut: CutTurn<'_>,
        attempt: usize,
    ) {
        if session.replaced.load(std::sync::atomic::Ordering::SeqCst) || self.shutting_down() {
            return;
        }
        let (root, cut_turn) = (cut.prompt_id, cut.turn_id);
        let skipped = |why: &str| json!({"promptId": root, "attempt": attempt, "turnId": cut_turn, "skipped": why});
        if let Err(why) = self.fire_pending(session, cut_turn) {
            self.append_retry(session, "auto_resume_skipped", skipped(why));
            return;
        }
        let why = if session.status() == SessionStatus::Closed || session.moving().is_some() {
            Some("closed")
        } else if !super::still_cut(session, cut_turn) {
            Some("superseded")
        } else if !self.can_compact(session).await {
            Some("cannot_compact")
        } else {
            None
        };
        if let Some(why) = why {
            self.clear_fired(session, cut_turn);
            self.append_retry(session, "auto_resume_skipped", skipped(why));
            return;
        }
        let prompt_id = format!("{root}{SUFFIX}{attempt}");
        *session.auto_resume.compacting.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(Compaction {
                prompt_id: prompt_id.clone(),
                turn: None,
                root: root.to_owned(),
                cut_turn: cut_turn.to_owned(),
                attempt,
                error: cut.error.to_owned(),
                from: cut.from.map(str::to_owned),
                control: cut.control,
                trust_gate: cut.trust_gate,
            });
        let mut provenance = json!({"kind": "auto_resume", "promptId": root, "attempt": attempt, "turnId": cut_turn, "step": "compact"});
        if let Some(from) = cut.from {
            provenance.set("from", json!(from));
        }
        let accepted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let on_accepted = {
            let accepted = accepted.clone();
            Box::new(move |_: Value| accepted.store(true, std::sync::atomic::Ordering::SeqCst))
        };
        let opts = PromptOptions {
            on_accepted: Some(on_accepted),
            prompt_id: Some(prompt_id.clone()),
            resend: true,
            control: cut.control,
            trust_gate: cut.trust_gate,
            provenance: Some(provenance),
            after_turn: Some(cut_turn.to_owned()),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": "/compact"})];
        let result = self.prompt_with(session, blocks, "acpmux", false, opts).await;
        let accepted = accepted.load(std::sync::atomic::Ordering::SeqCst);
        self.finish_compaction(session, cut_turn, &prompt_id, result, accepted, skipped);
    }

    /// The compaction's prompt answered. Its turn's end settled what follows
    /// ([`Hub::compaction_ended`]); one refused before its turn records why here.
    fn finish_compaction(
        &self,
        session: &Session,
        cut_turn: &str,
        prompt_id: &str,
        result: Result<Value, RpcError>,
        accepted: bool,
        skipped: impl Fn(&str) -> Value,
    ) {
        self.clear_fired(session, cut_turn);
        {
            let mut step = session.auto_resume.compacting.lock().unwrap_or_else(|e| e.into_inner());
            if step.as_ref().is_some_and(|s| s.prompt_id == prompt_id) {
                step.take();
            }
        }
        let fenced = self.shutting_down()
            && !self.restart_requested.load(std::sync::atomic::Ordering::SeqCst);
        if session.replaced.load(std::sync::atomic::Ordering::SeqCst) || fenced {
            return;
        }
        let Err(e) = result else { return };
        match e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str) {
            Some(why @ ("auto_resume.superseded" | "auto_resume.stopped")) => {
                let why = why.trim_start_matches("auto_resume.");
                self.append_retry(session, "auto_resume_skipped", skipped(why));
            }
            _ if !accepted => {
                tracing::warn!(session = %session.id, "auto compaction refused: {}", e.message);
                let mut msg = skipped("refused");
                msg.set("error", json!(e.message));
                self.append_retry(session, "auto_resume_skipped", msg);
            }
            _ => tracing::warn!(session = %session.id, "auto compaction: {}", e.message),
        }
    }
}
