//! Every Cloud refusal the cmux platform answers with its own HTTP status, and what a client
//! does with one: show it and stop, wait out its Retry-After, or send the same request again.
//!
//! cmux-platform#1192 gave each Cloud refusal code its own answer (a cap a final 403, a rate
//! limit a 429 with Retry-After, a machine-state conflict a 409, only a real outage a retryable
//! 503 with a `cause`), and every body a `retryable` flag. Before it, a route answered an unknown
//! code as 503 "Retry with the same client key", so a cap read as an outage; clients that read a
//! status alone (a 403 means "make the machine yourself", a 503 means "retry") walked straight
//! back into the cap. Every client reads a refusal here, so one table decides it everywhere: the
//! cmux CLI's platform calls (`cmux machine`, `link start-chat`), cmux-cloud-client's
//! [`ApiError`](../../cmux_cloud_client/struct.ApiError.html), cmux-cloud-api's turn retries and
//! the app's cap card ([`crate::cap`]).
//!
//! [`PLATFORM`] is a copy of `CLOUD_REFUSALS` in [`SOURCE`] at [`SOURCE_COMMIT`]. Its tests fail
//! when the copy is older than [`MAX_COPY_AGE_DAYS`] (the platform repository is private, so CI
//! cannot read it), and, with `CMUX_PLATFORM_REFUSALS_TS` naming that file, when the two differ.
//! Refresh: copy the rows, then [`SOURCE_COMMIT`] and [`COPIED_ON`].

use serde::Serialize;
use serde_json::Value;

/// Where [`PLATFORM`] is copied from.
pub const SOURCE: &str = "manaflow-ai/cmux-platform src/server/cloud/Refusals.ts (CLOUD_REFUSALS)";
/// The platform commit the copy was taken at (cmux-platform#1192's head).
pub const SOURCE_COMMIT: &str = "0f6ca7adb77c0250d051dd5afb2ed7d233e86ce9";
/// The day the copy was taken (UTC, `YYYY-MM-DD`).
pub const COPIED_ON: &str = "2026-11-10";
/// A copy older than this fails its test: the platform's list may have grown since.
pub const MAX_COPY_AGE_DAYS: u64 = 30;

/// What a client does with a refusal.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Handling {
    /// Final: the person reads it with its reason. Never retried, never a fallback that would
    /// meet the same cap.
    Final,
    /// A rate limit: the same request again after its Retry-After.
    RetryAfter,
    /// The same request again, with the same key.
    Retry,
}

/// One row of the platform's table.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub status: u16,
    /// The platform's `retryable` for this code.
    pub retryable: bool,
}

impl Refusal {
    pub const fn handling(&self) -> Handling {
        match (self.status, self.retryable) {
            (429, _) => Handling::RetryAfter,
            (_, true) => Handling::Retry,
            (_, false) => Handling::Final,
        }
    }
}

const fn row(code: &'static str, status: u16, retryable: bool) -> Refusal {
    Refusal { code, status, retryable }
}

