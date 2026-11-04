//! What a `cloud.startChat` start does about its machine's harness login, and
//! why (the app's `CloudStartChat+Login`, Leo 2026-10-31: "A TOKEN GETS
//! PASSED"). A start that passes no login leaves Claude there signed out or on
//! a rejected login, and every turn then fails with the bare "The provider
//! rejected Claude Code's credentials on this Cloud machine" card. So the start
//! logs this decision and keeps it on the machine's `cloud.machines` row
//! (`harness_login`), never a silent skip.
//!
//! The app gathers the inputs (the build and its setting, the chat's harness,
//! the account, the platform's owner answer, the guest's `/etc/cmux/vm-kind`
//! probe output, the machine's login probe output) and asks [`decide`], one
//! call that reads all of them; it runs the confirm and the transfer itself.
//! So an app FFI that does not answer is one failure the app records as
//! `ffi-failed`, never an ordinary skip reason (cmux#32416).

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

/// The person's login choice for a Cloud machine's harness: `cmux cloud start-session --login`,
/// or the one they made before, kept per user (Leo, 2026-11-01: sign in at most once per user).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Choice {
    /// Give the machine the person's own login (cmux's cached one, or a one-time `setup-token`).
    Pass,
    /// Use the machine's own login; refuse when it has none.
    Machine,
    /// Pass nothing: the machine stays as it is.
    None,
}

impl Choice {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pass => "pass",
            Self::Machine => "machine",
            Self::None => "none",
        }
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
    /// A start that may show no confirm (a CLI or agent run) and has no login to use and no
    /// choice: it stops at once with how to choose, never waiting on a prompt.
    #[serde(rename = "refuse")]
    Refuse,
    /// A Release build, before the person's first copy: show the one-time consent ("Use my Claude
    /// login on my own Cloud machines"), keep the answer per person, and install on yes.
    #[serde(rename = "ask-consent")]
    AskConsent,
}

impl Step {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Skip => "skip",
            Self::Install => "install",
            Self::ConfirmThenInstall => "confirm-then-install",
            Self::Refuse => "refuse",
            Self::AskConsent => "ask-consent",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Reason {
    /// This build passes no login (the app's `passesHarnessLogin`).
    #[serde(rename = "build-gate-off")]
    BuildGateOff,
    /// The chat's harness has no transfer here: pi and opencode none, and Codex in a Release build
    /// (its broker is DEV and dogfood only; the Release consent covers the Claude login alone).
    #[serde(rename = "no-transfer-for-harness")]
    NoTransfer,
    /// Codex: the Mac's broker gives the machine short-lived access before the first prompt. It
    /// shows its own device-code sign-in (with Cancel) only when the Mac holds no Codex login for
    /// this account yet; the refresh token stays on the Mac (cmux#33489).
    #[serde(rename = "codex-broker")]
    CodexBroker,
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
    /// The choice is `none`: nothing is passed.
    #[serde(rename = "chose-none")]
    ChoseNone,
    /// The choice is `machine` and the machine has no working login.
    #[serde(rename = "machine-login-missing")]
    MachineLoginMissing,
    /// The person's own `--login pass` is their confirm.
    #[serde(rename = "install-chosen")]
    InstallChosen,
    /// No login on the machine, none cached, no choice, and no confirm may be shown.
    #[serde(rename = "needs-login-choice")]
    NeedsLoginChoice,
    /// A Release build whose remote switch is off, or was not read: the machine shows the
    /// one-click "Sign in to Claude" instead (Leo, 2026-11-02, condition 3).
    #[serde(rename = "remote-switch-off")]
    RemoteSwitchOff,
    /// A Release build: the person has not said yes to the one-time consent yet.
    #[serde(rename = "consent-first")]
    ConsentFirst,
    /// A Release build: the person said no to the consent, or took it back in Settings.
    #[serde(rename = "consent-declined")]
    ConsentDeclined,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BuildGateOff => "build-gate-off",
            Self::NoTransfer => "no-transfer-for-harness",
            Self::CodexBroker => "codex-broker",
            Self::SignedOut => "signed-out",
            Self::CallerNotOwner => "caller-not-owner",
            Self::GuestNotOwner => "guest-not-owner",
            Self::GuestUnread => "guest-kind-unread",
            Self::MachineLoginKept => "machine-login-kept",
            Self::InstallCached => "install-cached",
            Self::ConfirmFirst => "confirm-first",
            Self::ChoseNone => "chose-none",
            Self::MachineLoginMissing => "machine-login-missing",
            Self::InstallChosen => "install-chosen",
            Self::NeedsLoginChoice => "needs-login-choice",
            Self::RemoteSwitchOff => "remote-switch-off",
            Self::ConsentFirst => "consent-first",
            Self::ConsentDeclined => "consent-declined",
        }
    }
}

