//! Answering a Cloud create's approval (G8, cx-wb5.65) as the person's own session, after their click.
//!
//! A create that the backend holds answers `approval.pending {request}`. Before, the app answered it in three
//! sequential session calls (`integration.approval.get`, `feed.list`, `feed.answer`) and then retried the create with
//! the same key to get the machine: five round trips at 0.26-0.98 s each on Leo's Mac. Now the first call is cmux-api's
//! `integration.approval.approve`, which makes the same checks on the server, answers the same feed item, and carries
//! the approved run's reply (the create's machine) when the run ends within its wait. Pending plus this one call is two.
//!
//! A backend that does not have it (an older cmux-api answers `validation.invalid` for an unknown mutation; one with
//! its flag off answers `approval.one_call_off`) gets the three calls, with the checks the app made before, here.
//!
//! The app makes the calls; this decides each one. [`next`] is stateless: the app sends every reply body so far in
//! `steps`, in order, and gets the next call or the outcome. The app's op (`cloud_approval_next`) is
//! [`next_remembered`]: a team whose backend answered `approval.one_call_off` goes straight to the three calls for
//! [`ONE_CALL_OFF_MS`], so each later approval skips the refused round trip (production has the flag off; about
//! 200 ms per approval). A backend that answers the one call is never remembered: it keeps the one call.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The one-call op (cmux-api `integration.approval.approve`).
pub const ONE_CALL_OP: &str = "integration.approval.approve";
/// The mismatch reason when no feed item of the create's team carries the request (the app's `closedItem`).
pub const CLOSED_ITEM: &str = "feed item or team";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    /// The approval request id (`apr_…`) the pending answer named.
    pub request: String,
    /// The op this create sent (`cloud.machine.create`, `cloud.environment.boot`, …).
    pub op: String,
    /// Exactly the params the person confirmed and the create sent (a JSON object).
    pub params: Value,
    /// The backend team the create was sent for (the install token's team when the person confirmed).
    pub team: String,
    /// Every reply body so far, in order.
    #[serde(default)]
    pub steps: Vec<Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Outcome {
    /// Answered here. `reply`: the approved run's answer value (`{machine, …}`) when it ended ok within the wait;
    /// none: retry the create with the same key, as before.
    Approved { reply: Option<Value> },
    /// The create's own team's item was already closed: answered elsewhere, nothing answered here.
    AnsweredElsewhere { reply: Option<Value> },
    /// The request is not the one confirmed: `op`, `state`, `params`, `digest` or [`CLOSED_ITEM`]. Nothing answered.
    Mismatch { reason: String },
    /// A call was refused with this code.
    Refused { code: String },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "next", rename_all = "camelCase")]
pub enum Next {
    /// POST `body` to `path` (`v1/read`, `v1/ops`) as the person's session and send its reply body back.
    Call {
        path: String,
        body: Value,
    },
    Done {
        outcome: Outcome,
    },
}

fn call(path: &str, body: Value) -> Next {
    Next::Call { path: path.into(), body }
}

fn done(outcome: Outcome) -> Next {
    Next::Done { outcome }
}

/// The error code of a reply, when it is a refusal (the shapes the app's `post` refused: `{ok: false, error}` or an
/// HTTP error body `{code, message}`; a reply with a `value` is never one).
fn refusal(reply: &Value) -> Option<String> {
    if reply.get("ok").and_then(Value::as_bool) == Some(true) || reply.get("value").is_some() {
        return None;
    }
    let code = reply
        .get("error")
        .and_then(|e| e.get("code"))
        .or_else(|| reply.get("code"))
        .and_then(Value::as_str);
    match code {
        Some(code) => Some(code.to_owned()),
        None if reply.get("ok").and_then(Value::as_bool) == Some(false)
            || reply.get("error").is_some() =>
        {
            Some("unknown".into())
        }
        None => None,
    }
}

/// Whether the backend lacks the one call (older cmux-api, or its flag off): then the three calls.
fn lacks_one_call(reply: &Value) -> bool {
    match refusal(reply).as_deref() {
        Some("approval.one_call_off") => true,
        // An unknown op is validation.invalid; the old checks below refuse anything a malformed call would have.
        Some("validation.invalid") => true,
        _ => false,
    }
}

