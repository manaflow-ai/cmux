//! The device hub client for cmux-tui on Windows and Linux
//! (`docs/device-hub/PROTOCOL.md`): the device's keys and identity, signed
//! requests, the HTTP API, the User DO socket, and Computer Use approvals
//! asked of the user's Mac or iPhone and checked here before they apply
//! (`docs/computer-use-approvals.md`, "Device hub approvals").
//!
//! Request and decision signatures match the Swift `CmuxDeviceHub` byte for
//! byte; `schemas/device-hub/test-vectors.json` is the shared conformance set.

pub mod approval;
pub mod approver;
pub mod canonical;
pub mod client;
pub mod error;
pub mod identity;
pub mod signing;
pub mod socket;

pub use approval::{
    ApprovalRequest, ApprovalState, ApprovalTarget, Decision, DecisionEvidence, Expectation,
    HubApproval, KnownDevice, PinnedApprover, Rejection, VerifiedDecision, decision_message,
    display_fingerprint, key_fingerprint, pin_of, verify_decision,
};
pub use approver::{
    ApprovalAsk, ApprovalOutcome, HubApprover, LateDecisionHandler, NoHubApprover, RemoteApprover,
};
pub use client::{
    AccountSession, CommandToken, Handshake, HubClient, HubClientConfig, HubDevice, HubMe,
    StackTokenSource, StaticToken,
};
pub use error::{ErrorCode, HubError};
pub use identity::{
    Assurance, DeviceIdentity, DeviceKeys, FileKeyStore, IdentityError, KeyStore, Platform,
    SoftwareKeys,
};
pub use socket::{Backoff, HubPush, PING_FRAME, SocketEvent, SocketOptions, UserSocket};

/// This machine's key store under `dir` (the cmux-tui state directory):
/// Windows CNG (TPM, else the software provider); on Linux the Secret Service,
/// else a 0600 key file; elsewhere the key file.
pub fn default_key_store(dir: &std::path::Path) -> Box<dyn KeyStore> {
    #[cfg(windows)]
    {
        Box::new(identity::CngKeyStore::new(dir, "default"))
    }
    #[cfg(target_os = "linux")]
    {
        Box::new(identity::LinuxKeyStore::new(dir, "default"))
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Box::new(FileKeyStore::new(dir, Platform::host()))
    }
}

/// Where this user's device identity lives when no Secret Service or CNG key
/// holds it, shared by the `cmux` CLI (`computer-use setup`) and the cmux
/// Remote host so both are the same device: `$XDG_STATE_HOME/cmux/device-hub`
/// (else `~/.local/state/cmux/device-hub`), `%LOCALAPPDATA%\cmux\device-hub` on Windows.
pub fn default_identity_dir() -> Option<std::path::PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(|base| std::path::PathBuf::from(base).join("cmux").join("device-hub"))
    }
    #[cfg(not(windows))]
    {
        let state = std::env::var_os("XDG_STATE_HOME")
            .map(std::path::PathBuf::from)
            .filter(|path| path.is_absolute())
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(|home| std::path::PathBuf::from(home).join(".local").join("state"))
            })?;
        Some(state.join("cmux").join("device-hub"))
    }
}
