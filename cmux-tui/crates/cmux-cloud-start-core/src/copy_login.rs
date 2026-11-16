//! The harness login copy: the person's own Claude or Codex login, from this Mac onto a Cloud
//! machine they own (the app's `CloudCredentialTransfer`, `CloudCredentialInstaller`,
//! `CloudCredentialLogin`'s rules and `CloudLoginCopyGate`), in Rust with a test per case before
//! the app's copy is replaced (cloud-instant-start-v2; Leo's V0 item: "A chat starts in a few
//! seconds: ready spare, harness login attached in advance, no 10 s relay credential timeout, no
//! first-boot self-update.").
//!
//! Pure, like the start's sequencer ([`crate::sequence`]): the app sends the copy's state, one
//! event, its monotonic clock in milliseconds and the account and team it has now; this answers the
//! next state and the effects to run. The app runs each effect (the machine's exec and write, the
//! Keychain, the local sign-in, its ownership answer and its Release switch) and tells its end. The
//! order, the checks between them, the guest wait's budget, the refusals and the cleanup are here.
//!
//! A login never enters the state: [`Event::Loaded`] and [`Event::Acquired`] carry it once so it is
//! validated, and [`Effect::Write`] asks the app to write the one it holds. No effect or line here
//! carries a login; the staging path's name is the app's random id.
//!
//! Served to the app over the app FFI's JSON channel as ops `cloud_copy_login_*`
//! (`cmux-layout-reducer-ffi/src/cloud_copy_login.rs`).

use serde::{Deserialize, Serialize};

pub mod scripts;

/// Every machine exec of the copy is bounded by the machine route to this long.
pub const EXEC_TIMEOUT_MS: u64 = 20_000;
/// How many times the first guest check runs while the guest has no kind record yet.
pub const GUEST_CHECK_TRIES: u32 = 30;
/// How long the first guest check may take in all, slow execs and pauses included: about 90 s, the
/// journey's `waitPreflight` budget.
pub const GUEST_CHECK_BUDGET_MS: u64 = 90_000;
/// The pause between two guest checks: 3 s with the app's ±20% jitter, never above 3 s
/// (`Backoff(initial: 3 s, maximum: 3 s, multiplier: 1)`).
pub const GUEST_PAUSE_MIN_MS: u64 = 2_400;
pub const GUEST_PAUSE_MAX_MS: u64 = 3_000;
/// One Keychain read of the transfer cache before the login counts as unreadable.
pub const KEYCHAIN_READ_TIMEOUT_MS: u64 = 30_000;
/// The Keychain store (`cmux cloud secret set`) of a login just signed in.
pub const KEYCHAIN_STORE_TIMEOUT_MS: u64 = 70_000;
/// The local sign-in in a visible terminal (`claude setup-token`, `codex login --device-auth`).
pub const SIGN_IN_TIMEOUT_MS: u64 = 300_000;
/// The largest login the copy carries.
pub const MAX_CREDENTIAL_BYTES: usize = 12_000;
/// The largest stored envelope (`cmux cloud secret set`'s bound).
pub const MAX_ENVELOPE_BYTES: usize = 16_384;
/// The largest `setup-token` capture read for its token.
pub const MAX_SIGN_IN_OUTPUT_BYTES: usize = 262_144;
/// Exits 0 only while the guest has no kind record: its cmux-host writes it once it binds.
pub const KIND_MISSING: &str = "[ ! -s /etc/cmux/vm-kind ]";
/// The folder the login is staged in, `cmux`'s own 0700 folder the guest check made.
pub const STAGING_DIR: &str = "/home/cmux/.cmux/credential-transfer";
/// The staged file's mode: `cmux` reads it; its folder keeps everyone else out.
pub const STAGING_MODE: u32 = 0o644;
/// The Keychain service `cmux cloud secret set` stores the transfer cache under.
pub const KEYCHAIN_SERVICE: &str = "cmux-cloud-secret";
/// The keychain tool's exit status for no such item (errSecItemNotFound, 44 as an exit code).
pub const KEYCHAIN_ITEM_NOT_FOUND: i32 = 44;

/// Whose login.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Claude,
    Codex,
}

impl Provider {
    pub fn as_str(self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::Codex => "codex",
        }
    }
}

/// Why a copy stopped: the app's `CloudCredentialTransfer.Failure`, with its words.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Failure {
    ConsentRequired,
    ScopeChanged,
    SharedMachine,
    MachineNotReady,
    IncompatibleConfiguration,
    CopyTurnedOff,
    LocalLoginUnavailable,
    LoginFailed,
    InvalidCredential,
    StoreFailed,
    DeliveryFailed,
}

