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
        attachments: Vec<Value>,
        deliver: Option<Delivery>,
        prompt_id: Option<String>,
    ) -> Result<Value, RpcError> {
        // Never files from an agent a remote device drives, before anything reads them.
        if !attachments.is_empty() {
            self.subsession_attach_check(caller)?;
        }
        // The uploads it names as its own (by their owner token) go if it is refused
        // (`attach::OwnedUploads`, `Saved`).
        let mut owned = crate::attach::OwnedUploads(
            crate::prompt_uploads::owned(&target.id, &attachments).await,
        );
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
        // A message goes into the receiver's running turn unless the sender asks to queue it, in
        // both directions: a steer never cancels the tool call the agent runs (it reads the message
        // at its next tool boundary, #22797), and an agent that takes no message mid-turn gets it
        // when the turn ends (`send_family_prompt`). Leo, 2026-10-22: agent messages steer by default.
        let deliver = deliver.unwrap_or(Delivery::NextStep);
        if deliver == Delivery::Interrupt && to_parent {
            return Err(RpcError::invalid_params(
                "a sub-session never interrupts its parent: send without interrupt. A working parent reads the message at its next tool step (or when its turn ends, if its agent takes no message mid-turn); an idle one starts a turn with it",
            ));
        }
        // An interrupt stops the running turn only once the message is accepted, so a message the
        // agent pair guard holds never cancels it (`Hub::interrupt_once_queued`).
        let (steer, interrupt) = (deliver == Delivery::NextStep, deliver == Delivery::Interrupt);
        // Never to a session that asks less than the sender (`subsession_guard.rs`); a queued
        // one is checked again when it runs (`turns.rs`).
        self.receiver_check(caller, target).await?;
        let mut blocks = vec![json!({"type": "text", "text": text})];
        blocks.extend(attachments);
        // Inline files fit one JSON-RPC message and are saved in the receiver's uploads, and files
        // sent by reference are read from them, as any message's are (`attach.rs`,
        // `prompt_uploads.rs`).
        crate::attach::check_wire(&json!({"sessionId": target.id, "prompt": blocks}))?;
        let (id, web) = (target.id.clone(), Self::web_turn(caller));
        let received = tokio::task::spawn_blocking(move || {
            if crate::prompt_uploads::any(&blocks) {
                crate::prompt_uploads::resolve(&id, web, &mut blocks)?;
            }
            crate::attach::receive(&id, web, &mut blocks).map(|saved| (blocks, saved))
        });
        let (blocks, saved) = received.await.map_err(|e| RpcError::internal(e.to_string()))??;
        let saved = crate::attach::Saved::with_owned(saved, &target.id, owned.take());
        let accepted = self
            .send_family_prompt(caller, target, blocks, prompt_id, steer, interrupt, None, saved)
            .await?;
        Ok(sent_reply(target, &accepted))
    }

    /// Whether `caller` may send files with a message: not while a remote device drives it (its
    /// turn, or its last one, is a Web turn, `remote_floor.rs`), since `send_message` reads the
    /// files it names as the agent's user on this machine. `send_message` asks this before it
    /// reads any file (`attachCheck`), and every send with files is checked again here.
    pub fn subsession_attach_check(&self, caller: &Session) -> Result<(), RpcError> {
        if Self::web_turn(caller) {
            return Err(refused(
                "attach.remote",
                "an agent a remote device drives cannot send files with a message".to_owned(),
                json!({"sessionId": caller.id}),
            ));
        }
        Ok(())
    }
}

/// How `send_message` delivers its text to a session with a running turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    /// Into the running turn: the agent reads it at its next tool step, the
    /// way a person's mid-turn message reaches Claude Code. An agent that
    /// takes no prompt mid-turn gets it when the turn ends instead. The default.
    NextStep,
    /// Queued behind the running turn: the agent reads it when the turn ends.
    AfterTurn,
    /// Stops the running turn first, then runs it.
    Interrupt,
}

