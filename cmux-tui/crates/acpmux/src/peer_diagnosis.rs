//! The first failed step of a machine link that is down, for the app (`diagnosis` on a
//! `peer_unreachable` refusal and on each `_acpmux/peers` row).
//!
//! A link to a machine goes through five steps in order: this device's own network
//! (`client`), the account or credential the machine accepts (`account`), the path the bytes
//! take (`transport`: a direct socket, an `ssh -W` tunnel, a relay), the machine and its acpmux
//! (`hostDaemon`), and the agent on it (`provider`). acpmux already knows why its last attempt
//! failed (`peer_carrier.rs`: `link`, `cause`, `reason`, the attempt's error); this names the
//! first step that failed, the one thing to do about it, on which machine, and a detail a person
//! may copy into a report.
//!
//! The SSH words are the ones `cmux remote doctor` reads from its probes (`cmux-tui`
//! `remote_doctor.rs` `Diagnosis::from_probes`): a refused key is the account step, a host key
//! that is unknown or changed and a closed SSH port are the transport, and a tunnel the server
//! opened whose far end refused is the machine's daemon. Here they are read from the `ssh`
//! error the attempt already recorded, so the app gets them without a new probe or transport.
//!
//! The detail is built only from fixed words, counts and the machine's name cut to safe
//! characters: never from the attempt's error text or the peer's URL, so it cannot carry a
//! token, a password, a private URL or a path, whatever the error said.

use serde::Serialize;

use crate::protocol::peer_state::{Carrier, DownCause, MachineLink, OfflineReason};

/// One step of a machine link, in the order a link goes through them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Step {
    /// This device's own network.
    Client,
    /// The account, token or SSH key the machine accepts.
    Account,
    /// The path to the machine: its socket, the SSH tunnel or the relay.
    Transport,
    /// The machine itself and the acpmux on it.
    HostDaemon,
    /// The agent (Claude Code, Codex, ...) on the machine.
    Provider,
}

impl Step {
    pub const ALL: [Self; 5] =
        [Self::Client, Self::Account, Self::Transport, Self::HostDaemon, Self::Provider];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Client => "client",
            Self::Account => "account",
            Self::Transport => "transport",
            Self::HostDaemon => "hostDaemon",
            Self::Provider => "provider",
        }
    }
}

/// What a step's evidence says.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum StepStatus {
    /// A later step was reached, so this one worked.
    Ok,
    /// The first step that failed.
    Failed,
    /// Not reached: nothing is known about it.
    Unknown,
}

/// The one thing to do about the failed step. Each names where it is done: on this device
/// (`checkNetwork`), or on the machine the diagnosis names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NextAction {
    /// This device is offline: reconnect it to a network. acpmux dials again by itself.
    CheckNetwork,
    /// The machine refused this device's token: sign in again.
    SignIn,
    /// The machine's SSH server refused this device's key: add the key on the machine.
    AuthorizeKey,
    /// The machine's SSH host key is unknown or changed: verify it before trusting it.
    VerifyHostKey,
    /// Nothing listens on the machine's SSH port: turn SSH (Remote Login) on there.
    EnableSsh,
    /// The machine does not answer (off, asleep or off the network): wake it.
    WakeMachine,
    /// The machine (or its Cloud VM) is stopped on purpose: start it.
    StartMachine,
    /// The machine answers but its acpmux does not: start it there.
    StartDaemon,
    /// The machine's acpmux stopped restarting after too many stops: restart it there.
    RestartDaemon,
    /// The machine's disk is full: free space there.
    FreeDisk,
    /// The relay or its credential failed: ask again.
    Reconnect,
}

