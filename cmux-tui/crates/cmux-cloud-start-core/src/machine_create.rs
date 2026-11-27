//! Same-key retry rules of the NEXT Cloud create and power ops on the Cloud app server (moved from
//! the app's `CloudMachineCreateRetry` and `CloudMachinePower`), and the create answer's spare note.

use serde::{Deserialize, Serialize};

/// The app server's code for a call longer than CloudDO's wait (`mutation.indeterminate`).
pub const INDETERMINATE: &str = "cmux.cloud.indeterminate";

/// Codes (by suffix) of a server that refused the create before making anything.
const DEFINITIVE: [&str; 18] = [
    "plan_required",
    "plan.required",
    "quota_exceeded",
    "quota.exceeded",
    // The team's VM limit (paused machines count), its spending cap and the member's budget
    // (cmux-platform#1192: each a final 403 until a machine is deleted or the cap is raised).
    "vm_limit",
    "spend_cap_reached",
    "spend_cap.reached",
    "member_budget_reached",
    "member_budget.reached",
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

/// How many times a create is asked again, each with a new key, after the machine it made or claimed
/// was gone before it answered.
pub const MACHINE_GONE_RETRIES: u32 = 2;

/// Whether a create refused on try `attempt` (from 1) is asked again with a new key because the machine
/// it made or claimed was gone before it answered: `cloud.machine.not_found {machine}` from the create
/// itself (cmux-platform's contract: "retry with a new key"; a spare claimed as another create or the
/// reaper deleted it). The bare refusal ended the start "Couldn't create Cloud machine X (no such machine
/// in this team)" (cosmic-gray gap ledger, 2026-11-27). Told apart from a snapshot or environment that is
/// gone (the same `not_found` on the app server's route) by the machine it names (`machine_named`, the
/// answer's `details.machine`) or its words; never past ``MACHINE_GONE_RETRIES``.
pub fn create_machine_gone_retries(
    code: &str,
    message: &str,
    machine_named: bool,
    attempt: u32,
) -> bool {
    let gone = code.ends_with("not_found")
        && !code.contains("snapshot")
        && !code.contains("environment")
        && (machine_named || message.to_ascii_lowercase().contains("no such machine"));
    gone && attempt.max(1) <= MACHINE_GONE_RETRIES
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

/// The create answer's spare claim report (cmux-platform CloudCore `withSpareAnswer`: `spare_fallback`,
/// `spare_skips`, `spare_skipped`, `spare_skipped_omitted` on the result's value) as one log note, so the
/// app's `created machine` line says why a create skipped this person's spare: the fallback reason, the
/// skips counted by reason, and how many spares it passed over. Reason codes and counts only: a value
/// that is no bare reason token (an id, an address, free text) is `?` or left out, and `spare_skipped`
/// (each spare's machine id) is only counted. `spare=none` when the answer has no claim attempt.
pub fn spare_note(answer: &serde_json::Value) -> String {
    use serde_json::Value;
    let field = |key: &str| answer.get(key);
    let mut parts = Vec::new();
    if let Some(fallback) = field("spare_fallback") {
        let shown = match fallback {
            Value::Null => "null",
            Value::String(reason) if is_reason_token(reason) => reason.as_str(),
            _ => "?",
        };
        parts.push(format!("spare_fallback={shown}"));
    }
    if let Some(Value::Object(skips)) = field("spare_skips") {
        let counted: std::collections::BTreeMap<&str, u64> = skips
            .iter()
            .filter(|(reason, _)| is_reason_token(reason))
            .filter_map(|(reason, count)| Some((reason.as_str(), count.as_u64()?)))
            .collect();
        let counted = serde_json::to_string(&counted).unwrap_or_else(|_| "{}".into());
        parts.push(format!("spare_skips={counted}"));
    }
    if let Some(Value::Array(skipped)) = field("spare_skipped") {
        parts.push(format!("spare_skipped={}", skipped.len()));
    }
    if let Some(omitted) = field("spare_skipped_omitted").and_then(Value::as_u64) {
        parts.push(format!("spare_skipped_omitted={omitted}"));
    }
    if parts.is_empty() { "spare=none".into() } else { parts.join(" ") }
}

/// A platform reason code (`all_skipped`, `image`, `state_paused`): lowercase, digits and `_`, at most 40,
/// starting with a letter, and not shaped like an id (`vm_01hx...`: an id prefix and a digit).
fn is_reason_token(text: &str) -> bool {
    const ID_PREFIXES: [&str; 12] = [
        "vm_", "team_", "user_", "inst_", "install_", "ws_", "org_", "acct_", "sess_", "mach_",
        "img_", "snap_",
    ];
    let mut chars = text.chars();
    let shaped = chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && text.len() <= 40
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    let id_like = ID_PREFIXES.iter().any(|prefix| text.starts_with(prefix))
        && text.chars().any(|c| c.is_ascii_digit());
    shaped && !id_like
}

#[cfg(test)]
mod tests;
