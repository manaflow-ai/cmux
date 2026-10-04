//! A delete retried after a lost answer (OWNERSHIP-PRINCIPLES invariant 5).
//!
//! A delete with the same idempotency key, op and args as an earlier
//! attempt whose outcome is unknown answers its success result when the
//! Cloud API now answers 404: the resource is gone, which is the outcome the
//! caller asked for. Only then. A first delete of a missing resource, and a
//! retry with no earlier unknown outcome (only definite 4xx answers), stay
//! `not_found`, so a wrong id is not hidden behind a success (DECISION in the
//! C7 report). The unknown outcome is sticky: a later 429 or sign-in error
//! says nothing about the earlier attempt.
//!
//! Residual risk: a 404 on such a retry may come from a gone parent (the
//! machine of a snapshot or file), and a relay error may hide a call that was
//! never sent; both then answer success. The Cloud API's not-found codes are
//! not specific enough to tell these apart (a firewall rule answers
//! `vm_not_found`).

use crate::api::{CloudError, codes};
use serde_json::{Value, json};

/// The deletes of the server that call the Cloud API. `cloud.port.close`
/// closes a local listener and never answers not found; `cloud.tunnel.detach`
/// changes a relation and keeps the tunnel record, so a 404 there means a
/// wrong device or network, never "already detached".
const DELETES: &[&str] = &[
    "cloud.machine.delete",
    "cloud.snapshot.delete",
    "cloud.firewall.delete",
    "cloud.publication.delete",
    "cloud.fs.remove",
];

pub(super) fn is_delete(name: &str) -> bool {
    DELETES.contains(&name)
}

/// True when `error` does not say whether the call changed anything: the
/// answer was lost on the way back (relay), or the Cloud API failed after it
/// may have acted (5xx other than 501). A 4xx or 501 answer, or a call that
/// was never sent (no sign-in), is definite. A relay error cannot tell "never
/// sent" from "answer lost", so it counts as unknown.
pub(super) fn outcome_unknown(error: &CloudError) -> bool {
    error.code == codes::RELAY_UNAVAILABLE || error.status.is_some_and(|s| s >= 500 && s != 501)
}

/// The answer of a successful delete, for a retry that finds the resource
/// gone. `None` for an op that is not a delete.
pub(super) fn gone_answer(name: &str, args: &Value) -> Option<Value> {
    match name {
        "cloud.fs.remove" => {
            let map = args.as_object()?;
            let path = crate::fs::path::guest_arg(map, "path").ok()?;
            Some(json!({ "ok": true, "path": path.as_str() }))
        }
        _ if is_delete(name) => Some(json!({ "ok": true })),
        _ => None,
    }
}
