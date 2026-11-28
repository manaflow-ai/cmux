//! The build-session kill switch for agents (cx-9ettq, cx-tgf4h), as the
//! daemon and the CLI read it. A GUI build job runs with
//! `ACPMUX_AGENT_LAUNCH=deny` (or `CMUX_AGENTS_DISABLED=1`): acpmux starts no
//! agent (acpmux launch_policy.rs, the same test), so no Chief turn can run.
//! The daemon then starts no Chief brain and answers `chief.engine.*` and
//! `chief.stop` with [`refusal`]; `cmux chief` refuses to send at once instead
//! of waiting for a reply that cannot come.

use serde_json::{Value, json};

/// The variable that names the policy; `deny` turns agents off.
pub const LAUNCH_ENV: &str = "ACPMUX_AGENT_LAUNCH";
/// The app-wide switch; `1` turns agents off too.
pub const DISABLED_ENV: &str = "CMUX_AGENTS_DISABLED";
/// `details.reason` of the refusal (acpmux's `data.reason`).
pub const REASON: &str = "agent_launch_disabled";
/// What a refusal says (English; the CLI localizes its own copy).
pub const MESSAGE: &str = "agents are disabled in this build session (ACPMUX_AGENT_LAUNCH=deny or CMUX_AGENTS_DISABLED=1): the Chief does not start a turn";

/// Whether this process's environment turns agents off. Read at each call,
/// never cached.
pub fn disabled() -> bool {
    disabled_by(
        std::env::var(LAUNCH_ENV).ok().as_deref(),
        std::env::var(DISABLED_ENV).ok().as_deref(),
    )
}

/// The test of [`disabled`] on given values (acpmux launch_policy.rs).
pub fn disabled_by(launch: Option<&str>, agents_disabled: Option<&str>) -> bool {
    launch.is_some_and(|v| v.trim().eq_ignore_ascii_case("deny"))
        || agents_disabled.is_some_and(|v| v.trim() == "1")
}

/// The variable that is set, for the refusal's details.
fn variable() -> &'static str {
    if std::env::var(LAUNCH_ENV).is_ok_and(|v| v.trim().eq_ignore_ascii_case("deny")) {
        LAUNCH_ENV
    } else {
        DISABLED_ENV
    }
}

/// The typed refusal as a protocol/2 `operation.failed` error object (the
/// CLI prints it as is); `message` is the caller's localized text.
pub fn refusal(message: &str) -> Value {
    json!({
        "code": "operation.failed",
        "message": message,
        "details": {"reason": REASON, "variable": variable()},
        "retryable": false,
    })
}
