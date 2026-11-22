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

const OWN_EXECUTABLE_CHILD: &str = "CMUX_OWN_EXECUTABLE_TEST_OUT";

// Only the parent test below opts into this fixture: it writes what this process reads as its
// own executable and that executable's app bundle.
#[cfg(unix)]
#[test]
fn own_executable_fixture_child() {
    let Some(out) = std::env::var_os(OWN_EXECUTABLE_CHILD) else { return };
    let exe = own_executable().expect("own executable");
    let bundle = containing_bundle(&exe).map(|b| b.display().to_string()).unwrap_or_default();
    std::fs::write(out, format!("{}\n{bundle}", exe.display())).unwrap();
}

/// A daemon started by a link into the app (launchd's `~/.local/bin/acpmux`, which links into
/// `cmux NIGHTLY.app/Contents/Resources/bin`) reads the bundle the linked binary is in. Read
/// from `current_exe` it named no bundle, so a Team-signed daemon refused every
/// `person_enroll` ("this binary is not inside an app bundle") and the person's own composer
/// prompts drew as "Unverified sender" (Leo, 2026-11-12: "STOP CALLING ME ... UNVERIFIED ...
/// SENDER").
#[cfg(unix)]
#[test]
fn a_binary_started_by_a_link_reads_the_bundle_it_is_in() {
    let root = cmux_unix_socket::short_test_dir("ownexe");
    let root = std::fs::canonicalize(root.path()).unwrap();
    let bundle = root.join("cmux NIGHTLY.app");
    let bin = bundle.join("Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let inside = bin.join("acpmux");
    // Copied by a short-lived `cp`, never by this process: a sibling test that forks while this
    // process holds the copy's write descriptor hands it to its child until that child execs,
    // and running the copy in that window fails with ETXTBSY ("Text file busy").
    let copied = std::process::Command::new("/bin/cp")
        .arg(std::env::current_exe().unwrap())
        .arg(&inside)
        .status()
        .unwrap();
    assert!(copied.success(), "could not copy the test binary");
    let local_bin = root.join("local-bin");
    std::fs::create_dir_all(&local_bin).unwrap();
    let link = local_bin.join("acpmux");
    std::os::unix::fs::symlink(&inside, &link).unwrap();
    // What the old read saw: the link names no bundle.
    assert_eq!(containing_bundle(&link), None);

    let out = root.join("out.txt");
    let status = std::process::Command::new(&link)
        .args([
            "--exact",
            "app_caller::tests::own_executable_fixture_child",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(OWN_EXECUTABLE_CHILD, &out)
        .stdin(std::process::Stdio::null())
        .status()
        .expect("run the linked test binary");
    assert!(status.success());
    let text = std::fs::read_to_string(&out).expect("the child wrote its reading");
    let (exe, found) = text.split_once('\n').unwrap();
    assert_eq!(Path::new(exe), inside);
    assert_eq!(Path::new(found), bundle);
}