/// `CLOUD_REFUSALS` of [`SOURCE`] at [`SOURCE_COMMIT`], in its order.
pub const PLATFORM: &[Refusal] = &[
    // The request itself.
    row("validation.invalid", 400, false),
    row("cloud.environment.invalid", 400, false),
    row("cloud.size.grow_only", 400, false),
    row("cloud.provider.unsupported", 400, false),
    // Who may, and the caps.
    row("auth.forbidden", 403, false),
    row("team.roles_required", 403, false),
    row("policy.denied", 403, false),
    row("approval.denied", 403, false),
    row("cloud.plan.required", 403, false),
    row("cloud.quota.exceeded", 403, false),
    row("cloud.quota.vm_limit", 403, false),
    row("cloud.size.locked", 403, false),
    row("cloud.spend_cap.reached", 403, false),
    row("cloud.member_budget.reached", 403, false),
    // Nothing there.
    row("cloud.machine.not_found", 404, false),
    row("cloud.snapshot.not_found", 404, false),
    row("cloud.environment.not_found", 404, false),
    row("cloud.provider.vm_missing", 404, false),
    // The machine's state does not allow the step.
    row("cloud.machine.not_running", 409, false),
    row("cloud.machine.not_paused", 409, false),
    row("cloud.machine.not_evictable", 409, false),
    row("cloud.machine.not_reapable", 409, false),
    row("cloud.machine.not_retryable", 409, false),
    row("cloud.machine.not_archived", 409, false),
    row("cloud.machine.pause_abandoned", 409, false),
    row("cloud.machine.idle_pause_off", 409, false),
    row("cloud.spare.not_running", 409, false),
    row("cloud.snapshot.not_expired", 409, false),
    row("cloud.migration.not_migrated", 409, false),
    row("cloud.environment.build_failed", 409, false),
    row("cloud.platform.start_cancelled", 409, false),
    row("cloud.provider.name_conflict", 409, false),
    row("workspace_machine.fleet_machine", 409, false),
    row("idempotency.conflict", 409, false),
    row("approval.expired", 409, false),
    // ... until it changes: the same request can pass later.
    row("cloud.machine.busy", 409, true),
    row("cloud.machine.not_bound", 409, true),
    row("cloud.environment.busy", 409, true),
    row("approval.pending", 409, true),
    row("approval.too_many_pending", 409, true),
    // A rate limit.
    row("cloud.rate_limited", 429, true),
    // Final 503s.
    row("cloud.no_snapshot_configured", 503, false),
    row("cloud.provider.image_withdrawn", 503, false),
    row("cloud.provider.refused", 503, false),
    // A real outage, or a step still settling.
    row("cloud.provider.unavailable", 503, true),
    row("cloud.provider.power_unconfirmed", 503, true),
    row("cloud.platform.pause_pending", 503, true),
    row("cloud.machine.pause_unconfirmed", 503, true),
    row("cloud.machine.idle_pause_settling", 503, true),
    row("cloud.machine.shape_unknown", 503, true),
    row("cloud.carrier_pending", 503, true),
    row("cloud.snapshot.failed", 503, true),
    row("cloud.environment.secrets_unavailable", 503, true),
    row("mutation.indeterminate", 503, true),
    row("owner.unreachable", 503, true),
];

/// The platform's row for `code`.
pub fn platform(code: &str) -> Option<&'static Refusal> {
    PLATFORM.iter().find(|refusal| refusal.code == code)
}

/// The table's own copy of `code` (a `&'static str` a caller may keep and print), when the
/// platform's table has it.
pub fn platform_code(code: &str) -> Option<&'static str> {
    platform(code).map(|refusal| refusal.code)
}

/// A cap or plan refusal: the team's plan, its machines, its VM limit, its spending. Final; the
/// person reads why. A client never answers one by making the machine another way, which meets
/// the same cap.
pub fn is_cap(code: &str) -> bool {
    matches!(
        code,
        "cloud.plan.required"
            | "cloud.quota.exceeded"
            | "cloud.quota.vm_limit"
            | "cloud.size.locked"
            | "cloud.spend_cap.reached"
            | "cloud.member_budget.reached"
    )
}

/// What a client does with an answer of `status`, whose body says `code` and maybe `retryable`:
/// the body's flag first (a 429 that may be retried waits its Retry-After), then the platform's
/// row for the code (an older deployment that sends no flag), then the status alone (no body,
/// a proxy's page, a code the platform's table lacks): a 429 waits, a 502, 503 or 504 retries.
pub fn handling(status: u16, code: Option<&str>, retryable: Option<bool>) -> Handling {
    match retryable {
        Some(false) => Handling::Final,
        Some(true) if status == 429 => Handling::RetryAfter,
        Some(true) => Handling::Retry,
        None => code.and_then(platform).map_or_else(
            || match status {
                429 => Handling::RetryAfter,
                502..=504 => Handling::Retry,
                _ => Handling::Final,
            },
            Refusal::handling,
        ),
    }
}

