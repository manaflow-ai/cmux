//! A computer use call waits for Computer Use setup, as the person sets it
//! up. The helper's tools (the `cmux-cua` upstream) need two macOS grants
//! that only the person can give. Before, a call made before setup waited
//! 55 s inside the helper proxy with nothing on screen, then failed, so the
//! agent gave up while the person did not know anything was asked.
//!
//! Now each call but the status read (`check_permissions`) first reads the
//! app's Computer Use Setup (`computer_use.status`). Ready, it runs. Not
//! ready, the server asks the app for the grant the way an agent does
//! (`permissions.request {kind: computer_use}`): the app shows its card
//! with who asks and why, the person's Continue turns Computer Use on and
//! guides them through System Settings, and the request returns when the
//! grants land, the person denies, or the wait ends. Repeated calls join the
//! one card. Then the call runs, or the agent gets a plain answer that says
//! what happened and what to do next (never "retry in a loop").
//!
//! The wait runs inside the call (`SetupWait::run`), so in direct mode it
//! holds only that call's thread; in a `cmux_exec` script it is bounded by
//! the script's limit. An app that does not answer the status read or the
//! request (an older app, no app) leaves the call as before.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::CallFailure;

/// The upstream whose tools need the helper's grants.
pub(super) const SERVER: &str = "cmux-cua";
/// Its status read: it reports the grants, so it never waits for them
/// (the helper proxy's own rule).
const STATUS_TOOL: &str = "check_permissions";
/// The app's Computer Use Setup: `{phase, accessibility, screen_recording, helper}`.
pub(super) const STATUS_METHOD: &str = super::super::agents_doctor::STATUS_METHOD;
/// The app's agent permission card.
pub(super) const REQUEST_METHOD: &str = "permissions.request";
/// How long a call waits for the person (the card's default).
const SETUP_WAIT: Duration = Duration::from_secs(300);
/// The app answers a request only when it ends: its wait, plus transport slack.
const REQUEST_SLACK: Duration = Duration::from_secs(15);

/// An app method call that may run on another thread.
pub(super) type AppCaller =
    Arc<dyn Fn(&str, Value, Duration) -> Result<Value, CallFailure> + Send + Sync>;

/// What a computer use call needs before it runs.
pub(super) enum Gate {
    /// Setup is ready (or unknown): run the call.
    Run,
    /// The call cannot run; this is its result.
    Refuse(Value),
    /// The person must finish setup first.
    Wait(SetupWait),
}

/// The card request for one call, run where the call runs.
pub(super) struct SetupWait {
    app: AppCaller,
    params: Value,
    wait: Duration,
}

impl SetupWait {
    /// Shows the card and waits for it to end: `None` runs the call, a
    /// value is the call's result instead.
    pub(super) fn run(self) -> Option<Value> {
        match (self.app)(REQUEST_METHOD, self.params, self.wait + REQUEST_SLACK) {
            Ok(outcome) => answer(&outcome),
            // No card in this app (or no answer): the call runs as before,
            // and the helper says what is missing.
            Err(_) => None,
        }
    }
}

/// Whether `status` (the app's Computer Use Setup) lets the helper act.
pub(super) fn is_ready(status: &Value) -> bool {
    status["phase"] == "ready" && status["accessibility"] == true && status["screen_recording"] == true
}

/// What `tool` of the computer use server needs, from the app's `status`
/// read. `app` runs the card request; `caller` names the chat that asks;
/// `cap` is the call's own time limit (a script's).
pub(super) fn decide(
    tool: &str,
    status: Result<Value, CallFailure>,
    app: Option<AppCaller>,
    caller: Option<Value>,
    cap: Option<Duration>,
) -> Gate {
    if tool == STATUS_TOOL {
        return Gate::Run;
    }
    // An app that does not answer (or knows no setup) leaves the call as before.
    let Ok(status) = status else { return Gate::Run };
    if !status.is_object() || is_ready(&status) {
        return Gate::Run;
    }
    match status["phase"].as_str() {
        Some("disabled_by_policy") => return Gate::Refuse(refusal(Refusal::Disabled)),
        Some("unavailable") => return Gate::Refuse(refusal(Refusal::Unavailable)),
        Some("version_mismatch") => return Gate::Refuse(refusal(Refusal::VersionMismatch)),
        _ => {}
    }
    let Some(app) = app else { return Gate::Run };
    let wait = cap.map_or(SETUP_WAIT, |cap| cap.min(SETUP_WAIT)).max(Duration::from_secs(1));
    let mut params = json!({
        "kind": "computer_use",
        "reason": format!("It called the computer use tool {tool} to work in an app on this Mac."),
        "timeout_seconds": wait.as_secs(),
    });
    if let Some(caller) = caller {
        params["caller"] = caller;
    }
    Gate::Wait(SetupWait { app, params, wait })
}

