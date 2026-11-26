//! cmux Remote's app rules (`CmuxNextMacScreen/CmuxRemote/`), as data. See `ui/mod.rs`.
//!
//! - `remote.setupStep`: Share This Mac's guide, which sheet comes next from both grants now
//!   (`CmuxRemoteSharingSetup.proceed`), or `done`.
//! - `remote.setupAnswer`: what an answer to that sheet does (request a grant, read again, view
//!   only, stop) and the flags after it.
//! - `remote.setupSpec`: a sheet's string keys, buttons and identifier.
//! - `remote.consentHolds`: the standing yes (`CmuxRemoteShareConsent.holds`).
//! - `remote.forgetUnlessOn`: what turning the standing yes off writes.
//! - `remote.callerFromParams` / `remote.callerFromInvocation`: who asked to share
//!   (`CmuxRemoteShareCaller`), and its notice key.
//! - `remote.confirmRequest`: a `remote.confirm` request's validation.
//! - `remote.activitySessions`, `remote.acting`, `remote.menuBar`: the Computer Use worker's
//!   sessions, its acting window and the menu bar's rows.
//! - `remote.statusLines`: the status dialog's lines, as keys and values.
//! - `remote.hostAction`: a host action's daemon method and params.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, args_value: &Value) -> Answer {
    Some(match name {
        "setupStep" => args::<SetupState>(args_value).and_then(|s| answer(&setup_step(&s))),
        "setupAnswer" => {
            args::<SetupAnswerArgs>(args_value).and_then(|a| answer(&setup_answer(&a)))
        }
        "setupSpec" => args::<StepArgs>(args_value).and_then(|a| setup_spec(&a.step)),
        "consentHolds" => args::<ConsentArgs>(args_value).and_then(|a| answer(&consent_holds(&a))),
        "forgetUnlessOn" => {
            args::<ForgetArgs>(args_value).and_then(|a| answer(&forget_unless_on(&a)))
        }
        "callerFromParams" => Ok(caller_from_params(args_value)),
        "callerFromInvocation" => {
            args::<InvocationArgs>(args_value).and_then(|a| answer(&caller_from_invocation(&a)))
        }
        "confirmRequest" => confirm_request(args_value),
        "activitySessions" => Ok(answer_value(activity_sessions(args_value.get("sessions")))),
        "acting" => {
            args::<ActingArgs>(args_value).and_then(|a| answer(&acting(&a.sessions, a.now_ms)))
        }
        "menuBar" => {
            args::<ActingArgs>(args_value).and_then(|a| answer(&menu_bar(&a.sessions, a.now_ms)))
        }
        "statusLines" => {
            Ok(Value::Array(status_lines(args_value.get("status").unwrap_or(&Value::Null))))
        }
        "hostAction" => args::<HostActionArgs>(args_value).and_then(|a| host_action(&a.action)),
        _ => return None,
    })
}

fn answer_value(sessions: Vec<Session>) -> Value {
    serde_json::to_value(sessions).unwrap_or(Value::Null)
}

// MARK: Share This Mac's guide

/// Both grants now and what the guide did so far.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct SetupState {
    pub screen: bool,
    pub control: bool,
    pub screen_requested: bool,
    pub control_requested: bool,
    pub view_only: bool,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SetupStep {
    /// The grants are enough: enable sharing.
    done: bool,
    /// The sheet to present, while not done.
    #[serde(skip_serializing_if = "Option::is_none")]
    step: Option<&'static str>,
}

