//! Power and lock enforcement (server.md 9.1).
//!
//! Linux: one logind inhibitor per kind, held by `systemd-inhibit
//! --mode=block` around `cat` reading a pipe this process owns. When this
//! process exits, the pipe closes, `cat` ends and logind drops the
//! inhibitor, so a crash never leaks one. logind maps a combined `--what`
//! to another polkit action, so each kind is its own process (measured in
//! the prototype). Stock polkit grants a lingering user without a session
//! only `idle`; `sleep` and `handle-lid-switch` need the polkit rule that
//! system mode installs.
//!
//! macOS: IOPM assertions are not in this slice; [`hold_power_assertions`]
//! returns `Unsupported`.

use std::io;
use std::process::{Child, ChildStdin, Command, Stdio};

use cmux_server_core::health::InhibitFacts;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Idle,
    Sleep,
    HandleLidSwitch,
}

impl Kind {
    pub const ALL: [Kind; 3] = [Kind::Idle, Kind::Sleep, Kind::HandleLidSwitch];

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Idle => "idle",
            Kind::Sleep => "sleep",
            Kind::HandleLidSwitch => "handle-lid-switch",
        }
    }
}

fn inhibit_command(kind: Kind) -> Command {
    let mut cmd = Command::new("systemd-inhibit");
    cmd.env_remove(cmux_server_core::reexec::GUARD_ENV);
    cmd.arg(format!("--what={}", kind.as_str()))
        .arg("--mode=block")
        .arg("--who=cmux-server")
        .arg("--why=cmux server is running");
    cmd
}

/// Whether logind grants `kind` to this user now (runs `true` under it).
pub fn probe(kind: Kind) -> bool {
    inhibit_command(kind)
        .arg("true")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// One held inhibitor. Dropping it closes the pipe and releases it.
#[derive(Debug)]
pub struct Inhibitor {
    pub kind: Kind,
    child: Child,
    stdin: Option<ChildStdin>,
}

impl Inhibitor {
    /// Spawns the holder. Callers [`probe`] first: a refused inhibitor
    /// makes `systemd-inhibit` exit at once, which [`Inhibitor::is_held`]
    /// then reports.
    pub fn hold(kind: Kind) -> io::Result<Inhibitor> {
        let mut child = inhibit_command(kind)
            .arg("cat")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take();
        Ok(Inhibitor { kind, child, stdin })
    }

    /// The holder still runs (a non-blocking check at the time of asking).
    pub fn is_held(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }
}

impl Drop for Inhibitor {
    fn drop(&mut self) {
        drop(self.stdin.take());
        let _ = self.child.wait();
    }
}

/// Holds every kind logind grants. Returns the holders and the facts for
/// the reducer (`inhibit.limited` when only `idle` is held).
pub fn hold_all() -> (Vec<Inhibitor>, InhibitFacts) {
    let mut held = Vec::new();
    for kind in Kind::ALL {
        if probe(kind)
            && let Ok(inhibitor) = Inhibitor::hold(kind)
        {
            held.push(inhibitor);
        }
    }
    let facts = facts_of(&held.iter().map(|i| i.kind).collect::<Vec<_>>());
    (held, facts)
}

/// What logind would grant now, without holding anything (`cmux server
/// health` when no server role runs).
pub fn probe_all() -> InhibitFacts {
    let granted: Vec<Kind> = Kind::ALL.into_iter().filter(|k| probe(*k)).collect();
    facts_of(&granted)
}

pub fn facts_of(kinds: &[Kind]) -> InhibitFacts {
    InhibitFacts {
        idle: kinds.contains(&Kind::Idle),
        sleep: kinds.contains(&Kind::Sleep),
        handle_lid_switch: kinds.contains(&Kind::HandleLidSwitch),
    }
}

/// macOS IOPM assertions (`PreventUserIdleSystemSleep`, …): not in this
/// slice.
pub fn hold_power_assertions() -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "macOS power assertions are not implemented in this build (server.md step 7)",
    ))
}