/// What the start knows so far. Fields the start has not asked yet are absent.
///
/// The app sends the raw facts and this resolves them: `dogfood` (with `setting`) gives the gate,
/// `harness` the provider, `guest_stdout` the guest's kind and `machine_probe` the machine's login.
/// The resolved fields (`gate`, `provider`, `guest_kind`, `machine_login`) are taken as given when
/// their raw fact is absent.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Inputs {
    /// Whether this is a DEV or dogfood build; with it the gate is [`passes_harness_login`].
    pub dogfood: Option<bool>,
    /// The `cmux.cloud.passHarnessLogin` setting, absent when unset.
    pub setting: Option<bool>,
    pub gate: bool,
    /// The chat's harness ("" for none named): the provider is [`login_provider`]'s.
    pub harness: Option<String>,
    pub provider: Option<Provider>,
    pub signed_in: bool,
    /// Absent when not asked (an earlier check decided).
    pub caller_owns: Option<bool>,
    /// The stdout of [`GUEST_KIND_PROBE`] once it ran; absent when not run or the exec failed.
    pub guest_stdout: Option<String>,
    /// The guest's `/etc/cmux/vm-kind` ("" when missing); absent when not read or the read failed.
    pub guest_kind: Option<String>,
    /// The machine's login probe once it ran: the login is [`crate::machine_login::parse`]'s.
    pub machine_probe: Option<crate::machine_login::Probe>,
    pub machine_login: Option<MachineLogin>,
    pub cached: bool,
    /// What came of it once decided: "installed", "declined" (the confirm), or the transfer's fixed failure text.
    pub outcome: Option<String>,
    /// The run's `--login`; absent when not given.
    pub requested: Option<Choice>,
    /// Whether `requested` is the person's own (their terminal or the palette), not an agent's:
    /// only the person's `pass` stands in for the first-login confirm.
    pub requested_by_person: bool,
    /// The choice the person made before, kept per user; absent when none.
    pub stored: Option<Choice>,
    /// A run that may show no confirm (`cmux cloud start-session` from a CLI or an agent): where a
    /// confirm would be shown it refuses at once instead.
    pub headless: bool,
    /// A Release build's copy (resolved from `dogfood: false`): it needs `consent` and
    /// `remote_switch`, and goes only to an `owner` guest, never a team one.
    pub release: bool,
    /// The person's answer to the one-time Release consent, kept per person on the Mac: absent
    /// when never asked, false when declined or taken back in Settings.
    pub consent: Option<bool>,
    /// The backend's remote switch for the Release copy (cmux-platform
    /// `GET /v1/cloud/harness-login-copy`): absent when not read or stale, which counts as off.
    pub remote_switch: Option<bool>,
}

/// The decision and everything the app reads off it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub step: Step,
    pub reason: Reason,
    /// Whether this build passes a login (the resolved gate).
    pub gate: bool,
    /// The provider whose login the start passes; absent for a harness with no transfer.
    pub provider: Option<Provider>,
    /// The guest's kind as read ("" for none); absent when not read.
    pub guest_kind: Option<String>,
    /// The machine's login as read; absent when not read.
    pub machine_login: Option<MachineLogin>,
    /// What the start runs on the guest to read its kind ([`GUEST_KIND_PROBE`]), once `reads_machine`.
    pub guest_kind_probe: String,
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

