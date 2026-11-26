//! `cmux computer-use doctor`: whether capture and input would work on a
//! machine now, and for each thing that would stop them the one step that
//! fixes it. Read-only: it reads the daemon's endpoint state, the engine's
//! `status` (preflight-only grant reads, never an OS prompt) and
//! `list_displays` (geometry, no grant), so it needs no app window and asks
//! nobody anything. Exit 0 only when every check passes.

use acpmux::computer_use::client::{DaemonError, ENDPOINT_CMD, Outcome, new_call_id};
use serde_json::{Value, json};

use super::{GlobalArgs, caller, legacy, with_machine};
use crate::cli::OutputMode;

/// The staging roots' path segments: `cmux_signed_bundle::helper_folder`'s
/// `~/Library/Application Support/cmux-next/helper/<bundle id>/`, which every stager uses now, and
/// the older `~/Library/Application Support/cmux-next/screen-sharing/<bundle id>/computer-use/`.
const STAGED_SEGMENTS: [&str; 2] = ["/cmux-next/helper/", "/cmux-next/screen-sharing/"];
/// The macOS helper's executable (the verified copy runs from the staging root).
const MAC_HELPER_EXE: &str = "cmux-screen-sharing";

/// What the daemon's endpoint said, or why it could not be asked.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Endpoint {
    /// Not asked (`--machine`: the call goes over the machine link instead).
    Skipped,
    /// `{"state": ready|starting|off|unavailable, "reason", "pid"}`.
    State(Value),
    /// The local daemon did not answer.
    Unreachable(String),
    /// The daemon answered with an error.
    Refused(String),
}

/// One tool call's result, reduced to what the doctor reads.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Reply {
    Ok(Value),
    /// Computer Use is off (the reason the worker gave).
    Off(String),
    Failed {
        code: String,
        message: String,
    },
}

impl From<Outcome> for Reply {
    fn from(outcome: Outcome) -> Self {
        match outcome {
            Outcome::Output(out) if !out.is_error => Reply::Ok(out.body),
            Outcome::Output(out) => Reply::Failed {
                code: out.code.unwrap_or_else(|| "refused".into()),
                message: out
                    .body
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("refused")
                    .to_owned(),
            },
            Outcome::Off(reason) => Reply::Off(reason),
            Outcome::Failed { code, message } => Reply::Failed { code, message },
        }
    }
}

/// One line of the report. `fix` is set exactly when the check failed.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
    pub fix: Option<String>,
}

fn pass(name: &'static str, detail: impl Into<String>) -> Check {
    Check { name, ok: true, detail: detail.into(), fix: None }
}

fn fail(name: &'static str, detail: impl Into<String>, fix: impl Into<String>) -> Check {
    Check { name, ok: false, detail: detail.into(), fix: Some(fix.into()) }
}

