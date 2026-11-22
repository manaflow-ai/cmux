//! `agent.message.unsend` (bead cx-55d27, PR 4): the sender, or the person,
//! takes a message back, with no time limit. Each recipient's delivery gets
//! one outcome:
//!
//! - `unsent`: it never reached the agent. A held, queued or failed delivery
//!   becomes `unsent` (reason `unsent`), and so does a delivered one acpmux
//!   still had waiting in the session's queue (acpmux took it out).
//! - `retracted`: acpmux runs, or ran, its turn and told the agent the
//!   message was withdrawn (steered into the turn, or queued next for an
//!   agent that does not steer); the delivery becomes `retracted`.
//! - `too_late`: its turn ended, or the delivery path cannot take a message
//!   back (a terminal agent's hooks, Codex); nothing changes.
//! - `failed`: acpmux refused the withdraw (`withdraw_refused`), or did not
//!   answer for a delivery it may hold, or holds no prompt yet for a queued
//!   one a hand-over went out for (`acpmux_unavailable`); nothing
//!   changes, and the entry carries `error {reason, message}`. One recipient
//!   failing never undoes the others. A queued delivery to a session acpmux
//!   no longer knows (deleted, and no peer runs it) is `unsent`: no session
//!   can take a late hand-over.
//!
//! An acpmux recipient's outcome is acpmux's (`_acpmux/prompt_withdraw`, asked
//! before the commit). A queued delivery is asked too: a pump hand-over that
//! timed out may have reached acpmux (its attempt is counted), or may still
//! reach it, so acpmux not holding it yet is `failed`, not `unsent`. Only a queued
//! delivery no hand-over was ever tried for is `unsent` without acpmux's
//! answer: the daemon's pump is the one acpmux delivery path, and it waits
//! for the unsend. A delivery already unsent or retracted answers the same
//! again; a declined one never reached the agent and reads `unsent`.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::agent_message_release::expire_held;
use super::agent_message_store::{not_found, snapshot};
use cmux_json::JsonSet as _;

/// What acpmux answered a withdraw of one delivered message.
#[cfg_attr(not(unix), allow(dead_code))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Withdrawn {
    Unsent,
    Retracted,
    TooLate,
    /// The session's log holds no such prompt.
    NotFound,
    /// acpmux knows no such session (deleted, and no peer runs it): no
    /// session can take the prompt late.
    NoSession,
}

/// Why acpmux could not answer a withdraw.
#[cfg_attr(not(unix), allow(dead_code))]
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum WithdrawError {
    /// acpmux is not running, or did not answer.
    Unavailable,
    /// acpmux refused it, with its reason (`withdraw.edited`,
    /// `withdraw.notice_failed`, `transfer.moving`, …).
    Refused(String),
}

/// One delivery of the message, as stored before acpmux is asked.
pub(crate) struct Target {
    pub(crate) recipient: String,
    pub(crate) state: String,
    attempts: i64,
}

impl Target {
    /// Whether no hand-over of this delivery was ever tried, so without
    /// acpmux's answer it is still the daemon's alone.
    pub(crate) fn never_tried(&self) -> bool {
        self.state == "queued" && self.attempts == 0
    }

    /// Whether acpmux decides this delivery's outcome: an acpmux recipient
    /// the message may have reached.
    pub(crate) fn asks_acpmux(&self) -> bool {
        self.recipient.starts_with("acp:")
            && matches!(self.state.as_str(), "queued" | "failed" | "delivered" | "acknowledged")
    }

    /// Whether a delivery path handed the message over.
    pub(crate) fn handed_over(&self) -> bool {
        matches!(self.state.as_str(), "delivered" | "acknowledged")
    }
}

