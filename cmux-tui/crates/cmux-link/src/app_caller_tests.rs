use super::*;
use std::path::{Path, PathBuf};

#[test]
fn the_containing_bundle_is_the_nearest_app_that_holds_the_binary() {
    let daemon = Path::new("/Applications/cmux.app/Contents/Resources/bin/cmux-tui");
    assert_eq!(containing_bundle(daemon), Some(PathBuf::from("/Applications/cmux.app")));
    let helper = Path::new("/A/cmux.app/Contents/Frameworks/H.app/Contents/MacOS/H");
    assert_eq!(
        containing_bundle(helper),
        Some(PathBuf::from("/A/cmux.app/Contents/Frameworks/H.app"))
    );
    assert_eq!(containing_bundle(Path::new("/usr/local/bin/cmux")), None);
    // A directory merely named like a bundle, without Contents, is not one.
    assert_eq!(containing_bundle(Path::new("/tmp/x.app/cmux-tui")), None);
}

#[test]
fn bundle_identifiers_are_plain() {
    assert!(plain_bundle_identifier("com.cmuxterm.app.debug.tag-1"));
    for bad in ["", "a\"b", "a b", "a\\b", "x\" or identifier \"y"] {
        assert!(!plain_bundle_identifier(bad), "{bad:?}");
    }
}

/// A test binary is not inside a signed app bundle, so it never proves
/// itself to itself, and a token of another uid is refused first.
#[cfg(unix)]
#[test]
fn a_test_binary_is_never_the_app() {
    use std::os::fd::AsRawFd;
    let (left, _right) = std::os::unix::net::UnixStream::pair().unwrap();
    let Some(token) = peer_token(left.as_raw_fd()) else {
        #[cfg(target_os = "macos")]
        panic!("macOS reports a peer audit token");
        #[cfg(not(target_os = "macos"))]
        return;
    };
    assert!(verify_containing_app(&token).is_err());
    let mut other = token;
    other.0[1] = other.0[1].wrapping_add(1);
    assert!(matches!(verify_containing_app(&other), Err(NotTheApp::OtherUser { .. })));
}

/// The prover resolves code by audit token: the same pid with another pid
/// version (a process that reused the pid) resolves to nothing.
#[cfg(target_os = "macos")]
#[test]
fn a_reused_pid_never_resolves_to_the_old_code() {
    use std::os::fd::AsRawFd;
    let (left, _right) = std::os::unix::net::UnixStream::pair().unwrap();
    let token = peer_token(left.as_raw_fd()).expect("audit token");
    crate::caller::macos::guest_for_test(&token.0).expect("the live token resolves");
    let reused = token.with_pid_version_for_test(token.0[7].wrapping_add(1));
    assert!(crate::caller::macos::guest_for_test(&reused.0).is_err());
}