impl Failure {
    /// Every failure, in the app's order.
    pub const ALL: [Failure; 11] = [
        Failure::ConsentRequired,
        Failure::ScopeChanged,
        Failure::SharedMachine,
        Failure::MachineNotReady,
        Failure::IncompatibleConfiguration,
        Failure::CopyTurnedOff,
        Failure::LocalLoginUnavailable,
        Failure::LoginFailed,
        Failure::InvalidCredential,
        Failure::StoreFailed,
        Failure::DeliveryFailed,
    ];

    /// The fixed text the app shows and records; never a provider's output.
    pub fn message(self) -> &'static str {
        match self {
            Failure::ConsentRequired => {
                "Confirm this machine and provider before transferring credentials."
            }
            Failure::CopyTurnedOff => {
                "Copying your login to Cloud machines is off; sign in on the machine instead."
            }
            Failure::ScopeChanged => {
                "The signed-in account or Cloud team changed; start the transfer again."
            }
            Failure::SharedMachine => {
                "Personal credentials can only be transferred to a Cloud machine you own."
            }
            Failure::MachineNotReady => {
                "The Cloud machine is still setting up, so cmux can't confirm it's yours yet. Try again in a minute."
            }
            Failure::IncompatibleConfiguration => {
                "The target's provider configuration conflicts with own login."
            }
            Failure::LocalLoginUnavailable => "Open a local terminal to finish provider sign-in.",
            Failure::LoginFailed => "Provider sign-in did not complete; retry setup in cmux.",
            Failure::InvalidCredential => {
                "Provider sign-in returned an invalid credential; retry setup in cmux."
            }
            Failure::StoreFailed => "cmux could not store the new credential securely.",
            Failure::DeliveryFailed => {
                "The credential was not installed on the machine; retry setup in cmux."
            }
        }
    }
}

/// The start record's outcome when the copy was cancelled with its start.
pub const OUTCOME_CANCELLED: &str = "cancelled";
/// The start record's outcome before a failure's fixed text.
pub const OUTCOME_FAILED: &str = "failed: ";
/// The start record's outcome when the person said no.
pub const OUTCOME_DECLINED: &str = "declined";
/// The start record's outcome when a login was installed.
pub const OUTCOME_INSTALLED: &str = "installed";

/// What a copy that ended records (`CloudHarnessLoginDecision.loginOutcome`): `installed`,
/// `cancelled`, or `failed: ` and the failure's fixed text.
pub fn outcome(end: &End) -> String {
    match end {
        End::Installed => OUTCOME_INSTALLED.to_owned(),
        End::Cancelled => OUTCOME_CANCELLED.to_owned(),
        End::Failed { failure } => format!("{OUTCOME_FAILED}{}", failure.message()),
    }
}

/// What cmux holds of this account's login: one, none, or a Keychain that did not answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CachedLogin {
    Cached,
    None,
    Unreadable,
}

impl CachedLogin {
    /// A start's record when it passes nothing for want of a cached login; None when there is one.
    pub fn start_outcome(self) -> Option<&'static str> {
        match self {
            CachedLogin::Cached => None,
            CachedLogin::None => Some("no cached login: the chat's Sign in to Claude card"),
            CachedLogin::Unreadable => Some(
                "cached login unreadable (the Keychain did not answer): the chat's Sign in to Claude card",
            ),
        }
    }
}

/// One scope's Keychain read: a login, none, or the read failed (`failure`, the app's
/// `storeFailed` for a Keychain that did not answer, `invalidCredential` for a stored entry that is
/// not a login).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "read", rename_all = "lowercase")]
pub enum ScopeRead {
    Found { index: usize },
    Empty,
    Failed { failure: Failure },
}

/// The scopes a cached login is read under, in order: the selected team, then (Claude only: a Codex
/// login is per machine) the person's other scopes, each once (`CloudCredentialLogin.loadAny`).
pub fn login_scopes(
    provider: Provider,
    team: Option<&str>,
    other_teams: &[Option<String>],
) -> Vec<Option<String>> {
    let mut scopes = vec![team.map(str::to_owned)];
    if provider == Provider::Claude {
        for scope in other_teams {
            if !scopes.contains(scope) {
                scopes.push(scope.clone());
            }
        }
    }
    scopes
}

/// The answer of every scope's read, in [`login_scopes`] order: the first login found wins, so an
/// unreadable or invalid entry under the selected team never hides a good one elsewhere; else the
/// first scope's own answer (none, or its failure).
pub fn pick_cached(reads: &[ScopeRead]) -> ScopeRead {
    reads
        .iter()
        .find(|read| matches!(read, ScopeRead::Found { .. }))
        .or_else(|| reads.first())
        .cloned()
        .unwrap_or(ScopeRead::Empty)
}

