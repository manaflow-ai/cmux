//! Owner exit (the holder's rule): a holder whose owner (its daemon) goes
//! away ends its terminals, unless the owner wrote a handoff record
//! ([`cmux_holder::handoff`]) before it exited. A recorded handoff keeps
//! them; a record a later daemon left behind does not carry over.

#![cfg(unix)]

use std::os::fd::OwnedFd;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_holder::SpawnRequest;
use cmux_holder::client::{Event, HolderClient, launch};
use cmux_holder::handoff;

const TOKEN: [u8; 32] = [0x6b; 32];

/// How long an orphaned holder may keep a shell: the CLOSE gives it 2 s
/// before SIGKILL, so this is the bound the rule gives.
const ENDS_WITHIN: Duration = Duration::from_secs(10);

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

mod support;

fn shell() -> SpawnRequest {
    SpawnRequest {
        id: [7; 16],
        cols: 80,
        rows: 24,
        px_w: 0,
        px_h: 0,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/sh".to_vec(), b"-c".to_vec(), b"echo ready-1; exec cat".to_vec()],
        env: vec![b"PATH=/usr/bin:/bin".to_vec(), b"TERM=xterm-256color".to_vec()],
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 probes a pid this test started.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Read output until it contains `needle`; returns everything read.
fn read_until(client: &mut HolderClient, needle: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut text = String::new();
    while !text.contains(needle) {
        match client.next_event(deadline) {
            Ok(Event::Data { bytes, .. }) => text.push_str(&String::from_utf8_lossy(&bytes)),
            Ok(_) => {}
            Err(error) => panic!("waiting for {needle:?}: {error}; got {text:?}"),
        }
    }
    text
}

/// A shell started through a holder by a first daemon; returns its pid,
/// its custody master and the client that owns it.
fn start_shell(socket: &Path) -> (std::process::Child, HolderClient, i32, OwnedFd) {
    let holder = launch(holder_binary(), socket, &TOKEN).unwrap();
    let (mut client, listed) = HolderClient::connect(socket, &TOKEN).unwrap();
    assert!(listed.is_empty());
    let (pid, master) = client.spawn(1, &shell()).unwrap();
    client.attach(1, 0).unwrap();
    read_until(&mut client, "ready-1");
    (holder, client, pid, master)
}

fn end_holder(mut holder: std::process::Child) {
    let _ = holder.kill();
    let _ = holder.wait();
}

/// RED first: no handoff, the owner exits, the terminal must end within
/// [`ENDS_WITHIN`].
#[test]
fn a_holder_whose_owner_exits_without_a_handoff_ends_its_terminals() {
    let dir = support::unique_dir("ownx");
    let socket = dir.join("h.sock");
    let (holder, client, pid, master) = start_shell(&socket);
    drop(client);
    let deadline = Instant::now() + ENDS_WITHIN;
    while alive(pid) {
        assert!(
            Instant::now() < deadline,
            "the owner exited with no handoff and the shell lived on"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    drop(master);
    end_holder(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A recorded handoff: the owner writes it before it exits, so the holder
/// keeps the shell, and a daemon that connects later gets it back.
#[test]
fn a_recorded_handoff_keeps_the_terminals_when_the_owner_exits() {
    let dir = support::unique_dir("ownx");
    let socket = dir.join("h.sock");
    let (holder, client, pid, master) = start_shell(&socket);
    let record = handoff::write_record(&socket).unwrap();
    assert!(record.is_file(), "the handoff record was not written");
    drop(client);
    // Longer than the CLOSE grace (2 s) that an unrecorded exit would take.
    std::thread::sleep(Duration::from_secs(3));
    assert!(alive(pid), "a recorded handoff did not keep the shell");
    assert!(!record.exists(), "the holder left the handoff record behind");

    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert_eq!(listed.len(), 1, "the holder lost its terminal across the handoff");
    client.attach(1, listed[0].oldest).unwrap();
    client.write(1, b"after\n").unwrap();
    read_until(&mut client, "after");
    client.close(1, 200).unwrap();
    drop(client);
    drop(master);
    end_holder(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A record a daemon leaves behind is not a handoff for the next exit: the
/// next daemon that connects removes it, so its own exit without a handoff
/// ends the terminal.
#[test]
fn a_stale_handoff_record_does_not_keep_terminals_for_a_later_exit() {
    let dir = support::unique_dir("ownx");
    let socket = dir.join("h.sock");
    let (holder, client, pid, master) = start_shell(&socket);
    let record = handoff::write_record(&socket).unwrap();
    // A second daemon takes the holder over; its link removes the record.
    let (second, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert_eq!(listed.len(), 1);
    assert!(!record.exists(), "a new daemon's link left the stale record in place");
    drop(client);
    drop(second);
    let deadline = Instant::now() + ENDS_WITHIN;
    while alive(pid) {
        assert!(Instant::now() < deadline, "a stale handoff record kept the shell");
        std::thread::sleep(Duration::from_millis(50));
    }
    drop(master);
    end_holder(holder);
    let _ = std::fs::remove_dir_all(&dir);
}
