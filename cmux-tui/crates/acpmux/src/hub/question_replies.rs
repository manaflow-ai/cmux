//! Part of `Hub`; see `hub/mod.rs`. The reply to a question no caller waits for goes back to the
//! session that asked (W5-S, bench round 4 A5 defect 2, 2026-11-08).
//!
//! A session's `acpmux send --no-wait --class question` (or `block`) to a session it did not
//! start goes into the receiver's inbox (`inbox.rs`). Before this, the receiver's answer stayed in
//! its own transcript: a lane reports only to the session that started it (`lane_reports.rs`), and
//! nobody read the reply on the send (the outbox's delivery keeps a request open, so the notice
//! even said the asker was "waiting for it"). In the bench, a subagent asked `bench4-beta` with
//! `--no-wait` and then ran `acpmux wait`; `81` reached nobody.
//!
//! Now such a message ([`super::inbox::reply_goes_back`]: a question or a block from a session
//! here, no caller still waiting for it) makes the turn that answers it report to the asker, as a
//! lane's turn reports to its parent: the report goes to the Claude Code subagent that asked
//! while it runs (`lane_report_subagents.rs`, acpmux's Bash hook hands it over), else to the
//! asker's chat as a `lane_report` prompt. The receiver's notice says so, so it ends its turn
//! with its answer instead of sending it as well.
//!
//! A notice that ran as its own turn reports when it ends (its turn ended before). One steered
//! into a running turn waits for that turn's end (`Inbox::replies_due`): its reply is that turn's.
//! A daemon restart forgets the replies due.

use super::lane_reports::Report;
use super::*;

/// A reply due to the session that asked: its asker, the asking subagent (`{id, type}`) and the
/// message it answers.
#[derive(Debug, Clone)]
pub(super) struct ReplyDue {
    pub(super) asker: String,
    pub(super) subagent: Option<Value>,
}

impl Hub {
    /// A question or block from session `asker` (another session here) that runs as a turn of
    /// its own, not as an inbox notice (`turns.rs`: the inbox is off, the chat reads none, or
    /// the asker started this chat), and that no caller reads the reply of: its reply goes
    /// back when the turn that answers it ends. A lane's own parent hears it as a lane report
    /// already (`lane_reports.rs`), so it is left out.
    pub(super) fn question_reply_on_turn(
        &self,
        session: &Session,
        asker: Option<String>,
        subagent: Option<Value>,
        class: Option<crate::prompt_class::PromptClass>,
        reads_reply: bool,
    ) {
        use crate::prompt_class::PromptClass;
        let Some(asker) = asker.filter(|a| *a != session.id) else { return };
        if reads_reply || !matches!(class, Some(PromptClass::Question | PromptClass::Block)) {
            return;
        }
        let parent = self.lane_links(|links| links.get(&session.id).map(|l| l.parent.clone()));
        if parent.as_deref() == Some(asker.as_str()) {
            return;
        }
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        inbox.replies_due.push(ReplyDue { asker, subagent });
    }

    /// The notice that carried `due`'s messages went in and ended (`inbox.rs` `notice_done`):
    /// their replies go back now when it ran as its own turn (which ended), or when it was
    /// `steered` into a turn that ended already; else at the end of that turn
    /// ([`Hub::question_replies_turn_ended`]).
    pub(super) fn question_replies_due(
        self: &Arc<Self>,
        session: &Arc<Session>,
        due: Vec<ReplyDue>,
        steered: bool,
    ) {
        if due.is_empty() {
            return;
        }
        if steered && session.turn().is_some() {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            inbox.replies_due.extend(due);
            return;
        }
        self.question_replies_send(session, due);
    }

    /// `session`'s turn ended: the replies due at its end go back (`inbox_turn_ended`).
    pub(super) fn question_replies_turn_ended(self: &Arc<Self>, session: &Arc<Session>) {
        let due = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            std::mem::take(&mut inbox.replies_due)
        };
        if !due.is_empty() {
            self.question_replies_send(session, due);
        }
    }

    /// Reports `session`'s last turn to each asker in `due`, once per asker and subagent.
    fn question_replies_send(self: &Arc<Self>, session: &Arc<Session>, due: Vec<ReplyDue>) {
        let mut seen: Vec<(String, Option<Value>)> = Vec::new();
        for d in due {
            let key = (d.asker.clone(), d.subagent.clone());
            if seen.contains(&key) || d.asker == session.id {
                continue;
            }
            seen.push(key);
            let report = self.lane_capture_reply(session, d.subagent);
            let (hub, from, asker) = (self.clone(), session.id.clone(), d.asker);
            tokio::spawn(async move {
                if let Err(e) = hub.question_reply_deliver(&asker, &from, &report).await {
                    tracing::warn!(asker = %asker, from = %from, "question reply not delivered: {}", e.message);
                }
            });
        }
    }

    /// Hands `report` (of `from`'s turn) to `asker`: to its asking subagent while that runs,
    /// else to its chat, saying whose it was once the subagent has ended.
    pub(super) async fn question_reply_deliver(
        self: &Arc<Self>,
        asker: &str,
        from: &str,
        report: &Report,
    ) -> Result<(), RpcError> {
        let local = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(asker).cloned();
        let Some(p) = local else { return Ok(()) };
        if super::queue::closing(&p) {
            return Ok(());
        }
        let ended;
        let report = if report.for_subagent.is_some() && !report.subagent_ended {
            if self.lane_report_to_subagent(&p, report, true) {
                return Ok(());
            }
            ended = report.subagent_gone();
            &ended
        } else {
            report
        };
        self.lane_report_to_parent(p, from, report).await
    }
}