/// [`pick_cached`]'s answer as the start reads it.
pub fn cached_login(pick: &ScopeRead) -> CachedLogin {
    match pick {
        ScopeRead::Found { .. } => CachedLogin::Cached,
        ScopeRead::Empty => CachedLogin::None,
        ScopeRead::Failed { .. } => CachedLogin::Unreadable,
    }
}

/// The Keychain item a cached login sits under (`CloudCredentialLogin.name`): the provider, then 12
/// bytes of SHA-256 of `user:team-or-personal:machine`, hex; the machine only for Codex. The item's
/// account is `*/` and this.
pub fn keychain_name(
    provider: Provider,
    team: Option<&str>,
    user: &str,
    machine: Option<&str>,
) -> String {
    use sha2::{Digest as _, Sha256};
    let vm = if provider == Provider::Codex { machine.unwrap_or("") } else { "" };
    let digest = Sha256::digest(format!("{user}:{}:{vm}", team.unwrap_or("personal")).as_bytes());
    let hex: String = digest.iter().take(12).map(|byte| format!("{byte:02x}")).collect();
    format!("{}_TRANSFER_{hex}", provider.as_str().to_uppercase())
}

/// The credential in a stored envelope (`{"created": T, "credential": BASE64}`, one line as
/// `security -w` prints it): `created` a positive number, `credential` strict base64. None for
/// anything else.
pub fn envelope(output: &[u8]) -> Option<Vec<u8>> {
    let mut body = output;
    while let Some((b'\n' | b'\r', rest)) = body.split_last() {
        body = rest;
    }
    let value: serde_json::Value = serde_json::from_slice(body).ok()?;
    let object = value.as_object()?;
    if object.get("created")?.as_f64()? <= 0.0 {
        return None;
    }
    base64_decode(object.get("credential")?.as_str()?)
}

/// Whether a stored envelope fits the store's bound.
pub fn envelope_fits(envelope: &[u8]) -> bool {
    envelope.len() <= MAX_ENVELOPE_BYTES
}

/// Strict standard base64 (padding required, no whitespace), as Foundation's
/// `Data(base64Encoded:)` reads it.
fn base64_decode(text: &str) -> Option<Vec<u8>> {
    fn value(byte: u8) -> Option<u32> {
        Some(match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    }
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let last = index + 1 == bytes.len() / 4;
        let pad = chunk.iter().rev().take_while(|byte| **byte == b'=').count();
        if pad > 2 || (pad > 0 && !last) {
            return None;
        }
        let mut word = 0u32;
        for byte in chunk.iter().take(4 - pad) {
            word = (word << 6) | value(*byte)?;
        }
        word <<= 6 * pad as u32;
        let decoded = [(word >> 16) as u8, (word >> 8) as u8, word as u8];
        out.extend(decoded.iter().take(3 - pad));
    }
    Some(out)
}

/// Whether `data` is a login the copy may carry (`CloudCredentialTransfer.validate`): at most
/// [`MAX_CREDENTIAL_BYTES`]; for Claude a `setup-token` login (`sk-ant-oat01-`, at least 32
/// printable ASCII bytes, no space); for Codex an `auth.json` with its three tokens and no API key.
pub fn validate(data: &[u8], provider: Provider) -> bool {
    if data.len() > MAX_CREDENTIAL_BYTES {
        return false;
    }
    match provider {
        Provider::Claude => {
            data.starts_with(b"sk-ant-oat01-")
                && data.len() >= 32
                && data.iter().all(|byte| (33..127).contains(byte))
        }
        Provider::Codex => {
            let Ok(serde_json::Value::Object(auth)) = serde_json::from_slice(data) else {
                return false;
            };
            if !matches!(auth.get("OPENAI_API_KEY"), None | Some(serde_json::Value::Null)) {
                return false;
            }
            let Some(tokens) = auth.get("tokens").and_then(serde_json::Value::as_object) else {
                return false;
            };
            ["access_token", "refresh_token", "id_token"].iter().all(|key| {
                tokens.get(*key).and_then(serde_json::Value::as_str).is_some_and(|v| !v.is_empty())
            })
        }
    }
}