fn key(request: &str) -> String {
    format!("approve:{request}")
}

fn list(state: &str) -> Next {
    let mut params = json!({"state": state, "type": "request", "kind": "approve", "poster_kind": "integration", "limit": 100});
    if let (true, Some(map)) = (state != "open", params.as_object_mut()) {
        map.insert("order".into(), json!("recent"));
    }
    call("v1/read", json!({"op": "feed.list", "params": params}))
}

/// The id of the item for `request`: for `team` (never another team the person belongs to), posted by that team's
/// Cloud owner (`system:cloud:<team>`), for `op`, with `digest` (the app's `CloudApprovalAnswer.item`).
fn item_carrying(r: &Request, digest: &str, reply: &Value) -> Option<String> {
    if r.team.is_empty() {
        return None;
    }
    let items = reply.get("value").and_then(|v| v.get("items")).and_then(Value::as_array)?;
    items
        .iter()
        .find(|item| {
            let action = item.get("prompt").and_then(|p| p.get("action"));
            let approval = action.and_then(|a| a.get("input")).and_then(|i| i.get("approval"));
            let poster = item.get("poster");
            let s = |v: Option<&Value>, k: &str| {
                v.and_then(|v| v.get(k)).and_then(Value::as_str).map(str::to_owned)
            };
            s(approval, "request").as_deref() == Some(r.request.as_str())
                && s(approval, "digest").as_deref() == Some(digest)
                && s(action, "tool").as_deref() == Some(r.op.as_str())
                && s(approval, "team").as_deref() == Some(r.team.as_str())
                && s(poster, "kind").as_deref() == Some("integration")
                && s(poster, "scope") == Some(format!("system:cloud:{}", r.team))
        })
        .and_then(|item| item.get("id").and_then(Value::as_str).map(str::to_owned))
}

/// The run's answer value when the one call carried an ok reply.
fn run_reply(value: &Value) -> Option<Value> {
    let reply = value.get("reply")?;
    (reply.get("ok").and_then(Value::as_bool) == Some(true))
        .then(|| reply.get("value").cloned())
        .flatten()
}

/// The next call, or the outcome, after the replies in `r.steps`.
pub fn next(r: &Request) -> Next {
    let steps = &r.steps;
    let Some(first) = steps.first() else {
        return call(
            "v1/ops",
            json!({"op": ONE_CALL_OP, "origin": "user", "idempotency_key": key(&r.request),
                "params": {"request": r.request, "op": r.op, "params": r.params, "team": r.team}}),
        );
    };
    if !lacks_one_call(first) {
        if let Some(code) = refusal(first) {
            if code == "approval.mismatch" {
                let reason = first
                    .get("error")
                    .and_then(|e| e.get("details"))
                    .and_then(|d| d.get("reason"))
                    .and_then(Value::as_str)
                    .unwrap_or("params");
                return done(Outcome::Mismatch { reason: reason.into() });
            }
            return done(Outcome::Refused { code });
        }
        let value = first.get("value").cloned().unwrap_or(Value::Null);
        let reply = run_reply(&value);
        return done(match value.get("answered").and_then(Value::as_str) {
            Some("elsewhere") => Outcome::AnsweredElsewhere { reply },
            _ => Outcome::Approved { reply },
        });
    }
    legacy(r, steps.get(1..).unwrap_or_default())
}

/// How long a team's `approval.one_call_off` is remembered: long enough that each approval of an app session skips
/// the refused call, short enough that a backend that turns the one call on is asked it again within minutes.
pub const ONE_CALL_OFF_MS: u64 = 10 * 60_000;
/// The most approvals whose path (the three calls first) is remembered at once.
const REMEMBERED_REQUESTS: usize = 64;

/// What [`next_remembered`] keeps between calls: each team whose backend refused the one call (until when, ms), and
/// each request answered through the three calls from the start, so its later steps are read as theirs even after
/// the team's entry ends.
#[derive(Debug, Default)]
pub struct Memo {
    off: Vec<(String, u64)>,
    three_calls: std::collections::VecDeque<String>,
}

