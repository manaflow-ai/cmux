//! Settings → Cloud → Spending's overage write (RFD 0080 "Spend controls"): the person's "Overage after the plan's pool
//! (Off) On, up to $__ a month" saved as cmux-api's `usage.cap.set {overage_usd}` (cmux#61328), as their own session.
//!
//! The app makes the call; this decides it. [`next`] is stateless, like `approval_answer`: the app sends what the person
//! saved, the save's idempotency key and every reply body so far in `steps`, and gets the one call to make or the
//! outcome. The backend decides the cap (pool plus overage, team-cap.ts `teamCapState`) and who may set it (a team
//! admin, `team.roles_required`); this checks only the amount's shape and words the answer, so the card and any other
//! surface say the same thing.
//!
//! `overage_usd: null` is overage off: past the plan's pool, cloud agents pause (`paused_by: spend_cap`), local agents
//! keep running. Nothing here picks a default; the card's default stays off (cmuxterm-hq#19567 decides it).

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// cmux-api's op (backend/packages/protocol/src/usage.ts `UsageCapSet`).
pub const OP: &str = "usage.cap.set";
/// The largest amount cmux-api accepts (`CapUsd`: at most 1,000,000).
pub const MAX_USD: f64 = 1_000_000.0;
/// The longest idempotency key the app may send.
const MAX_KEY: usize = 128;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    /// The overage limit the person saved, in dollars a month; null (or absent) is overage off.
    #[serde(default)]
    pub overage_usd: Option<f64>,
    /// One key per save: the app keeps it when it retries the same save, so a lost answer never sets it twice.
    pub key: String,
    /// Every reply body so far, in order.
    #[serde(default)]
    pub steps: Vec<Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Outcome {
    /// Saved. `overage_usd`: the overage now in force (null = off); `team_cap_usd`: the team's cap it makes (pool plus
    /// overage), null when the team has none.
    #[serde(rename_all = "camelCase")]
    Saved { overage_usd: Option<f64>, team_cap_usd: Option<f64> },
    /// Not sent: the amount is not one cmux-api takes. `message` says what to type.
    Invalid { message: String },
    /// cmux-api refused it. `retry`: the same save (same key) may succeed later; `message` is the card's sentence.
    Refused { code: String, message: String, retry: bool },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "next", rename_all = "camelCase")]
pub enum Next {
    /// POST `body` to `path` (`v1/ops`) as the person's session and send its reply body back in `steps`.
    Call {
        path: String,
        body: Value,
    },
    Done {
        outcome: Outcome,
    },
}

fn done(outcome: Outcome) -> Next {
    Next::Done { outcome }
}

fn invalid(message: &str) -> Next {
    done(Outcome::Invalid { message: message.into() })
}

/// The amount as cmux-api takes it: whole cents, above $0, at most [`MAX_USD`]. Zero is refused like the card's field
/// refuses it: "off" is null, not $0 (a $0 overage would read as on while pausing at the pool).
fn checked_amount(usd: f64) -> Result<f64, &'static str> {
    if !usd.is_finite() || usd <= 0.0 {
        return Err("Enter an amount above $0, or leave it empty to turn overage off.");
    }
    if usd > MAX_USD {
        return Err("Enter at most $1,000,000 a month.");
    }
    let cents = (usd * 100.0).round();
    if (cents - usd * 100.0).abs() > 1e-6 {
        return Err("Enter dollars and cents, like 40 or 40.50.");
    }
    Ok(cents / 100.0)
}

/// The error code of a reply, when it is a refusal: `{ok: false, error: {code}}` or an HTTP error body `{code}`.
fn refusal(reply: &Value) -> Option<(String, Option<String>)> {
    if reply.get("ok").and_then(Value::as_bool) == Some(true) || reply.get("value").is_some() {
        return None;
    }
    let error = reply.get("error").filter(|e| e.is_object()).unwrap_or(reply);
    let code = error.get("code").and_then(Value::as_str);
    let message = error.get("message").and_then(Value::as_str).map(str::to_owned);
    match code {
        Some(code) => Some((code.to_owned(), message)),
        None if reply.get("ok").and_then(Value::as_bool) == Some(false)
            || reply.get("error").is_some() =>
        {
            Some(("unknown".into(), message))
        }
        None => None,
    }
}

/// Whether the same save, with the same key, may succeed later.
fn retryable(code: &str) -> bool {
    matches!(
        code,
        "mutation.indeterminate" | "owner.unreachable" | "rate_limited" | "unavailable" | "network"
    )
}

/// The card's sentence for a refusal. cmux-api's own words are not shown: they name fields, not the setting.
fn refusal_message(code: &str) -> &'static str {
    match code {
        "team.roles_required" | "auth.forbidden" => {
            "Only a team admin can change the overage limit."
        }
        "auth.unauthenticated" | "auth.sso_required" => {
            "Sign in again to change the overage limit."
        }
        "validation.invalid" => {
            "Cloud did not take that amount. Enter dollars and cents, like 40 or 40.50."
        }
        "idempotency.conflict" | "revision.conflict" => {
            "The limit changed elsewhere. Reopen Spending and try again."
        }
        code if retryable(code) => "Couldn't reach Cloud. Try again.",
        _ => "Couldn't save the overage limit. Try again.",
    }
}

fn number(value: &Value, key: &str) -> Option<f64> {
    value.get(key).and_then(Value::as_f64).filter(|n| n.is_finite())
}

/// The next session call to make for `r`, or the outcome.
pub fn next(r: &Request) -> Next {
    let overage = match r.overage_usd.map(checked_amount).transpose() {
        Ok(overage) => overage,
        Err(message) => return invalid(message),
    };
    let key = r.key.trim();
    if key.is_empty() || key.len() > MAX_KEY || key.chars().any(char::is_control) {
        return invalid("This save has no key: close Spending and try again.");
    }
    match r.steps.as_slice() {
        [] => Next::Call {
            path: "v1/ops".into(),
            body: json!({"op": OP, "origin": "user", "idempotency_key": key, "params": {"overage_usd": overage}}),
        },
        [reply] => match refusal(reply) {
            Some((code, _)) => {
                let message = refusal_message(&code).into();
                let retry = retryable(&code);
                done(Outcome::Refused { code, message, retry })
            }
            None => {
                let value = reply.get("value").unwrap_or(reply);
                // An answer without `overage_usd` (a `cap_usd` set raced this one) keeps what was asked: the next read
                // of the cap says what is in force.
                let overage_usd = match value.get("overage_usd") {
                    Some(Value::Null) => None,
                    Some(_) => number(value, "overage_usd"),
                    None => overage,
                };
                done(Outcome::Saved { overage_usd, team_cap_usd: number(value, "team_cap_usd") })
            }
        },
        _ => done(Outcome::Refused {
            code: "protocol".into(),
            message: refusal_message("protocol").into(),
            retry: false,
        }),
    }
}

#[cfg(test)]
mod tests;