/// The one Claude login `claude setup-token` printed into its private capture
/// (`CloudCredentialLogin.claudeToken`): every `sk-ant-oat01-` followed by 20 or more of
/// `[A-Za-z0-9_-]`; exactly one distinct token, else none. A capture above
/// [`MAX_SIGN_IN_OUTPUT_BYTES`] is refused.
pub fn claude_token(output: &[u8]) -> Option<Vec<u8>> {
    const PREFIX: &[u8] = b"sk-ant-oat01-";
    if output.len() > MAX_SIGN_IN_OUTPUT_BYTES {
        return None;
    }
    let word = |byte: &u8| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'-';
    let mut tokens: Vec<&[u8]> = Vec::new();
    let mut at = 0;
    while let Some(found) =
        output.get(at..).and_then(|rest| rest.windows(PREFIX.len()).position(|w| w == PREFIX))
    {
        let start = at + found;
        let body = start + PREFIX.len();
        let run = output.iter().skip(body).take_while(|byte| word(byte)).count();
        if run >= 20 {
            if let Some(token) = output.get(start..body + run)
                && !tokens.contains(&token)
            {
                tokens.push(token);
            }
            at = body + run;
        } else {
            at = start + 1;
        }
    }
    match tokens.as_slice() {
        [token] => Some(token.to_vec()),
        _ => None,
    }
}

/// A shell word: single-quoted, a quote inside closed, escaped and reopened.
pub fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// The guest check a copy runs before and after the login: the owner one, or with the DEV and
/// dogfood creator allowance an owner or team guest.
pub fn preflight(creator_team_guest: bool) -> &'static str {
    if creator_team_guest { scripts::CREATOR_TEAM_PREFLIGHT } else { scripts::PREFLIGHT }
}

/// The install of a staged login (`CloudCredentialInstaller.command`): the image's own-mode
/// normalization, then the installer for `provider`, reading `payload_path`, allowing an owner
/// guest (and a team one with the creator allowance). `account` is the cmux account (an id, never
/// the login): the same account's same login is left in place and answers success.
pub fn install_command(
    provider: Provider,
    payload_path: &str,
    creator_team_guest: bool,
    account: &str,
) -> String {
    format!(
        "set -e\n. /etc/cmux/agent-auth.sh\ncmux_agent_drop_model_plane_env\npython3 - {} {} {} {} <<'CMUX_CREDENTIAL_INSTALL'\n{}\nCMUX_CREDENTIAL_INSTALL",
        quote(provider.as_str()),
        quote(payload_path),
        if creator_team_guest { "owner,team" } else { "owner" },
        quote(account),
        scripts::install_script(),
    )
}

/// The removal of a staged login after a failed or stopped delivery.
pub fn cleanup_command(payload_path: &str) -> String {
    format!("rm -f -- {}", quote(payload_path))
}

/// The guest-kind line of the chat restart after a copy: the kinds the copy installs on.
pub fn restart_guest_check(creator_team_guest: bool) -> String {
    format!(
        r#"case "$(cat /etc/cmux/vm-kind 2>/dev/null)" in {}) ;; *) exit 1 ;; esac"#,
        if creator_team_guest { "owner|team" } else { "owner" }
    )
}

/// The Release copy's gate (`CloudLoginCopyGate`, Leo, 2026-11-02: consent first, your own token
/// to your own machine only, and a remote off switch). DEV and NIGHTLY builds (`dogfood`) keep
/// their own gate and read neither the switch nor the consent.
pub mod gate {
    use serde::{Deserialize, Serialize};

    /// The copy's last check before it writes ([`super::Effect::StillAllowed`]): in Release the
    /// switch read fresh is on and the consent is still yes.
    pub fn still_allowed(dogfood: bool, switch: Option<bool>, consent: Option<bool>) -> bool {
        dogfood || automatic_allowed(switch, consent)
    }

    /// Whether a copy that asks nobody may run now: the switch on and the consent already yes.
    pub fn automatic_allowed(switch: Option<bool>, consent: Option<bool>) -> bool {
        switch == Some(true) && consent == Some(true)
    }

    /// What a turn card's copy does now.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
    #[serde(rename_all = "lowercase")]
    pub enum Verdict {
        Allowed,
        /// Ask the one-time consent; its answer decides.
        Ask,
        Refused,
    }

    /// Whether a Release turn card may copy now (`copyAllowed`): the switch read fresh, then the
    /// kept consent, else ask once.
    pub fn copy_allowed(dogfood: bool, switch: Option<bool>, consent: Option<bool>) -> Verdict {
        if dogfood {
            return Verdict::Allowed;
        }
        if switch != Some(true) {
            return Verdict::Refused;
        }
        match consent {
            Some(true) => Verdict::Allowed,
            Some(false) => Verdict::Refused,
            None => Verdict::Ask,
        }
    }

