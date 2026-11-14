use super::*;
use std::os::unix::net::UnixStream;

/// This test process is the same user and the same code as itself, so
/// it passes its own check (on macOS through the signature path too).
#[test]
fn a_process_of_the_same_user_and_code_is_accepted() {
    let (left, right) = UnixStream::pair().unwrap();
    verify(&left).unwrap();
    verify(&right).unwrap();
}

/// A different binary of the same user is refused: `/usr/bin/nc` is
/// Apple's code, so it has neither this build's Team ID nor this test
/// binary's cdhash. The uid check alone would accept it.
#[cfg(target_os = "macos")]
#[test]
fn a_different_binary_of_the_same_user_is_refused() {
    use std::process::{Command, Stdio};
    let directory = cmux_unix_socket::short_test_dir("caller");
    let path = directory.path().join("c.sock");
    let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
    let mut child = Command::new("/usr/bin/nc")
        .arg("-U")
        .arg(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let (stream, _) = listener.accept().unwrap();
    let refused = verify(&stream);
    let _ = child.kill();
    let _ = child.wait();
    assert!(matches!(refused, Err(CallerRefused::Signature(_))), "{refused:?}");
}
