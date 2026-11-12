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
//! The asker is the session the daemon bound the send to ([`asker_of`]), never a `from` a caller
//! wrote. A reply belongs to one turn (review B2 of #39055): it is due under the prompt that
//! carries the question (its own prompt, or the inbox notice) until that prompt's turn starts, or
//! its steer is written into a running turn; then under that turn's id. Only that turn's end sends
//! it, with what that turn did (`started`: a turn whose agent never got the prompt reports it
//! failed, with no reply). A prompt that never reached a turn (a Stop or a refusal before it
//! started) drops its replies. A lane's own parent hears the turn as a lane report already
//! (`lane_reports.rs`), so it gets none. An asker on another machine gets none either: the reply
//! goes only to a session here. A daemon restart forgets the replies due.

use super::lane_reports::Report;
use super::*;

/// The session that asked, as the daemon bound the send to it: the `fromSessionId` of a
/// verified `session_message` (the daemon writes that kind itself, `server/requests.rs`), or of a
/// verified provenance whose `from` names the same session. Never a `from` a caller wrote alone:
/// a forged `from: <victim>` would put the reply, and a turn, in the victim's chat (review B1 of
/// #39055).
pub(super) fn asker_of(provenance: Option<&Value>) -> Option<String> {
    let p = provenance?;
    if p.get(crate::prompt_provenance::VERIFIED).and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let bound = crate::prompt_provenance::sender_of(Some(p)).0.filter(|id| !id.is_empty())?;
    let daemons = p.get("kind").and_then(Value::as_str) == Some("session_message");
    let same = super::inbox::sender_session(Some(p)).as_deref() == Some(bound.as_str());
    (daemons || same).then_some(bound)
}

/// Replies one session keeps due at most: past it the oldest go (a turn that never ended).
const KEEP_DUE: usize = 64;

/// A reply due to the session that asked: the prompt that carries the question, the turn that
/// answers it once known, the asker, the asking subagent (`{id, type}`) and the caller that
/// reads the reply on its send, if any (`PromptOptions::reply_reader`).
#[derive(Debug, Clone)]
pub(super) struct ReplyDue {
    pub(super) prompt_id: String,
    pub(super) turn: Option<String>,
    pub(super) asker: String,
    pub(super) subagent: Option<Value>,
    pub(super) reader: Option<tokio::sync::watch::Receiver<bool>>,
}

impl ReplyDue {
    /// A reply due under prompt `prompt_id`, whose turn is not known yet.
    pub(super) fn pending(prompt_id: &str, asker: String, subagent: Option<Value>) -> Self {
        Self { prompt_id: prompt_id.to_owned(), turn: None, asker, subagent, reader: None }
    }

    /// Its caller still reads the reply on its send: that reply is the answer, no report.
    fn read_on_the_send(&self) -> bool {
        self.reader.as_ref().is_some_and(|ended| !*ended.borrow())
    }
}

/// Drops the replies still due under a prompt that never reached a turn, when that prompt's
/// request ends (`turns.rs`).
pub(super) struct PendingReply {
    session: Arc<Session>,
    prompt_id: String,
}

impl Drop for PendingReply {
    fn drop(&mut self) {
        let mut inbox = self.session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        inbox.replies_due.retain(|d| d.turn.is_some() || d.prompt_id != self.prompt_id);
    }
}

/// Adds `due` to `inbox`'s replies due, keeping at most [`KEEP_DUE`].
pub(super) fn keep_due(inbox: &mut super::inbox::Inbox, due: ReplyDue) {
    if inbox.replies_due.len() >= KEEP_DUE {
        inbox.replies_due.remove(0);
    }
    inbox.replies_due.push(due);
}

impl Hub {
    /// A question or block from session `asker` that runs as a prompt of its own, not as an
    /// inbox notice (`turns.rs`: the inbox is off, the chat reads none, or the asker started this
    /// chat), and that no caller reads the reply of: its reply is due under `prompt_id` until
    /// that prompt's turn is known. The guard drops it if none ever is.
    pub(super) fn question_reply_pending(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        asker: Option<String>,
        subagent: Option<Value>,
        class: Option<crate::prompt_class::PromptClass>,
        reads_reply: bool,
    ) -> Option<PendingReply> {
        use crate::prompt_class::PromptClass;
        let asker = asker.filter(|a| *a != session.id)?;
        if reads_reply || !matches!(class, Some(PromptClass::Question | PromptClass::Block)) {
            return None;
        }
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        keep_due(&mut inbox, ReplyDue::pending(prompt_id, asker, subagent));
        Some(PendingReply { session: session.clone(), prompt_id: prompt_id.to_owned() })
    }

    /// Prompt `prompt_id` reached turn `turn_id`: its turn started (`turns.rs`), or its steer was
    /// written into that running turn (`steer_end.rs`). The replies due under it are that turn's.
    pub(super) fn question_reply_in_turn(&self, session: &Session, prompt_id: &str, turn_id: &str) {
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        for d in inbox.replies_due.iter_mut().filter(|d| d.turn.is_none()) {
            if d.prompt_id == prompt_id {
                d.turn = Some(turn_id.to_owned());
            }
        }
    }

    /// Prompt `prompt_id` (a notice, or a prompt of its own) ended: `went_in`, the replies due
    /// under it that reached no turn go; not in (refused, or a Stop took its steer back unread),
    /// they all go, also one tied to the turn its steer was written into. Its messages come again
    /// as a new notice, with replies of their own.
    pub(super) fn question_replies_settled(
        &self,
        session: &Session,
        prompt_id: &str,
        went_in: bool,
    ) {
        let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        inbox.replies_due.retain(|d| d.prompt_id != prompt_id || (went_in && d.turn.is_some()));
    }

    /// `session`'s turn `turn_id` (number `turn`) ended (`inbox_turn_ended`): the replies due at
    /// its end go back, with what it did (`started`: its agent got the prompt).
    pub(super) fn question_replies_turn_ended(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn_id: &str,
        turn: u64,
        started: bool,
    ) {
        let due: Vec<ReplyDue> = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            let (due, keep) = std::mem::take(&mut inbox.replies_due)
                .into_iter()
                .partition(|d| d.turn.as_deref() == Some(turn_id));
            inbox.replies_due = keep;
            due
        };
        if due.is_empty() {
            return;
        }
        // A lane's parent hears this turn as the lane's report (`lane_reports.rs`).
        let parent = self.lane_links(|links| links.get(&session.id).map(|l| l.parent.clone()));
        let mut seen: Vec<(String, Option<Value>)> = Vec::new();
        for d in due {
            if d.asker == session.id
                || parent.as_deref() == Some(d.asker.as_str())
                || d.read_on_the_send()
            {
                continue;
            }
            let key = (d.asker.clone(), d.subagent.clone());
            if seen.contains(&key) {
                continue;
            }
            seen.push(key);
            let report = self.lane_capture_reply(session, turn, started, d.subagent);
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
        let Some(p) = local else {
            tracing::debug!(asker, from, "question reply dropped: the asker is no session here");
            return Ok(());
        };
        if super::queue::closing(&p) {
            tracing::debug!(asker, from, "question reply dropped: the asker's chat is closing");
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

#[cfg(test)]
#[path = "question_replies_tests.rs"]
mod question_replies_tests;