    /// Whether a turn card's recovery may copy (`recoveryAllowed`): a dogfood build always; in
    /// Release Claude only, an automatic recovery never asking.
    pub fn recovery_allowed(
        dogfood: bool,
        claude: bool,
        automatic: bool,
        switch: Option<bool>,
        consent: Option<bool>,
    ) -> Verdict {
        if dogfood {
            return Verdict::Allowed;
        }
        if !claude {
            return Verdict::Refused;
        }
        if automatic {
            return if automatic_allowed(switch, consent) {
                Verdict::Allowed
            } else {
                Verdict::Refused
            };
        }
        copy_allowed(dogfood, switch, consent)
    }

    /// Whether this build may offer the copy at all (`offersLoginCopy`): a dogfood build by its
    /// gate; Release unless `cmux.cloud.passHarnessLogin` is NO.
    pub fn offers_login_copy(dogfood: bool, dogfood_gate: bool, setting: Option<bool>) -> bool {
        if dogfood { dogfood_gate } else { setting != Some(false) }
    }

    /// Whether a team guest whose creator is the caller may take the login, and whether a copy asks
    /// no consent (`allowsCreatorTeamGuest`, `copiesWithoutConsent`): a dogfood build with its gate on.
    pub fn dogfood_only(dogfood: bool, dogfood_gate: bool) -> bool {
        dogfood && dogfood_gate
    }
}

/// A spare warm's end (`CloudSpareWarm`): the copy's own answer while the account and team that
/// asked are still the app's, else abandoned (Rust answers that machine's copy again).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WarmEnd {
    Finished,
    Installed,
    Verified,
    Abandoned,
}

/// The end a spare warm reports for `result`, read once the copy is over.
pub fn warm_end(result: WarmEnd, still: bool) -> WarmEnd {
    if still { result } else { WarmEnd::Abandoned }
}

/// The account and team the app has now.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Scope {
    pub team_id: Option<String>,
    pub user_id: Option<String>,
}

/// A guest check the start ran just before, beside its machine reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GuestCheck {
    pub machine_id: String,
    #[serde(default)]
    pub team_id: Option<String>,
    /// When it passed, on the app's monotonic clock in milliseconds.
    pub at: u64,
}

/// One copy, as the app asks it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub provider: Provider,
    pub machine_id: String,
    /// None: the account's personal Cloud scope.
    #[serde(default)]
    pub team_id: Option<String>,
    pub user_id: String,
    /// The person confirmed this machine and provider.
    pub confirmed: bool,
    /// Sign in again instead of reading the cache (Retry after a rejected login).
    #[serde(default)]
    pub refresh: bool,
    /// DEV and dogfood only: a team guest whose creator is the caller may take it.
    #[serde(default)]
    pub creator_team_guest: bool,
    /// The start's own guest check, taken as the first one when it is this machine's and team's
    /// and recent; never with the creator allowance.
    #[serde(default)]
    pub guest_checked: Option<GuestCheck>,
    /// The staged file's name: the app's random id, letters, digits and dashes only.
    pub staging_id: String,
}

/// Where the copy is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Phase {
    #[default]
    Idle,
    Owns,
    Guest,
    KindMissing,
    Pause,
    Load,
    Acquire,
    Store,
    Reowns,
    Recheck,
    StillAllowed,
    Write,
    Install,
    Cleanup,
    Ended,
}

/// The copy's state: the app keeps it between calls and sends it with each event. It holds no login.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub copy: Option<Request>,
    pub phase: Phase,
    /// The guest wait's attempt (from 1) and its deadline.
    pub attempt: u32,
    pub deadline: u64,
    /// When the guest check the login is delivered on passed.
    pub checked: u64,
    /// The login came from the cache, not a sign-in.
    pub from_cache: bool,
    /// The staged file's path, once the write began.
    pub staged: Option<String>,
    /// The end a cleanup reports once its exec answers.
    pub ending: Option<End>,
}

/// How a copy ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "end", rename_all = "lowercase")]
pub enum End {
    Installed,
    Failed {
        failure: Failure,
    },
    /// Cancelled with its start: no failure is recorded.
    Cancelled,
}

