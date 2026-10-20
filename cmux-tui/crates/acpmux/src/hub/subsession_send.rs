//! Part of `Hub`; see `hub/mod.rs`. `send_message` (`_acpmux/subsession/send`):
//! how a family message reaches a session with a running turn (`Delivery`),
//! what the sender reads back about it, and the "currently doing" line a
//! parent reads of a child (`get_session`'s `doing`).

use super::subsessions::refused;
use super::*;

impl Hub {
    /// `_acpmux/subsession/send`: a prompt from `caller` to a descendant or
    /// to its parent, delivered as `deliver` says (`Delivery`).
    pub async fn subsession_send(
        self: &Arc<Self>,
        caller: &Arc<Session>,
        target: &Arc<Session>,
        text: &str,
        deliver: Option<Delivery>,
        prompt_id: Option<String>,
    ) -> Result<Value, RpcError> {
        if text.trim().is_empty() {
            return Err(RpcError::invalid_params("text must not be empty"));
        }
        if target.meta().status == SessionStatus::Closed {
            return Err(refused(
                "subsessions.closed",
                "that session is closed; start a new one with start_session".to_owned(),
                json!({"sessionId": target.id}),
            ));
        }
        // A child reports to its parent; it never stops the parent's turn.
        let to_parent =
            caller.meta().subsession.as_ref().is_some_and(|l| l.started_by == target.id);
        // A parent's word reaches a working child at its next step; a
        // child's report waits for its parent's turn to end.
        let deliver =
            deliver.unwrap_or(if to_parent { Delivery::AfterTurn } else { Delivery::NextStep });
        if deliver == Delivery::Interrupt && to_parent {
            return Err(RpcError::invalid_params(
                "a sub-session never interrupts its parent: send without interrupt, and the message waits for the parent's turn to end",
            ));
        }
        if deliver == Delivery::Interrupt && target.turn().is_some() {
            self.cancel(target).await?;
        }
        let steer = deliver == Delivery::NextStep;
        let accepted = self.send_family_prompt(caller, target, text, prompt_id, steer).await?;
        Ok(sent_reply(target, &accepted))
    }
}

/// How `send_message` delivers its text to a session with a running turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    /// Into the running turn: the agent reads it at its next tool step, the
    /// way a person's mid-turn message reaches Claude Code. An agent that
    /// takes no prompt mid-turn gets it when the turn ends instead.
    NextStep,
    /// Queued behind the running turn: the agent reads it when the turn ends.
    AfterTurn,
    /// Stops the running turn first, then runs it.
    Interrupt,
}

impl Delivery {
    /// `deliver` (`next_step`, `after_turn`, `interrupt`) or the older
    /// `interrupt: true`; None leaves the default to the sender's place.
    pub fn parse(deliver: Option<&str>, interrupt: bool) -> Result<Option<Self>, RpcError> {
        let named = match deliver {
            None => None,
            Some("next_step") => Some(Self::NextStep),
            Some("after_turn") => Some(Self::AfterTurn),
            Some("interrupt") => Some(Self::Interrupt),
            Some(other) => {
                return Err(RpcError::invalid_params(format!(
                    "deliver must be next_step, after_turn or interrupt, not {other:?}"
                )));
            }
        };
        match (named, interrupt) {
            (Some(d), true) if d != Self::Interrupt => Err(RpcError::invalid_params(
                "interrupt: true contradicts deliver; send one of them",
            )),
            (None, true) => Ok(Some(Self::Interrupt)),
            (d, _) => Ok(d),
        }
    }
}

/// `send_message`'s answer: how the text went (`delivery`: `started` a turn,
/// `next_step` into the running one, or `queued` behind it at `position`),
/// and the receiver's queue, so the sender knows when it will be read.
fn sent_reply(target: &Session, accepted: &Value) -> Value {
    let queued = accepted["queued"].as_bool().unwrap_or(false);
    let delivery = if accepted["steer"].as_bool().unwrap_or(false) {
        "next_step"
    } else if queued {
        "queued"
    } else {
        "started"
    };
    json!({
        "sessionId": target.id,
        "delivery": delivery,
        "queued": queued,
        "position": accepted.get("position").cloned().unwrap_or(Value::Null),
        "queueLength": target.queued(),
        // Whether its agent takes a message mid-turn at all.
        "steering": target.steering.load(Ordering::SeqCst),
        "turnId": accepted.get("turnId"),
    })
}

/// What the sender `from` is to the receiver `to` in their family: its
/// `parent`, its `subsession`, or a farther `ancestor` or `descendant`.
pub(super) fn family_role(from: &SessionMeta, to: &SessionMeta) -> &'static str {
    let started_by = |m: &SessionMeta| m.subsession.as_ref().map(|l| l.started_by.clone());
    let depth = |m: &SessionMeta| m.subsession.as_ref().map_or(0, |l| l.depth);
    if started_by(to).as_deref() == Some(from.id.as_str()) {
        "parent"
    } else if started_by(from).as_deref() == Some(to.id.as_str()) {
        "subsession"
    } else if depth(from) < depth(to) {
        "ancestor"
    } else {
        "descendant"
    }
}

/// A sub-session's "currently doing" line for its parent: while a turn runs,
/// its plan step and latest tool (`activity.rs`), else what the turn was
/// asked; while it waits on the person, that; else null (its `state` and
/// `lastReply` say the rest).
pub(super) fn doing(summary: &Value) -> Value {
    let turn = &summary["turn"];
    if summary["lane"]["state"] == "input" {
        return json!("Waiting for the user to answer it");
    }
    if turn.is_null() {
        return Value::Null;
    }
    let line = super::activity::doing_line(turn["planStep"].as_str(), turn["activity"].as_str())
        .or_else(|| turn["prompt"].as_str().map(|p| format!("Working on: {}", short_text(p, 120))));
    line.map_or(Value::Null, Value::String)
}
