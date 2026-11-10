//! Same-key retry rules of the NEXT Cloud create and power ops on the Cloud app server (moved from
//! the app's `CloudMachineCreateRetry` and `CloudMachinePower`).

use serde::{Deserialize, Serialize};

/// The app server's code for a call longer than CloudDO's wait (`mutation.indeterminate`).
pub const INDETERMINATE: &str = "cmux.cloud.indeterminate";

/// Codes (by suffix) of a server that refused the create before making anything.
const DEFINITIVE: [&str; 13] = [
    "plan_required",
    "plan.required",
    "quota_exceeded",
    "quota.exceeded",
    "size_locked",
    "size.locked",
    "approval_denied",
    "approval.denied",
    "approval_expired",
    "approval.expired",
    // cloud.environment.boot: secrets the Vault can't serve yet, no usable snapshot, an
    // environment or snapshot that is gone. Each is stored with the key; a Retry after the fix
    // needs a new one.
    "secrets_unavailable",
    "no_snapshot_configured",
    "not_found",
];

/// Whether the server refused the create before making anything (no plan, the plan's machine limit
/// or size, an approval denied or expired, which the contract asks again with a new key), an answer
/// a same-key Retry would only replay. A lost answer, a timeout or a relay that is down is
/// uncertain, so it keeps the key.
pub fn is_definitive_refusal(code: &str) -> bool {
    DEFINITIVE.iter().any(|suffix| code.ends_with(suffix))
}

/// The team an app-server create goes to.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamRequest {
    /// The install token's team now.
    pub current: String,
    /// The create was sent at least once with its key.
    #[serde(default)]
    pub was_sent: bool,
    /// The team its first send went to.
    #[serde(default)]
    pub first: Option<String>,
}

/// The install token's team `current`, or, once the request was sent, the team of its first send,
/// which `current` must still be: the key is scoped per team, so the same key in another team would
/// be a second machine. `None` refuses the retry as one in another team.
pub fn create_team(request: &TeamRequest) -> Option<String> {
    match (&request.first, request.was_sent) {
        (Some(first), true) => (first == &request.current).then(|| first.clone()),
        _ => Some(request.current.clone()),
    }
}

/// Whether a pause or start that failed with `code` on try `attempt` (from 1) of `attempts` is
/// asked again with the same key: only an indeterminate answer (it joins the call in flight), and
/// never past the attempts (at least one).
pub fn power_retries(code: &str, attempt: u32, attempts: u32) -> bool {
    code == INDETERMINATE && attempt < attempts.max(1)
}

/// The app server's op that starts (resumes) a paused machine.
pub const START_OP: &str = "cloud.machine.start";

/// Whether a power op whose last same-key try still answered `code` is still on its way, not failed:
/// only a start that answered indeterminate. That call joined the one in flight, which CloudDO keeps
/// running after its wait, so the machine's record (`starting`, then `running`, or paused again with
/// its error) says how it ended. A start's link wait then keeps waiting on that record instead of
/// ending on the resume as failed: Leo's nightly said "didn't connect" 15 s into a start on a paused
/// machine (three indeterminate answers), and the retry found the machine running (hq#7086,
/// 2026-11-09). A pause keeps failing: its answer is what frees the active slot a caller waits on.
pub fn power_pending(op: &str, code: &str) -> bool {
    op == START_OP && code == INDETERMINATE
}

#[cfg(test)]
mod tests;