impl Delivery {
    /// `deliver` (`next_step`, `after_turn`, `interrupt`) or the older
    /// `interrupt: true`; None is the default, `NextStep`.
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
/// `next_step` into the running one, `queued` behind it at `position`, or
/// `waiting_for_slot` of its parent's run slots),
/// and the receiver's queue, so the sender knows when it will be read.
fn sent_reply(target: &Session, accepted: &Value) -> Value {
    let queued = accepted["queued"].as_bool().unwrap_or(false);
    let delivery = if accepted["steer"].as_bool().unwrap_or(false) {
        "next_step"
    } else if accepted["waitsForSlot"].as_bool().unwrap_or(false) {
        // No turn runs: its parent's run slots are all taken (`subsession_runs.rs`).
        "waiting_for_slot"
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

/// What a sub-session waits on the person for, when it does: `question`
/// (an agent question, with its first prompt) or `permission`. Only the
/// person allows a permission (`person.rs`), in the app's card or with
/// `acpmux allow` from their own terminal. An ancestor may answer a question
/// only when the person turned that on (`subsession_answer.rs`, the row's
/// `questions`); otherwise the person answers it too.
pub(super) fn waiting_on(s: &Session) -> Option<(&'static str, Option<String>)> {
    waiting_cut(s, short_text)
}

/// The question prompt [`waiting_on`] reads, masked before its cut
/// (`session::masked_preview`): the sub-session tools' `doing` quotes it.
pub(super) fn masked_waiting_prompt(s: &Session) -> Option<String> {
    waiting_cut(s, super::session::masked_preview).and_then(|w| w.1)
}

/// [`waiting_on`], its question prompt cut to 120 characters by `cut`.
fn waiting_cut(
    s: &Session,
    cut: fn(&str, usize) -> String,
) -> Option<(&'static str, Option<String>)> {
    let pending = s.pending_permissions();
    let question = pending.iter().find(|(_, r)| super::questions::needs_person(r));
    match (question, pending.first()) {
        (Some((_, r)), _) => {
            let prompt = super::questions::question(r)
                .and_then(|q| q.pointer("/items/0/prompt"))
                .and_then(Value::as_str)
                .map(|p| cut(p, 120));
            Some(("question", prompt))
        }
        (None, Some(_)) => Some(("permission", None)),
        (None, None) => None,
    }
}

/// A sub-session's "currently doing" line for its parent: while it waits on
/// the person, what for (the summary's `waitingOn`, from [`waiting_on`]);
/// while a turn runs, its plan step and latest tool (`activity.rs`), else
/// what the turn was asked; else null (its `state` and `lastReply` say the rest).
pub(super) fn doing(summary: &Value) -> Value {
    let turn = &summary["turn"];
    match (summary["waitingOn"].as_str(), summary["waitingPrompt"].as_str()) {
        (Some("question"), Some(prompt)) => {
            return json!(format!("Waiting for the user to answer, in the app: {prompt}"));
        }
        (Some("question"), None) => {
            return json!("Waiting for the user to answer a question, in the app");
        }
        (Some(_), _) => return json!("Waiting for the user to allow a tool, in the app"),
        (None, _) if summary["lane"]["state"] == "input" => {
            return json!("Waiting for the user to answer it");
        }
        (None, _) => {}
    }
    if turn.is_null() {
        return Value::Null;
    }
    let line = super::activity::doing_line(turn["planStep"].as_str(), turn["activity"].as_str())
        .or_else(|| turn["prompt"].as_str().map(|p| format!("Working on: {}", short_text(p, 120))));
    line.map_or(Value::Null, Value::String)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_child_waiting_on_the_user_says_what_for() {
        let waiting = |on: &str, prompt: Value| {
            json!({"lane": {"state": "input"}, "turn": {"prompt": "fix it"},
                   "waitingOn": on, "waitingPrompt": prompt})
        };
        assert_eq!(
            doing(&waiting("question", json!("Which branch?"))),
            "Waiting for the user to answer, in the app: Which branch?"
        );
        assert_eq!(
            doing(&waiting("permission", Value::Null)),
            "Waiting for the user to allow a tool, in the app"
        );
        let input = json!({"lane": {"state": "input"}, "turn": {"prompt": "fix it"}});
        assert_eq!(doing(&input), "Waiting for the user to answer it");
        let working = json!({"lane": {"state": "working"}, "turn": {"activity": "Run cargo test"}});
        assert_eq!(doing(&working), "Run cargo test");
        assert_eq!(doing(&json!({"lane": {"state": "idle"}, "turn": null})), Value::Null);
    }
}