/// The checks, from what was read. Pure, so the tests drive every branch.
pub(super) fn evaluate(
    machine: Option<&str>,
    endpoint: &Endpoint,
    status: &Reply,
    displays: &Reply,
) -> Vec<Check> {
    let mut checks = Vec::new();
    let here = machine.map_or("this machine".to_owned(), |m| format!("machine {m:?}"));

    // 1. The daemon and the worker endpoint.
    match endpoint {
        Endpoint::Skipped => {}
        Endpoint::Unreachable(message) => checks.push(fail(
            "daemon",
            format!("the cmux daemon did not answer: {message}"),
            "Start cmux (open the app, or run `cmux` once), then run the doctor again.",
        )),
        Endpoint::Refused(message) => checks.push(fail(
            "daemon",
            format!("the daemon refused the Computer Use endpoint: {message}"),
            "Run `cmux computer-use status` to see what this daemon serves; its build has no Computer Use endpoint.",
        )),
        Endpoint::State(state) => {
            checks.push(pass("daemon", "the cmux daemon answered"));
            let s = state.get("state").and_then(Value::as_str).unwrap_or("unknown");
            let reason = state.get("reason").and_then(Value::as_str).unwrap_or("");
            checks.push(match s {
                "ready" => pass("worker", "the Computer Use worker is up"),
                "starting" => fail(
                    "worker",
                    "the worker is starting",
                    "Wait a few seconds and run the doctor again.",
                ),
                "off" => fail(
                    "worker",
                    "Computer Use is off",
                    "Turn it on in Settings > Computer Use (or `cmux settings set computerUse.mode fullAccess` from the person's own shell).",
                ),
                _ => fail(
                    "worker",
                    format!("the worker is {s}{}", if reason.is_empty() { String::new() } else { format!(": {reason}") }),
                    if reason.is_empty() { "Restart cmux.".to_owned() } else { reason.to_owned() },
                ),
            });
        }
    }

    // 2. The engine's own status.
    let body = match status {
        Reply::Ok(body) if body.get("mode").and_then(Value::as_str) != Some("off") => body,
        Reply::Ok(body) => {
            let reason = body.get("reason").and_then(Value::as_str).unwrap_or("");
            checks.push(fail(
                "mode",
                format!("Computer Use is off on {here}{}", suffix(reason)),
                "Turn it on in Settings > Computer Use on that machine.",
            ));
            return checks;
        }
        Reply::Off(reason) => {
            checks.push(fail(
                "mode",
                format!("Computer Use is off on {here}{}", suffix(reason)),
                "Turn it on in Settings > Computer Use on that machine.",
            ));
            return checks;
        }
        Reply::Failed { code, message } => {
            checks.push(fail(
                "status",
                format!("status failed ({code}): {message}"),
                match code.as_str() {
                    "computer_use_unavailable" => message.clone(),
                    _ if machine.is_some() => {
                        "Check the machine link with `cmux computer-use machines`.".to_owned()
                    }
                    _ => "Restart cmux.".to_owned(),
                },
            ));
            return checks;
        }
    };

    // The helper: on macOS the worker must be the staged, verified copy.
    checks.push(helper(body));

    // OS grants, preflight reads only.
    let grants = body.get("permissions").cloned().unwrap_or(Value::Null);
    for (key, label, fix) in [
        (
            "screen_capture",
            "Screen Recording",
            "Allow cmux in System Settings > Privacy & Security > Screen & System Audio Recording (or run `cmux computer-use call request_permission --args '{\"permission\":\"screen_capture\"}'` from the person's session).",
        ),
        (
            "accessibility",
            "Accessibility",
            "Allow cmux in System Settings > Privacy & Security > Accessibility (or run `cmux computer-use call request_permission --args '{\"permission\":\"accessibility\"}'`). On Linux, start the AT-SPI bus (at-spi-bus-launcher).",
        ),
        (
            "input",
            "input events",
            "Allow cmux to post input: System Settings > Privacy & Security > Accessibility on macOS; on Linux a session with XTEST or a wlroots virtual-input compositor.",
        ),
    ] {
        let g = grants.get(key).and_then(Value::as_str).unwrap_or("unknown");
        checks.push(match g {
            "granted" | "not_needed" => pass(key, format!("{label}: {g}")),
            _ => fail(key, format!("{label}: {g}"), fix),
        });
    }

    // The lock screen.
    let locked = body.get("screen_locked").and_then(Value::as_bool).unwrap_or(false);
    checks.push(if locked {
        fail(
            "screen_locked",
            "the screen is locked: capture and input are refused",
            "Unlock the screen (or let the person allow Computer Use while locked: Settings > Computer Use).",
        )
    } else {
        pass("screen_locked", "the screen is not locked")
    });

    // The mode: input needs more than lookOnly.
    let mode = body.get("mode").and_then(Value::as_str).unwrap_or("unknown");
    let own = body.get("allow_own_machines").and_then(Value::as_bool);
    let own_text = match own {
        Some(true) => "; own machines allowed",
        Some(false) => "; own machines not allowed",
        None => "",
    };
    checks.push(match mode {
        "lookOnly" => fail(
            "mode",
            format!("mode lookOnly{own_text}: screenshots only, no input"),
            "Pick a mode with input in Settings > Computer Use (the person only).",
        ),
        _ => pass("mode", format!("mode {mode}{own_text}")),
    });
    if machine.is_some() && own == Some(false) {
        checks.push(fail(
            "own_machines",
            "this machine does not take calls from the person's other machines",
            "On that machine: Settings > Computer Use > Other machines (computerUse.allowOwnMachines).",
        ));
    }

    // Displays.
    checks.push(match displays {
        Reply::Ok(v) => {
            let list = v.get("displays").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
            if list.is_empty() {
                fail(
                    "displays",
                    "no display",
                    "Attach a display, or start a virtual one (Xvfb, a headless compositor output).",
                )
            } else {
                let ids: Vec<String> = list
                    .iter()
                    .map(|d| {
                        let id = d.get("id").and_then(Value::as_str).unwrap_or("?");
                        if d.get("main").and_then(Value::as_bool) == Some(true) {
                            format!("{id} (main)")
                        } else {
                            id.to_owned()
                        }
                    })
                    .collect();
                pass("displays", format!("{} display(s): {}", list.len(), ids.join(", ")))
            }
        }
        Reply::Off(reason) => fail(
            "displays",
            format!("Computer Use is off{}", suffix(reason)),
            "Turn it on in Settings > Computer Use.",
        ),
        Reply::Failed { code, message } => fail(
            "displays",
            format!("list_displays failed ({code}): {message}"),
            "Run `cmux computer-use status` on that machine: its worker has no list_displays, or this desktop cannot list displays (Windows and the portal desktop do not yet).",
        ),
    });

    checks
}

