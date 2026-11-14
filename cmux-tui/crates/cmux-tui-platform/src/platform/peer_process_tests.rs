//! The start time of a peer's process, the version in its key
//! (`peer_process.rs`).

use std::os::unix::process::CommandExt;

/// The start time of a process is read whatever bytes the name of its
/// program has. The system keeps 15 bytes of that name.
#[test]
fn the_start_time_is_read_for_each_program_name() {
    let dir = std::env::temp_dir().join(format!("cmux-start-name-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("folder");
    // 8 characters of 2 bytes: byte 15 is the first half of the last one.
    let program = dir.join("\u{e9}".repeat(8));
    std::os::unix::fs::symlink("/bin/sleep", &program).expect("link");
    let mut child =
        std::process::Command::new(&program).arg0("sleep").arg("30").spawn().expect("child");
    let line = std::fs::read(format!("/proc/{}/stat", child.id())).expect("line");
    let start = super::start_time_of(libc::pid_t::try_from(child.id()).expect("process id"));
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        std::str::from_utf8(&line).is_err(),
        "setup: the name was not cut inside a character: {}",
        String::from_utf8_lossy(&line)
    );
    assert!(start.is_some(), "the start time of a child of this test");
}