/// Whether a guest of this kind takes the caller's login. A Release copy goes only to an `owner`
/// guest: "never on team machines, never shared" (Leo, 2026-11-02). So does Codex's broker access:
/// acpmux's Codex bridge refuses it on a team guest (`codex_auth_file`), where the team login stays.
fn guest_takes_login(kind: Option<&str>, release: bool, provider: Option<Provider>) -> bool {
    if release || provider == Some(Provider::Codex) {
        kind == Some("owner")
    } else {
        matches!(kind, Some("owner" | "team"))
    }
}

/// Whether the start passes this provider's login: Claude always (its gate decides), Codex only
/// outside Release, where the Mac's broker runs (cmux#33489: a Codex start that passed nothing
/// failed its first prompt until the turn card's broker sign-in).
fn transfers(d: &Inputs) -> bool {
    match d.provider {
        Some(Provider::Claude) => true,
        Some(Provider::Codex) => !d.release,
        None => false,
    }
}

fn step_and_reason(d: &Inputs) -> (Step, Reason) {
    // Codex's refresh token never leaves the Mac: the start runs its broker, which delivers only
    // short-lived access to the machine and renews it (CloudCodexBroker).
    // A Release copy is held by its setting and its remote switch whatever `gate` the caller sent
    // (a pre-resolved request with `release` and `gate` but no `dogfood` gets the same answer).
    if d.release && !release_passes_harness_login(d.setting, d.remote_switch) {
        let reason =
            if d.setting == Some(false) { Reason::BuildGateOff } else { Reason::RemoteSwitchOff };
        return (Step::Skip, reason);
    }
    if !d.gate {
        return (Step::Skip, Reason::BuildGateOff);
    }
    if !transfers(d) {
        return (Step::Skip, Reason::NoTransfer);
    }
    if !d.signed_in {
        return (Step::Skip, Reason::SignedOut);
    }
    let choice = choice(d);
    // `none` passes nothing, so it reads neither the owner nor the machine.
    if choice == Some(Choice::None) {
        return (Step::Skip, Reason::ChoseNone);
    }
    if d.caller_owns != Some(true) {
        return (Step::Skip, Reason::CallerNotOwner);
    }
    let Some(kind) = d.guest_kind.as_deref() else {
        return (Step::Skip, Reason::GuestUnread);
    };
    // The caller created the machine: an owner or team guest takes the login
    // (the transfer runs its creator allowance on a team guest).
    if !guest_takes_login(Some(kind), d.release, d.provider) {
        return (Step::Skip, Reason::GuestNotOwner);
    }
    if d.provider == Some(Provider::Codex) {
        // The machine keeps its own Codex sign-in when asked to; otherwise the broker runs. Its
        // device-code prompt is its own confirm (with Cancel), so no second one comes first, and a
        // run that may show no prompt passes nothing rather than refusing the start.
        let chose_pass = choice == Some(Choice::Pass)
            && (d.requested_by_person || d.stored == Some(Choice::Pass));
        return match choice {
            Some(Choice::Machine) => (Step::Skip, Reason::MachineLoginKept),
            _ if d.headless && !chose_pass => (Step::Skip, Reason::NeedsLoginChoice),
            _ => (Step::Install, Reason::CodexBroker),
        };
    }
    // A machine that already has a working login keeps it, whatever the choice.
    if !d.machine_login.is_none_or(MachineLogin::needs_login) {
        return (Step::Skip, Reason::MachineLoginKept);
    }
    if choice == Some(Choice::Machine) {
        return (Step::Refuse, Reason::MachineLoginMissing);
    }
    // Release: nothing is copied until the person has said yes to the one-time consent. No
    // `--login pass` or kept choice stands in for it, and a run that may show no prompt refuses.
    if d.release {
        match d.consent {
            Some(true) => {}
            Some(false) => return (Step::Skip, Reason::ConsentDeclined),
            None if d.headless => return (Step::Refuse, Reason::ConsentFirst),
            None => return (Step::AskConsent, Reason::ConsentFirst),
        }
        // The consent is the person's confirm: no second prompt before the copy.
        return (
            Step::Install,
            if d.cached { Reason::InstallCached } else { Reason::InstallChosen },
        );
    }
    if d.cached {
        (Step::Install, Reason::InstallCached)
    } else if choice == Some(Choice::Pass)
        && (d.requested_by_person || d.stored == Some(Choice::Pass))
    {
        // The person's own --login pass, or the pass they chose before (kept per user): their consent.
        // An agent's --login pass alone is not.
        (Step::Install, Reason::InstallChosen)
    } else if d.headless {
        (Step::Refuse, Reason::NeedsLoginChoice)
    } else {
        (Step::ConfirmThenInstall, Reason::ConfirmFirst)
    }
}