/// One thing that happened, as the app tells it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "on", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    /// Begin `copy`; a copy under way ignores it.
    Begin {
        copy: Request,
    },
    /// [`Effect::CallerOwns`]'s answer: the platform says the caller owns the machine.
    Owns {
        owns: bool,
    },
    /// [`Effect::Exec`]'s exit code.
    Exec {
        exit: i64,
    },
    /// The effect's `cutoffMs` passed before it answered; the app cancelled it.
    Cutoff,
    /// [`Effect::Pause`] is over.
    Paused,
    /// [`Effect::Load`]'s answer ([`pick_cached`]'s): the login (validated here, never kept) or none.
    Loaded {
        #[serde(default)]
        credential: Option<Vec<u8>>,
    },
    /// [`Effect::Acquire`]'s login.
    Acquired {
        credential: Vec<u8>,
    },
    Stored,
    /// [`Effect::StillAllowed`]'s answer.
    Allowed {
        allowed: bool,
    },
    Written,
    /// The running effect threw: `failure` when it is one of the copy's own (a Keychain that did not
    /// answer is `store_failed`, a sign-in that did not finish `login_failed`), else none.
    Threw {
        #[serde(default)]
        failure: Option<Failure>,
    },
    /// The copy's task was cancelled.
    Cancelled,
}

/// What the app does next.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Effect {
    /// Ask the platform whether the caller owns the machine (never a guest file).
    CallerOwns,
    /// One exec on the machine, its route bounded to `timeoutMs`; with `cutoffMs`, cancel it then
    /// and answer [`Event::Cutoff`].
    Exec {
        command: String,
        timeout_ms: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cutoff_ms: Option<u64>,
    },
    /// Wait a random time in `minMs..=maxMs`, or until `cutoffMs` ([`Event::Cutoff`]).
    Pause { min_ms: u64, max_ms: u64, cutoff_ms: u64 },
    /// Read the cached login under each scope at once (each read bounded to `timeoutMs`) and answer
    /// [`pick_cached`]'s login.
    Load { provider: Provider, timeout_ms: u64 },
    /// Sign in locally in a visible terminal, bounded to `timeoutMs`.
    Acquire { provider: Provider, timeout_ms: u64 },
    /// Keep the login just signed in, bounded to `timeoutMs` (Claude only: a Codex login is never kept).
    Store { timeout_ms: u64 },
    /// Read the Release switch and the consent again ([`gate::still_allowed`]).
    StillAllowed,
    /// Write the login the app holds at `path`, mode `mode`.
    Write { path: String, mode: u32 },
    /// One split of the copy's time (`transfer.guest`, `transfer.load`, ...).
    Mark { name: String },
    /// The copy is over.
    Finish {
        #[serde(flatten)]
        end: End,
        outcome: String,
    },
}

/// The next state and the effects to run, in order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answer {
    pub state: State,
    pub effects: Vec<Effect>,
}

/// One event at `now` (the app's monotonic clock, in milliseconds), with the account and team the
/// app has at that moment.
pub fn step(mut state: State, event: Event, now: u64, scope: &Scope) -> Answer {
    let mut effects = Vec::new();
    if state.phase == Phase::Ended {
        return Answer { state, effects };
    }
    if let Event::Begin { copy } = event {
        if state.phase == Phase::Idle {
            begin(&mut state, copy, now, scope, &mut effects);
        }
        return Answer { state, effects };
    }
    let Some(copy) = state.copy.clone() else {
        return Answer { state, effects };
    };
    let mut run = Run { state: &mut state, copy: &copy, now, scope, effects: &mut effects };
    if let Event::Cancelled = event {
        run.stop(End::Cancelled);
    } else {
        run.on(event);
    }
    Answer { state, effects }
}

fn staging_id_ok(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn begin(state: &mut State, copy: Request, now: u64, scope: &Scope, effects: &mut Vec<Effect>) {
    state.copy = Some(copy.clone());
    let mut run = Run { state, copy: &copy, now, scope, effects };
    if !copy.confirmed {
        return run.fail(Failure::ConsentRequired);
    }
    if !staging_id_ok(&copy.staging_id) {
        return run.fail(Failure::DeliveryFailed);
    }
    if !run.in_scope() {
        return run.fail(Failure::ScopeChanged);
    }
    run.go(Phase::Owns, Effect::CallerOwns);
}

struct Run<'a> {
    state: &'a mut State,
    copy: &'a Request,
    now: u64,
    scope: &'a Scope,
    effects: &'a mut Vec<Effect>,
}

