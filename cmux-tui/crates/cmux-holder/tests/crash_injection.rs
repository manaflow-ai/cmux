//! Crash injection: kill the holder, then the daemon side, and check that
//! no shell dies and every screen comes back (terminal-host-model-DESIGN.md
//! slice 1).
//!
//! The test plays the daemon: it starts 16 shells through a holder and keeps
//! the custody dup of each PTY master, as the daemon will. Then:
//! 1. SIGKILL the holder. Every shell is still alive; input the "daemon"
//!    writes to its master dup while no holder runs reaches the shell, and
//!    its output waits in the PTY.
//! 2. Start a new holder and adopt every master. The output written while no
//!    holder ran arrives, offsets continue, and input through the new
//!    holder works: the daemon's copy of every screen is unchanged and live.
//! 3. Drop the daemon link (a daemon crash) and connect again: the holder
//!    lists every terminal and re-sends each one's output from its ring,
//!    byte for byte what the first link received.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_holder::client::{Event, HolderClient, launch, launch_with};
use cmux_holder::holder::error_code;
use cmux_holder::wire::{ACK_EVERY, Kind};
use cmux_holder::{ExitStatus, NOFILE_SOFT_ENV, SpawnRequest};

const TERMINALS: u32 = 16;
const TOKEN: [u8; 32] = [0x5a; 32];

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