/// The call's result for the card's `outcome`, or `None` to run it.
fn answer(outcome: &Value) -> Option<Value> {
    match outcome["outcome"].as_str() {
        Some("denied") => Some(refusal(Refusal::Denied)),
        Some("timed_out" | "cancelled") => Some(refusal(Refusal::Pending)),
        Some("unavailable") => Some(refusal(Refusal::Unavailable)),
        // granted, already_granted, or an answer this server does not know:
        // the helper decides.
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Refusal {
    Denied,
    Pending,
    Disabled,
    Unavailable,
    VersionMismatch,
}

impl Refusal {
    fn code(self) -> &'static str {
        match self {
            Self::Denied => "computer_use.denied",
            Self::Pending => "computer_use.setup_pending",
            Self::Disabled => "computer_use.disabled",
            Self::Unavailable => "computer_use.unavailable",
            Self::VersionMismatch => "computer_use.version_mismatch",
        }
    }

    /// What the model reads: what happened, and what to do now.
    fn message(self) -> &'static str {
        match self {
            Self::Denied => {
                "The person chose not to allow computer use. Do not call computer use tools \
                 again in this turn. Tell the person in one line what you could not do, then \
                 continue with the work that does not need their apps."
            }
            Self::Pending => {
                "Computer use is not set up yet: the person has not finished the setup cmux \
                 showed them. Tell the person in one line that computer use waits for them in \
                 cmux, then continue with other work. Call computer use again only after they \
                 say it is done."
            }
            Self::Disabled => {
                "Computer use is turned off on this Mac by its administrator. Do not call \
                 computer use tools. Tell the person in one line, then continue with other work."
            }
            Self::Unavailable => {
                "Computer use is not available in this cmux build (it has no signed cmux \
                 Computer Use helper). Do not call computer use tools. Tell the person in one \
                 line, then continue with other work."
            }
            Self::VersionMismatch => {
                "Computer use cannot start: the cmux Computer Use helper and cmux are \
                 different versions. Tell the person in one line to update cmux, then continue \
                 with other work."
            }
        }
    }
}

/// The tool result for `refusal`: nothing ran.
pub(super) fn refusal(refusal: Refusal) -> Value {
    let error = json!({
        "code": refusal.code(),
        "message": refusal.message(),
        "details": {},
        "retryable": refusal == Refusal::Pending,
    });
    super::tool_error(super::envelope(error, "not_run", None))
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::FailureKind;

    fn caller() -> Option<AppCaller> {
        Some(Arc::new(|_: &str, _: Value, _: Duration| Ok(json!({"outcome": "granted"}))))
    }

    fn not_set_up() -> Result<Value, CallFailure> {
        Ok(json!({"phase": "ready", "accessibility": true, "screen_recording": false}))
    }

    fn code(gate: Gate) -> Option<String> {
        match gate {
            Gate::Refuse(result) => result["structuredContent"]["error"]["code"].as_str().map(str::to_owned),
            _ => None,
        }
    }

    #[test]
    fn the_status_read_and_an_unknown_setup_run_as_before() {
        assert!(matches!(decide("check_permissions", not_set_up(), caller(), None, None), Gate::Run));
        let down = Err(CallFailure::local(FailureKind::NotRun, "app.unreachable", "no app"));
        assert!(matches!(decide("click", down, caller(), None, None), Gate::Run));
        assert!(matches!(decide("click", Ok(Value::Null), caller(), None, None), Gate::Run));
        // A missing grant with no way to show the card: the helper says what is missing.
        assert!(matches!(decide("click", not_set_up(), None, None, None), Gate::Run));
    }

    #[test]
    fn a_missing_grant_waits_for_the_card_within_the_calls_limit() {
        let Gate::Wait(wait) = decide("click", not_set_up(), caller(), Some(json!({"agent_session": "s1"})), Some(Duration::from_secs(90)))
        else {
            panic!("a missing grant must wait for the card");
        };
        assert_eq!(wait.params["kind"], "computer_use");
        assert_eq!(wait.params["timeout_seconds"], 90);
        assert_eq!(wait.params["caller"], json!({"agent_session": "s1"}));
        assert!(wait.run().is_none(), "granted runs the call");
    }

    #[test]
    fn phases_the_card_cannot_fix_answer_at_once() {
        for (phase, expected) in [
            ("disabled_by_policy", "computer_use.disabled"),
            ("unavailable", "computer_use.unavailable"),
            ("version_mismatch", "computer_use.version_mismatch"),
        ] {
            let status = Ok(json!({"phase": phase, "accessibility": null, "screen_recording": null}));
            assert_eq!(code(decide("click", status, caller(), None, None)).as_deref(), Some(expected), "{phase}");
        }
    }
}
