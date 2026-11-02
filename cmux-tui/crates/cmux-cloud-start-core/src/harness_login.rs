//! What a `cloud.startChat` start does about its machine's harness login, and
//! why (the app's `CloudStartChat+Login`, Leo 2026-10-31: "A TOKEN GETS
//! PASSED"). A start that passes no login leaves Claude there signed out or on
//! a rejected login, and every turn then fails with the bare "The provider
//! rejected Claude Code's credentials on this Cloud machine" card. So the start
//! logs this decision and keeps it on the machine's `cloud.machines` row
//! (`harness_login`), never a silent skip.
//!
//! The app gathers the inputs (the build gate, the account, the platform's
//! owner answer, the guest's `/etc/cmux/vm-kind`, the machine's own login) and
//! asks [`decide`]; it runs the confirm and the transfer itself.

use serde::{Deserialize, Serialize};

/// The provider whose login a start passes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Claude,
    Codex,
}

impl Provider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

/// The Claude login a Cloud machine already holds (the app's `CloudMachineLogin`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MachineLogin {
    /// No own Claude sign-in on the machine.
    None,
    /// A `/login` session with a refresh token: Claude renews it itself.
    Session,
    /// The token is the one cmux holds for this account.
    Cached,
    /// Another token the provider did not reject, or could not be asked about.
    Working,
    /// Another token the provider answered 401 for: expired or revoked.
    Rejected,
}

impl MachineLogin {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Session => "session",
            Self::Cached => "cached",
            Self::Working => "working",
            Self::Rejected => "rejected",
        }
    }

    /// Whether a start gives the machine the account's login, replacing a rejected one.
    pub fn needs_login(self) -> bool {
        matches!(self, Self::None | Self::Rejected)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Step {
    #[serde(rename = "skip")]
    Skip,
    #[serde(rename = "install")]
    Install,
    #[serde(rename = "confirm-then-install")]
    ConfirmThenInstall,
}

impl Step {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Skip => "skip",
            Self::Install => "install",
            Self::ConfirmThenInstall => "confirm-then-install",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Reason {
    /// This build passes no login (the app's `passesHarnessLogin`).
    #[serde(rename = "build-gate-off")]
    BuildGateOff,
    /// The chat's harness has no transfer here (Codex keeps its broker flow, pi and opencode none).
    #[serde(rename = "no-transfer-for-harness")]
    NoTransfer,
    #[serde(rename = "signed-out")]
    SignedOut,
    /// The platform does not say the signed-in caller owns the machine.
    #[serde(rename = "caller-not-owner")]
    CallerNotOwner,
    /// The guest's `/etc/cmux/vm-kind` is neither `owner` nor `team` (missing or unknown).
    #[serde(rename = "guest-not-owner")]
    GuestNotOwner,
    /// The guest's kind could not be read (the exec failed).
    #[serde(rename = "guest-kind-unread")]
    GuestUnread,
    /// The machine's own login stays ([`MachineLogin::needs_login`] is false).
    #[serde(rename = "machine-login-kept")]
    MachineLoginKept,
    #[serde(rename = "install-cached")]
    InstallCached,
    #[serde(rename = "confirm-first")]
    ConfirmFirst,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BuildGateOff => "build-gate-off",
            Self::NoTransfer => "no-transfer-for-harness",
            Self::SignedOut => "signed-out",
            Self::CallerNotOwner => "caller-not-owner",
            Self::GuestNotOwner => "guest-not-owner",
            Self::GuestUnread => "guest-kind-unread",
            Self::MachineLoginKept => "machine-login-kept",
            Self::InstallCached => "install-cached",
            Self::ConfirmFirst => "confirm-first",
        }
    }
}

/// What the start knows so far. Fields the start has not asked yet are absent.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Inputs {
    pub gate: bool,
    pub provider: Option<Provider>,
    pub signed_in: bool,
    /// Absent when not asked (an earlier check decided).
    pub caller_owns: Option<bool>,
    /// The guest's `/etc/cmux/vm-kind` ("" when missing); absent when not read or the read failed.
    pub guest_kind: Option<String>,
    pub machine_login: Option<MachineLogin>,
    pub cached: bool,
    /// What came of it once decided: "installed", "declined" (the confirm), or the transfer's fixed failure text.
    pub outcome: Option<String>,
}

/// The decision and everything the app reads off it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub step: Step,
    pub reason: Reason,
    /// Whether the start reads the guest and its login: only once the earlier checks let it go on.
    pub reads_machine: bool,
    /// Whether the guest takes the caller's login: an `owner` guest, or a `team` one, since the
    /// creator is the machine's owner team or no team (Leo, 2026-11-01: "team or no team the thing
    /// should just work"). Reached only once `reads_machine`, so a teammate who did not create the
    /// machine never gets here and a shared machine keeps each guest on their own login.
    pub guest_takes_login: bool,
    /// The start passed no personal login because the machine is a team machine (handshake
    /// `cloudTeamMachine`). The creator's own machine takes the login whatever its guest kind,
    /// so this no longer happens; kept for the handshake.
    pub skipped_team_machine: bool,
    /// One line for the log and the `cloud.machines` row; no token, path or provider output.
    pub summary: String,
}