impl NextAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CheckNetwork => "checkNetwork",
            Self::SignIn => "signIn",
            Self::AuthorizeKey => "authorizeKey",
            Self::VerifyHostKey => "verifyHostKey",
            Self::EnableSsh => "enableSsh",
            Self::WakeMachine => "wakeMachine",
            Self::StartMachine => "startMachine",
            Self::StartDaemon => "startDaemon",
            Self::RestartDaemon => "restartDaemon",
            Self::FreeDisk => "freeDisk",
            Self::Reconnect => "reconnect",
        }
    }

    /// Whether a person must act: acpmux keeps dialing either way, but these never heal by a
    /// retry alone. The rest (an offline device, a machine that does not answer, a relay that
    /// failed) come back by themselves, so the pane keeps saying only "Reconnecting…" for them.
    pub fn needs_person(self) -> bool {
        !matches!(self, Self::CheckNetwork | Self::WakeMachine | Self::Reconnect)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepRow {
    pub step: Step,
    pub status: StepStatus,
}

/// The first failed step of a down link (`diagnosis`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Diagnosis {
    /// The machine the link goes to: where `action` is done (unless it is `checkNetwork`).
    pub machine: String,
    pub failed_step: Step,
    /// Every step in order, `ok` before the failed one and `unknown` after it.
    pub steps: Vec<StepRow>,
    pub action: NextAction,
    /// `action.needs_person()`: the line names the step and its action instead of
    /// "Reconnecting…".
    pub needs_person: bool,
    /// What a person may copy: fixed words, counts and the machine's safe name only.
    pub detail: String,
}

/// What acpmux knows of a down link (`Peer::observed` plus the attempt's carrier).
#[derive(Debug, Clone, Copy)]
pub struct Evidence<'a> {
    pub link: MachineLink,
    /// The carrier the last attempt used, when known.
    pub carrier: Option<Carrier>,
    pub cause: Option<DownCause>,
    pub reason: Option<OfflineReason>,
    /// The last attempt's error: read for its class only, never copied.
    pub error: Option<&'a str>,
    pub last_seen: Option<u64>,
    pub attempts: u32,
}

/// The first failed step of a link in `evidence`, or none for a link that is up or on its way
/// (connecting, degraded, restarting, paused): nothing failed yet.
pub fn diagnose(machine: &str, evidence: &Evidence<'_>, now: u64) -> Option<Diagnosis> {
    if !matches!(
        evidence.link,
        MachineLink::Reconnecting
            | MachineLink::Offline
            | MachineLink::AuthFailed
            | MachineLink::UpdateRequired
    ) {
        return None;
    }
    let (failed_step, action, finding) = classify(evidence);
    let steps = Step::ALL
        .iter()
        .map(|&step| StepRow {
            step,
            status: match (step as u8).cmp(&(failed_step as u8)) {
                std::cmp::Ordering::Less => StepStatus::Ok,
                std::cmp::Ordering::Equal => StepStatus::Failed,
                std::cmp::Ordering::Greater => StepStatus::Unknown,
            },
        })
        .collect();
    let machine = safe_name(machine);
    let detail = detail(&machine, evidence, failed_step, action, finding, now);
    Some(Diagnosis {
        machine,
        failed_step,
        steps,
        action,
        needs_person: action.needs_person(),
        detail,
    })
}

