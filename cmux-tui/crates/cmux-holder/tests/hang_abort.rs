//! Hang = crash (cp/daemon-holder-crash-loop): a holder loop pass that
//! stays open past the hang limit aborts the holder process, as Chrome's
//! GPU watchdog thread crashes a GPU process whose main thread hangs
//! (gpu/ipc/service/gpu_watchdog_thread.cc). A loop that stays stuck never
//! sends its own HANG frame, so only the holder can end it; the daemon then
//! counts the abort as a holder crash.
//!
//! The debug-only hook `CMUX_HOLDER_TEST_STALL_READ` stalls the loop inside
//! the PTY read that takes the needle, and `CMUX_HOLDER_HANG_LIMIT_MS` sets
//! the limit to 300 ms. The holder must end by SIGABRT, and the terminal's
//! ring segment must say a read was in flight: the cut the daemon counts.

#![cfg(unix)]

use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_holder::SpawnRequest;
use cmux_holder::client::{Event, HolderClient, launch_with};

mod support;

const TOKEN: [u8; 32] = [0x4d; 32];
const NEEDLE: &str = "cmux-holder-hang-abort-needle";

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

#[test]
fn a_loop_pass_stuck_past_the_hang_limit_aborts_the_holder_with_its_read_in_flight() {
    let dir = support::unique_dir("cmha");
    let socket = dir.join("h.sock");
    let mut holder = launch_with(holder_binary(), &socket, &TOKEN, |command| {
        command.env("CMUX_HOLDER_HANG_LIMIT_MS", "300").env("CMUX_HOLDER_TEST_STALL_READ", NEEDLE);
    })
    .unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let script =
        format!("stty raw -echo; printf 'before\\n'; sleep 0.5; printf '{NEEDLE}'; exec sleep 60");
    let request = SpawnRequest {
        id: [7; 16],
        cols: 80,
        rows: 24,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/sh".to_vec(), b"-c".to_vec(), script.into_bytes()],
        env: vec![b"PATH=/usr/bin:/bin".to_vec()],
        ..SpawnRequest::default()
    };
    let spawned = client.spawn_with_ring(1, &request).unwrap();
    let ring = spawned.ring.expect("this build's holder passes the ring segment");
    client.attach(1, 0).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    while !String::from_utf8_lossy(&seen).contains("before") {
        match client.next_event(deadline).expect("the terminal's first output") {
            Event::Data { bytes, .. } => seen.extend_from_slice(&bytes),
            Event::Exit { .. } => panic!("the terminal ended"),
            _ => {}
        }
    }

    // The holder reads the needle, its pass stalls, and the hang watch ends
    // it well within a few seconds of the 300 ms limit.
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = holder.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = holder.kill();
            let _ = holder.wait();
            panic!("a pass stuck past the hang limit did not end the holder");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(status.signal(), Some(libc::SIGABRT), "the holder ended by {status:?}");
    let at = cmux_holder::ring::interrupted_read(&ring).unwrap();
    assert_eq!(at, Some(seen.len() as u64), "the stalled read is not the ring's cut");
    // Dropping the last master dup hangs up the shell (the holder is gone).
    drop(spawned.master);
    drop(client);
    let _ = std::fs::remove_dir_all(&dir);
}
