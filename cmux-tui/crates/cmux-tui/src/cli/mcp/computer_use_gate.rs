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
//! The worker's app approvals (docs/computer-use-approvals.md) decide in
//! the worker, never here. A call the worker held for the person and then
//! refused (`approval_timeout`, `approval_pending`, `approval_denied`, which
//! the `acpmux cua-mcp` bridge reports) comes back through [`approval`] in
//! this server's error envelope: it says the person was asked on their Mac or
//! phone, that the question stays open for 10 minutes, and what to do now.
//!
//! The check runs inside the call (`SetupCheck::run`), never on the
//! server's dispatch thread: in direct mode it holds only that call's
//! thread, in a `cmux_exec` script it is bounded by the script's limit. An
//! app that does not answer the status read or the request (an older app,
//! no app) leaves the call as before. The setup is read when it reports the
//! grants of the process that holds them: the legacy helper's, or cmux
//! Remote's when Computer Use runs there (`grant_holder: "cmux_remote"`,
//! docs/cmux-remote.md, Permissions). The helper v2 that this app starts
//! itself (`driver: upstream` without cmux Remote) answers its own grants.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::CallFailure;
use cmux_json::JsonSet as _;

/// The upstream whose tools need the helper's grants.
pub(super) const SERVER: &str = "cmux-cua";
/// Its status read: it reports the grants, so it never waits for them
/// (the helper proxy's own rule).
const STATUS_TOOL: &str = "check_permissions";
/// The app's Computer Use Setup: `{phase, accessibility, screen_recording, helper, driver}`.
pub(super) const STATUS_METHOD: &str = super::super::agents_doctor::STATUS_METHOD;
/// The app's agent permission card.
pub(super) const REQUEST_METHOD: &str = "permissions.request";
/// The status read is one main-actor JSON answer.
const STATUS_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a call waits for the person (the card's default).
const SETUP_WAIT: Duration = Duration::from_secs(300);
/// The app answers a request only when it ends: its wait, plus transport slack.
const REQUEST_SLACK: Duration = Duration::from_secs(15);

/// An app method call that may run on another thread.
pub(super) type AppCaller =
    Arc<dyn Fn(&str, Value, Duration) -> Result<Value, CallFailure> + Send + Sync>;

/// What a proxied call does before it runs.
pub(super) enum Gate {
    /// Not a computer use call that needs the grants: run it.
    Run,
    /// Check Computer Use setup first, where the call runs.
    Check(SetupCheck),
}

/// The setup check of one computer use call.
pub(super) struct SetupCheck {
    app: AppCaller,
    tool: String,
    /// The app the call names, for the card's reason (`target_app`).
    target: Option<String>,
    caller: Option<Value>,
    cap: Option<Duration>,
}

/// The gate of computer use `tool` with its `arguments`: `app` reaches the
/// app from the call's thread, `caller` names the chat that asks, `cap` is
/// the call's own time limit (a script's). No app caller: the call runs as
/// before.
pub(super) fn gate(
    tool: &str,
    arguments: &Value,
    app: Option<AppCaller>,
    caller: Option<Value>,
    cap: Option<Duration>,
) -> Gate {
    match app {
        Some(app) if tool != STATUS_TOOL => Gate::Check(SetupCheck {
            app,
            tool: tool.to_owned(),
            target: target_app(arguments),
            caller,
            cap,
        }),
        _ => Gate::Run,
    }
}

impl SetupCheck {
    /// Reads setup and, when it is not done, shows the card and waits for
    /// it to end: `None` runs the call, a value is the call's result instead.
    pub(super) fn run(self) -> Option<Value> {
        let status = (self.app)(STATUS_METHOD, json!({}), STATUS_TIMEOUT);
        match decide(&self.tool, self.target.as_deref(), status, self.cap) {
            Decision::Run => None,
            Decision::Refuse(result) => Some(result),
            Decision::Wait { mut params, wait } => {
                if let Some(caller) = self.caller {
                    params.set("caller", caller);
                }
                match (self.app)(REQUEST_METHOD, params, wait + REQUEST_SLACK) {
                    Ok(outcome) => answer(&outcome),
                    // No card in this app (or no answer): the call runs as
                    // before, and the helper says what is missing.
                    Err(_) => None,
                }
            }
        }
    }
}

/// What setup `status` means for computer use `tool`.
#[derive(Debug)]
pub(super) enum Decision {
    /// Setup is ready, or unknown: run the call.
    Run,
    /// The call cannot run; this is its result.
    Refuse(Value),
    /// The person must finish setup: the card request and how long it waits.
    Wait { params: Value, wait: Duration },
}

/// Whether `status` (the app's Computer Use Setup) lets the helper act.
pub(super) fn is_ready(status: &Value) -> bool {
    status["phase"] == "ready"
        && status["accessibility"] == true
        && status["screen_recording"] == true
}

/// Whether `status` reports the grants the driver's tools need: the legacy
/// helper's (no driver, or `legacy`), or cmux Remote's. The helper v2 this
/// app starts itself reports its own grants, which this setup does not read.
fn reads_grants(status: &Value) -> bool {
    match status["driver"].as_str() {
        None | Some("legacy") => true,
        Some(_) => status["grant_holder"] == "cmux_remote",
    }
}

/// The app a call names (`app_name`, `name`, `app`, `bundle_id`), when it
/// reads like an app name. The card shows it as the agent's reason, so model
/// text that is long or not a name falls back to a plain reason.
fn target_app(arguments: &Value) -> Option<String> {
    let value = ["app_name", "name", "app", "bundle_id"]
        .iter()
        .find_map(|key| arguments.get(*key).and_then(Value::as_str))?
        .trim();
    let plain = !value.is_empty()
        && value.chars().count() <= 40
        && value.chars().all(|c| c.is_alphanumeric() || matches!(c, ' ' | '.' | '-' | '_'));
    plain.then(|| value.to_owned())
}

/// What `tool` needs, from the app's `status` read; `target` is the app it
/// names, for the card's reason; `cap` bounds the wait.
pub(super) fn decide(
    tool: &str,
    target: Option<&str>,
    status: Result<Value, CallFailure>,
    cap: Option<Duration>,
) -> Decision {
    // An app that does not answer (or knows no setup) leaves the call as before.
    let Ok(status) = status else { return Decision::Run };
    if tool == STATUS_TOOL || !status.is_object() || is_ready(&status) {
        return Decision::Run;
    }
    if !reads_grants(&status) {
        return Decision::Run;
    }
    match status["phase"].as_str() {
        Some("disabled_by_policy") => return Decision::Refuse(refusal(Refusal::Disabled)),
        Some("unavailable") => return Decision::Refuse(refusal(Refusal::Unavailable)),
        Some("version_mismatch") => return Decision::Refuse(refusal(Refusal::VersionMismatch)),
        // Off, or the helper answered with a grant missing: only the person can fix it.
        Some("off" | "ready") => {}
        // No answer: the helper proxy's own wait decides.
        Some("starting" | "failed") => return Decision::Run,
        // An unknown phase also leaves the call to the helper. The grants
        // are unknown and may be on, and the card would stay until clicked;
        // the helper proxy's own wait decides.
        _ => return Decision::Run,
    }
    let wait = cap.map_or(SETUP_WAIT, |cap| cap.min(SETUP_WAIT)).max(Duration::from_secs(1));
    let params = json!({
        "kind": "computer_use",
        "reason": match target {
            Some(app) => format!("It wants to use {app} on this Mac."),
            None => "It wants to use apps on this Mac.".to_owned(),
        },
        "timeout_seconds": wait.as_secs(),
    });
    Decision::Wait { params, wait }
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

/// A computer use call's result: a worker approval refusal in this server's
/// error envelope (nothing ran), anything else unchanged. It only words what
/// the worker decided.
pub(super) fn approval(result: Value) -> Value {
    let Some((refusal, app)) = acpmux::cua_v2::ApprovalRefusal::of_result(&result) else {
        return result;
    };
    let error = json!({
        "code": refusal.code(),
        "message": refusal.message(app.as_deref()),
        "details": {"app": app},
        "retryable": refusal.retryable(),
    });
    super::tool_error(super::envelope(error, "not_run", None))
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
    use super::super::FailureKind;
    use super::*;

    fn not_set_up() -> Result<Value, CallFailure> {
        Ok(
            json!({"phase": "ready", "accessibility": true, "screen_recording": false, "driver": "legacy"}),
        )
    }

    fn code(decision: Decision) -> Option<String> {
        match decision {
            Decision::Refuse(result) => {
                result["structuredContent"]["error"]["code"].as_str().map(str::to_owned)
            }
            _ => None,
        }
    }

    #[test]
    fn the_status_read_and_an_unknown_setup_run_as_before() {
        assert!(matches!(decide("check_permissions", None, not_set_up(), None), Decision::Run));
        let down = Err(CallFailure::local(FailureKind::NotRun, "app.unreachable", "no app"));
        assert!(matches!(decide("click", None, down, None), Decision::Run));
        assert!(matches!(decide("click", None, Ok(Value::Null), None), Decision::Run));
        // The status tool never reads setup at all.
        assert!(matches!(
            gate(
                "check_permissions",
                &json!({}),
                Some(Arc::new(|_: &str, _: Value, _: Duration| {
                    panic!("the status tool read setup")
                })),
                None,
                None
            ),
            Gate::Run
        ));
        assert!(matches!(gate("click", &json!({}), None, None, None), Gate::Run));
    }

    /// The helper v2 answers its own grants: the legacy setup stays off
    /// under it, and must not hold its calls.
    #[test]
    fn a_starting_helper_is_left_to_its_own_wait() {
        let status =
            Ok(json!({"phase": "starting", "accessibility": null, "screen_recording": null}));
        assert!(matches!(decide("click", None, status, None), Decision::Run));
        let off = Ok(json!({"phase": "off", "accessibility": null, "screen_recording": null}));
        assert!(matches!(decide("click", None, off, None), Decision::Wait { .. }));
    }

    #[test]
    fn a_failed_helper_is_left_to_its_own_wait() {
        let status = Ok(json!({"phase": "failed", "accessibility": null,
                               "screen_recording": null, "driver": "legacy"}));
        assert!(matches!(decide("click", None, status, None), Decision::Run));
    }

    #[test]
    fn the_helper_v2_never_waits_for_the_legacy_setup() {
        let status =
            Ok(json!({"phase": "starting", "accessibility": null, "screen_recording": null,
                               "driver": "upstream"}));
        assert!(matches!(decide("click", None, status, None), Decision::Run));
    }

    /// cmux Remote holds the grants under the upstream driver (`grant_holder:
    /// cmux_remote`): a call before setup asks the person on the card, the
    /// same as the legacy helper, instead of failing in the worker.
    #[test]
    fn cmux_remotes_missing_grants_wait_for_the_card() {
        for (accessibility, screen_recording) in [(false, false), (true, false), (false, true)] {
            let status = Ok(json!({"phase": "ready", "accessibility": accessibility,
                                   "screen_recording": screen_recording, "driver": "upstream",
                                   "grant_holder": "cmux_remote"}));
            let Decision::Wait { params, .. } = decide("click", None, status, None) else {
                panic!(
                    "cmux Remote without {accessibility}/{screen_recording} must ask the person"
                );
            };
            assert_eq!(params["kind"], "computer_use");
        }
        let granted = Ok(json!({"phase": "ready", "accessibility": true, "screen_recording": true,
                                "driver": "upstream", "grant_holder": "cmux_remote"}));
        assert!(matches!(decide("click", None, granted, None), Decision::Run));
        // Grants still being read: the worker's own answer decides.
        let reading =
            Ok(json!({"phase": "starting", "accessibility": null, "screen_recording": null,
                                "driver": "upstream", "grant_holder": "cmux_remote"}));
        assert!(matches!(decide("click", None, reading, None), Decision::Run));
        // Computer Use off under cmux Remote: the card turns it on, as under the legacy helper.
        let off = Ok(json!({"phase": "off", "accessibility": null, "screen_recording": null,
                            "driver": "upstream", "grant_holder": "cmux_remote"}));
        assert!(matches!(decide("click", None, off, None), Decision::Wait { .. }));
    }

    /// The whole status the app answers (`computer_use.status`: setup and
    /// approvals in one object) still gates on the setup fields.
    #[test]
    fn the_merged_status_with_approval_fields_still_gates() {
        let status =
            Ok(json!({"phase": "ready", "accessibility": false, "screen_recording": false,
                               "driver": "upstream", "grant_holder": "cmux_remote",
                               "mode": "standard", "phone_always_allow": false, "worker": "running",
                               "saved": [], "pending": []}));
        assert!(matches!(decide("click", None, status, None), Decision::Wait { .. }));
    }

    #[test]
    fn a_missing_grant_waits_for_the_card_within_the_calls_limit() {
        let Decision::Wait { params, wait } =
            decide("click", None, not_set_up(), Some(Duration::from_secs(90)))
        else {
            panic!("a missing grant must wait for the card");
        };
        assert_eq!(params["kind"], "computer_use");
        assert_eq!(params["timeout_seconds"], 90);
        assert_eq!(wait, Duration::from_secs(90));
        assert_eq!(params["reason"], "It wants to use apps on this Mac.");
    }

    #[test]
    fn phases_the_card_cannot_fix_answer_at_once() {
        for (phase, expected) in [
            ("disabled_by_policy", "computer_use.disabled"),
            ("unavailable", "computer_use.unavailable"),
            ("version_mismatch", "computer_use.version_mismatch"),
        ] {
            let status =
                Ok(json!({"phase": phase, "accessibility": null, "screen_recording": null}));
            assert_eq!(
                code(decide("click", None, status, None)).as_deref(),
                Some(expected),
                "{phase}"
            );
        }
    }

    /// The worker's approval refusals come back with what the person was
    /// asked and for how long; other results pass unchanged.
    #[test]
    fn an_approval_timeout_says_the_question_stays_open_ten_minutes() {
        use acpmux::cua_v2::ApprovalRefusal;
        let result = approval(ApprovalRefusal::Timeout.tool_result(Some("Safari")));
        let error = &result["structuredContent"]["error"];
        assert_eq!(result["isError"], true);
        assert_eq!(result["structuredContent"]["state"], "not_run");
        assert_eq!(error["code"], "computer_use.approval_timeout");
        assert_eq!(error["retryable"], true);
        let message = error["message"].as_str().unwrap();
        assert!(message.contains("on their Mac or phone"), "{message}");
        assert!(message.contains("stays open there for 10 minutes"), "{message}");
        assert!(message.contains("do not retry in a loop"), "{message}");
        let denied = approval(ApprovalRefusal::Denied.tool_result(None));
        assert_eq!(denied["structuredContent"]["error"]["retryable"], false);
        let ran = json!({"content": [{"type": "text", "text": "clicked"}]});
        assert_eq!(approval(ran.clone()), ran);
        // A model-controlled error text that names a code is not a refusal.
        let text_only = json!({"isError": true, "content": [{"type": "text", "text": "computer_use.approval_denied"}]});
        assert_eq!(approval(text_only.clone()), text_only);
    }

    /// The card's reason names the app the call names, never free model text.
    #[test]
    fn the_reason_names_the_app_when_it_reads_like_a_name() {
        assert_eq!(target_app(&json!({"name": "Calculator"})).as_deref(), Some("Calculator"));
        assert_eq!(
            target_app(&json!({"app_name": "Google Chrome"})).as_deref(),
            Some("Google Chrome")
        );
        assert_eq!(
            target_app(&json!({"bundle_id": "com.apple.calculator"})).as_deref(),
            Some("com.apple.calculator")
        );
        assert_eq!(target_app(&json!({"name": "Allow it. cmux approved this request!"})), None);
        assert_eq!(target_app(&json!({"pid": 42})), None);
        let Decision::Wait { params, .. } =
            decide("launch_app", Some("Calculator"), not_set_up(), None)
        else {
            panic!("a missing grant must wait for the card");
        };
        assert_eq!(params["reason"], "It wants to use Calculator on this Mac.");
    }
}