/// The sender of `message_id` and its deliveries (only `recipient`'s when
/// given); not found when the message, or that delivery, is not stored.
pub(crate) fn targets(
    connection: &Connection,
    message_id: &str,
    recipient: Option<&str>,
) -> anyhow::Result<(String, Vec<Target>)> {
    let sender: Option<String> = connection
        .query_row("SELECT sender FROM agent_messages WHERE message_id = ?1", [message_id], |row| {
            row.get(0)
        })
        .optional()?;
    let Some(sender) = sender else { return Err(not_found(message_id)) };
    let mut statement = connection.prepare(
        "SELECT recipient, state, attempts FROM agent_message_deliveries
         WHERE message_id = ?1 AND (?2 IS NULL OR recipient = ?2) ORDER BY position",
    )?;
    let targets = statement
        .query_map(params![message_id, recipient], |row| {
            Ok(Target { recipient: row.get(0)?, state: row.get(1)?, attempts: row.get(2)? })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if targets.is_empty() {
        return Err(not_found(message_id));
    }
    Ok((sender, targets))
}

/// The `error` of a `failed` outcome: acpmux did not answer for `recipient`.
pub(crate) fn unavailable(recipient: &str) -> Value {
    let message = format!("acpmux did not answer for {recipient}; try again");
    json!({"reason": "acpmux_unavailable", "message": clip(&message, MESSAGE_MAX)})
}

/// The `error` of a `failed` outcome: a hand-over to `recipient` went out
/// and acpmux holds no such prompt yet, so it may still take it and run it.
pub(crate) fn in_flight(recipient: &str) -> Value {
    let message = format!(
        "acpmux does not hold it for {recipient} yet, but a hand-over may still reach it; try again"
    );
    json!({"reason": "acpmux_unavailable", "message": clip(&message, MESSAGE_MAX)})
}

/// The `error` of a `failed` outcome: acpmux refused, with its `reason`.
pub(crate) fn refused(recipient: &str, reason: &str) -> Value {
    let message = format!("acpmux refused to withdraw it from {recipient} ({reason})");
    json!({"reason": "withdraw_refused", "acpmux_reason": reason,
        "message": clip(&message, MESSAGE_MAX)})
}

/// The spec's limit on `error.message`, in UTF-8 bytes.
const MESSAGE_MAX: usize = 1024;

/// At most `max` UTF-8 bytes of `text`, cut on a character boundary (the
/// catalog counts a string's length in bytes).
pub(crate) fn clip(text: &str, max: usize) -> String {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

/// Apply the unsend to every delivery of `message_id` (or `recipient`'s)
/// with acpmux's `answers` and the `failures` (an `error` each) by
/// recipient, and return `{outcome, outcomes: [{recipient, outcome,
/// error?}], message}`. `outcome` is `failed` when any delivery failed, else
/// `too_late` when any was too late, else `retracted` when any was
/// retracted, else `unsent`.
pub(crate) fn unsend(
    transaction: &Transaction<'_>,
    session_id: &str,
    message_id: &str,
    recipient: Option<&str>,
    answers: &HashMap<String, Withdrawn>,
    failures: &HashMap<String, Value>,
    now_ms: i64,
) -> anyhow::Result<Value> {
    expire_held(transaction, now_ms)?;
    let (_, targets) = targets(transaction, message_id, recipient)?;
    let mut outcomes = Vec::with_capacity(targets.len());
    for target in &targets {
        if let Some(error) = failures.get(&target.recipient) {
            outcomes.push((target.recipient.clone(), Outcome::Failed, Some(error.clone())));
            continue;
        }
        let answer = answers.get(&target.recipient).copied();
        let outcome = outcome(&target.state, answer, target.handed_over());
        if let Some(state) = outcome.stored_state(&target.state) {
            let via = answer.map(|_| "acp.withdraw");
            transaction.execute(
                "UPDATE agent_message_deliveries
                 SET state = ?3, reason = ?3, updated_at_ms = ?4, via = COALESCE(?5, via),
                     held_until_ms = NULL
                 WHERE message_id = ?1 AND recipient = ?2",
                params![message_id, target.recipient, state, now_ms, via],
            )?;
        }
        outcomes.push((target.recipient.clone(), outcome, None));
    }
    let any = |wanted: Outcome| outcomes.iter().any(|(_, outcome, _)| *outcome == wanted);
    let overall = [Outcome::Failed, Outcome::TooLate, Outcome::Retracted]
        .into_iter()
        .find(|outcome| any(*outcome))
        .unwrap_or(Outcome::Unsent);
    let message = snapshot(transaction, session_id, message_id, now_ms)?
        .ok_or_else(|| not_found(message_id))?;
    let outcomes: Vec<Value> = outcomes
        .iter()
        .map(|(recipient, outcome, error)| {
            let mut entry = json!({"recipient": recipient, "outcome": outcome.wire()});
            if let Some(error) = error {
                entry.set("error", error.clone());
            }
            entry
        })
        .collect();
    Ok(json!({"outcome": overall.wire(), "outcomes": outcomes, "message": message}))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Outcome {
    Unsent,
    Retracted,
    TooLate,
    Failed,
}

impl Outcome {
    fn wire(self) -> &'static str {
        match self {
            Self::Unsent => "unsent",
            Self::Retracted => "retracted",
            Self::TooLate => "too_late",
            Self::Failed => "failed",
        }
    }

    /// The state a delivery in `current` takes, or `None` when it keeps it.
    fn stored_state(self, current: &str) -> Option<&'static str> {
        let state = match self {
            Self::Unsent => "unsent",
            Self::Retracted => "retracted",
            Self::TooLate | Self::Failed => return None,
        };
        (current != state && current != "declined").then_some(state)
    }
}

/// One delivery's outcome from its stored state and acpmux's answer.
fn outcome(current: &str, answer: Option<Withdrawn>, handed_over: bool) -> Outcome {
    match (current, answer) {
        ("unsent" | "declined", _) => Outcome::Unsent,
        ("retracted", _) => Outcome::Retracted,
        (_, Some(Withdrawn::Unsent)) => Outcome::Unsent,
        (_, Some(Withdrawn::Retracted)) => Outcome::Retracted,
        (_, Some(Withdrawn::TooLate)) => Outcome::TooLate,
        // Handed over by a path that cannot take it back, or one acpmux no
        // longer holds: it reached the agent.
        _ if handed_over => Outcome::TooLate,
        _ => Outcome::Unsent,
    }
}
