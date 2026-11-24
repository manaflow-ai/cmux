//! Only the holder of a home's `daemon.lock` removes the socket it serves. A bind that found the
//! socket slow to answer took it from under a live daemon before: a connect fails on a daemon
//! whose accept queue is full as it does on a dead socket, and `bind_unix` then unlinked the path
//! (cosmic-gray, 2026-11-02: the lock's holder ran on with no socket). Synthetic temp homes only.
#![cfg(unix)]

use std::io::{BufRead, BufReader};
use std::os::unix::fs::MetadataExt;
use std::process::{Command, Stdio};

/// A daemon of another home (or a command) whose bind finds the socket refusing connects while
/// a live process holds the lock that records it leaves the socket in place and binds nothing.
#[tokio::test]
async fn a_bind_that_does_not_hold_the_lock_never_unlinks_the_holders_socket() {
    let dir = tempfile::Builder::new().prefix("amx-own").tempdir_in("/tmp").unwrap();
    let home = dir.path().join("h");
    std::fs::create_dir(&home).unwrap();
    let socket = home.join("s.sock");
    // The holder's socket, refusing connects as a daemon whose accept queue is full does.
    drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
    let before = std::fs::symlink_metadata(&socket).unwrap().ino();
    // The holder: another live process with the lock, its pid and socket written in it as a
    // daemon writes them (`daemon/lock.rs` `record_pid`).
    let lock = home.join("daemon.lock");
    let holder = r#"
import fcntl, os, sys, time
f = open(sys.argv[1], "a+")
fcntl.flock(f, fcntl.LOCK_EX)
f.truncate(0); f.write(f"{os.getpid()}\n{sys.argv[2]}\n"); f.flush()
print("held", flush=True)
time.sleep(60)
"#;
    let mut holder = Command::new("python3")
        .args(["-c", holder])
        .arg(&lock)
        .arg(&socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(holder.stdout.take().unwrap()).read_line(&mut line).unwrap();
    assert_eq!(line.trim(), "held");

    let bound = acpmux::server::bind_unix(&socket).await;
    let after = std::fs::symlink_metadata(&socket).map(|m| m.ino()).ok();
    let _ = holder.kill();
    let _ = holder.wait();
    let error = bound.expect_err("a bind without the lock took the holder's socket path");
    assert!(error.to_string().contains(&holder.id().to_string()), "{error:#}");
    assert_eq!(after, Some(before), "a bind without the lock unlinked the holder's socket");
}
