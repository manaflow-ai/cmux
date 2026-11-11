//! Whether a Cloud machine's agents reach models through its edge before a Cloud start opens
//! the first chat there (plans/cmux-next/vm-coderouter-edge.md). The app runs [`GUEST`] on the
//! machine (`cmux-tui acp --json machine-auth`, acpmux `cli/machine_auth.rs`) once the machine
//! runs the app's own machine software, and asks [`verdict`] about the output: a start goes on
//! only when every agent routes to the edge and the machine holds no provider login, so a chat
//! never begins with a turn the provider rejects. `cmux cloud machine-auth` reads the same report
//! ([`report`]).

use serde::Serialize;
use serde_json::Value;

/// The machine-side command: the work user's cmux-tui (the build the machine's acpmux runs) prints
/// its model-route report, as that user when the exec runs as root. It prints nothing when the
/// machine's cmux-tui predates the report.
pub const GUEST: &str = "c=/home/cmux/.cmux/bin/cmux-tui; [ -x \"$c\" ] || c=cmux-tui; \
if [ \"$(id -u)\" = 0 ] && id cmux >/dev/null 2>&1; then \
set -- setpriv --reuid=cmux --regid=cmux --init-groups env HOME=/home/cmux USER=cmux LOGNAME=cmux; \
else set --; fi; \"$@\" \"$c\" acp --json machine-auth 2>/dev/null; true";

/// What a start does with a machine's report.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// Every agent routes to the edge and no provider login is on the machine: start.
    Ready,
    /// No report: the machine's software is older than the report (its update did not land).
    Unsupported,
    /// Output that is not the report.
    Invalid,
    /// acpmux, which starts every agent, does not run.
    NoDaemon,
    /// A provider login or credential variable is on the machine.
    HoldsCredential,
    /// An agent's base URL or key is not the edge's.
    NotEdge,
}

/// What a machine printed for [`GUEST`].
#[derive(Clone, Debug, PartialEq)]
pub enum Reported {
    /// Nothing: its cmux-tui predates the report.
    Nothing,
    /// Something that is not the report.
    Other,
    /// The report: the last JSON object of the output that names `agents`.
    Report(Value),
}

/// Reads the machine's output of [`GUEST`].
pub fn report(stdout: &str) -> Reported {
    if stdout.trim().is_empty() {
        return Reported::Nothing;
    }
    stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok().filter(Value::is_object))
        .filter(|report| report.get("agents").is_some())
        .map_or(Reported::Other, Reported::Report)
}

/// The start's verdict on the machine's output of [`GUEST`].
pub fn verdict(stdout: &str) -> Verdict {
    let report = match report(stdout) {
        Reported::Nothing => return Verdict::Unsupported,
        Reported::Other => return Verdict::Invalid,
        Reported::Report(report) => report,
    };
    if report["ok"].as_bool() == Some(true) {
        Verdict::Ready
    } else if report["holds_credential"].as_bool() != Some(false) {
        Verdict::HoldsCredential
    } else if report["daemon"]["running"].as_bool() != Some(true) {
        Verdict::NoDaemon
    } else {
        Verdict::NotEdge
    }
}

#[cfg(test)]
mod tests;