fn temp_dir() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!(
        "cmhx-{}-{}",
        std::process::id(),
        stamp % 1_000_000_000
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn shell(chan: u32) -> SpawnRequest {
    let mut id = [0u8; 16];
    id[..4].copy_from_slice(&chan.to_le_bytes());
    SpawnRequest {
        id,
        cols: 80,
        rows: 24,
        px_w: 0,
        px_h: 0,
        cwd: b"/tmp".to_vec(),
        argv: vec![
            b"/bin/sh".to_vec(),
            b"-c".to_vec(),
            format!("echo ready-{chan}; exec cat").into_bytes(),
        ],
        env: vec![b"PATH=/usr/bin:/bin".to_vec(), b"TERM=xterm-256color".to_vec()],
    }
}

/// What the "daemon" holds per terminal: its custody master, its pid and
/// every output byte it received, at offsets starting from `base`.
struct Screen {
    master: OwnedFd,
    pid: i32,
    base: u64,
    bytes: Vec<u8>,
}

impl Screen {
    fn end(&self) -> u64 {
        self.base + self.bytes.len() as u64
    }

    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}

/// Feed events into the screens until every screen contains `needle(chan)`.
fn pump_until(
    client: &mut HolderClient,
    screens: &mut BTreeMap<u32, Screen>,
    needle: impl Fn(u32) -> String,
) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !screens.iter().all(|(chan, screen)| screen.text().contains(&needle(*chan))) {
        match client.next_event(deadline).unwrap_or_else(|error| {
            let missing: Vec<_> = screens
                .iter()
                .filter(|(chan, screen)| !screen.text().contains(&needle(**chan)))
                .map(|(chan, screen)| (*chan, screen.text()))
                .collect();
            panic!("waiting for output: {error}; missing {missing:?}")
        }) {
            Event::Data { chan, offset, bytes } => {
                let screen = screens.get_mut(&chan).unwrap();
                assert_eq!(offset, screen.end(), "terminal {chan}: output offsets must continue");
                screen.bytes.extend_from_slice(&bytes);
            }
            Event::Gap { chan, .. } => panic!("terminal {chan}: unexpected gap"),
            Event::Prologue { chan, .. } => panic!("terminal {chan}: unexpected prologue"),
            Event::Exit { chan, .. } => panic!("terminal {chan}: shell exited"),
            Event::Error { chan, message, .. } => panic!("terminal {chan}: holder error {message}"),
            Event::Pong { .. } => {}
        }
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 probes a pid this test started.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn write_master(master: &OwnedFd, bytes: &[u8]) {
    let mut written = 0;
    while written < bytes.len() {
        // SAFETY: writes from a live slice to a descriptor the test owns.
        let n = unsafe {
            libc::write(master.as_raw_fd(), bytes[written..].as_ptr().cast(), bytes.len() - written)
        };
        if n > 0 {
            written += n as usize;
        } else {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

fn kill(mut holder: Child) {
    let _ = holder.kill();
    let _ = holder.wait();
}

#[test]
fn shells_survive_a_holder_crash_and_a_daemon_crash_with_their_screens() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let first = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert!(listed.is_empty());
    let mut screens = BTreeMap::new();
    for chan in 1..=TERMINALS {
        let (pid, master) = client.spawn(chan, &shell(chan)).unwrap();
        client.attach(chan, 0).unwrap();
        screens.insert(chan, Screen { master, pid, base: 0, bytes: Vec::new() });
    }
    pump_until(&mut client, &mut screens, |chan| format!("ready-{chan}"));

    // 1. The holder crashes.
    drop(client);
    kill(first);
    for (chan, screen) in &screens {
        assert!(alive(screen.pid), "terminal {chan}: the shell died with its holder");
        write_master(&screen.master, format!("gap-{chan}\n").as_bytes());
    }

    // 2. A new holder takes every master back.
    let second = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert!(listed.is_empty(), "a fresh holder runs nothing yet");
    for (chan, screen) in &screens {
        let mut id = [0u8; 16];
        id[..4].copy_from_slice(&chan.to_le_bytes());
        client.adopt(*chan, &id, screen.pid, screen.end(), &screen.master).unwrap();
        client.attach(*chan, screen.end()).unwrap();
    }
    // `cat` echoes the line once more after the PTY's own echo.
    pump_until(&mut client, &mut screens, |chan| format!("gap-{chan}\r\ngap-{chan}"));
    for chan in 1..=TERMINALS {
        client.write(chan, format!("after-{chan}\n").as_bytes()).unwrap();
    }
    pump_until(&mut client, &mut screens, |chan| format!("after-{chan}\r\nafter-{chan}"));

    // 3. The daemon crashes; a new one restores every screen from the rings.
    let adopted_at: BTreeMap<u32, u64> =
        screens.iter().map(|(chan, screen)| (*chan, screen.base)).collect();
    let before: BTreeMap<u32, Vec<u8>> =
        screens.iter().map(|(chan, s)| (*chan, s.bytes.clone())).collect();
    drop(client);
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert_eq!(listed.len(), TERMINALS as usize, "the holder lists every terminal");
    let mut restored = BTreeMap::new();
    for entry in &listed {
        assert!(!entry.exited, "terminal {}: listed as exited", entry.chan);
        let screen = &screens[&entry.chan];
        assert!(alive(screen.pid), "terminal {}: the shell died with the daemon link", entry.chan);
        // The new holder's ring starts where it adopted the terminal.
        let start = entry.oldest;
        let dup = screen.master.try_clone().unwrap();
        restored.insert(
            entry.chan,
            Screen { master: dup, pid: screen.pid, base: start, bytes: Vec::new() },
        );
        client.attach(entry.chan, start).unwrap();
    }
    pump_until(&mut client, &mut restored, |chan| format!("after-{chan}\r\nafter-{chan}"));
    for (chan, screen) in &restored {
        let original = &before[chan];
        let skip = (screen.base - adopted_at[chan]) as usize;
        let expected = &original[skip..];
        assert_eq!(
            &screen.bytes[..expected.len().min(screen.bytes.len())],
            expected,
            "terminal {chan}: the restored screen differs from the one the daemon had"
        );
    }

    // Close every terminal; the holder reports each end.
    for chan in 1..=TERMINALS {
        client.close(chan, 200).unwrap();
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut ended = 0;
    while ended < TERMINALS {
        if let Event::Exit { status, .. } = client.next_event(deadline).unwrap() {
            assert_eq!(status, ExitStatus::Unobserved, "adopted children have no status");
            ended += 1;
        }
    }
    drop(screens);
    drop(restored);
    kill(second);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_spawned_shells_exit_status_reaches_the_daemon_after_its_last_output() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let mut request = shell(1);
    request.argv = vec![b"/bin/sh".to_vec(), b"-c".to_vec(), b"echo last-words; exit 3".to_vec()];
    // The daemon keeps its custody dup of the master for the whole life of
    // the terminal, so the end must not wait for every master to close.
    let (_pid, _custody) = client.spawn(1, &request).unwrap();
    client.attach(1, 0).unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut output = Vec::new();
    loop {
        match client.next_event(deadline).unwrap() {
            Event::Data { bytes, .. } => output.extend_from_slice(&bytes),
            Event::Exit { status, end, .. } => {
                assert_eq!(status, ExitStatus::Exited(3));
                assert_eq!(end, output.len() as u64);
                break;
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(String::from_utf8_lossy(&output).contains("last-words"));
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_wrong_token_is_refused() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    assert!(HolderClient::connect(&socket, &[0u8; 32]).is_err());
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_flood_through_a_slow_daemon_arrives_whole_and_in_order() {
    const FLOOD: usize = 3 * 1024 * 1024;
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert!(client.has_credit(), "this build's holder takes acknowledgements");
    let mut request = shell(1);
    // Raw mode: the PTY passes the bytes as they are.
    request.argv = vec![
        b"/bin/sh".to_vec(),
        b"-c".to_vec(),
        format!("stty raw -echo; head -c {FLOOD} /dev/zero | tr '\\0' a; printf done-flood")
            .into_bytes(),
    ];
    let (_pid, _custody) = client.spawn(1, &request).unwrap();
    client.attach(1, 0).unwrap();
    let deadline = Instant::now() + Duration::from_secs(120);
    let (mut received, mut acked) = (0u64, 0u64);
    let mut output = Vec::new();
    loop {
        match client.next_event(deadline).unwrap() {
            Event::Data { offset, bytes, .. } => {
                assert_eq!(offset, received, "output must stay contiguous: no byte dropped");
                received += bytes.len() as u64;
                output.extend_from_slice(&bytes);
                // A parser far slower than the shell prints.
                std::thread::sleep(Duration::from_millis(20));
                if received - acked >= ACK_EVERY {
                    client.ack(1, received).unwrap();
                    acked = received;
                }
            }
            Event::Exit { status, end, .. } => {
                assert_eq!(status, ExitStatus::Exited(0));
                assert_eq!(end, received);
                break;
            }
            Event::Gap { requested, oldest, .. } => {
                panic!("the holder dropped output {requested}..{oldest}")
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(output.iter().filter(|byte| **byte == b'a').count(), FLOOD);
    assert!(output.ends_with(b"done-flood"), "the last output arrived after the flood");
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_probe_or_a_bad_token_keeps_the_attached_daemon_and_a_new_daemon_supersedes_it() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let (pid, master) = client.spawn(1, &shell(1)).unwrap();
    client.attach(1, 0).unwrap();
    let mut screens = BTreeMap::from([(1, Screen { master, pid, base: 0, bytes: Vec::new() })]);
    pump_until(&mut client, &mut screens, |chan| format!("ready-{chan}"));

    // A second holder start's liveness probe, a stale token, a silent peer.
    drop(UnixStream::connect(&socket).unwrap());
    assert!(HolderClient::connect(&socket, &[0u8; 32]).is_err());
    let silent = UnixStream::connect(&socket).unwrap();
    client.write(1, b"still-here\n").unwrap();
    pump_until(&mut client, &mut screens, |_| "still-here\r\nstill-here".to_string());
    drop(silent);

    // A daemon with the token takes the holder, and the old one is told.
    let (_second, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert_eq!(listed.len(), 1);
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        match client.next_event(deadline) {
            Ok(Event::Error { chan: 0, request_kind, code, .. }) => {
                assert_eq!(request_kind, Kind::Hello as u16);
                assert_eq!(code, error_code::SUPERSEDED);
                break;
            }
            Ok(_) => {}
            Err(error) => panic!("the replaced daemon was not told it was superseded: {error}"),
        }
    }
    drop(screens);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_bare_program_runs_from_path_and_a_bad_directory_or_program_fails_the_spawn() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let mut bare = shell(1);
    bare.argv[0] = b"sh".to_vec();
    let (pid, master) = client.spawn(1, &bare).unwrap();
    client.attach(1, 0).unwrap();
    let mut screens = BTreeMap::from([(1, Screen { master, pid, base: 0, bytes: Vec::new() })]);
    pump_until(&mut client, &mut screens, |chan| format!("ready-{chan}"));

    let mut bad_dir = shell(2);
    bad_dir.cwd = b"/nonexistent-cmux-holder-dir".to_vec();
    let error = client.spawn(2, &bad_dir).unwrap_err();
    assert!(error.to_string().contains("nonexistent-cmux-holder-dir"), "{error}");

    let mut missing = shell(3);
    missing.argv = vec![b"cmux-no-such-program".to_vec()];
    let error = client.spawn(3, &missing).unwrap_err();
    assert!(error.to_string().contains("cmux-no-such-program"), "{error}");
    drop(screens);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The next event, failing the test with `what` when none comes in time.
fn expect_event(client: &mut HolderClient, what: &str) -> Event {
    let deadline = Instant::now() + Duration::from_secs(20);
    client.next_event(deadline).unwrap_or_else(|error| panic!("{what}: {error}"))
}

/// Review 2: a CLOSE of a terminal whose shell already ended must not
/// forget it before the attached daemon got the rest of its output and its
/// EXIT. The shell prints more than one credit window and exits; the
/// daemon has not acknowledged anything when it closes the tab.
#[test]
fn a_close_after_the_shell_ended_still_delivers_the_rest_of_its_output_and_its_exit() {
    const OUTPUT: usize = 700 * 1024;
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let mut request = shell(1);
    request.argv = vec![
        b"/bin/sh".to_vec(),
        b"-c".to_vec(),
        format!("stty raw -echo; head -c {OUTPUT} /dev/zero | tr '\\0' a; exit 0").into_bytes(),
    ];
    let (pid, _custody) = client.spawn(1, &request).unwrap();
    client.attach(1, 0).unwrap();
    // No ACK yet: the holder sends one credit window and keeps the rest
    // in its ring; the shell still ends (the rest fits).
    let deadline = Instant::now() + Duration::from_secs(20);
    while alive(pid) {
        assert!(Instant::now() < deadline, "the shell never ended");
        std::thread::sleep(Duration::from_millis(10));
    }
    // Let the holder read the last output and see the end of file.
    std::thread::sleep(Duration::from_millis(300));
    client.close(1, 2000).unwrap();
    let (mut received, mut acked) = (0u64, 0u64);
    loop {
        match expect_event(&mut client, "the closed terminal's output and EXIT") {
            Event::Data { offset, bytes, .. } => {
                assert_eq!(offset, received, "output stays contiguous");
                received += bytes.len() as u64;
                if received - acked >= ACK_EVERY {
                    client.ack(1, received).unwrap();
                    acked = received;
                }
            }
            Event::Exit { status, end, .. } => {
                assert_eq!(status, ExitStatus::Exited(0));
                assert_eq!(end, received);
                break;
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(received, OUTPUT as u64, "every byte the shell printed arrived");
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 2 (design section 3, poison pill): a terminal whose stream ended
/// twice without DETACH (two daemon crashes in a row, maybe on its output)
/// is restored without its ring tail; a daemon that DETACHes before it
/// exits is no strike.
#[test]
fn a_terminal_whose_streams_keep_ending_without_detach_restores_without_its_ring_tail() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let (pid, master) = client.spawn(1, &shell(1)).unwrap();
    client.attach(1, 0).unwrap();
    let mut screens = BTreeMap::from([(1, Screen { master, pid, base: 0, bytes: Vec::new() })]);
    pump_until(&mut client, &mut screens, |chan| format!("ready-{chan}"));
    // Strike 1: the first daemon's link ends without DETACH.
    drop(client);
    // Strike 2: the next one replays the ring, then ends the same way.
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    client.reattach(1, listed[0].oldest).unwrap();
    match expect_event(&mut client, "the replayed ring") {
        Event::Data { offset: 0, .. } => {}
        other => panic!("the second daemon did not get the ring: {other:?}"),
    }
    drop(client);
    // The third gets no ring tail: a GAP to the end, then live output.
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let end = listed[0].end;
    assert!(end > 0);
    client.reattach(1, listed[0].oldest).unwrap();
    match expect_event(&mut client, "the skipped ring tail") {
        Event::Gap { requested: 0, oldest, .. } => assert_eq!(oldest, end),
        other => panic!("the poisoned ring tail replayed: {other:?}"),
    }
    client.write(1, b"live\n").unwrap();
    match expect_event(&mut client, "live output after the skip") {
        Event::Data { offset, .. } => assert_eq!(offset, end, "live output continues at the end"),
        other => panic!("unexpected {other:?}"),
    }
    // A daemon that DETACHes is no strike: the next one gets the whole ring.
    client.detach(1).unwrap();
    drop(client);
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    client.reattach(1, listed[0].oldest).unwrap();
    match expect_event(&mut client, "the ring after a clean detach") {
        Event::Data { offset: 0, .. } => {}
        other => panic!("a clean detach counted as a strike: {other:?}"),
    }
    drop(screens);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 2: a restarted daemon gets the newest SNAPSHOT as the prologue
/// and the stream from its base, so modes and screen set before the ring's
/// oldest byte survive.
#[test]
fn a_snapshot_becomes_the_prologue_a_restarted_daemon_starts_from() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let (pid, master) = client.spawn(1, &shell(1)).unwrap();
    client.attach(1, 0).unwrap();
    let mut screens = BTreeMap::from([(1, Screen { master, pid, base: 0, bytes: Vec::new() })]);
    pump_until(&mut client, &mut screens, |chan| format!("ready-{chan}"));
    let end = screens[&1].end();
    client.snapshot(1, end, b"<screen>").unwrap();
    client.detach(1).unwrap();
    drop(client);
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    client.reattach(1, listed[0].oldest).unwrap();
    match expect_event(&mut client, "the snapshot prologue") {
        Event::Prologue { base, bytes, .. } => {
            assert_eq!(base, end);
            assert_eq!(bytes, b"<screen>");
        }
        other => panic!("no prologue: {other:?}"),
    }
    client.write(1, b"next\n").unwrap();
    match expect_event(&mut client, "output after the snapshot") {
        Event::Data { offset, .. } => {
            assert_eq!(offset, end, "the ring before the snapshot replayed");
        }
        other => panic!("unexpected {other:?}"),
    }
    drop(screens);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 2: a holder shell gets the open-file limit cmux started with (not
/// the daemon's raised one) and no descriptor the daemon inherited without
/// close-on-exec.
#[test]
fn a_shell_gets_the_open_file_limit_cmux_started_with_and_no_inherited_descriptor() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    // SAFETY: opens /dev/null without close-on-exec: the "daemon's" leak.
    let leaked = unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY) };
    assert!(leaked > 2, "open: {}", std::io::Error::last_os_error());
    let holder = launch_with(holder_binary(), &socket, &TOKEN, |command| {
        command.env(NOFILE_SOFT_ENV, "200");
    })
    .unwrap();
    // SAFETY: closes the descriptor this test opened.
    unsafe { libc::close(leaked) };
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let mut request = shell(1);
    request.argv = vec![
        b"/bin/sh".to_vec(),
        b"-c".to_vec(),
        format!(
            "echo limit=$(ulimit -n); if [ -e /dev/fd/{leaked} ]; then echo fd=open; \
             else echo fd=closed; fi; exec cat"
        )
        .into_bytes(),
    ];
    let (pid, master) = client.spawn(1, &request).unwrap();
    client.attach(1, 0).unwrap();
    let mut screens = BTreeMap::from([(1, Screen { master, pid, base: 0, bytes: Vec::new() })]);
    pump_until(&mut client, &mut screens, |_| "fd=".to_string());
    pump_until(&mut client, &mut screens, |_| "\n".to_string());
    let text = screens[&1].text();
    assert!(text.contains("limit=200"), "the shell kept the daemon's raised limit: {text}");
    assert!(text.contains("fd=closed"), "the shell inherited the daemon's descriptor: {text}");
    drop(screens);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 2: a holder with terminals ignores a SIGTERM that is not
/// launchd's (a cleanup script), and a holder with no terminal and no
/// daemon exits after its idle exit and removes its socket.
#[test]
fn an_idle_holder_exits_and_a_scripts_sigterm_does_not_end_one_with_terminals() {
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let mut holder = launch_with(holder_binary(), &socket, &TOKEN, |command| {
        command.args(["--idle-exit-ms", "1000"]);
    })
    .unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let (pid, master) = client.spawn(1, &shell(1)).unwrap();
    client.attach(1, 0).unwrap();
    let mut screens = BTreeMap::from([(1, Screen { master, pid, base: 0, bytes: Vec::new() })]);
    pump_until(&mut client, &mut screens, |chan| format!("ready-{chan}"));
    // SAFETY: SIGTERM to the holder this test started.
    unsafe { libc::kill(holder.id() as i32, libc::SIGTERM) };
    drop(client);
    std::thread::sleep(Duration::from_secs(2));
    assert!(holder.try_wait().unwrap().is_none(), "a holder with a terminal exited");
    assert!(alive(pid), "the shell died");

    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    client.attach(1, screens[&1].end()).unwrap();
    client.close(1, 200).unwrap();
    loop {
        if let Event::Exit { .. } = expect_event(&mut client, "the closed terminal's EXIT") {
            break;
        }
    }
    drop(client);
    drop(screens);
    let deadline = Instant::now() + Duration::from_secs(10);
    while holder.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "an idle holder kept running");
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(!socket.exists(), "the idle holder left its socket");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 2: a frontend shell started through login(1), as the daemon
/// starts it on macOS, is a login shell, and a CLOSE reaches it (it runs in
/// a process group of its own under login's) well before the grace's
/// SIGKILL.
#[cfg(target_os = "macos")]
#[test]
fn a_shell_started_through_login_is_a_login_shell_and_a_close_reaches_it() {
    if !Path::new("/usr/bin/login").is_file() {
        return;
    }
    let user = std::process::Command::new("/usr/bin/id").arg("-un").output().unwrap();
    let user = String::from_utf8_lossy(&user.stdout).trim().to_string();
    let home = std::env::var("HOME").unwrap_or_default();
    let dir = temp_dir();
    let socket = dir.join("h.sock");
    let holder = launch(holder_binary(), &socket, &TOKEN).unwrap();
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let mut request = shell(1);
    let argv = [
        "/usr/bin/login",
        "-flp",
        user.as_str(),
        "/bin/bash",
        "--noprofile",
        "--norc",
        "-c",
        "export SHELL=\"$0\"; exec -l \"$0\" \"$@\"",
        "/bin/zsh",
        "-f",
        "-i",
    ];
    request.argv = argv.iter().map(|arg| arg.as_bytes().to_vec()).collect();
    request.env.push(format!("HOME={home}").into_bytes());
    let (pid, master) = client.spawn(1, &request).unwrap();
    client.attach(1, 0).unwrap();
    let mut screens = BTreeMap::from([(1, Screen { master, pid, base: 0, bytes: Vec::new() })]);
    client.write(1, b"echo zero=$0\n").unwrap();
    pump_until(&mut client, &mut screens, |_| "zero=-".to_string());
    let closed = Instant::now();
    client.close(1, 10_000).unwrap();
    loop {
        match expect_event(&mut client, "the login shell's EXIT") {
            Event::Exit { .. } => break,
            Event::Data { .. } => {}
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(
        closed.elapsed() < Duration::from_secs(5),
        "only the grace's SIGKILL ended the shell under login(1)"
    );
    drop(screens);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}
