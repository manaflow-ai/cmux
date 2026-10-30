//! `acpmux host join` takes its pairing ticket on stdin (one line), so no
//! process has it in its argv, where other users of the machine read it
//! (`ps`, `/proc/PID/cmdline`). The old `host join TICKET` still works and
//! warns once on stderr, without the ticket. Both read and check the ticket
//! before a daemon is reached: an expired ticket fails here with no daemon.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::io::Write;
use std::process::{Output, Stdio};

use acpmux::pairing::{Role, Ticket};

/// A well-formed ticket that expired a minute ago.
fn expired_ticket() -> String {
    Ticket {
        url: "wss://minter.example/acp".to_owned(),
        minter: "minter".to_owned(),
        role: Role::Client,
        expires_ms: acpmux::store::now_ms() - 60_000,
        secret: "ab".repeat(32),
    }
    .encode()
}

/// `acpmux host join ARGS` with `stdin` piped in.
fn join(args: &[&str], stdin: &[u8]) -> Output {
    let scratch = tempfile::tempdir().unwrap();
    let mut child = daemon_env::acpmux(scratch.path())
        .args(["host", "join"])
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin).unwrap();
    child.wait_with_output().unwrap()
}

const WARNING: &str = "a ticket on the command line is readable by other users";

#[test]
fn a_ticket_on_stdin_is_read_and_checked_without_a_warning() {
    let ticket = expired_ticket();
    let out = join(&[], format!("{ticket}\n").as_bytes());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success());
    assert!(stderr.contains("this ticket expired"), "{stderr}");
    assert!(!stderr.contains(WARNING), "{stderr}");
    assert!(!stderr.contains(&ticket) && !String::from_utf8_lossy(&out.stdout).contains(&ticket));
}

#[test]
fn a_ticket_in_argv_still_joins_and_warns_once_without_the_ticket() {
    let ticket = expired_ticket();
    let out = join(&[&ticket], b"");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success());
    assert!(stderr.contains("this ticket expired"), "{stderr}");
    assert_eq!(stderr.matches(WARNING).count(), 1, "{stderr}");
    assert!(!stderr.contains(&ticket), "{stderr}");
}

#[test]
fn stdin_with_more_than_one_ticket_line_is_refused_without_echoing_it() {
    let ticket = expired_ticket();
    for stdin in [format!("{ticket}\n{ticket}\n"), String::new(), "\n".to_owned()] {
        let out = join(&[], stdin.as_bytes());
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(2), "{stdin:?}: {stderr}");
        assert!(!stderr.contains("cmxt1."), "{stderr}");
    }
}
