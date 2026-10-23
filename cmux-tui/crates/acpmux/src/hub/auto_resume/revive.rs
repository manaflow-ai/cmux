//! A chat whose agent process is gone comes back by itself (2026-10-20: lane `chief-fix` sat
//! `disconnected` for hours after its agent closed mid-turn, two coordinator messages held).
//!
//! - An agent that dies mid-turn: its turn is continued like one a connection error cut off
//!   (`auto_resume.rs`, cause `agent_exited`).
//! - An agent that exits between turns, after a turn it answered or before any: the chat is
//!   `idle` (no agent; the next prompt starts one on the same conversation with `session/load`),
//!   not `disconnected`, logged as `agent_exited {betweenTurns: true}`. Prompts queued behind
//!   it start the agent as they run. After a turn that failed or was stopped it stays
//!   `disconnected` as before: a limit or a sign-in failure stays visible to the reconciler
//!   that moves such chats (`lastTurn`), and an exhausted continuation keeps its queue held.
//! - A prompt that comes while a continuation waits out its delay fires it now and runs after
//!   it (`hurry_auto_resume`).

use super::super::{Hub, Session, SessionStatus};
use super::Mark;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

/// The longest a prompt waits for a continuation it hurried to start its turn.
const HURRY_LIMIT: Duration = Duration::from_secs(30);

impl Hub {
    /// A prompt arrived: the chat's continuation waiting out its delay fires now, and this
    /// returns once it started its turn (the prompt then queues behind it) or was dropped. A
    /// turn that just ended is settled first. Bounded by [`HURRY_LIMIT`].
    pub(in crate::hub) async fn hurry_auto_resume(&self, session: &Session) {
        let _ = tokio::time::timeout(HURRY_LIMIT, async {
            loop {
                let moved = self.auto_resumes.1.notified();
                tokio::pin!(moved);
                moved.as_mut().enable();
                let pending = {
                    let marks = self.auto_resumes.lock();
                    match marks.get(&session.id) {
                        Some(Mark::Waiting(_, wake)) => {
                            wake.notify_one();
                            true
                        }
                        Some(Mark::Firing(_) | Mark::Ending(_)) => true,
                        Some(Mark::Stopped(_)) | None => false,
                    }
                };
                if !pending {
                    return;
                }
                moved.await;
            }
        })
        .await;
    }

    /// The agent process exited and nobody stopped it (`Inbound::Exited`). With no turn
    /// running, the chat is settled now; else once that turn ends (`settle_exit`).
    pub(in crate::hub) fn agent_gone(self: &Arc<Self>, session: &Arc<Session>, code: Option<i32>) {
        if let Ok(_free) = session.turn_lock.try_lock() {
            if self.exit_leaves_idle(session) {
                self.idle_after_exit(session, code);
            } else {
                self.set_status(session, SessionStatus::Disconnected);
            }
            return;
        }
        self.set_status(session, SessionStatus::Disconnected);
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move { hub.settle_exit(&session, code).await });
    }

    /// After the turn that ran when the agent exited: the chat is idle when that turn left it
    /// `disconnected` with nothing lost (`exit_leaves_idle`) and no agent started since.
    async fn settle_exit(self: &Arc<Self>, session: &Arc<Session>, code: Option<i32>) {
        let _turn = session.turn_lock.lock().await;
        if session.status() != SessionStatus::Disconnected || session.child.lock().await.is_some() {
            return;
        }
        if self.exit_leaves_idle(session) {
            self.idle_after_exit(session, code);
        }
    }

    /// Whether a chat whose agent is gone, under its turn lock, is idle rather than
    /// disconnected: no turn, no continuation pending, and its last turn answered (or none ran).
    fn exit_leaves_idle(&self, session: &Session) -> bool {
        let pending = matches!(
            self.auto_resumes.lock().get(&session.id),
            Some(Mark::Waiting(..) | Mark::Firing(_) | Mark::Ending(_))
        );
        let last = session.meta().last_turn;
        let status = last.as_ref().and_then(|t| t.get("status")).and_then(Value::as_str);
        session.turn().is_none() && !pending && matches!(status, None | Some("completed"))
    }

    fn idle_after_exit(&self, session: &Session, code: Option<i32>) {
        self.append(session, "mux", "agent_exited", json!({"betweenTurns": true, "code": code}));
        self.set_status(session, SessionStatus::Idle);
    }

    /// A turn refused after it was accepted (dispatch check, remote floor): failed unstarted.
    pub(in crate::hub) fn refuse_started_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
    ) {
        self.fail_unstarted_turn(session, prompt_id, turn_id, e);
        if session.status() == SessionStatus::Disconnected {
            self.set_status(session, SessionStatus::Ready);
        }
    }

    /// A prompt that left the queue (`dequeued`, `waiting`) refused before its turn: the log
    /// settles it with `prompt_refused`, so a restart does not queue it again (`restore_queue`).
    pub(in crate::hub) fn refuse_dequeued(
        &self,
        session: &Arc<Session>,
        waiting: bool,
        prompt_id: &str,
        turn_id: &str,
        client: &str,
        e: &RpcError,
    ) {
        if waiting {
            let msg = json!({"promptId": prompt_id, "turnId": turn_id, "client": client, "error": e.message, "data": e.data});
            self.append(session, "mux", "prompt_refused", msg);
        }
    }

    /// A recorded prompt whose agent could not start: the turn ends failed, so every client
    /// sees the prompt settle instead of a turn that never starts.
    pub(in crate::hub) fn fail_unstarted_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
    ) {
        *session.turn.lock().unwrap() = None;
        self.append(
            session,
            "mux",
            "turn_error",
            json!({"error": e.message, "code": e.code, "turnId": turn_id, "turnSeq": 0}),
        );
        self.pause_queue(session, turn_id);
        let msg = json!({"status": "failed", "error": e.message, "code": e.code, "turnSeq": 0, "turnId": turn_id, "promptId": prompt_id});
        self.record_last_turn(session, &msg);
        self.append(session, "mux", "turn_result", msg);
        self.reset_stream(session);
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Disconnected);
        }
        self.save_meta(session);
    }
}
