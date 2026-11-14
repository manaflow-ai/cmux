//! The host side's check of a link token (cloud-client-contract.md 1.7: the
//! VM's endpoint checks `link_token` on `hello` and closes a link without a
//! valid one).
//!
//! The control-plane verifier plugs in behind [`TokenVerifier`]. Until it
//! is composed into the production host, [`DenyAllTokens`] refuses every
//! token, so no Cloud host serves a link stream.
//!
//! The daemon's remote entry decides what a stamp's `check` means from
//! [`StampChecks`], fixed once at daemon start from the daemon's own config
//! ([`VERIFIER_ENV`]), never from a stamp or a stream. Without a real
//! verifier every `check` is malformed. A real verifier is refused at start
//! until the entry binds the check to the supervised link child (G1, Linux).
//! The entry records the signed issue time instead of the read time (G2,
//! every OS); see [`CheckBinding`].

use crate::dial::Service;
use crate::stamp::LinkPeer;

/// What the host expects a token to grant, from the stream it arrived on.
#[derive(Debug, Clone, Copy)]
pub struct Expected<'a> {
    /// This host's id.
    pub host: &'a str,
    /// This host's current epoch; the hello and the token must name it.
    pub epoch: u64,
    /// The service the hello asks for.
    pub service: Service,
    /// The WireGuard key of the session the stream came from.
    pub peer_key: &'a [u8; 32],
}

/// Why a token was refused. The host closes the stream and says nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenRefused {
    /// The hello had no token.
    Missing,
    /// The token does not verify, or names another host, epoch or install.
    Invalid,
    /// The token expired.
    Expired,
    /// The token was already used.
    Replayed,
    /// The token does not grant the requested service.
    ServiceNotAllowed,
    /// No token format is configured on this host.
    NoVerifier,
    /// The keyset owner may request its bounded unknown-kid refresh.
    UnknownKey,
    /// Replay storage is full of unexpired tokens; never evict a live id.
    ReplayCapacity,
}

impl TokenRefused {
    /// A stable snake_case name for logs and the dialer's refusal line.
    pub fn name(self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Invalid => "invalid",
            Self::Expired => "expired",
            Self::Replayed => "replayed",
            Self::ServiceNotAllowed => "service_not_allowed",
            Self::NoVerifier => "no_verifier",
            Self::UnknownKey => "unknown_key",
            Self::ReplayCapacity => "replay_capacity",
        }
    }
}

/// A refusal and the specific check that failed, for the host's log and the
/// dialer's refusal line. It never carries token, signature or key bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenRefusal {
    pub kind: TokenRefused,
    /// A stable snake_case name of the failed check (`issuer`, `audience`, ...).
    pub reason: &'static str,
    /// Non-secret context, such as the expected and received issuer.
    pub detail: Option<String>,
}

impl TokenRefusal {
    pub fn new(kind: TokenRefused, reason: &'static str) -> Self {
        Self { kind, reason, detail: None }
    }
}

impl From<TokenRefused> for TokenRefusal {
    fn from(kind: TokenRefused) -> Self {
        Self::new(kind, kind.name())
    }
}

impl std::fmt::Display for TokenRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}", self.reason)?;
        if let Some(detail) = &self.detail {
            write!(formatter, " ({detail})")?;
        }
        Ok(())
    }
}

/// Checks one token for one stream. A verifier must refuse a token used
/// twice (single use).
pub trait TokenVerifier: Send + Sync + 'static {
    /// Bound a connection before its hello arrives. This proves only that the
    /// authenticated transport peer is current; it grants no service and does
    /// not spend a token. Missing authority refuses before reading caller data.
    fn begin_handshake(
        &self,
        _host: &str,
        _epoch: u64,
        _peer_key: &[u8; 32],
    ) -> Result<crate::stream_lease::StreamLease, TokenRefused> {
        Err(TokenRefused::NoVerifier)
    }

    /// The peer and signed issue time, or why the token was refused.
    /// Never substitute the verification or stream-delivery time for `iat`.
    fn verify(&self, token: &str, expected: &Expected<'_>) -> Result<VerifiedToken, TokenRefused>;

    /// [`TokenVerifier::verify`] with the specific failed check. It accepts
    /// and refuses exactly the tokens `verify` does.
    fn verify_explained(
        &self,
        token: &str,
        expected: &Expected<'_>,
    ) -> Result<VerifiedToken, TokenRefusal> {
        self.verify(token, expected).map_err(TokenRefusal::from)
    }
}

