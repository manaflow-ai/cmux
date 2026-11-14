//! The session host's relay Register ticket (sans I/O): the agent socket
//! line `{"carrier_ticket": {}}`, the platform call it becomes
//! (`POST /v1/cloud/machines/{machine}/carrier` as this machine's `vm`
//! install, which answers a Register ticket for the machine's own slot), and
//! the one reply line. cmux design/cloud-carrier.md, slice 4.
//!
//! The session host's `--relay-ticket-command` runs `host cloud
//! carrier-ticket` (`carrier_entry.rs`) for each Register. A ticket only
//! lets a daemon take this machine's relay slot; the Mac still pins the
//! daemon's Noise key, so a ticket in another local process's hands opens no
//! session. The caller supplies nothing: the machine picks its own id,
//! origin and bearer.

use serde_json::{Value, json};

use super::github::refusal;
use super::sender::Answer;

/// The socket line's key.
pub const REQUEST_KEY: &str = "carrier_ticket";

/// The longest ticket accepted from the platform.
pub const MAX_TICKET_BYTES: usize = 4096;

/// The platform route for `machine`.
pub fn path(machine: &str) -> String {
    format!("/v1/cloud/machines/{machine}/carrier")
}

/// The `carrier_ticket` object of a socket line: it takes no fields.
pub fn check_ask(value: &Value) -> Result<(), String> {
    match value {
        Value::Null => Ok(()),
        Value::Object(fields) if fields.is_empty() => Ok(()),
        _ => Err("carrier_ticket takes no fields; the machine asks for its own slot.".to_owned()),
    }
}

/// A ticket: printable ASCII with no spaces, bounded.
fn valid_ticket(ticket: &str) -> bool {
    (1..=MAX_TICKET_BYTES).contains(&ticket.len()) && ticket.bytes().all(|b| b.is_ascii_graphic())
}

/// The reply for the platform's answer: `{ok, relay, slot, ticket,
/// expires_at}`, each checked, or a refusal.
pub fn reply_for(answer: &Answer) -> Value {
    match answer {
        Answer::Http { status: 200, body } => {
            let value = body.get("value");
            let text = |name: &str| value.and_then(|v| v.get(name)).and_then(Value::as_str);
            let relay = text("relay").filter(|r| r.starts_with(crate::carrier_entry::RELAY_SCHEME));
            let slot = text("slot").filter(|s| crate::carrier_entry::valid_slot(s));
            let ticket = text("ticket").filter(|t| valid_ticket(t));
            let expires_at = value.and_then(|v| v.get("expires_at")).and_then(Value::as_u64);
            match (body.get("ok") == Some(&json!(true)), relay, slot, ticket, expires_at) {
                (true, Some(relay), Some(slot), Some(ticket), Some(expires_at)) => json!({
                    "ok": true,
                    "relay": relay,
                    "slot": slot,
                    "ticket": ticket,
                    "expires_at": expires_at,
                }),
                _ => refusal("carrier.bad_answer", "cmux did not return a carrier ticket."),
            }
        }
        Answer::Http { status: 401 | 403, .. } => {
            refusal("auth.refused", "cmux refused this machine's carrier ticket.")
        }
        Answer::Http { status: 404, .. } => {
            refusal("carrier.unavailable", "cmux has no carrier route here yet.")
        }
        Answer::Http { status: 429, .. } => {
            refusal("rate_limited", "cmux is rate limited. Wait a moment, then retry.")
        }
        Answer::Http { .. } => {
            refusal("carrier.unavailable", "cmux did not answer the carrier ticket request.")
        }
        Answer::Transport => refusal(
            "carrier.unreachable",
            "Check this machine's connection and retry the carrier ticket request.",
        ),
    }
}

/// What `host cloud carrier-ticket` prints for an agent reply: the ticket
/// alone on stdout (`Ok`), or the refusal (`Err`), which leads with its
/// dotted error code ([`printed_code`]). The ticket never goes to stderr or
/// a log. The session host logs only the codes from this stderr (cmux-remote
/// `relay.rs`, `stderr_summary`), so the code is the reason it keeps.
pub fn ticket_of(reply: &Value) -> Result<String, String> {
    if reply.get("ok") == Some(&json!(true))
        && let Some(ticket) =
            reply.get("ticket").and_then(Value::as_str).filter(|t| valid_ticket(t))
    {
        return Ok(ticket.to_owned());
    }
    let error = reply.get("error");
    let field = |name: &str| error.and_then(|e| e.get(name)).and_then(Value::as_str);
    Err(format!(
        "{}: {}",
        printed_code(field("code")),
        field("message").unwrap_or("the Cloud agent gave no carrier ticket")
    ))
}

/// A refusal's code as printed: dotted lowercase segments of letters and
/// `_` (`carrier.unavailable`). A shared agent code with no dot (`busy`,
/// `rate_limited`) is printed under `carrier.`; a missing or other code is
/// `carrier.bad_answer`.
fn printed_code(code: Option<&str>) -> String {
    let segment = |part: &str| {
        part.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
            && part.bytes().all(|byte| byte.is_ascii_lowercase() || byte == b'_')
    };
    match code {
        Some(code) if code.len() <= 64 && code.split('.').all(segment) => {
            if code.contains('.') {
                code.to_owned()
            } else {
                format!("carrier.{code}")
            }
        }
        _ => "carrier.bad_answer".to_owned(),
    }
}

#[cfg(test)]
#[path = "carrier_ticket_tests.rs"]
mod tests;
