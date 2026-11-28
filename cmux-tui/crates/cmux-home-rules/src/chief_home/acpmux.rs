//! The Chief host's acpmux and the app's links (CmuxNextHomeEngine `ChiefAppAcpmuxMove.swift`,
//! `ChiefAppLinks.swift`).

use super::path::join;
use serde::{Deserialize, Serialize};

/// `ChiefAppAcpmuxMove.plan`'s inputs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveInputs {
    #[serde(default, rename = "hostPID")]
    pub host_pid: Option<i32>,
    #[serde(default)]
    pub host_replaced: bool,
    #[serde(default, rename = "markedPID")]
    pub marked_pid: Option<i32>,
    #[serde(default)]
    pub marked_home: Option<String>,
    pub app_home: String,
    #[serde(default)]
    pub own_daemon_present: bool,
    #[serde(default)]
    pub named_chiefs_run: bool,
}

/// `ChiefAppAcpmuxMove.Plan`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MovePlan {
    pub restart_host: bool,
    pub end_own_daemon: bool,
}

/// `ChiefAppAcpmuxMove.plan`: restart a running host not on the app's acpmux; end the Chief's own daemon
/// unless a named Chief still runs on it.
pub fn plan(inputs: &MoveInputs) -> MovePlan {
    let restart_host = inputs.host_pid.is_some_and(|pid| {
        inputs.host_replaced
            || inputs.marked_pid != Some(pid)
            || inputs.marked_home.as_deref() != Some(inputs.app_home.as_str())
    });
    MovePlan { restart_host, end_own_daemon: inputs.own_daemon_present && !inputs.named_chiefs_run }
}

/// `state/host.acpmux` below the home's root.
pub fn mark_file(root: &str) -> String {
    join(root, "state/host.acpmux")
}

/// What the mark holds (`readMark`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Mark {
    #[serde(rename = "pid")]
    pub pid: Option<i32>,
    pub home: Option<String>,
}

/// `ChiefAppAcpmuxMove.readMark`: the first non-empty line is the pid, the second the acpmux home.
pub fn read_mark(text: &str) -> Mark {
    let mut lines = text.split('\n').filter(|line| !line.is_empty());
    let pid = lines.next().and_then(swift_int32);
    Mark { pid, home: lines.next().map(str::to_owned) }
}

/// `Int32(_ text:)`: an optional sign and decimal digits only.
fn swift_int32(text: &str) -> Option<i32> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// `ChiefAppAcpmuxMove.mark(pid:)`'s text.
pub fn mark_text(pid: i32, app_home: &str) -> String {
    format!("{pid}\n{app_home}\n")
}

/// `ChiefAppAcpmuxMove.onAppAcpmux`: the running host is the marked one and the mark names another acpmux.
pub fn on_app_acpmux(
    host_pid: Option<i32>,
    marked_pid: Option<i32>,
    marked_home: Option<&str>,
    own_home: &str,
) -> bool {
    match (host_pid, marked_home) {
        (Some(host), Some(marked)) if marked_pid == Some(host) => marked != own_home,
        _ => false,
    }
}

/// An acpmux session census (`AcpmuxSessionCensus`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Census {
    #[serde(default)]
    pub in_turn: i64,
    #[serde(default)]
    pub chief_in_turn: bool,
}

/// `ChiefAppAcpmuxMove.idle`: a census that came back with nothing in a turn.
pub fn idle(census: Option<&Census>) -> bool {
    census.is_some_and(|census| census.in_turn == 0 && !census.chief_in_turn)
}

/// `ChiefAppLinks`: where the home links to the app's sockets, and the host's variables naming them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Links {
    pub control_link: String,
    pub daemon_link: String,
    pub state_directory: String,
    pub host_environment: std::collections::BTreeMap<String, String>,
}

/// `ChiefAppLinks.controlLink`, `daemonLink`, `hostEnvironment`.
pub fn links(root: &str) -> Links {
    let control_link = join(root, "state/app.sock");
    let daemon_link = join(root, "state/app-daemon.sock");
    let host_environment = [
        ("CMUX_SOCKET_PATH".to_owned(), control_link.clone()),
        ("CMUX_APP_DAEMON_SOCKET".to_owned(), daemon_link.clone()),
    ]
    .into_iter()
    .collect();
    Links { control_link, daemon_link, state_directory: join(root, "state"), host_environment }
}

/// `ChiefAppLinks.point`'s temporary link: `<link>.<pid>.tmp`.
pub fn temporary_link(link: &str, pid: i32) -> String {
    format!("{link}.{pid}.tmp")
}