fn guest_takes_login(kind: Option<&str>) -> bool {
    matches!(kind, Some("owner" | "team"))
}

fn step_and_reason(d: &Inputs) -> (Step, Reason) {
    // Codex logins are per machine (its refresh token is VM-bound): its broker flow stays the turn card's.
    if !d.gate {
        return (Step::Skip, Reason::BuildGateOff);
    }
    if d.provider != Some(Provider::Claude) {
        return (Step::Skip, Reason::NoTransfer);
    }
    if !d.signed_in {
        return (Step::Skip, Reason::SignedOut);
    }
    if d.caller_owns != Some(true) {
        return (Step::Skip, Reason::CallerNotOwner);
    }
    let Some(kind) = d.guest_kind.as_deref() else {
        return (Step::Skip, Reason::GuestUnread);
    };
    // The caller created the machine: an owner or team guest takes the login
    // (the transfer runs its creator allowance on a team guest).
    if !guest_takes_login(Some(kind)) {
        return (Step::Skip, Reason::GuestNotOwner);
    }
    if !d.machine_login.is_none_or(MachineLogin::needs_login) {
        return (Step::Skip, Reason::MachineLoginKept);
    }
    if d.cached {
        (Step::Install, Reason::InstallCached)
    } else {
        (Step::ConfirmThenInstall, Reason::ConfirmFirst)
    }
}

fn summary(d: &Inputs, step: Step, reason: Reason) -> String {
    fn word(value: Option<bool>) -> &'static str {
        match value {
            Some(true) => "yes",
            Some(false) => "no",
            None => "-",
        }
    }
    let kind = match d.guest_kind.as_deref() {
        Some("") => "(none)",
        Some(kind) => kind,
        None => "-",
    };
    let mut line = format!(
        "{} ({}): gate {}, provider {}, signed in {}, caller owns {}, guest {}, machine login {}, cached {}",
        step.as_str(),
        reason.as_str(),
        if d.gate { "on" } else { "off" },
        d.provider.map_or("-", Provider::as_str),
        word(Some(d.signed_in)),
        word(d.caller_owns),
        kind,
        d.machine_login.map_or("-", MachineLogin::as_str),
        word(Some(d.cached)),
    );
    if let Some(outcome) = &d.outcome {
        line.push_str(" -> ");
        line.push_str(outcome);
    }
    line
}

/// The start's decision for these inputs.
pub fn decide(d: &Inputs) -> Decision {
    let (step, reason) = step_and_reason(d);
    let kind = d.guest_kind.as_deref();
    Decision {
        step,
        reason,
        reads_machine: d.gate
            && d.provider == Some(Provider::Claude)
            && d.signed_in
            && d.caller_owns == Some(true),
        guest_takes_login: guest_takes_login(kind),
        skipped_team_machine: reason == Reason::GuestNotOwner && kind == Some("team"),
        summary: summary(d, step, reason),
    }
}

/// The provider whose login a start needs; `None` for a harness that has no
/// transfer (pi, opencode). No harness named is the app's default agent,
/// Claude. A named harness maps by family, as the web `agentKey` does for
/// named profiles and scoped ids: the last `/` segment, up to its first `-`,
/// `_` or whitespace, lowercased (`claude-sr2` and `team/Claude` are Claude).
pub fn login_provider(harness: Option<&str>) -> Option<Provider> {
    let harness = match harness {
        None | Some("") => return Some(Provider::Claude),
        Some(harness) => harness,
    };
    let name = harness.rsplit('/').next()?;
    let family = name
        .split(|c: char| c == '-' || c == '_' || c.is_whitespace())
        .find(|part| !part.is_empty())?;
    match family.to_lowercase().as_str() {
        "claude" => Some(Provider::Claude),
        "codex" => Some(Provider::Codex),
        _ => None,
    }
}

/// Prints the guest's kind after a fixed marker, so an exec that ran is told from one that failed.
pub const GUEST_KIND_PROBE: &str =
    r#"printf 'vm-kind:%s\n' "$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]')""#;

const GUEST_KIND_MARKER: &str = "vm-kind:";

/// Foundation's `CharacterSet.whitespaces`: tab and the space separators, never a line break.
fn is_inline_space(c: char) -> bool {
    c == '\t'
        || matches!(
            c,
            ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
                ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
}

/// The kind [`GUEST_KIND_PROBE`] printed ("" when the guest has none), or `None` for output without the marker.
pub fn guest_kind(stdout: &str) -> Option<String> {
    stdout
        .split('\n')
        .find_map(|line| line.strip_prefix(GUEST_KIND_MARKER))
        .map(|kind| kind.trim_matches(is_inline_space).to_owned())
}

#[cfg(test)]
mod tests;