fn suffix(reason: &str) -> String {
    if reason.is_empty() { String::new() } else { format!(" ({reason})") }
}

/// The worker's executable, and on macOS whether it is the staged copy.
fn helper(body: &Value) -> Check {
    let os = body.pointer("/platform/os").and_then(Value::as_str).unwrap_or("");
    let Some(exe) = body.pointer("/worker/executable").and_then(Value::as_str) else {
        return pass("helper", "the worker does not name its executable (an older cmux)");
    };
    let staged = STAGED_SEGMENTS
        .iter()
        .find_map(|segment| exe.find(segment).map(|at| (at, segment)))
        .map(|(at, segment)| {
            let rest = &exe[at + segment.len()..];
            rest.split('/').next().unwrap_or("").to_owned()
        });
    let is_helper = exe.rsplit('/').next() == Some(MAC_HELPER_EXE);
    match (os, staged, is_helper) {
        (_, Some(bundle), _) => {
            pass("helper", format!("{exe} (staged, verified copy for {bundle})"))
        }
        ("macos", None, true) => fail(
            "helper",
            format!("{exe} is not the staged, verified copy"),
            "cmux couldn't start Computer Use. Restart cmux.",
        ),
        _ => pass("helper", exe.to_owned()),
    }
}

/// Reads everything, prints the report, returns the exit code.
pub(super) fn run(global: &GlobalArgs, machine: Option<&str>, json_flag: bool) -> i32 {
    let endpoint = if machine.is_some() {
        Endpoint::Skipped
    } else {
        match legacy(global, ENDPOINT_CMD, json!({})) {
            Ok(v) => Endpoint::State(v),
            Err(DaemonError::Unreachable(m)) => Endpoint::Unreachable(m),
            Err(e) => Endpoint::Refused(e.to_string()),
        }
    };
    let unreachable = matches!(endpoint, Endpoint::Unreachable(_));
    let call = |tool: &str| -> Reply {
        if unreachable {
            return Reply::Failed {
                code: "daemon_unreachable".into(),
                message: "not asked".into(),
            };
        }
        caller(global).call(tool, &with_machine(json!({}), machine), &new_call_id()).into()
    };
    let status = call("status");
    let displays = call("list_displays");
    let checks = evaluate(machine, &endpoint, &status, &displays);
    let ok = checks.iter().all(|c| c.ok);
    let report = json!({
        "ok": ok,
        "machine": machine,
        "checks": checks.iter().map(|c| json!({
            "name": c.name, "ok": c.ok, "detail": c.detail, "fix": c.fix,
        })).collect::<Vec<_>>(),
        "status": match &status { Reply::Ok(v) => v.clone(), _ => Value::Null },
        "displays": match &displays {
            Reply::Ok(v) => v.get("displays").cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        },
    });
    match (json_flag, global.output) {
        (true, _) | (_, OutputMode::Json | OutputMode::JsonLines) => println!("{report}"),
        (_, OutputMode::Quiet) => {}
        (_, OutputMode::Human) => print!("{}", human(&checks, ok)),
    }
    if ok { 0 } else { 1 }
}

pub(super) fn human(checks: &[Check], ok: bool) -> String {
    let mut out = String::new();
    for c in checks {
        out.push_str(&format!(
            "{} {:<15} {}\n",
            if c.ok { "ok  " } else { "FAIL" },
            c.name,
            c.detail
        ));
        if let Some(fix) = &c.fix {
            out.push_str(&format!("     {:<15} fix: {fix}\n", ""));
        }
    }
    out.push_str(if ok {
        "Computer Use can capture and act here.\n"
    } else {
        "Computer Use would not fully work here; fix the FAIL lines above.\n"
    });
    out
}
