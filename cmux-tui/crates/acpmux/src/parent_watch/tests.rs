use super::*;
use std::io::{BufRead, BufReader, Read};
use std::process::{Command, Stdio};
use std::sync::mpsc;

const CHILD_ENV: &str = "ACPMUX_PARENT_WATCH_TEST_CHILD";
const CHILD_TEST: &str = "parent_watch::tests::a_server_whose_parent_died_exits";

/// The orphaned server: the test binary again, under a shell that the
/// test kills while the test still holds the server's stdin open.
#[test]
fn a_server_whose_parent_died_exits() {
    if std::env::var_os(CHILD_ENV).is_some() {
        exit_with_parent();
        eprintln!("ready {}", std::process::id());
        // Blocks: stdin stays open, so only the parent watch ends this.
        let _ = io::stdin().read_to_end(&mut Vec::new());
        return;
    }
    let mut shell = Command::new("/bin/sh")
        .arg("-c")
        // A background job's stdin would be /dev/null; fd 3 keeps the pipe.
        .arg(r#"exec 3<&0; "$0" --exact "$1" --nocapture <&3 3<&- & wait"#)
        .arg(std::env::current_exe().unwrap())
        .arg(CHILD_TEST)
        .env(CHILD_ENV, "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = shell.stdin.take().unwrap();
    let (tx, lines) = mpsc::channel();
    let stderr = BufReader::new(shell.stderr.take().unwrap());
    // Only the shell and the server hold the stderr pipe: its EOF is
    // both gone.
    std::thread::spawn(move || {
        for line in stderr.lines() {
            let _ = tx.send(line.ok());
        }
        let _ = tx.send(None);
    });
    let server = loop {
        let line = lines.recv_timeout(Duration::from_secs(30)).unwrap().unwrap();
        if let Some(pid) = line.strip_prefix("ready ") {
            break pid.parse::<libc::pid_t>().unwrap();
        }
    };
    shell.kill().unwrap();
    shell.wait().unwrap();
    let exited = loop {
        match lines.recv_timeout(Duration::from_secs(20)) {
            Ok(Some(_)) => continue,
            Ok(None) => break true,
            Err(_) => break false,
        }
    };
    if !exited {
        // SAFETY: the server this test started still runs as `server`.
        unsafe { libc::kill(server, libc::SIGKILL) };
    }
    assert!(exited, "the server outlived its parent with stdin still open");
}

#[test]
fn a_parent_that_is_not_ours_counts_as_gone() {
    // Not our parent: the wait returns at once instead of blocking.
    wait_for_parent(std::process::id()).unwrap();
}