/// The choice in force: the run's `--login`, else the person's stored one.
fn choice(d: &Inputs) -> Option<Choice> {
    d.requested.or(d.stored)
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
    if let Some(choice) = choice(d) {
        line.push_str(", login ");
        line.push_str(choice.as_str());
    }
    if d.headless {
        line.push_str(", headless");
    }
    if d.release {
        line.push_str(", release consent ");
        line.push_str(word(d.consent));
        line.push_str(", switch ");
        line.push_str(word(d.remote_switch));
    }
    if let Some(outcome) = &d.outcome {
        line.push_str(" -> ");
        line.push_str(outcome);
    }
    line
}

/// Whether this build passes the harness login: only DEV and dogfood builds, never Release, and
/// in them the setting may turn it off (`defaults write ... cmux.cloud.passHarnessLogin -bool NO`
/// makes a DEV build behave as production). The setting never turns it on in Release: a Release
/// build never copies a subscription login off the Mac.
pub fn passes_harness_login(dogfood: bool, setting: Option<bool>) -> bool {
    dogfood && setting.unwrap_or(true)
}

/// Whether a Release build may copy the person's login (Leo, 2026-11-02, approving the copy in
/// Release on three conditions): only while the backend's remote switch says on (absent, unread
/// or stale is off), and the setting may still turn it off. The person's one-time consent is asked
/// after this, by [`decide`], and only where a copy would happen.
pub fn release_passes_harness_login(setting: Option<bool>, remote_switch: Option<bool>) -> bool {
    setting != Some(false) && remote_switch == Some(true)
}

/// `d` with its raw facts resolved into the fields the rules read.
fn resolved(d: &Inputs) -> Inputs {
    let mut d = d.clone();
    if let Some(dogfood) = d.dogfood {
        d.release = !dogfood;
        d.gate = if dogfood {
            passes_harness_login(true, d.setting)
        } else {
            release_passes_harness_login(d.setting, d.remote_switch)
        };
    }
    if let Some(harness) = d.harness.as_deref() {
        d.provider = login_provider(Some(harness));
    }
    if let Some(stdout) = d.guest_stdout.as_deref() {
        d.guest_kind = guest_kind(stdout);
    }
    if let Some(probe) = &d.machine_probe {
        d.machine_login = Some(crate::machine_login::parse(probe.exit_code, &probe.stdout));
    }
    d
}

/// The start's decision for these inputs.
pub fn decide(d: &Inputs) -> Decision {
    let d = &resolved(d);
    let (step, reason) = step_and_reason(d);
    let kind = d.guest_kind.as_deref();
    Decision {
        step,
        reason,
        gate: d.gate && (!d.release || release_passes_harness_login(d.setting, d.remote_switch)),
        provider: d.provider,
        guest_kind: d.guest_kind.clone(),
        machine_login: d.machine_login,
        guest_kind_probe: GUEST_KIND_PROBE.to_owned(),
        reads_machine: d.gate
            && (!d.release || release_passes_harness_login(d.setting, d.remote_switch))
            && transfers(d)
            && d.signed_in
            && d.caller_owns == Some(true)
            && choice(d) != Some(Choice::None),
        guest_takes_login: guest_takes_login(kind, d.release, d.provider),
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
