//! How one wait's answer reads: a sandboxed Run's snapshot (the daemon's `cloud.runs.wait`) and a
//! hand-off's `{handoff}` (`GET /v1/handoffs/:id/wait`), plus what a Run's card keeps of it.

use serde_json::{Map, Value};

use crate::handoff;
use crate::model::{Notice, Outcome};

/// One wait's answer, as a source reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Read {
    /// Still going; the next wait passes `cursor`. A `notice` is told once per key; `running`:
    /// its current turn runs, so it is not given up for age.
    Going { cursor: Option<i64>, notice: Option<Notice>, running: bool },
    /// A Run's end, told by the follower's rules.
    Ended(Outcome),
    /// It will not change again (a hand-off closed): its `notice`, if not told yet, is told, then
    /// the follow ends without telling more.
    Closed(Option<Notice>),
    /// No answer of the source's shape: never an end.
    Unreadable,
}

/// The Run API's statuses.
const RUN_STATUSES: [&str; 6] =
    ["queued", "running", "cancelling", "succeeded", "failed", "cancelled"];

fn object(body: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(body).ok()? {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

/// A whole number, also when the JSON spells it `2.0`.
pub(crate) fn integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        // A whole number within f64's exact integers, so the cast loses nothing.
        value
            .as_f64()
            .filter(|number| number.fract() == 0.0 && number.abs() < 9.0e15)
            .map(|number| number as i64)
    })
}

/// A sandboxed Run's snapshot. It is terminal once it carries its receipt (the server writes it
/// with the terminal status); until then it runs. A body that is no Run snapshot, or names a
/// status the Run API has not, is unreadable, never an end.
pub fn run(body: &str) -> Read {
    let Some(snapshot) = object(body) else { return Read::Unreadable };
    let status = snapshot
        .get("run")
        .and_then(Value::as_object)
        .and_then(|run| run.get("status"))
        .and_then(Value::as_str);
    if !status.is_some_and(|status| RUN_STATUSES.contains(&status)) {
        return Read::Unreadable;
    }
    let receipt = match snapshot.get("receipt") {
        None | Some(Value::Null) => {
            return Read::Going { cursor: None, notice: None, running: false };
        }
        Some(Value::Object(receipt)) => receipt,
        Some(_) => return Read::Unreadable,
    };
    match receipt.get("status").and_then(Value::as_str) {
        Some("succeeded") => Read::Ended(Outcome::Succeeded),
        Some("cancelled") => Read::Ended(Outcome::Cancelled),
        Some("failed") if receipt.get("timedOut") == Some(&Value::Bool(true)) => {
            Read::Ended(Outcome::TimedOut)
        }
        Some("failed") => Read::Ended(Outcome::Failed),
        _ => Read::Unreadable,
    }
}

/// A hand-off wait's `{handoff}`. A body of another shape, or a status the store has not, is
/// unreadable. A store from before turns (no `state`) closes a hand-off with its first done,
/// failed or cancel.
pub fn handoff(body: &str) -> Read {
    let Some(object) = object(body) else { return Read::Unreadable };
    let Some(handoff) = object.get("handoff").and_then(Value::as_object) else {
        return Read::Unreadable;
    };
    let status = handoff
        .get("status")
        .and_then(Value::as_str)
        .filter(|status| handoff::STATUSES.contains(status));
    let (Some(status), Some(version)) = (status, handoff.get("version").and_then(integer)) else {
        return Read::Unreadable;
    };
    let turn = handoff.get("turn").and_then(integer);
    let state = handoff.get("state").and_then(Value::as_str);
    if !matches!(state, None | Some("open" | "closed")) {
        return Read::Unreadable;
    }
    let notice = handoff::notice(status, turn);
    let closed =
        state.map_or_else(|| handoff::TURN_ENDS.contains(&status), |state| state == "closed");
    if closed {
        Read::Closed(notice)
    } else {
        Read::Going { cursor: Some(version), notice, running: handoff::TURN_RUNS.contains(&status) }
    }
}

/// The part of a final snapshot a Run's card needs, `{"receipt": …}`, as base64 (the saved
/// list's spelling of the app's `Data`); none when the snapshot has no receipt object.
pub fn card(snapshot: &str) -> Option<String> {
    let receipt = object(snapshot)?.remove("receipt")?;
    if !receipt.is_object() {
        return None;
    }
    let mut card = Map::new();
    card.insert("receipt".into(), receipt);
    Some(base64(serde_json::to_string(&card).ok()?.as_bytes()))
}

/// Standard base64 with padding, as Foundation's `base64EncodedString()` writes it.
pub(crate) fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let bits = chunk
            .iter()
            .enumerate()
            .fold(0u32, |bits, (index, byte)| bits | u32::from(*byte) << (16 - 8 * index));
        for index in 0..4 {
            if index <= chunk.len() {
                text.push(
                    ALPHABET
                        .get((bits >> (18 - 6 * index) & 63) as usize)
                        .map_or('=', |c| char::from(*c)),
                );
            } else {
                text.push('=');
            }
        }
    }
    text
}