impl Run<'_> {
    /// `CloudCredentialTransfer.checkScope`: the same machine, account and team as when it began.
    fn in_scope(&self) -> bool {
        !self.copy.machine_id.is_empty()
            && !self.copy.user_id.is_empty()
            && self.scope.team_id == self.copy.team_id
            && self.scope.user_id.as_deref() == Some(self.copy.user_id.as_str())
    }

    fn go(&mut self, phase: Phase, effect: Effect) {
        self.state.phase = phase;
        self.effects.push(effect);
    }

    fn mark(&mut self, name: &str) {
        self.effects.push(Effect::Mark { name: name.to_owned() });
    }

    fn exec(&mut self, phase: Phase, command: String, cutoff_ms: Option<u64>) {
        self.go(phase, Effect::Exec { command, timeout_ms: EXEC_TIMEOUT_MS, cutoff_ms });
    }

    fn preflight(&self) -> String {
        preflight(self.copy.creator_team_guest).to_owned()
    }

    fn finish(&mut self, end: End) {
        self.state.phase = Phase::Ended;
        self.state.ending = None;
        let outcome = outcome(&end);
        self.effects.push(Effect::Finish { end, outcome });
    }

    fn fail(&mut self, failure: Failure) {
        self.finish(End::Failed { failure });
    }

    /// Ends the copy: once its write began, the staged file is removed first, whatever stopped it
    /// (a cancelled caller's cleanup still runs), and a failure there is the delivery's.
    fn stop(&mut self, end: End) {
        if self.state.phase == Phase::Cleanup {
            // Already removing: a cancel keeps the end it has, and is reported as one.
            if end == End::Cancelled {
                self.state.ending = Some(End::Cancelled);
            }
            return;
        }
        match self.state.staged.clone() {
            Some(path) if matches!(self.state.phase, Phase::Write | Phase::Install) => {
                let end = match end {
                    End::Cancelled => End::Cancelled,
                    _ => End::Failed { failure: Failure::DeliveryFailed },
                };
                self.state.ending = Some(end);
                self.exec(Phase::Cleanup, cleanup_command(&path), None);
            }
            _ => self.finish(end),
        }
    }

    /// A failure as `run` rethrows it: the copy's own failures as they are, anything else the
    /// delivery's.
    fn threw(&mut self, failure: Option<Failure>) {
        self.stop(End::Failed { failure: failure.unwrap_or(Failure::DeliveryFailed) });
    }

    /// The guest wait's deadline left, None once it passed.
    fn left(&self) -> Option<u64> {
        self.state.deadline.checked_sub(self.now).filter(|left| *left > 0)
    }

    fn guest_attempt(&mut self) {
        match self.left() {
            Some(left) => self.exec(Phase::Guest, self.preflight(), Some(left)),
            None => self.fail(Failure::MachineNotReady),
        }
    }

    fn guest_passed(&mut self) {
        self.state.checked = self.now;
        self.after_guest();
    }

    fn after_guest(&mut self) {
        self.mark("transfer.guest");
        if !self.in_scope() {
            return self.fail(Failure::ScopeChanged);
        }
        if self.copy.refresh || self.copy.provider == Provider::Codex {
            // Codex `auth.json` is never reused: its refresh token is bound to one machine.
            self.acquire();
        } else {
            self.go(
                Phase::Load,
                Effect::Load { provider: self.copy.provider, timeout_ms: KEYCHAIN_READ_TIMEOUT_MS },
            );
        }
    }

    fn acquire(&mut self) {
        self.state.from_cache = false;
        self.go(
            Phase::Acquire,
            Effect::Acquire { provider: self.copy.provider, timeout_ms: SIGN_IN_TIMEOUT_MS },
        );
    }

    fn have_login(&mut self, credential: &[u8]) {
        if !self.in_scope() {
            return self.fail(Failure::ScopeChanged);
        }
        if !validate(credential, self.copy.provider) {
            return self.fail(Failure::InvalidCredential);
        }
        if !self.state.from_cache && self.copy.provider == Provider::Claude {
            self.go(Phase::Store, Effect::Store { timeout_ms: KEYCHAIN_STORE_TIMEOUT_MS });
        } else {
            self.loaded();
        }
    }

    fn loaded(&mut self) {
        self.mark("transfer.load");
        if !self.in_scope() {
            return self.fail(Failure::ScopeChanged);
        }
        self.go(Phase::Reowns, Effect::CallerOwns);
    }

    fn allowed(&mut self) {
        self.mark("transfer.recheck");
        if !self.in_scope() {
            return self.fail(Failure::ScopeChanged);
        }
        let path = format!("{STAGING_DIR}/{}.json", self.copy.staging_id);
        self.state.staged = Some(path.clone());
        self.go(Phase::Write, Effect::Write { path, mode: STAGING_MODE });
    }

    fn on(&mut self, event: Event) {
        let phase = self.state.phase;
        match (phase, event) {
            // The cleanup's exec answered, failed or ran out: its result is ignored.
            (Phase::Cleanup, Event::Exec { .. } | Event::Cutoff | Event::Threw { .. }) => {
                let end = self
                    .state
                    .ending
                    .clone()
                    .unwrap_or(End::Failed { failure: Failure::DeliveryFailed });
                self.finish(end);
            }
            (_, Event::Threw { failure }) => self.threw(failure),
            (Phase::Owns, Event::Owns { owns }) => {
                if !owns {
                    return self.fail(Failure::SharedMachine);
                }
                let reuse = (!self.copy.creator_team_guest)
                    .then_some(self.copy.guest_checked.as_ref())
                    .flatten()
                    .filter(|check| {
                        check.machine_id == self.copy.machine_id
                            && check.team_id == self.copy.team_id
                            && self.now.saturating_sub(check.at)
                                <= crate::sequence::RECHECK_AFTER_MS
                    })
                    .map(|check| check.at);
                if let Some(at) = reuse {
                    self.state.checked = at;
                    return self.after_guest();
                }
                self.state.attempt = 1;
                self.state.deadline = self.now + GUEST_CHECK_BUDGET_MS;
                self.guest_attempt();
            }
            (Phase::Guest, Event::Exec { exit }) => {
                if exit == 0 {
                    return self.guest_passed();
                }
                match self.left() {
                    Some(left) => {
                        self.exec(Phase::KindMissing, KIND_MISSING.to_owned(), Some(left));
                    }
                    None => self.fail(Failure::MachineNotReady),
                }
            }
            (Phase::KindMissing, Event::Exec { exit }) => {
                if exit != 0 {
                    // A kind record that fails the check is the guest's answer.
                    return self.fail(Failure::SharedMachine);
                }
                match self.left() {
                    Some(left) if self.state.attempt < GUEST_CHECK_TRIES => self.go(
                        Phase::Pause,
                        Effect::Pause {
                            min_ms: GUEST_PAUSE_MIN_MS,
                            max_ms: GUEST_PAUSE_MAX_MS,
                            cutoff_ms: left,
                        },
                    ),
                    _ => self.fail(Failure::MachineNotReady),
                }
            }
            (Phase::Guest | Phase::KindMissing | Phase::Pause, Event::Cutoff) => {
                self.fail(Failure::MachineNotReady);
            }
            (Phase::Pause, Event::Paused) => {
                if !self.in_scope() {
                    return self.fail(Failure::ScopeChanged);
                }
                self.state.attempt += 1;
                self.guest_attempt();
            }
            (Phase::Load, Event::Loaded { credential }) => match credential {
                Some(credential) => {
                    self.state.from_cache = true;
                    self.have_login(&credential);
                }
                None => {
                    if !self.in_scope() {
                        return self.fail(Failure::ScopeChanged);
                    }
                    self.acquire();
                }
            },
            (Phase::Acquire, Event::Acquired { credential }) => self.have_login(&credential),
            (Phase::Store, Event::Stored) => self.loaded(),
            (Phase::Reowns, Event::Owns { owns }) => {
                if !owns {
                    return self.fail(Failure::SharedMachine);
                }
                let since = self.now.saturating_sub(self.state.checked);
                if crate::sequence::recheck_guest(self.state.from_cache, since) {
                    self.exec(Phase::Recheck, self.preflight(), None);
                } else {
                    self.go(Phase::StillAllowed, Effect::StillAllowed);
                }
            }
            (Phase::Recheck, Event::Exec { exit }) => {
                if exit != 0 {
                    return self.fail(Failure::SharedMachine);
                }
                self.go(Phase::StillAllowed, Effect::StillAllowed);
            }
            (Phase::StillAllowed, Event::Allowed { allowed }) => {
                if !allowed {
                    return self.fail(Failure::CopyTurnedOff);
                }
                self.allowed();
            }
            (Phase::Write, Event::Written) => {
                self.mark("transfer.write");
                if !self.in_scope() {
                    return self.stop(End::Failed { failure: Failure::DeliveryFailed });
                }
                let path = self.state.staged.clone().unwrap_or_default();
                let command = install_command(
                    self.copy.provider,
                    &path,
                    self.copy.creator_team_guest,
                    &self.copy.user_id,
                );
                self.exec(Phase::Install, command, None);
            }
            (Phase::Install, Event::Exec { exit }) => {
                if exit != 0 {
                    // 70, 71 and 72 alike: the installer's output may hold a provider diagnostic,
                    // never surfaced.
                    return self.stop(End::Failed { failure: Failure::DeliveryFailed });
                }
                self.mark("transfer.install");
                self.finish(End::Installed);
            }
            // An answer the copy did not ask for: it fails closed.
            _ => self.stop(End::Failed { failure: Failure::DeliveryFailed }),
        }
    }
}

#[cfg(test)]
mod tests;