/// The failed step, its action and a kebab word for the detail (the class of the error).
fn classify(evidence: &Evidence<'_>) -> (Step, NextAction, &'static str) {
    if evidence.cause == Some(DownCause::LocalNetwork) {
        return (Step::Client, NextAction::CheckNetwork, "device-offline");
    }
    if evidence.link == MachineLink::AuthFailed
        || evidence.reason == Some(OfflineReason::LoginNeeded)
    {
        return (Step::Account, NextAction::SignIn, "token-refused");
    }
    match evidence.reason {
        Some(OfflineReason::CredentialUnavailable) => {
            return (Step::Account, NextAction::Reconnect, "relay-credential-unavailable");
        }
        Some(OfflineReason::MachineStopped) => {
            return (Step::HostDaemon, NextAction::StartMachine, "machine-stopped");
        }
        Some(OfflineReason::RestartBudgetExceeded) => {
            return (Step::HostDaemon, NextAction::RestartDaemon, "daemon-restart-budget");
        }
        Some(OfflineReason::DiskFull) => {
            return (Step::HostDaemon, NextAction::FreeDisk, "disk-full");
        }
        Some(OfflineReason::LoginNeeded) | None => {}
    }
    let error = evidence.error.unwrap_or_default().to_ascii_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| error.contains(n));
    // `ssh`'s own words, in the order `remote_doctor.rs` decides them: a server that answered
    // and refused the key, then its host key, then a tunnel it opened whose far end refused.
    if has(&["permission denied (publickey", "permission denied (", "too many authentication"]) {
        return (Step::Account, NextAction::AuthorizeKey, "ssh-key-not-authorized");
    }
    if has(&["remote host identification has changed", "host key for "]) && has(&["changed"]) {
        return (Step::Transport, NextAction::VerifyHostKey, "ssh-host-key-changed");
    }
    if has(&["host key verification failed", "no matching host key"]) {
        return (Step::Transport, NextAction::VerifyHostKey, "ssh-host-key-unknown");
    }
    if has(&["channel 0: open failed", "stdio forwarding failed", "open failed: connect failed"]) {
        return (Step::HostDaemon, NextAction::StartDaemon, "daemon-not-listening");
    }
    if has(&["401", "403", "unauthorized", "forbidden"]) {
        return (Step::Account, NextAction::SignIn, "token-refused");
    }
    if has(&["connection refused", "os error 61", "os error 111"]) {
        // A refused SSH port is SSH switched off (`SshOff`); a refused daemon socket on a
        // machine that answered is its acpmux not running.
        return if evidence.carrier == Some(Carrier::Ssh) || error.contains("ssh") {
            (Step::Transport, NextAction::EnableSsh, "ssh-off")
        } else {
            (Step::HostDaemon, NextAction::StartDaemon, "daemon-not-listening")
        };
    }
    if has(&["relay", "credential-unavailable"]) {
        return (Step::Transport, NextAction::Reconnect, "relay-failed");
    }
    (Step::Transport, NextAction::WakeMachine, "machine-not-answering")
}

/// The machine's name as the detail and the line carry it: printable ASCII word characters
/// only, at most 64, so a name cannot smuggle a URL's userinfo, query or a path.
fn safe_name(name: &str) -> String {
    let name = name.split(['/', '?', '#', '@', ':']).next().unwrap_or_default();
    let safe: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        .take(64)
        .collect();
    if safe.is_empty() { "unknown".to_owned() } else { safe }
}

fn detail(
    machine: &str,
    evidence: &Evidence<'_>,
    step: Step,
    action: NextAction,
    finding: &str,
    now: u64,
) -> String {
    let carrier = match evidence.carrier {
        Some(Carrier::Direct) => "direct",
        Some(Carrier::Ssh) => "ssh",
        Some(Carrier::Hub) => "hub",
        Some(Carrier::Cloud) => "cloud",
        None => "unknown",
    };
    let seen = match evidence.last_seen {
        Some(at) => format!("{}s ago", now.saturating_sub(at) / 1000),
        None => "never".to_owned(),
    };
    let steps = Step::ALL
        .iter()
        .map(|&s| {
            let mark = match (s as u8).cmp(&(step as u8)) {
                std::cmp::Ordering::Less => "ok",
                std::cmp::Ordering::Equal => "failed",
                std::cmp::Ordering::Greater => "unknown",
            };
            format!("{}={mark}", s.as_str())
        })
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "machine: {machine}\nlink: {}\ncarrier: {carrier}\nsteps: {steps}\nfinding: {finding}\n\
         next: {}\nlast seen: {seen}\nattempts: {}",
        evidence.link.as_str(),
        action.as_str(),
        evidence.attempts,
    )
}

#[cfg(test)]
#[path = "peer_diagnosis_tests.rs"]
mod tests;
