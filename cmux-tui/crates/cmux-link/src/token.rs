//! The host side's check of a link token (cloud-client-contract.md 1.7: the
//! VM's endpoint checks `link_token` on `hello` and closes a link without a
//! valid one).
//!
//! The token format is not decided yet (a signed team-scoped token with a
//! single-use id, or an opaque token checked back at CloudDO). Both plug in
//! behind [`TokenVerifier`]. Until one ships, [`DenyAllTokens`] refuses every
//! token, so no Cloud host serves a link stream.
//!
//! The daemon's remote entry decides what a stamp's `check` means from
//! [`StampChecks`], fixed once at daemon start from the daemon's own config
//! ([`VERIFIER_ENV`]), never from a stamp or a stream. Without a real
//! verifier every `check` is malformed. A real verifier is refused at start
//! until the entry binds the check to the supervised link child (G1, Linux)
//! and records the token's issue time instead of the read time (G2, every
//! OS); see [`CheckBinding`].

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
}

/// Checks one token for one stream. A verifier must refuse a token used
/// twice (single use).
pub trait TokenVerifier: Send + Sync + 'static {
    /// The peer the token names, for the stamp, or why it was refused.
    fn verify(&self, token: &str, expected: &Expected<'_>) -> Result<LinkPeer, TokenRefused>;
}

/// The default: no token is valid.
pub struct DenyAllTokens;

impl TokenVerifier for DenyAllTokens {
    fn verify(&self, _token: &str, _expected: &Expected<'_>) -> Result<LinkPeer, TokenRefused> {
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
    /// This build: neither binding exists yet (F1 and F2 are open), so every
    /// real verifier is refused at daemon start.
    pub const BUILT: Self = Self { link_child: false, token_iat: false };
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
mod tests {
    use super::*;

    #[test]
    fn the_default_verifier_refuses_every_token() {
        let expected =
            Expected { host: "host_a", epoch: 1, service: Service::Daemon, peer_key: &[1; 32] };
        assert_eq!(DenyAllTokens.verify("anything", &expected), Err(TokenRefused::NoVerifier));
    }

    /// RED (security, decision 2): only the daemon's own config names a real
    /// verifier. An absent, unknown or unreadable value means no real
    /// verifier, and then every `check` is rejected.
    #[test]
    fn a_missing_unknown_or_unreadable_config_rejects_every_check() {
        use std::ffi::OsStr;
        #[cfg(unix)]
        let unreadable = {
            use std::os::unix::ffi::OsStrExt;
            OsStr::from_bytes(b"control_plane\xff").to_os_string()
        };
        #[cfg(not(unix))]
        let unreadable = std::ffi::OsString::from("control_plane ");
        let values = ["", "deny_all", "CONTROL_PLANE", "control_plane ", "true"];
        let values = values.iter().map(|value| Some(OsStr::new(*value)));
        for value in [None, Some(unreadable.as_os_str())].into_iter().chain(values) {
            let config = VerifierConfig::from_daemon_config(value);
            assert_eq!(config, VerifierConfig::DenyAll, "{value:?}");
            let checks = StampChecks::at_daemon_start(config).expect("deny-all always starts");
            assert!(!checks.records(), "{value:?}");
        }
        assert!(!StampChecks::default().records());
        assert_eq!(
            VerifierConfig::from_daemon_config(Some(OsStr::new("control_plane"))),
            VerifierConfig::ControlPlane
        );
    }

    /// RED (security, G1): on Linux a real verifier is refused at start
    /// while the entry does not bind `check` to the supervised link child.
    #[test]
    fn g1_linux_refuses_a_real_verifier_without_the_link_child_binding() {
        let iat_only = CheckBinding { link_child: false, token_iat: true };
        assert_eq!(
            StampChecks::decide(VerifierConfig::ControlPlane, true, iat_only),
            Err(VerifierRefused::LinkChildNotBound)
        );
        assert_eq!(
            StampChecks::decide(VerifierConfig::ControlPlane, true, CheckBinding::BUILT),
            Err(VerifierRefused::LinkChildNotBound)
        );
        if cfg!(any(target_os = "linux", target_os = "android")) {
            assert_eq!(
                StampChecks::at_daemon_start(VerifierConfig::ControlPlane),
                Err(VerifierRefused::LinkChildNotBound)
            );
        }
    }

    /// RED (security, G2): on every OS a real verifier is refused at start
    /// while the recorded check uses the read time instead of the token's
    /// issue time. With both bindings the guards pass (they are the only
    /// gate).
    #[test]
    fn g2_every_os_refuses_a_real_verifier_without_the_token_iat() {
        for linux in [false, true] {
            let child_only = CheckBinding { link_child: true, token_iat: false };
            assert_eq!(
                StampChecks::decide(VerifierConfig::ControlPlane, linux, child_only),
                Err(VerifierRefused::CheckTimeNotTokenIat)
            );
            let both = CheckBinding { link_child: true, token_iat: true };
            let checks = StampChecks::decide(VerifierConfig::ControlPlane, linux, both).unwrap();
            assert!(checks.records());
        }
        assert_eq!(
            StampChecks::decide(VerifierConfig::ControlPlane, false, CheckBinding::BUILT),
            Err(VerifierRefused::CheckTimeNotTokenIat)
        );
        assert!(StampChecks::at_daemon_start(VerifierConfig::ControlPlane).is_err());
    }

    /// RED (G3): the start log line names the mode and the reason, and
    /// never the raw value.
    #[test]
    fn g3_the_start_log_line_names_the_mode_and_reason_but_never_the_value() {
        use std::ffi::OsStr;
        let line = |value: Option<&str>| {
            let choice = VerifierChoice::from_daemon_config(value.map(OsStr::new));
            mode_log_line(choice, &StampChecks::at_daemon_start(choice.config))
        };
        assert_eq!(
            line(None),
            "cmux link: token verifier mode deny_all: CMUX_LINK_TOKEN_VERIFIER is not set"
        );
        assert_eq!(
            line(Some("deny_all")),
            "cmux link: token verifier mode deny_all: named by CMUX_LINK_TOKEN_VERIFIER"
        );
        let unknown = line(Some("hunter2-secret"));
        assert_eq!(
            unknown,
            "cmux link: token verifier mode deny_all: CMUX_LINK_TOKEN_VERIFIER holds an \
             unrecognized value (not shown)"
        );
        assert!(!unknown.contains("hunter2"));
        let control = line(Some("control_plane"));
        let refused = "cmux link: token verifier mode control_plane: refused at start: ";
        assert!(control.starts_with(refused), "{control}");
        assert!(control.contains("(G1)") || control.contains("(G2)"), "{control}");
        assert!(!line(None).contains('\n'));
    }
}
