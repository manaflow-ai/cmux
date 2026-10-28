//! A cold terminal's holder ring gives its pages back once
//! the daemon acknowledged its output and the prologue is past it, and a
//! holder crash after that still loses no byte.

#![cfg(unix)]

use std::os::fd::{AsRawFd, OwnedFd};
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_holder::client::{Event, HolderClient, launch_with};
use cmux_holder::{RING_COLD_ENV, SpawnRequest};

mod support;

const TOKEN: [u8; 32] = [0x6b; 32];
const TOTAL: usize = 1 << 20;
const COLD_MS: u64 = 300;

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

/// The holder's memory footprint: `phys_footprint` on macOS (what Activity
/// Monitor shows), the resident set on Linux (its memfd ring pages count as
/// shared resident memory).
#[cfg(target_vendor = "apple")]
fn footprint(pid: u32) -> u64 {
    // SAFETY: zeroed rusage_info_v2 is a valid out-buffer for its flavor.
    let mut usage: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    // SAFETY: the buffer matches RUSAGE_INFO_V2's layout and size.
    let rc = unsafe {
        libc::proc_pid_rusage(pid as libc::c_int, libc::RUSAGE_INFO_V2, (&raw mut usage).cast())
    };
    assert_eq!(rc, 0, "proc_pid_rusage({pid}): {}", std::io::Error::last_os_error());
    usage.ri_phys_footprint
}

#[cfg(not(target_vendor = "apple"))]
fn footprint(pid: u32) -> u64 {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap();
    let line = status.lines().find(|line| line.starts_with("VmRSS:")).expect("VmRSS");
    let kib: u64 = line.split_whitespace().nth(1).unwrap().parse().unwrap();
    kib * 1024
}

/// A PING and its PONG: the holder handled everything sent before it.
fn holder_turn(client: &mut HolderClient, nonce: u64) {
    client.ping(nonce).unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        match client.next_event(deadline).unwrap() {
            Event::Pong { nonce: answered } if answered == nonce => return,
            Event::Pong { .. } | Event::Adopted { .. } => {}
            other => panic!("unexpected {other:?} before PONG {nonce}"),
        }
    }
}

fn wait_for_segment_end(ring: &OwnedFd, end: u64) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while cmux_holder::ring::segment_end(ring).unwrap() < end {
        assert!(Instant::now() < deadline, "the holder never read the echo into its ring");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn write_master(master: &OwnedFd, bytes: &[u8]) {
    // SAFETY: writes from a live slice to a descriptor the test owns.
    let n = unsafe { libc::write(master.as_raw_fd(), bytes.as_ptr().cast(), bytes.len()) };
    assert_eq!(n, bytes.len() as isize, "write the custody master");
}

#[test]
fn a_cold_ring_gives_back_its_pages_and_a_holder_crash_loses_no_byte() {
    let ring_bytes = cmux_memory::DaemonBudget::for_host().holder_ring_bytes;
    let dir = support::unique_dir("cmcr");
    let socket = dir.join("h.sock");
    let configure = |command: &mut std::process::Command| {
        command.env(RING_COLD_ENV, COLD_MS.to_string());
    };
    let mut first = launch_with(holder_binary(), &socket, &TOKEN, configure).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let mut id = [0u8; 16];
    id[0] = 1;
    let request = SpawnRequest {
        id,
        cols: 80,
        rows: 24,
        px_w: 0,
        px_h: 0,
        cwd: b"/tmp".to_vec(),
        argv: vec![
            b"/bin/sh".to_vec(),
            b"-c".to_vec(),
            format!("stty raw -echo; yes 0123456789abcdef | head -c {TOTAL}; exec cat")
                .into_bytes(),
        ],
        env: vec![b"PATH=/usr/bin:/bin".to_vec(), b"TERM=xterm-256color".to_vec()],
    };
    let spawned = client.spawn_with_ring(1, &request).unwrap();
    let ring = spawned.ring.expect("the holder passes its ring segment");
    client.attach(1, 0).unwrap();
    // Write 1 MiB and acknowledge every byte of it as the daemon parses it.
    let mut received = 0u64;
    let deadline = Instant::now() + Duration::from_secs(30);
    while received < TOTAL as u64 {
        if let Event::Data { offset, bytes, .. } = client.next_event(deadline).unwrap() {
            assert_eq!(offset, received, "output offsets must continue");
            received += bytes.len() as u64;
            client.ack(1, received).unwrap();
        }
    }
    holder_turn(&mut client, 1);
    let warm = footprint(first.id());
    // The daemon's screen snapshot at the end: the prologue a restarted
    // daemon starts from, so no reader needs the ring before it.
    client.snapshot(1, received, b"\x1b[H\x1b[2Jscreen").unwrap();
    holder_turn(&mut client, 2);
    // Nothing wakes the holder from here on: only its own cold-ring
    // deadline can release the ring, as for a cold terminal in use.
    let want = (ring_bytes as u64).saturating_sub(124 * 1024);
    let deadline = Instant::now() + Duration::from_millis(30 * COLD_MS);
    loop {
        let cold = footprint(first.id());
        let freed = warm.saturating_sub(cold);
        if freed >= want {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "an idle holder's cold ring freed {freed} bytes (warm {warm}, cold {cold}), want {want}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    holder_turn(&mut client, 3);

    // The shell prints after the release, the daemon goes away, and the
    // holder dies with that output unsent: the next holder continues the
    // released segment and the daemon gets every byte at its offset.
    client.end();
    write_master(&spawned.master, b"after the release\n");
    wait_for_segment_end(&ring, received + 18);
    let _ = first.kill();
    let _ = first.wait();
    let mut second = launch_with(holder_binary(), &socket, &TOKEN, configure).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    client
        .adopt_with_ring(1, &id, (spawned.pid, received, received), &spawned.master, &ring, b"x")
        .unwrap();
    let adopted = client.adopted(1).unwrap();
    assert_eq!(adopted.end, received + 18, "the new holder continues the released segment");
    assert!(adopted.oldest <= received, "the released ring dropped a byte the daemon lacked");
    client.attach(1, received).unwrap();
    let mut got = Vec::new();
    while got.len() < 18 {
        match client.next_event(deadline).unwrap() {
            Event::Data { offset, bytes, .. } => {
                assert_eq!(offset, received + got.len() as u64, "offsets continue after a crash");
                got.extend(bytes);
            }
            Event::Gap { requested, oldest, .. } => panic!("lost {requested}..{oldest}"),
            _ => {}
        }
    }
    assert_eq!(got, b"after the release\n");
    client.close(1, 200).unwrap();
    drop(client);
    let _ = second.kill();
    let _ = second.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
