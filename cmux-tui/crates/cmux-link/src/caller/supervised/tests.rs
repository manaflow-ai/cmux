use super::*;
use cmux_process::{Command, Stdio};
use std::io::{Read as _, Write as _};

const FIXTURE_SOCKET: &str = "CMUX_SUPERVISED_CHILD_TEST_SOCKET";

// Re-exec this test binary, preserving the same macOS code identity. Only
// that child connects, after spawn, so SO_PEERCRED names the writer itself.
#[test]
fn supervised_link_child_fixture() {
    let Some(path) = std::env::var_os(FIXTURE_SOCKET) else { return };
    let mut stream = cmux_unix_socket::connect(std::path::Path::new(&path)).unwrap();
    stream.write_all(b"ready").unwrap();
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    let mut finish = [0];
    stream.read_exact(&mut finish).unwrap();
    assert_eq!(finish, [b'1']);
}

fn connected_child() -> (SupervisedChild, UnixStream, cmux_unix_socket::TestDir) {
    let directory = cmux_unix_socket::short_test_dir("slc");
    let path = directory.path().join("c.sock");
    let listener = cmux_unix_socket::bind(&path).unwrap();
    let child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "caller::supervised::tests::supervised_link_child_fixture"])
        .env(FIXTURE_SOCKET, &path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let owned = SupervisedChild::capture(child).unwrap();
    let mut poll = libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: one initialized pollfd is writable for the given length.
    assert_eq!(unsafe { libc::poll(&raw mut poll, 1, 10_000) }, 1, "child did not connect");
    let (mut stream, _) = listener.accept().unwrap();
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    let mut ready = [0; 5];
    stream.read_exact(&mut ready).unwrap();
    assert_eq!(&ready, b"ready");
    (owned, stream, directory)
}

#[test]
fn supervised_link_accepts_only_the_live_child_and_enables_its_stamp_policy() {
    let (child, mut stream, _directory) = connected_child();
    child.verify(&stream).unwrap();
    assert!(
        crate::token::StampChecks::at_supervised_daemon_start(
            crate::token::VerifierConfig::ControlPlane,
            &child
        )
        .unwrap()
        .records()
    );
    let (other, _keep) = UnixStream::pair().unwrap();
    assert_eq!(child.verify(&other).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
    stream.write_all(b"1").unwrap();
    assert!(child.child.lock().unwrap().wait().unwrap().success());
    assert!(child.verify(&stream).is_err(), "an exited child's connection was accepted");
}

#[test]
fn supervised_link_rejects_a_matching_pid_with_a_different_start_instance() {
    let (mut child, mut stream, _directory) = connected_child();
    child.verify(&stream).unwrap();
    child.started.0 = child.started.0.wrapping_add(1);
    assert_eq!(child.verify(&stream).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
    stream.write_all(b"1").unwrap();
}

#[test]
fn supervised_link_linux_start_retains_raw_ticks_after_a_process_name_with_parentheses() {
    let tail = (3..=21).map(|_| "0").collect::<Vec<_>>().join(" ");
    let stat = format!("123 (a tricky ) process) {tail} 9007199254740993 0");
    assert_eq!(linux_start(&stat), Some(ProcessStart(9_007_199_254_740_993, 0)));
    assert_eq!(linux_start("123 (short) 0"), None);
    assert_eq!(linux_start(&format!("123 (invalid) {tail} -1")), None);
}
