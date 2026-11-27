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

/// The one fixed folder every build stages the helper in (`cmux_signed_bundle::helper_folder`,
/// the app's `SignedHelperStaging`, cmux-tui-core `computer_use_host/macos.rs`):
/// `~/Library/Application Support/cmux-next/helper/<bundle id>/<bundle name>.app`.
const STAGED_SEGMENT: &str = "/Library/Application Support/cmux-next/helper/";
/// The per-build layout before the fixed path
/// (`.../cmux-next/screen-sharing/<bundle id>/computer-use/<16 hex>/`): a copy there was
/// started by an older cmux daemon.
const LEGACY_SEGMENT: &str = "/cmux-next/screen-sharing/";
/// The macOS helper's executable (the verified copy runs from the staging folder).
const MAC_HELPER_EXE: &str = "cmux-screen-sharing";
/// The marker beside the staged copy: the content digest it was checked to have.
const MARKER: &str = ".verified";
/// What makes a running worker use the copy the current cmux stages: Computer Use off stops
/// the worker, on starts it again through this daemon's stager. Restarting the app alone does
/// not: the daemon and its worker outlive it.
const RESTAGE_FIX: &str = "Turn Computer Use off and on again in Settings > Computer Use (or `cmux settings set computerUse.mode off`, then back to your mode) so cmux starts the worker again from its staged copy. If the doctor still says so, the cmux daemon is older than the app: quit cmux, check no `cmux-tui` process is left, and open it again.";

/// What the staged copy's `.verified` marker says about the bundle beside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Marker {
    /// Not read: another machine's worker, or the doctor does not look at disk.
    Unread,
    /// The marker holds the copy's own content digest.
    Matches,
    /// The marker is missing or holds another digest.
    Differs,
}

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
    evaluate_with(machine, endpoint, status, displays, &|_| Marker::Unread)
}

/// [`evaluate`], with `marker` reading the staged copy's `.verified` marker for the helper
/// check (the local machine only: a remote worker's disk is not this one's).
pub(super) fn evaluate_with(
    machine: Option<&str>,
    endpoint: &Endpoint,
    status: &Reply,
    displays: &Reply,
    marker: &dyn Fn(&str) -> Marker,
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
    checks.push(helper(body, marker));

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

/// The worker's executable, and on macOS whether it is the staged, verified copy: under the
/// fixed helper folder and, when `marker` reads it, matching the folder's `.verified` digest.
pub(super) fn helper(body: &Value, marker: &dyn Fn(&str) -> Marker) -> Check {
    let os = body.pointer("/platform/os").and_then(Value::as_str).unwrap_or("");
    let Some(exe) = body.pointer("/worker/executable").and_then(Value::as_str) else {
        return pass("helper", "the worker does not name its executable (an older cmux)");
    };
    if exe.rsplit('/').next() != Some(MAC_HELPER_EXE) {
        return pass("helper", exe.to_owned());
    }
    let staged = exe
        .split_once(STAGED_SEGMENT)
        .map(|(_, rest)| rest.split('/').next().unwrap_or("").to_owned());
    match (staged, marker(exe)) {
        (Some(bundle), Marker::Matches | Marker::Unread) if !bundle.is_empty() => {
            pass("helper", format!("{exe} (staged, verified copy for {bundle})"))
        }
        (Some(bundle), _) if !bundle.is_empty() => fail(
            "helper",
            format!(
                "{exe} does not match the digest in its folder's {MARKER} marker (a copy for {bundle} left half replaced)"
            ),
            RESTAGE_FIX,
        ),
        _ if exe.contains(LEGACY_SEGMENT) => fail(
            "helper",
            format!(
                "{exe} is an older cmux's copy, not the one staged at ~{STAGED_SEGMENT}<bundle id>/"
            ),
            RESTAGE_FIX,
        ),
        _ if os == "macos" => fail(
            "helper",
            format!(
                "{exe} is not the staged, verified copy (~{STAGED_SEGMENT}<bundle id>/): macOS checks the grants of the app it runs inside"
            ),
            RESTAGE_FIX,
        ),
        _ => pass("helper", exe.to_owned()),
    }
}

/// Reads the staged copy's marker for the worker executable `exe`
/// (`<folder>/<name>.app/Contents/MacOS/<exe>`): whether `<folder>/.verified` holds the
/// bundle's own content digest (`cmux_signed_bundle::digest_of`, as the stager checks).
pub(super) fn read_marker(exe: &str) -> Marker {
    let path = std::path::Path::new(exe);
    let Some(app) = path.ancestors().nth(3).filter(|app| {
        app.extension().is_some_and(|e| e == "app")
            && path.parent().and_then(|p| p.file_name()).is_some_and(|n| n == "MacOS")
    }) else {
        return Marker::Unread;
    };
    let Some(folder) = app.parent() else { return Marker::Unread };
    let Ok(want) = std::fs::read_to_string(folder.join(MARKER)) else { return Marker::Differs };
    let parts = cmux_signed_bundle::digest_parts(MAC_HELPER_EXE);
    match cmux_signed_bundle::digest_of(app, &parts) {
        Ok(digest) if digest == want.trim() => Marker::Matches,
        Ok(_) => Marker::Differs,
        Err(_) => Marker::Unread,
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
    // The staged copy's marker is on this machine's disk only for a local worker.
    let checks = if machine.is_none() {
        evaluate_with(machine, &endpoint, &status, &displays, &read_marker)
    } else {
        evaluate(machine, &endpoint, &status, &displays)
    };
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
