//! The server tests' private socket ([`TestSocket`]) fits a Unix socket path
//! (104 bytes of `sun_path` on macOS) on any host, whatever `$TMPDIR` is. On
//! the fleet hosts after the private-TMPDIR fix (hq #4063, #4130) `$TMPDIR` is
//! long, and a socket under it with a long label did not fit, so the test
//! failed before it ran (step 11a0e7d25a7a0243c9bcffec).

use super::*;

/// The longest label a server test uses, with room to spare.
const LONG_LABEL: &str = "a-long-test-socket-label-for-the-sun-path-limit";
/// Set in the child run: make a [`TestSocket`] and stop.
const CHILD: &str = "CMUX_TEST_SOCKET_PATH_CHILD";

#[test]
fn a_test_socket_fits_a_unix_socket_path_under_a_long_tmpdir() {
    if std::env::var_os(CHILD).is_some() {
        let socket = TestSocket::new(LONG_LABEL);
        assert!(socket.path.exists() || socket.path.parent().is_some_and(Path::exists));
        let listener = transport::listen(&socket.path).expect("bind the test socket");
        drop(listener);
        return;
    }
    // A real directory whose path alone is longer than a socket path may be.
    let root = cmux_unix_socket::short_test_dir("tsp");
    let mut long = root.path().to_path_buf();
    while long.as_os_str().len() < 120 {
        long.push("a-private-tmpdir-segment");
    }
    std::fs::create_dir_all(&long).unwrap();
    // The test binary runs this test alone, with that TMPDIR.
    let exe = std::env::current_exe().unwrap();
    let output = std::process::Command::new(exe)
        .args([
            "--exact",
            "server::tests::test_socket_path::a_test_socket_fits_a_unix_socket_path_under_a_long_tmpdir",
            "--nocapture",
            "--test-threads",
            "1",
        ])
        .env("TMPDIR", &long)
        .env(CHILD, "1")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&output.stdout) + String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "a test socket under a long TMPDIR failed:\n{text}");
    assert!(text.contains("1 passed"), "the child run did not run the test:\n{text}");
}