/// The caller's machine role signed by CloudDO for this individual dial.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VmKind {
    Owner,
    Team,
}

/// Identity and issue time from an accepted token's authenticated claims.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedToken {
    pub peer: LinkPeer,
    /// Absent on old tokens; absence never grants an owner answer.
    pub vm_kind: Option<VmKind>,
    /// Unix milliseconds, converted from the verified JWT `iat` with checked arithmetic.
    pub issued_at_ms: u64,
    /// Live authority of this authenticated stream, acquired atomically with
    /// token verification. Missing authority never opens a receiving stream.
    pub lease: Option<crate::stream_lease::StreamLease>,
}

/// The default: no token is valid.
pub struct DenyAllTokens;

impl TokenVerifier for DenyAllTokens {
    fn verify(
        &self,
        _token: &str,
        _expected: &Expected<'_>,
    ) -> Result<VerifiedToken, TokenRefused> {
        Err(TokenRefused::NoVerifier)
    }
}

/// The daemon config entry that names its token verifier: an environment
/// variable of the daemon process, read once at daemon start.
pub const VERIFIER_ENV: &str = "CMUX_LINK_TOKEN_VERIFIER";

/// The token verifier the daemon's own config names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerifierConfig {
    /// [`DenyAllTokens`]: the default, and the value of an absent, unknown or
    /// unreadable config.
    DenyAll,
    /// A real verifier of control-plane link tokens (`control_plane`).
    ControlPlane,
}

impl VerifierConfig {
    /// The config from the raw value of [`VERIFIER_ENV`]. Only the exact
    /// value `control_plane` names a real verifier; an absent value, a value
    /// that is not UTF-8 and any other value give [`Self::DenyAll`].
    pub fn from_daemon_config(value: Option<&std::ffi::OsStr>) -> Self {
        match value.and_then(std::ffi::OsStr::to_str) {
            Some("control_plane") => Self::ControlPlane,
            _ => Self::DenyAll,
        }
    }
}

/// Why the daemon has its [`VerifierConfig`]: the reason in the start log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerifierReason {
    /// [`VERIFIER_ENV`] was not set.
    Absent,
    /// [`VERIFIER_ENV`] named a known mode.
    Named,
    /// [`VERIFIER_ENV`] held a value that is not UTF-8 or not a known mode.
    Unrecognized,
}

/// The daemon's verifier config and why it has it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VerifierChoice {
    pub config: VerifierConfig,
    pub reason: VerifierReason,
}

impl VerifierChoice {
    /// The choice for the raw value of [`VERIFIER_ENV`].
    pub fn from_daemon_config(value: Option<&std::ffi::OsStr>) -> Self {
        let reason = match value.map(|value| value.to_str()) {
            None => VerifierReason::Absent,
            Some(Some("control_plane" | "deny_all")) => VerifierReason::Named,
            Some(_) => VerifierReason::Unrecognized,
        };
        Self { config: VerifierConfig::from_daemon_config(value), reason }
    }
}

static DAEMON_CHOICE: std::sync::OnceLock<VerifierChoice> = std::sync::OnceLock::new();

/// Read [`VERIFIER_ENV`] once and remove it from this process's environment
/// (G4), so no terminal or other child inherits it. Later calls keep the
/// first choice. [`daemon_verifier_choice`] returns it.
///
/// # Safety
///
/// No other thread may run: removing an environment variable is unsound
/// while another thread can read the environment. `main` calls this as its
/// first statement.
pub unsafe fn take_from_process_env() {
    let choice = VerifierChoice::from_daemon_config(std::env::var_os(VERIFIER_ENV).as_deref());
    // SAFETY: the caller guarantees that no other thread runs.
    unsafe { std::env::remove_var(VERIFIER_ENV) };
    let _ = DAEMON_CHOICE.set(choice);
}

/// The choice [`take_from_process_env`] read at start; without that call
/// (tests, other entry points), no real verifier.
pub fn daemon_verifier_choice() -> VerifierChoice {
    DAEMON_CHOICE.get().copied().unwrap_or(VerifierChoice {
        config: VerifierConfig::DenyAll,
        reason: VerifierReason::Absent,
    })
}

