//! Is a local socket peer the cmux app that contains this binary?
//! (P8 slice 3b-2, prover A of `verified_app`, plans/cmux-next/identity.md.)
//!
//! The peer is named by its AUDIT TOKEN only, read once with
//! `LOCAL_PEERTOKEN` when the connection is accepted. The token carries the
//! pid version, so a process that reuses a dead peer's pid has another
//! token and never passes; nothing here looks a process up by pid.
//!
//! A peer passes only when ALL hold:
//! - its effective uid is this process's effective uid;
//! - this binary is signed with a Team ID (an unsigned or ad-hoc development
//!   build has no prover A; it relies on the install-key proof);
//! - this binary sits inside an app bundle (`<X>.app/Contents/...`); the
//!   bundle's `CFBundleIdentifier` is the identifier the peer must have;
//! - the peer satisfies `anchor apple generic and certificate
//!   leaf[subject.OU] = "<team>" and identifier "<bundle id>"`.
//!
//! The identifier rule keeps out every other program the team signs: the
//! `cmux` CLI agents run, the remote sidecar, helper apps. The expected
//! identifier comes from this binary's own location, never from the peer.

use std::fmt;
use std::io;

/// A Unix socket peer's audit token (macOS `audit_token_t`).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct PeerToken(pub(crate) [u32; 8]);

impl fmt::Debug for PeerToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // pid and pid version only; the rest names the user's audit session.
        write!(formatter, "PeerToken(pid {}, version {})", self.0[5], self.0[7])
    }
}

impl PeerToken {
    /// The token's effective uid (`audit_token_to_euid`).
    pub fn euid(&self) -> u32 {
        self.0[1]
    }

    /// The same token with another pid version: a stand-in for a process
    /// that reused this pid. Tests only.
    #[doc(hidden)]
    pub fn with_pid_version_for_test(mut self, version: u32) -> Self {
        self.0[7] = version;
        self
    }
}

/// The audit token of the peer of a connected Unix socket. `None` off
/// macOS (no audit tokens) or when the kernel does not report one.
#[cfg(unix)]
pub fn peer_token(fd: std::os::fd::RawFd) -> Option<PeerToken> {
    #[cfg(target_os = "macos")]
    {
        crate::caller::macos::peer_audit_token(fd).ok().map(PeerToken)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = fd;
        None
    }
}

/// Why a peer is not the containing app.
#[derive(Debug)]
pub enum NotTheApp {
    /// No code signature prover on this platform or in this build.
    Unavailable(String),
    /// The peer runs as another user.
    OtherUser { uid: u32 },
    /// The peer's code does not satisfy the app requirement.
    Signature(String),
}

impl fmt::Display for NotTheApp {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable(why) => write!(formatter, "no code signature prover: {why}"),
            Self::OtherUser { uid } => write!(formatter, "peer runs as another user (uid {uid})"),
            Self::Signature(why) => write!(formatter, "peer is not the cmux app: {why}"),
        }
    }
}

impl std::error::Error for NotTheApp {}

impl From<NotTheApp> for io::Error {
    fn from(refused: NotTheApp) -> Self {
        io::Error::new(io::ErrorKind::PermissionDenied, refused.to_string())
    }
}

/// Accept `token` only when it names the signed cmux app that contains this
/// binary (module docs). Costs a few Security framework calls; callers
/// cache the answer per connection.
pub fn verify_containing_app(token: &PeerToken) -> Result<(), NotTheApp> {
    #[cfg(unix)]
    // SAFETY: geteuid has no preconditions.
    let own = unsafe { libc::geteuid() };
    #[cfg(not(unix))]
    let own = u32::MAX;
    if token.euid() != own {
        return Err(NotTheApp::OtherUser { uid: token.euid() });
    }
    #[cfg(target_os = "macos")]
    {
        crate::caller::macos::verify_app_token(&token.0)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(NotTheApp::Unavailable("audit tokens exist only on macOS".to_string()))
    }
}

/// Whether prover A applies to this process: a Team-signed binary inside a
/// signed app bundle (Release and signed builds). Checked once.
pub fn signed_app_build() -> bool {
    static SIGNED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *SIGNED.get_or_init(|| {
        #[cfg(target_os = "macos")]
        {
            crate::caller::macos::signed_inside_app()
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    })
}

/// `CFBundleIdentifier` characters allowed into the requirement text.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn plain_bundle_identifier(identifier: &str) -> bool {
    !identifier.is_empty()
        && identifier.len() <= 255
        && identifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-')
}

/// The app bundle that contains `executable`: the nearest ancestor named
/// `*.app` whose `Contents` directory holds the executable.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn containing_bundle(executable: &std::path::Path) -> Option<std::path::PathBuf> {
    executable
        .ancestors()
        .skip(1)
        .find(|candidate| {
            candidate.extension().is_some_and(|extension| extension == "app")
                && executable.starts_with(candidate.join("Contents"))
        })
        .map(std::path::Path::to_path_buf)
}

#[cfg(test)]
#[path = "app_caller_tests.rs"]
mod tests;