/// A rate limit that names no window waits this long (the platform's own default).
pub const DEFAULT_RETRY_AFTER_SECONDS: u64 = 60;

/// The numbers a refusal's body carries, and nothing else it says: a cap's limit and use, the
/// VM limit's held and orphan VMs, a rate limit's window. Numbers only, so a client may keep and
/// print them where it keeps no server text.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Facts {
    /// `retryable`, when the body says.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retryable: Option<bool>,
    /// `retryAfterSeconds`, or the Retry-After header.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after_s: Option<u64>,
    /// `details.limit`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<u64>,
    /// `details.used`, or the VM limit's `details.team_vms`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub used: Option<u64>,
    /// The VM limit's `details.orphans`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub orphans: Option<u64>,
    /// The VM limit's `details.oldest_vm_age_s`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oldest_vm_age_s: Option<u64>,
}

impl Facts {
    /// The facts of a refusal `body` (`{code, message, retryable, details, retryAfterSeconds}`,
    /// or the Worker's `{error: {...}}`) and its Retry-After header.
    pub fn read(body: Option<&Value>, retry_after_header: Option<&str>) -> Self {
        let error = body.map(|body| match body.get("error") {
            Some(nested) if nested.is_object() => nested,
            _ => body,
        });
        let details = error.and_then(|error| error.get("details"));
        let number = |value: Option<&Value>| value.and_then(Value::as_u64);
        let detail = |name: &str| number(details.and_then(|details| details.get(name)));
        let header = retry_after_header.and_then(|text| text.trim().parse::<u64>().ok());
        Self {
            retryable: error.and_then(|error| error.get("retryable")).and_then(Value::as_bool),
            retry_after_s: number(error.and_then(|error| error.get("retryAfterSeconds")))
                .or(header)
                .or_else(|| detail("retry_after_ms").map(|ms| ms.div_ceil(1000).max(1))),
            limit: detail("limit"),
            used: detail("used").or_else(|| detail("team_vms")),
            orphans: detail("orphans"),
            oldest_vm_age_s: detail("oldest_vm_age_s"),
        }
    }

    /// How long a rate limit asks to wait.
    pub fn wait_s(&self) -> u64 {
        self.retry_after_s.unwrap_or(DEFAULT_RETRY_AFTER_SECONDS)
    }
}

/// Why the platform refused, for a person: a cap names its limit and what holds it, a rate limit
/// when to try again. None for a code with no reason of its own (the caller's own words stand).
pub fn reason(code: &str, facts: &Facts) -> Option<String> {
    let of = |noun: &str| match (facts.used, facts.limit) {
        (Some(used), Some(limit)) => format!(" ({used} of {limit} {noun})"),
        (None, Some(limit)) => format!(" (its limit is {limit} {noun})"),
        _ => String::new(),
    };
    Some(match code {
        "cloud.quota.vm_limit" => {
            let orphans = match facts.orphans {
                Some(orphans) if orphans > 0 => format!(", {orphans} of them left over"),
                _ => String::new(),
            };
            format!(
                "this team is at its Cloud machine limit{}{orphans}; paused machines count, so delete one to make room",
                of("machines")
            )
        }
        "cloud.quota.exceeded" => {
            format!("this team is at its plan's Cloud machine limit{}", of("machines"))
        }
        "cloud.plan.required" => "this team has no Cloud plan".to_owned(),
        "cloud.size.locked" => "this machine size needs another plan".to_owned(),
        "cloud.spend_cap.reached" => {
            "this team reached its Cloud spending cap; an admin can raise it".to_owned()
        }
        "cloud.member_budget.reached" => {
            "you spent your monthly Cloud budget; an admin can raise it".to_owned()
        }
        "cloud.rate_limited" => {
            format!("too many Cloud machine starts; try again in {} s", facts.wait_s())
        }
        _ => return None,
    })
}

#[cfg(test)]
mod tests;