/// The one start log line (G3): the mode and why, never a token, a secret
/// or the raw config value.
pub fn mode_log_line(
    choice: VerifierChoice,
    checks: &Result<StampChecks, VerifierRefused>,
) -> String {
    let mode = match choice.config {
        VerifierConfig::DenyAll => "deny_all",
        VerifierConfig::ControlPlane => "control_plane",
    };
    let reason = match (choice.reason, checks) {
        (_, Err(refused)) => format!("refused at start: {refused}"),
        (VerifierReason::Absent, Ok(_)) => format!("{VERIFIER_ENV} is not set"),
        (VerifierReason::Named, Ok(_)) => format!("named by {VERIFIER_ENV}"),
        (VerifierReason::Unrecognized, Ok(_)) => {
            format!("{VERIFIER_ENV} holds an unrecognized value (not shown)")
        }
    };
    format!("cmux link: token verifier mode {mode}: {reason}")
}

/// How this build binds a recorded check to its source and time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckBinding {
    /// G1: the entry accepts `check` only from the supervised link child
    /// (SO_PEERCRED pid and that process's start time). Linux needs it: there
    /// the same-user test is the whole caller check, so any same-user process
    /// can write a stamp.
    pub link_child: bool,
    /// G2: the recorded check uses the token's issue time (`iat`), not the
    /// time the entry read the stamp.
    pub token_iat: bool,
}

impl CheckBinding {
    /// The entry retains the signed issue time (G2). Linux still refuses a
    /// real verifier until it binds checked stamps to a supervised link (G1).
    pub const BUILT: Self = Self { link_child: false, token_iat: true };
}

/// Why the daemon refuses to start with a real token verifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerifierRefused {
    /// G1: on Linux the entry does not bind `check` to the link child.
    LinkChildNotBound,
    /// G2: the recorded check does not use the token's issue time.
    CheckTimeNotTokenIat,
}

impl std::fmt::Display for VerifierRefused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::LinkChildNotBound => {
                "link token verifier refused: the remote entry does not bind a check to the link process (G1)"
            }
            Self::CheckTimeNotTokenIat => {
                "link token verifier refused: a recorded check does not use the token issue time (G2)"
            }
        })
    }
}

impl std::error::Error for VerifierRefused {}

/// What the daemon's remote entry does with a stamp's `check`. Fixed at
/// daemon start ([`Self::at_daemon_start`]); the default rejects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StampChecks {
    records: bool,
}

impl StampChecks {
    /// The policy of a daemon that starts with `config`. A real verifier is
    /// refused (G1 on Linux, G2 on every OS) until this build binds the check
    /// ([`CheckBinding::BUILT`]).
    pub fn at_daemon_start(config: VerifierConfig) -> Result<Self, VerifierRefused> {
        let linux = cfg!(any(target_os = "linux", target_os = "android"));
        Self::decide(config, linux, CheckBinding::BUILT)
    }

    /// The policy for an entry that verifies every connection against this
    /// owned child. The caller must retain and use that same process handle
    /// in its entry verifier; an unsupervised entry uses `at_daemon_start`.
    #[cfg(unix)]
    pub fn at_supervised_daemon_start(
        config: VerifierConfig,
        _child: &crate::caller::SupervisedChild,
    ) -> Result<Self, VerifierRefused> {
        let linux = cfg!(any(target_os = "linux", target_os = "android"));
        Self::decide(config, linux, CheckBinding { link_child: true, ..CheckBinding::BUILT })
    }

    fn decide(
        config: VerifierConfig,
        linux: bool,
        binding: CheckBinding,
    ) -> Result<Self, VerifierRefused> {
        match config {
            VerifierConfig::DenyAll => Ok(Self { records: false }),
            VerifierConfig::ControlPlane => {
                if linux && !binding.link_child {
                    return Err(VerifierRefused::LinkChildNotBound);
                }
                if !binding.token_iat {
                    return Err(VerifierRefused::CheckTimeNotTokenIat);
                }
                Ok(Self { records: true })
            }
        }
    }

    /// True when the entry records a stamp's `check`; false when a stamp
    /// with any `check` is malformed (the entry closes the stream and
    /// records nothing).
    pub fn records(&self) -> bool {
        self.records
    }
}

#[cfg(test)]
mod tests;
