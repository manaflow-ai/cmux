//! Link benches (review 2 of pl-daemon-holder). Ignored: run them on a
//! fleet Mac, not in CI:
//!
//! ```sh
//! cargo test --release -p cmux-holder --test link_bench -- --ignored --nocapture --test-threads 1
//! ```
//!
//! - `echo_behind_two_flooders`: two terminals print as fast as they can
//!   (channels 1 and 2), a third echoes what is typed (channel 3). It types
//!   200 markers and measures each marker's input-to-output time through
//!   the holder. Fails above 10 ms p95: the echo must not wait behind the
//!   flooders' queued output.
//! - `four_yes_terminals_through_the_holder_and_direct`: 4 terminals print
//!   64 MiB each through the holder, then on direct PTYs read by this
//!   process. Prints MB/s and CPU time of each path.

#![cfg(unix)]

use std::collections::HashMap;
use std::io::Read;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, Instant};

use cmux_holder::SpawnRequest;
use cmux_holder::client::{Event, HolderClient, launch};
use cmux_holder::wire::ACK_EVERY;

const TOKEN: [u8; 32] = [0x6b; 32];

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

mod support;

fn temp_dir() -> PathBuf {
    support::unique_dir("cmhb")
}

fn script(chan: u32, script: &str) -> SpawnRequest {
    let mut id = [0u8; 16];
    id[..4].copy_from_slice(&chan.to_le_bytes());
    SpawnRequest {
        id,
        cols: 120,
        rows: 40,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/sh".to_vec(), b"-c".to_vec(), script.as_bytes().to_vec()],
        env: vec![b"PATH=/usr/bin:/bin".to_vec(), b"TERM=xterm-256color".to_vec()],
        ..SpawnRequest::default()
    }
}

