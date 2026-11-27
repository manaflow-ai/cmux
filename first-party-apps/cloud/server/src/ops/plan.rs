//! `cloud.plan.get` (limits and usage in one record; `cloud.usage.get`
//! folded in) and `cloud.billing.checkout` (a checkout URL the host opens in
//! the browser; no card data in cmux). The backend reads the plan from the
//! billing owner; the server computes no limit itself (contract 1.5).
//! `cloud.allotment.get` (the team's allotment and the scheduler's proposal,
//! for the Settings Compute card) is a read of the same kind.
//! `cloud.allotment.set` passes on only the team's hold for its people
//! (`person_hold_seconds`); the keys that move the monthly commit are refused.
//! `cloud.retention.set` (the team's cleanup numbers and the caller's email
//! heads-up, answered by `cloud.plan.get` as `retention`) lives here too.

use crate::api::args;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use cmux_cloud_wire::{
    CloudAllotmentGetOp, CloudAllotmentSetOp, CloudPlanGetOp, CloudUsageCurrentOp, Op,
};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct Checkout {
    url: String,
}

/// The checkout URL the host opens in the browser: `https://` with a
/// host, no user info (`user@` can disguise the real host), no whitespace
/// or control characters, at most 4096 bytes.
fn checked_checkout_url(url: &str) -> Result<&str, CloudError> {
    let bad = |why: &str| CloudError::new(codes::BAD_RESPONSE, format!("checkout URL: {why}"));
    let rest = url.strip_prefix("https://").ok_or_else(|| bad("not https"))?;
    if url.len() > 4096 || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(bad("too long or has whitespace or control characters"));
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    if authority.is_empty() || authority.contains('@') {
        return Err(bad("no host, or user info before the host"));
    }
    Ok(url)
}

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.plan.get" => {
            args::object(raw, &[])?;
            let plan: <CloudPlanGetOp as Op>::Result =
                decode_answer(name, ctx.wire(name, json!({}))?.value)?;
            Ok(json!(plan))
        }
        // The team's allotment and the scheduler's proposal, as the platform computed them from its
        // meter: this server adds no figure of its own.
        "cloud.allotment.get" => {
            args::object(raw, &[])?;
            let view: <CloudAllotmentGetOp as Op>::Result =
                decode_answer(name, ctx.wire(name, json!({}))?.value)?;
            Ok(json!(view))
        }
        // Only the team's hold for its people. The platform's op also takes action, auto and
        // auto_max_micros, which move the monthly commit (money): refused here until the app has a
        // flow for them, so nothing in the app can move money through this op.
        "cloud.allotment.set" => {
            let map = args::object(raw, &["person_hold_seconds"])?;
            person_hold_arg(map)?;
            let answer: <CloudAllotmentSetOp as Op>::Result =
                decode_answer(name, ctx.wire(name, args::params(map, &["person_hold_seconds"]))?.value)?;
            Ok(json!(answer))
        }
        // The team's usage this month and its price, from the billing owner
        // (cmux-platform metering): checked against the catalog shape, then
        // passed through. The server prices nothing.
        "cloud.usage.current" => {
            args::object(raw, &[])?;
            let usage: <CloudUsageCurrentOp as Op>::Result =
                decode_answer(name, ctx.wire(name, json!({}))?.value)?;
            Ok(json!(usage))
        }
        "cloud.billing.checkout" => {
            let map = args::object(raw, &["plan"])?;
            // No plan: attach a payment method.
            args::opt_id(map, "plan")?;
            let checkout: Checkout =
                decode_answer(name, ctx.wire(name, args::params(map, &["plan"]))?.value)?;
            // The host opens it in the browser: only an https URL.
            if !checkout.url.starts_with("https://") {
                return Err(CloudError::new(codes::BAD_RESPONSE, "the checkout URL is not https"));
            }
            Ok(json!({ "url": checked_checkout_url(&checkout.url)? }))
        }
        "cloud.retention.set" => {
            let map = args::object(raw, &["settings", "email_heads_up"])?;
            retention_args(map)?;
            let changed: Changed = decode_answer(
                name,
                ctx.wire(name, args::params(map, &["settings", "email_heads_up"]))?.value,
            )?;
            Ok(json!({ "changed": changed.changed }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

/// The holds a team may choose for its people, seconds (the platform's
/// PERSON_HOLD_CHOICES_S).
const PERSON_HOLD_CHOICES: &[u64] = &[300, 900, 1800];

/// `cloud.allotment.set {person_hold_seconds}`: required, one of the choices
/// or null (null clears it).
fn person_hold_arg(map: &serde_json::Map<String, Value>) -> Result<(), CloudError> {
    match map.get("person_hold_seconds") {
        Some(Value::Null) => Ok(()),
        Some(value) if value.as_u64().is_some_and(|n| PERSON_HOLD_CHOICES.contains(&n)) => Ok(()),
        _ => Err(CloudError::invalid("person_hold_seconds is 300, 900 or 1800, or null to clear it")),
    }
}

/// `cloud.retention.set`'s answer.
#[derive(Deserialize)]
struct Changed {
    changed: bool,
}

/// The team's cleanup numbers a team admin may set (`settings`; null clears
/// them), each a whole number. The platform checks each against the plan's
/// limits; this server checks only the shape.
const RETENTION_FIELDS: &[&str] = &[
    "failed_create_hours",
    "never_used_hours",
    "idle_pause_minutes",
    "worked_in_days",
    "heads_up_days",
    "last_note_days",
    "archive_days",
];

/// `cloud.retention.set {settings?, email_heads_up?}`: at least one, each of
/// its shape.
fn retention_args(map: &serde_json::Map<String, Value>) -> Result<(), CloudError> {
    let settings = map.get("settings");
    let email = map.get("email_heads_up");
    if settings.is_none() && email.is_none() {
        return Err(CloudError::invalid("give settings, email_heads_up, or both"));
    }
    if email.is_some_and(|value| !value.is_boolean()) {
        return Err(CloudError::invalid("email_heads_up is true or false"));
    }
    match settings {
        None | Some(Value::Null) => Ok(()),
        Some(Value::Object(numbers)) => {
            for (key, value) in numbers {
                if !RETENTION_FIELDS.contains(&key.as_str()) {
                    return Err(CloudError::invalid(format!("unknown setting {key}")));
                }
                if value.as_u64().is_none_or(|n| n > 10_000) {
                    return Err(CloudError::invalid(format!("{key} is a whole number")));
                }
            }
            Ok(())
        }
        Some(_) => Err(CloudError::invalid("settings is an object or null")),
    }
}
