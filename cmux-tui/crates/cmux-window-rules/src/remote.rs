//! Which SSH machine a remote action acts on, and where Open Terminal Here
//! opens a terminal of another machine.

use serde::{Deserialize, Serialize};

/// One SSH machine: its id and the names a person may call it by (its sidebar
/// label, its destination in each spelling).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Machine {
    pub id: String,
    pub names: Vec<String>,
}

/// Why no machine was found.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "refusal")]
pub enum MachineRefusal {
    /// The target names no machine, or more than one.
    UnknownMachine { target: String },
    /// No target, and neither the active window nor a single machine says which.
    NoMachine,
}

/// The machine a remote action acts on (an index into `machines`): the
/// target's (by id, else by exactly one case-insensitive name), else the
/// active window's machine, else the only machine.
pub fn machine(
    target: Option<&str>,
    machines: &[Machine],
    active: Option<&str>,
) -> Result<usize, MachineRefusal> {
    if let Some(target) = target {
        if let Some(index) = machines.iter().position(|machine| machine.id == target) {
            return Ok(index);
        }
        let wanted = target.to_lowercase();
        let mut matches = machines
            .iter()
            .enumerate()
            .filter(|(_, machine)| machine.names.iter().any(|name| name.to_lowercase() == wanted));
        return match (matches.next(), matches.next()) {
            (Some((index, _)), None) => Ok(index),
            _ => Err(MachineRefusal::UnknownMachine { target: target.to_owned() }),
        };
    }
    if let Some(index) =
        active.and_then(|active| machines.iter().position(|machine| machine.id == active))
    {
        return Ok(index);
    }
    if machines.len() == 1 { Ok(0) } else { Err(MachineRefusal::NoMachine) }
}

/// The split a remote terminal opens in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Split {
    Right,
    Down,
}

/// What Open Terminal Here does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum TerminalHere {
    /// The pane's own machine with no direction or folder: a new tab, as New Tab does.
    NewSurface,
    /// A remote terminal tab in the pane, or in a new split.
    Open { split: Option<Split> },
    /// The direction is neither right nor down.
    SplitRightOrDown,
}

/// Open Terminal Here on a machine: `direction` takes placement words too
/// (`below`, `bottom`); the daemon splits right or down only.
pub fn terminal_here(direction: Option<&str>, same_machine: bool, cwd: bool) -> TerminalHere {
    let split = match direction {
        None => None,
        Some("right") => Some(Split::Right),
        Some("down" | "below" | "bottom") => Some(Split::Down),
        Some(_) => return TerminalHere::SplitRightOrDown,
    };
    if same_machine && split.is_none() && !cwd {
        return TerminalHere::NewSurface;
    }
    TerminalHere::Open { split }
}

/// What a connect's observation reads on each change.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ConnectFacts {
    /// The machine's tree loaded and its daemon is connected.
    pub loaded: bool,
    /// A window is open.
    pub has_window: bool,
    /// The link went offline (a disconnect).
    pub offline: bool,
    /// The link's status asks for recovery (auth, host key, install failures).
    pub needs_recovery: bool,
    /// The connect attempt the daemon's last failure belongs to.
    pub failure_attempt: Option<u64>,
    /// The current connect attempt (a Retry or Reconnect starts a new one).
    pub current_attempt: u64,
}

/// What a connect's observation does on a change.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectStep {
    /// Show the machine's first workspace and end.
    pub show_workspace: bool,
    /// End (disconnected).
    pub end: bool,
    /// Open a window for the recovery sheet (none is open).
    pub open_window: bool,
    /// Show the recovery sheet. A daemon failure counts only for the current attempt: an old
    /// failure never reopens recovery after a newer Retry or Reconnect started.
    pub recovery: bool,
}

/// One step of the observation after Connect.
pub fn connect_step(facts: ConnectFacts) -> ConnectStep {
    if facts.loaded {
        return ConnectStep { show_workspace: true, ..ConnectStep::default() };
    }
    if facts.offline {
        return ConnectStep { end: true, ..ConnectStep::default() };
    }
    let recovery = facts.needs_recovery || facts.failure_attempt == Some(facts.current_attempt);
    ConnectStep { open_window: recovery && !facts.has_window, recovery, ..ConnectStep::default() }
}

#[cfg(test)]
#[path = "remote_tests.rs"]
mod tests;