fn write_master(master: &OwnedFd, bytes: &[u8]) {
    let mut written = 0;
    while written < bytes.len() {
        // SAFETY: writes from a live slice to a descriptor the bench owns.
        let n = unsafe {
            libc::write(master.as_raw_fd(), bytes[written..].as_ptr().cast(), bytes.len() - written)
        };
        if n > 0 {
            written += n as usize;
        } else {
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

fn cpu_time(who: libc::c_int) -> Duration {
    // SAFETY: zeroed rusage is a valid out-buffer.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: getrusage fills one rusage.
    unsafe { libc::getrusage(who, &mut usage) };
    let time = |value: libc::timeval| {
        Duration::from_secs(value.tv_sec as u64) + Duration::from_micros(value.tv_usec as u64)
    };
    time(usage.ru_utime) + time(usage.ru_stime)
}

fn kill(mut holder: Child) {
    let _ = holder.kill();
    let _ = holder.wait();
}

/// Acknowledge a flooder's output as a daemon whose parser keeps up does.
fn take(client: &mut HolderClient, acked: &mut HashMap<u32, (u64, u64)>, chan: u32, len: usize) {
    let (received, last) = acked.entry(chan).or_insert((0, 0));
    *received += len as u64;
    if *received - *last >= ACK_EVERY {
        *last = *received;
        client.ack(chan, *received).unwrap();
    }
}

#[test]
#[ignore = "bench: run on a fleet Mac with --ignored --nocapture"]
fn echo_behind_two_flooders() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let mut keep = Vec::new();
    for chan in 1..=2 {
        let (_, master) = client
            .spawn(chan, &script(chan, "stty raw -echo; exec yes flooding-terminal"))
            .unwrap();
        client.attach(chan, 0).unwrap();
        keep.push(master);
    }
    let (_, echo) = client.spawn(3, &script(3, "stty raw -echo; exec cat")).unwrap();
    client.attach(3, 0).unwrap();
    let mut acked = HashMap::new();
    let mut echoed = Vec::new();
    let mut latencies = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(120);
    // Let the flooders fill every queue first.
    let warm = Instant::now() + Duration::from_millis(500);
    while Instant::now() < warm {
        if let Event::Data { chan, bytes, .. } = client.next_event(deadline).unwrap() {
            take(&mut client, &mut acked, chan, bytes.len());
        }
    }
    for sample in 0..200 {
        let marker = format!("<{sample}>");
        let typed = Instant::now();
        write_master(&echo, marker.as_bytes());
        loop {
            match client.next_event(deadline).unwrap() {
                Event::Data { chan: 3, bytes, .. } => {
                    take(&mut client, &mut acked, 3, bytes.len());
                    echoed.extend_from_slice(&bytes);
                    if String::from_utf8_lossy(&echoed).contains(&marker) {
                        latencies.push(typed.elapsed());
                        echoed.clear();
                        break;
                    }
                }
                Event::Data { chan, bytes, .. } => take(&mut client, &mut acked, chan, bytes.len()),
                Event::Exit { chan, .. } => panic!("terminal {chan} ended"),
                _ => {}
            }
        }
    }
    latencies.sort();
    let at = |q: f64| latencies[((latencies.len() - 1) as f64 * q) as usize];
    let flooded: u64 = acked.iter().filter(|(chan, _)| **chan != 3).map(|(_, (r, _))| *r).sum();
    println!(
        "ECHO-BEHIND-FLOODERS p50_ms={:.2} p95_ms={:.2} max_ms={:.2} flood_mib={}",
        at(0.5).as_secs_f64() * 1e3,
        at(0.95).as_secs_f64() * 1e3,
        at(1.0).as_secs_f64() * 1e3,
        flooded >> 20
    );
    assert!(at(0.95) < Duration::from_millis(10), "the echo waited behind the flooders");
    drop(keep);
    drop(echo);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
#[ignore = "bench: run on a fleet Mac with --ignored --nocapture"]
fn four_yes_terminals_through_the_holder_and_direct() {
    const PER_TERMINAL: usize = 64 << 20;
    const TERMINALS: u32 = 4;
    let print = format!("stty raw -echo; yes | head -c {PER_TERMINAL}; exit 0");

    // Through the holder: this process plays the daemon (one reader, acks).
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let cpu = cpu_time(libc::RUSAGE_SELF);
    let started = Instant::now();
    let mut keep = Vec::new();
    for chan in 1..=TERMINALS {
        let (_, master) = client.spawn(chan, &script(chan, &print)).unwrap();
        client.attach(chan, 0).unwrap();
        keep.push(master);
    }
    let mut acked = HashMap::new();
    let mut ended = 0;
    let deadline = Instant::now() + Duration::from_secs(300);
    while ended < TERMINALS {
        match client.next_event(deadline).unwrap() {
            Event::Data { chan, bytes, .. } => take(&mut client, &mut acked, chan, bytes.len()),
            Event::Exit { .. } => ended += 1,
            _ => {}
        }
    }
    let holder_wall = started.elapsed();
    let daemon_cpu = cpu_time(libc::RUSAGE_SELF) - cpu;
    let total: u64 = acked.values().map(|(received, _)| *received).sum();
    assert_eq!(total, u64::from(TERMINALS) * PER_TERMINAL as u64);
    drop(client);
    drop(keep);
    let children = cpu_time(libc::RUSAGE_CHILDREN);
    kill(holder);
    let holder_cpu = cpu_time(libc::RUSAGE_CHILDREN) - children;

    // Direct PTYs, one reader thread each, as the local path reads them.
    let cpu = cpu_time(libc::RUSAGE_SELF);
    let started = Instant::now();
    let readers: Vec<_> = (1..=TERMINALS)
        .map(|chan| {
            let spawned = cmux_holder::pty::spawn(&script(chan, &print), None).unwrap();
            // SAFETY: clears O_NONBLOCK on the master this bench owns.
            unsafe {
                let fd = spawned.master.as_raw_fd();
                let flags = libc::fcntl(fd, libc::F_GETFL);
                libc::fcntl(fd, libc::F_SETFL, flags & !libc::O_NONBLOCK);
            }
            let pid = spawned.pid;
            std::thread::spawn(move || {
                let mut master = std::fs::File::from(spawned.master);
                let mut buf = vec![0u8; 64 * 1024];
                let mut read = 0u64;
                while read < PER_TERMINAL as u64 {
                    match master.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => read += n as u64,
                    }
                }
                let mut status = 0;
                // SAFETY: reaps the child this bench started.
                unsafe { libc::waitpid(pid, &mut status, 0) };
                read
            })
        })
        .collect();
    let direct: u64 = readers.into_iter().map(|reader| reader.join().unwrap()).sum();
    let direct_wall = started.elapsed();
    let direct_cpu = cpu_time(libc::RUSAGE_SELF) - cpu;
    let mib = |bytes: u64, wall: Duration| (bytes as f64 / f64::from(1 << 20)) / wall.as_secs_f64();
    println!(
        "YES-X4 holder_mib_s={:.0} daemon_cpu_ms={} holder_cpu_ms={} direct_mib_s={:.0} direct_cpu_ms={}",
        mib(total, holder_wall),
        daemon_cpu.as_millis(),
        holder_cpu.as_millis(),
        mib(direct, direct_wall),
        direct_cpu.as_millis()
    );
    let _ = std::fs::remove_dir_all(&dir);
}