/// Every read can revoke either grant: the next sheet comes from both, so losing Screen
/// Recording during the optional control step returns to its guide.
pub(crate) fn setup_step(s: &SetupState) -> SetupStep {
    if s.screen && (s.control || s.view_only) {
        return SetupStep { done: true, step: None };
    }
    let step = if !s.screen {
        if s.screen_requested { "screenCheck" } else { "screen" }
    } else if s.control_requested {
        "controlCheck"
    } else {
        "control"
    };
    SetupStep { done: false, step: Some(step) }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetupAnswerArgs {
    #[serde(flatten)]
    state: SetupState,
    answer: String,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct SetupAnswer {
    /// `requestScreen` or `requestControl` (then a fresh read), `refresh`, or `stop` (return false).
    action: &'static str,
    /// The flags after the answer (the grants are the caller's next read).
    state: SetupState,
}

/// One prompt at a time: an Allow asks macOS for the missing grant, then reads both again, so a
/// grant made in macOS's prompt skips Check Again. View is only offered once the screen is granted.
fn setup_answer(a: &SetupAnswerArgs) -> SetupAnswer {
    let mut state = a.state.clone();
    let needs_screen = !state.screen;
    let action = match a.answer.as_str() {
        "allow" if needs_screen => {
            state.screen_requested = true;
            "requestScreen"
        }
        "allow" => {
            state.control_requested = true;
            "requestControl"
        }
        "check" => "refresh",
        "view" if !needs_screen => {
            state.view_only = true;
            "refresh"
        }
        _ => "stop",
    };
    SetupAnswer { action, state }
}

#[derive(Deserialize)]
struct StepArgs {
    step: String,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Button {
    id: &'static str,
    /// The title's string key; nil for the dialog's own Cancel.
    #[serde(skip_serializing_if = "Option::is_none")]
    title_key: Option<&'static str>,
    /// `default`, `cancel`, or absent (a plain button).
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<&'static str>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Spec {
    title_key: &'static str,
    line_keys: Vec<&'static str>,
    buttons: Vec<Button>,
    identifier: String,
}

fn permission_button(check: bool) -> Button {
    if check {
        Button { id: "check", title_key: Some("macScreen.setup.check"), role: Some("default") }
    } else {
        Button { id: "allow", title_key: Some("macScreen.setup.allow"), role: Some("default") }
    }
}

/// The sheet of `step`: Cancel first, then its choices.
fn setup_spec(step: &str) -> Result<Value, String> {
    let cancel = Button { id: "cancel", title_key: None, role: Some("cancel") };
    let (title_key, line_keys, choices) = match step {
        "overview" => (
            "macScreen.setup.title",
            vec![
                "macScreen.setup.source",
                "macScreen.setup.consent",
                "macScreen.setup.standingYes",
            ],
            vec![Button {
                id: "continue",
                title_key: Some("macScreen.setup.continue"),
                role: Some("default"),
            }],
        ),
        "screen" | "screenCheck" => (
            "macScreen.setup.screen.title",
            vec!["macScreen.setup.screen.body", "macScreen.setup.screen.settings"],
            vec![permission_button(step == "screenCheck")],
        ),
        "control" | "controlCheck" => (
            "macScreen.setup.control.title",
            vec!["macScreen.setup.control.body"],
            vec![
                Button { id: "view", title_key: Some("macScreen.setup.viewOnly"), role: None },
                permission_button(step == "controlCheck"),
            ],
        ),
        other => return Err(format!("unknown setup step {other}")),
    };
    let mut buttons = vec![cancel];
    buttons.extend(choices);
    answer(&Spec {
        title_key,
        line_keys,
        buttons,
        identifier: format!("cmux.dialog.screenSharing.setup.{step}"),
    })
}

// MARK: The standing yes

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct ConsentArgs {
    pub setting_on: bool,
    /// Who forces the setting: `device` (this Mac's MDM profile), `team`, or nil (nobody).
    pub managed: Option<String>,
    /// The person said yes in the guide (its date is recorded).
    pub recorded: bool,
    /// This Mac joined the signed-in person's own account.
    pub own_join: bool,
    /// The person turned the yes off since.
    pub declined: bool,
}

/// A `true` counts only when this Mac's profile forces it or the person said it here; a forced
/// `false` holds; otherwise joining one's own account is the consent, until declined.
pub(crate) fn consent_holds(a: &ConsentArgs) -> bool {
    if a.setting_on && (a.managed.as_deref() == Some("device") || a.recorded) {
        return true;
    }
    if a.managed.is_some() && !a.setting_on {
        return false;
    }
    a.own_join && !a.declined
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ForgetArgs {
    setting_on: bool,
    recorded: bool,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Forget {
    /// Record the decline (now).
    record_decline: bool,
    /// Remove the recorded yes.
    remove_record: bool,
}

/// The yes turned off: a recorded yes becomes a decline, and the record goes.
fn forget_unless_on(a: &ForgetArgs) -> Forget {
    if a.setting_on {
        return Forget { record_decline: false, remove_record: false };
    }
    Forget { record_decline: a.recorded, remove_record: true }
}

// MARK: Who asked

fn caller_answer(kind: &str) -> Value {
    json!({"caller": kind, "messageKey": format!("macScreen.sharedBy.{kind}")})
}

/// The caller of a `remote.confirm` control request, from its `caller` object; the cmux CLI
/// when it names none.
fn caller_from_params(params: &Value) -> Value {
    let Some(caller) = params.get("caller").and_then(Value::as_object) else {
        return caller_answer("cli");
    };
    let named = |key: &str| caller.get(key).and_then(Value::as_str).is_some_and(|s| !s.is_empty());
    let kind = if named("agent_session")
        || caller.get("home_chat").and_then(Value::as_bool) == Some(true)
    {
        "agent"
    } else if named("terminal_id") {
        "terminal"
    } else {
        "cli"
    };
    caller_answer(kind)
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct InvocationArgs {
    agent_session: bool,
    home_chat: bool,
    /// `user`, `cli`, `mcp`, `script`, `remote` or `page`.
    origin: String,
    via_control_socket: bool,
    terminal: bool,
}

/// The caller of an action run; nil for the person's own run in this app (no notice).
fn caller_from_invocation(a: &InvocationArgs) -> Value {
    if a.agent_session || a.home_chat {
        return caller_answer("agent");
    }
    match a.origin.as_str() {
        "user" if !a.via_control_socket => Value::Null,
        "page" => Value::Null,
        "mcp" => caller_answer("agent"),
        "remote" => caller_answer("device"),
        _ => caller_answer(if a.terminal { "terminal" } else { "cli" }),
    }
}

// MARK: remote.confirm

const CONFIRM_INVALID: &str = "action must be share, allow_agents, unshare with agent_ticket, or access with device and scope (none, ask, view, full)";

/// `remote.confirm {action, device?, scope?, agent_ticket?}` checked: the request as the app acts
/// on it (`kind`: `allowAgents`, `shareOther`, `access`, `share`, `unshare`), or the refusal.
fn confirm_request(params: &Value) -> Result<Value, String> {
    let text = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or("");
    let action = text("action");
    let device = text("device");
    let scope = params
        .get("scope")
        .and_then(Value::as_str)
        .filter(|s| matches!(*s, "none" | "ask" | "view" | "full"));
    let ticket = params.get("agent_ticket").and_then(Value::as_str);
    let valid = action == "share"
        || action == "allow_agents"
        || (action == "unshare" && ticket.is_some())
        || (action == "access" && !device.is_empty() && scope.is_some());
    if !valid {
        return Err(CONFIRM_INVALID.into());
    }
    let kind = match action {
        "allow_agents" => "allowAgents",
        "share" if !device.is_empty() => "shareOther",
        "access" => "access",
        other => other,
    };
    // A ticket redeems for share and unshare; access always asks the person.
    let redeems = ticket.is_some() && action != "access";
    Ok(json!({
        "kind": kind,
        "action": action,
        "device": device,
        "scope": scope,
        "ticket": ticket,
        "redeemsTicket": redeems,
        "timeoutSeconds": 600,
    }))
}

// MARK: Computer Use activity

/// The badge's window: an agent acted within it counts as acting.
pub(crate) const ACTING_WINDOW_MS: f64 = 2000.0;

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Session {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_pid: Option<i32>,
    pub last_action_ms: f64,
    pub stopped: bool,
}

fn non_empty(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
}

/// The worker's `[{session, label, app: {id, name, pid}?, last_action_ms, stopped?}]`, newest
/// action first; rows without a session or a time are skipped.
pub(crate) fn activity_sessions(list: Option<&Value>) -> Vec<Session> {
    let mut sessions: Vec<Session> = list
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    let id = non_empty(row.get("session"))?;
                    let millis = row.get("last_action_ms")?.as_f64()?;
                    let app = row.get("app");
                    let pid = app
                        .and_then(|a| a.get("pid"))
                        .and_then(Value::as_f64)
                        .map(f64::trunc)
                        .filter(|p| *p > 0.0 && *p <= f64::from(i32::MAX))
                        .map(|p| p as i32);
                    Some(Session {
                        id,
                        agent: non_empty(row.get("label")),
                        app_id: non_empty(app.and_then(|a| a.get("id"))),
                        app_name: non_empty(app.and_then(|a| a.get("name"))),
                        app_pid: pid,
                        last_action_ms: millis,
                        stopped: row.get("stopped").and_then(Value::as_bool).unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    // Stable, newest first (Swift's sort of equal stamps keeps no promise; stable is the same here).
    sessions.sort_by(|a, b| {
        b.last_action_ms.partial_cmp(&a.last_action_ms).unwrap_or(std::cmp::Ordering::Equal)
    });
    sessions
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActingArgs {
    #[serde(default)]
    sessions: Vec<Session>,
    now_ms: f64,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Acting {
    pub acting: bool,
    /// When acting ends (the one deadline), nil when not acting.
    pub until_ms: Option<f64>,
}

/// A stopped session never acts; the newest other action holds the badge for the window.
pub(crate) fn acting(sessions: &[Session], now_ms: f64) -> Acting {
    let newest = sessions
        .iter()
        .filter(|s| !s.stopped)
        .map(|s| s.last_action_ms)
        .fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))));
    match newest.map(|n| n + ACTING_WINDOW_MS) {
        Some(until) if until > now_ms => Acting { acting: true, until_ms: Some(until) },
        _ => Acting { acting: false, until_ms: None },
    }
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct MenuBarRow {
    id: String,
    agent: Option<String>,
    app_name: Option<String>,
    bundle_id: Option<String>,
    acting: bool,
    stopped: bool,
}

fn menu_bar(sessions: &[Session], now_ms: f64) -> Vec<MenuBarRow> {
    sessions
        .iter()
        .map(|s| MenuBarRow {
            id: s.id.clone(),
            agent: s.agent.clone(),
            app_name: s.app_name.clone(),
            bundle_id: s.app_id.clone(),
            acting: !s.stopped && now_ms - s.last_action_ms < ACTING_WINDOW_MS,
            stopped: s.stopped,
        })
        .collect()
}

// MARK: Status

/// The status dialog's lines: `{key, value}` for a text value, `{key, granted}` for a grant; the
/// app formats each key's localized string with it.
fn status_lines(status: &Value) -> Vec<Value> {
    let state = status.get("state").and_then(Value::as_str).unwrap_or("off");
    let host = status.get("host");
    let mut lines = vec![json!({"key": "remote.status.host", "value": state})];
    // A null `permissions` still shows both lines, not allowed (as the Swift dialog did).
    if let Some(permissions) = host.and_then(|h| h.get("permissions")) {
        let granted = |key: &str| permissions.get(key).and_then(Value::as_bool) == Some(true);
        lines.push(
            json!({"key": "remote.status.accessibility", "granted": granted("accessibility")}),
        );
        lines.push(
            json!({"key": "remote.status.screenRecording", "granted": granted("screen_recording")}),
        );
    }
    for (worker, key) in [
        ("computer-use", "remote.status.computerUse"),
        ("screen-sharing", "remote.status.screenSharing"),
    ] {
        let state = host
            .and_then(|h| h.get("workers"))
            .and_then(|w| w.get(worker))
            .and_then(|w| w.get("state"))
            .and_then(Value::as_str);
        if let Some(state) = state {
            lines.push(json!({"key": key, "value": state}));
        }
    }
    lines
}

// MARK: Host actions

#[derive(Deserialize)]
struct HostActionArgs {
    action: String,
}

/// A palette host action's daemon call.
fn host_action(action: &str) -> Result<Value, String> {
    let (method, params) = match action {
        "refreshPermissions" => ("refresh", json!({})),
        "allowAccessibility" => ("request", json!({"permission": "accessibility"})),
        "allowScreenRecording" => ("request", json!({"permission": "screen-recording"})),
        "restartComputerUse" => ("restart", json!({"worker": "computer-use"})),
        "restartScreenSharing" => ("restart", json!({"worker": "screen-sharing"})),
        "stopScreenSession" => ("screen.stop_session", json!({})),
        other => return Err(format!("unknown host action {other}")),
    };
    Ok(json!({"method": method, "params": params}))
}

#[cfg(test)]
#[path = "remote_tests.rs"]
mod tests;