impl Memo {
    /// [`next`], skipping the one call for a team whose backend refused it within [`ONE_CALL_OFF_MS`] of `now_ms`.
    pub fn next(&mut self, r: &Request, now_ms: u64) -> Next {
        if r.steps.is_empty() {
            // A new answer of this request decides its path again.
            self.three_calls.retain(|q| q != &r.request);
            self.off.retain(|(_, until)| *until > now_ms);
            if !r.team.is_empty() && self.off.iter().any(|(team, _)| team == &r.team) {
                if self.three_calls.len() >= REMEMBERED_REQUESTS {
                    self.three_calls.pop_front();
                }
                self.three_calls.push_back(r.request.clone());
                return legacy(r, &[]);
            }
            return next(r);
        }
        if self.three_calls.contains(&r.request) {
            return legacy(r, &r.steps);
        }
        if r.steps.len() == 1
            && !r.team.is_empty()
            && refusal(&r.steps[0]).as_deref() == Some("approval.one_call_off")
        {
            self.off.retain(|(team, _)| team != &r.team);
            self.off.push((r.team.clone(), now_ms.saturating_add(ONE_CALL_OFF_MS)));
        }
        next(r)
    }
}

static MEMO: std::sync::Mutex<Memo> =
    std::sync::Mutex::new(Memo { off: Vec::new(), three_calls: std::collections::VecDeque::new() });

/// [`Memo::next`] on the process's memo, at the wall clock (op `cloud_approval_next`).
pub fn next_remembered(r: &Request) -> Next {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
    MEMO.lock().unwrap_or_else(std::sync::PoisonError::into_inner).next(r, now_ms)
}

/// The three calls the app made before the one call: approval.get, feed.list (open, then closed), feed.answer.
fn legacy(r: &Request, steps: &[Value]) -> Next {
    let Some(read) = steps.first() else {
        return call(
            "v1/read",
            json!({"op": "integration.approval.get", "params": {"request": r.request}}),
        );
    };
    if let Some(code) = refusal(read) {
        return done(Outcome::Refused { code });
    }
    let held = read.get("value").cloned().unwrap_or(Value::Null);
    let mismatch = |reason: &str| done(Outcome::Mismatch { reason: reason.into() });
    if held.get("op").and_then(Value::as_str) != Some(r.op.as_str()) {
        return mismatch("op");
    }
    if held.get("state").and_then(Value::as_str) != Some("pending") {
        return mismatch("state");
    }
    // serde_json's Value equality is deep and ignores key order, like the app's NSDictionary isEqual.
    if !r.params.is_object() || held.get("params") != Some(&r.params) {
        return mismatch("params");
    }
    let Some(digest) = held.get("digest").and_then(Value::as_str) else {
        return mismatch("digest");
    };
    let Some(open) = steps.get(1) else { return list("open") };
    if let Some(code) = refusal(open) {
        return done(Outcome::Refused { code });
    }
    match item_carrying(r, digest, open) {
        Some(item) => {
            let Some(answer) = steps.get(2) else {
                return call(
                    "v1/ops",
                    json!({"op": "feed.answer", "origin": "user", "idempotency_key": key(&r.request),
                        "params": {"item": item, "answer": {"decision": "allow", "scope": "once"}}}),
                );
            };
            match refusal(answer) {
                Some(code) => done(Outcome::Refused { code }),
                None => done(Outcome::Approved { reply: None }),
            }
        }
        None => {
            // No open item: answered elsewhere when this team's closed item carries it (cmux#32354).
            let Some(closed) = steps.get(2) else { return list("closed") };
            if let Some(code) = refusal(closed) {
                return done(Outcome::Refused { code });
            }
            match item_carrying(r, digest, closed) {
                Some(_) => done(Outcome::AnsweredElsewhere { reply: None }),
                None => mismatch(CLOSED_ITEM),
            }
        }
    }
}

#[cfg(test)]
mod tests;
