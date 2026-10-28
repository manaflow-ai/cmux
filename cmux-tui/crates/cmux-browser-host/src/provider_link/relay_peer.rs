//! Who may open a relay link (p01-process.md risk 6: the
//! provider credential is a new local attack surface, so the peer's audit
//! token and code signature are checked as well as the credential).
//!
//! The peer is named by its audit token (`LOCAL_PEERTOKEN`), never by pid, so
//! a process that reused a dead peer's pid never passes:
//! - a Team-signed build (Release, signed dev builds): the peer satisfies
//!   `anchor apple generic and certificate leaf[subject.OU] = "<this build's
//!   Team ID>"` (`cmux_link::caller::verify`, the link sockets' own check);
//! - an unsigned or ad-hoc build has no team to check: the peer's executable,
//!   read by its token (`proc_pidpath_audittoken`), lies in this binary's own
//!   app bundle (the Chromium Host is a nested app in it).
//!
//! Linux and other Unix systems have no code signature: the same-uid check at
//! accept (`server::serve_providers_notifying`) is the whole boundary there,
//! as for `cmux_link::caller`.

use std::fmt;
use std::os::unix::net::UnixStream;
use std::path::Path;

/// Why a relay link's peer was refused.
#[derive(Debug)]
pub enum RelayPeerRefused {
    /// A Team-signed build: the peer is not signed with this build's Team ID.
    Signature(String),
    /// An unsigned build: the peer's executable is not in this binary's app
    /// bundle, or either could not be read.
    OutsideBundle(String),
}

impl fmt::Display for RelayPeerRefused {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Signature(why) => write!(formatter, "relay peer is not signed as cmux: {why}"),
            Self::OutsideBundle(why) => {
                write!(formatter, "relay peer is not code of this cmux bundle: {why}")
            }
        }
    }
}

impl std::error::Error for RelayPeerRefused {}

/// Accepts the peer of a relay link only when it is code signed as this cmux
/// (module docs). A few Security framework calls, once per relay link.
pub fn verify_relay_peer(stream: &UnixStream) -> Result<(), RelayPeerRefused> {
    #[cfg(target_os = "macos")]
    {
        verify_macos(stream)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = stream;
        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn verify_macos(stream: &UnixStream) -> Result<(), RelayPeerRefused> {
    use std::os::fd::AsRawFd;
    if cmux_link::app_caller::signed_app_build() {
        return cmux_link::caller::verify(stream)
            .map_err(|refused| RelayPeerRefused::Signature(refused.to_string()));
    }
    let outside = |why: &str| RelayPeerRefused::OutsideBundle(why.to_owned());
    let token = cmux_link::app_caller::peer_token(stream.as_raw_fd())
        .ok_or_else(|| outside("the peer has no audit token"))?;
    let peer = cmux_link::app_caller::executable_path(&token)
        .ok_or_else(|| outside("the peer's executable cannot be read by its audit token"))?;
    let own = std::env::current_exe().map_err(|error| outside(&format!("current_exe: {error}")))?;
    let canonical =
        |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if same_app_bundle(&canonical(&own), &canonical(&peer)) {
        Ok(())
    } else {
        Err(outside(&format!("{} is outside this binary's app bundle", peer.display())))
    }
}

/// The outermost `*.app` directory that contains `path`.
fn outer_app_bundle(path: &Path) -> Option<&Path> {
    path.ancestors()
        .skip(1)
        .filter(|ancestor| ancestor.extension().is_some_and(|extension| extension == "app"))
        .last()
}

/// Whether `own` and `peer` are executables of one app bundle (nested
/// helper apps included). Two paths outside any bundle are not.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn same_app_bundle(own: &Path, peer: &Path) -> bool {
    match (outer_app_bundle(own), outer_app_bundle(peer)) {
        (Some(own), Some(peer)) => own == peer,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST: &str = "/Applications/cmux DEV x.app/Contents/Resources/bin/cmux-browser-host";

    #[test]
    fn the_chromium_host_in_the_same_bundle_is_the_same_cmux() {
        let chromium = "/Applications/cmux DEV x.app/Contents/Frameworks/cmux DEV x Chromium Host.app/Contents/MacOS/cmux DEV x Chromium Host";
        assert!(same_app_bundle(Path::new(HOST), Path::new(chromium)));
        assert!(same_app_bundle(
            Path::new(HOST),
            Path::new("/Applications/cmux DEV x.app/Contents/MacOS/cmux DEV x")
        ));
    }

    #[test]
    fn another_bundle_or_no_bundle_is_refused() {
        for peer in [
            "/Applications/cmux DEV y.app/Contents/MacOS/cmux DEV y",
            "/Applications/cmux DEV x.app.evil/Contents/MacOS/x",
            "/tmp/cmux DEV x.app-copy/Contents/MacOS/x",
            "/usr/bin/python3",
        ] {
            assert!(!same_app_bundle(Path::new(HOST), Path::new(peer)), "{peer}");
        }
        assert!(!same_app_bundle(Path::new("/usr/local/bin/h"), Path::new("/usr/local/bin/h")));
    }

    /// This test binary is neither Team-signed nor in an app bundle, so its
    /// own connection is refused as a relay peer.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_peer_outside_the_bundle_is_refused() {
        let (ours, _theirs) = UnixStream::pair().unwrap();
        assert!(verify_relay_peer(&ours).is_err());
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn without_code_signatures_the_same_user_is_the_boundary() {
        let (ours, _theirs) = UnixStream::pair().unwrap();
        assert!(verify_relay_peer(&ours).is_ok());
    }
}
