//! Pure decisions of `AcpmuxChiefSessionRouter`. The native host still queries the daemon,
//! checks directories, opens sockets, and performs every lifecycle operation.
//!
//! A session's exact resolve decides ownership, not its Chief tag. A peer row is not owned
//! by the daemon that mirrors it. The native host can still prove ownership from its disk
//! when resolve is unavailable. Only this Mac's daemon can be restarted by the pane.

use serde_json::{Value, json};

/// A supplied ownership callback applies to every present session, including an empty string.
/// Only the native daemon probe rejects an empty session before making its request.
pub fn uses_chief(session: Option<&str>, chief_owns: bool) -> bool {
    session.is_some() && chief_owns
}

/// Swift's `(found["peer"] as? String)?.isEmpty != false`: missing, null, and non-string
/// peer fields all mean an owned resolve. A nonempty peer string means a mirrored row.
pub fn owns_resolved(summary: Option<&serde_json::Map<String, Value>>) -> bool {
    summary.is_some_and(|row| row.get("peer").and_then(Value::as_str).is_none_or(str::is_empty))
}

/// The existing native directory probe's single-component check. This deliberately does not
/// trim, normalize, or add an identifier format restriction: the host owns filesystem semantics.
pub fn allows_disk_key(session: &str) -> bool {
    !session.is_empty() && session != "." && session != ".." && !session.contains('/')
}

/// `session_routing`: facts from the native host in, decisions out; no I/O or host lifetime.
/// Unknown kinds and missing/mistyped facts fail instead of silently selecting another daemon.
pub fn call(request: &Value) -> Option<Value> {
    match request.get("kind")?.as_str()? {
        "route" => {
            let session = match request.get("session")? {
                Value::Null => None,
                Value::String(session) => Some(session.as_str()),
                _ => return None,
            };
            let chief = uses_chief(session, request.get("chief_owns")?.as_bool()?);
            Some(json!({"host": if chief { "chief" } else { "local" }, "restart": !chief}))
        }
        "resolved" => {
            let summary = match request.get("summary")? {
                Value::Null => None,
                Value::Object(summary) => Some(summary),
                _ => return None,
            };
            Some(json!({"owned": owns_resolved(summary)}))
        }
        "disk_key" => Some(json!({"allowed": allows_disk_key(request.get("session")?.as_str()?)})),
        _ => None,
    }
}
