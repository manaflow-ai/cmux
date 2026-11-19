//! A Cloud machine change an agent or a script asked for (`cmux vm resize`, `vm snapshot-machine`,
//! `vm fork`, `vm restore-machine`, `vm promote-template`) waits for the person's Allow in the
//! cmux window. The app answers such a run at once with `pending: true`, `waiting_for: person`
//! and the dialog's `dialog_id`, and marks it `ask_again_joins: true`: the same ask again joins
//! that run (never a second change or dialog) and answers its end, or `pending` again after 30 s.
//! Before, the CLI printed that first `pending` and exited 0, so a declined or unanswered change
//! read as done and a fork never named its new machine. The CLI now says at once that the change
//! waits for the person (a note on stderr, the app's answer itself in JSON), then asks again until
//! the run ends: the change's own answer (exit 0), refused when the person chose Don't Allow (the
//! app's refusal, exit 1), or [`JOIN_LIMIT`] with no end (`cloud.change.unanswered`, exit 1).

use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// How long the CLI waits for a change the person has not answered. The run goes on in the app;
/// the same command again joins it.
pub(super) const JOIN_LIMIT: Duration = Duration::from_secs(10 * 60);
/// At most this many asks, whatever the clock says: each waits in the app up to 30 s.
const MAX_ASKS: usize = 64;

/// Whether `answer` (an `action.run` success) is a run that the same ask again joins.
pub(super) fn joins(answer: &Value) -> bool {
    let result = answer.get("result").unwrap_or(answer);
    result.get("pending").and_then(Value::as_bool) == Some(true)
        && result.get("ask_again_joins").and_then(Value::as_bool) == Some(true)
}

/// Asks again (`ask`) while the answer is a joinable `pending`, until the run ends or `limit`
/// passes. `waiting` is called once per new state the run answers (waiting for the person, then
/// running), so the caller hears it at once. Answers the run's end, or `cloud.change.unanswered`.
pub(super) fn join(
    first: Value,
    limit: Duration,
    now: impl Fn() -> Instant,
    mut waiting: impl FnMut(&Value),
    mut ask: impl FnMut() -> Result<Result<Value, Value>, Value>,
) -> Result<Result<Value, Value>, Value> {
    let start = now();
    let mut last = first;
    let mut said: Option<Value> = None;
    for _ in 0..MAX_ASKS {
        if !joins(&last) {
            return Ok(Ok(last));
        }
        let state = state(&last);
        if said.as_ref() != Some(&state) {
            waiting(&last);
            said = Some(state);
        }
        if now().saturating_duration_since(start) >= limit {
            break;
        }
        last = match ask()? {
            Ok(answer) => answer,
            Err(refusal) => return Ok(Err(refusal)),
        };
    }
    Ok(Err(unanswered(&last, limit)))
}

/// What a waiting answer says about its run: who it waits for, and which dialog.
fn state(answer: &Value) -> Value {
    let result = answer.get("result").unwrap_or(answer);
    json!({ "waiting_for": result.get("waiting_for"), "dialog_id": result.get("dialog_id") })
}

/// The note a person reads on stderr while the change waits.
pub(super) fn note(answer: &Value) -> String {
    let result = answer.get("result").unwrap_or(answer);
    match result.get("waiting_for").and_then(Value::as_str) {
        Some("person") => {
            let dialog = result.get("dialog_id").and_then(Value::as_str).unwrap_or("?");
            format!(
                "cmux: waiting for Allow or Don't Allow in the cmux window (dialog {dialog}); \
                 nothing changes until then"
            )
        }
        _ => "cmux: allowed; waiting for Cloud to finish the change".to_owned(),
    }
}

fn unanswered(last: &Value, limit: Duration) -> Value {
    let result = last.get("result").unwrap_or(last);
    let person = result.get("waiting_for").and_then(Value::as_str) == Some("person");
    let minutes = limit.as_secs() / 60;
    let message = if person {
        let dialog = result.get("dialog_id").and_then(Value::as_str).unwrap_or("?");
        format!(
            "nobody answered the cmux window's dialog {dialog} in {minutes} min, so nothing has \
             changed yet; it stays open, and the same command again waits for it"
        )
    } else {
        format!(
            "the change was allowed but had not finished after {minutes} min; it goes on, and \
             the same command again answers its end"
        )
    };
    json!({
        "code": "cloud.change.unanswered",
        "message": message,
        "data": result,
        "retryable": true,
    })
}

#[cfg(test)]
mod tests;
