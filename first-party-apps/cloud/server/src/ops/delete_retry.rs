//! A delete retried after a lost answer (OWNERSHIP-PRINCIPLES invariant 5).
//!
//! A delete with the same idempotency key, op and args as an earlier
//! attempt whose outcome is unknown answers its success result when the
//! Cloud API now answers 404 WITH THE KIND'S OWN NOT-FOUND CODE
//! ([`gone_code`]): the resource is gone, which is the outcome the caller
//! asked for. Only then. A bare 404 (a missing route: production has no
//! `/api/vm/:id/fs/*` routes today), a 404 with no code, or with another
//! kind's code stays the typed error. A first delete of a missing resource, and a
//! retry with no earlier unknown outcome (only definite 4xx answers), stay
//! `not_found`, so a wrong id is not hidden behind a success (DECISION in the
//! C7 report). The unknown outcome is sticky: a later 429 or sign-in error
//! says nothing about the earlier attempt.
//!
//! Residual risk: a relay error may hide a call that was never sent; then a
//! retry that finds the resource gone (deleted by someone else) answers
//! success. `vm_publication_not_found` is also the code for a missing VM of
//! the publication, so that case counts as gone too.

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

/// The Cloud API's not-found code that means "this resource is gone" for
/// delete `name` (the `error` field or `x-cmux-vm-error` of the 404).
/// `None` for an op that is not a delete.
pub(super) fn gone_code(name: &str) -> Option<&'static str> {
    Some(match name {
        "cloud.machine.delete" => "vm_not_found",
        // Planned by the backend lead for "rule missing"; `vm_not_found`
        // means the VM is missing and is not success here. Until the code
        // ships, firewall retries stay errors.
        "cloud.firewall.delete" => "vm_firewall_rule_not_found",
        "cloud.snapshot.delete" => "vm_snapshot_not_found",
        // Planned for web/app/api/vm/[id]/fs/[operation]/route.ts; not
        // served yet, so fs retries stay errors until then.
        "cloud.fs.remove" => "vm_file_not_found",
        // web/app/api/vm/publications/routeShared.ts: the same code for a
        // missing publication and for its missing VM; both mean gone.
        "cloud.publication.delete" => "vm_publication_not_found",
        _ => return None,
    })
}

/// True when `error` is the 404 that says delete `name`'s resource is gone.
pub(super) fn is_gone(name: &str, error: &CloudError) -> bool {
    error.code == codes::NOT_FOUND
        && error.status == Some(404)
        && gone_code(name).is_some_and(|code| error.upstream_code.as_deref() == Some(code))
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
