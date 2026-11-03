//! A holder out of descriptors (holder-core review): it refuses what it
//! cannot take and keeps serving what it has. The holder runs under a low
//! `RLIMIT_NOFILE`, set to leave it an exact number of free descriptors, so
//! each step fails at the point the test names:
//!
//! - a HELLO is answered with every terminal and its descriptors however
//!   few are free: a listing passes the holder's own descriptors and makes
//!   none (before: two dups per terminal, so a full holder refused it);
//! - a SPAWN whose PTY cannot be opened fails before it forks, and nothing
//!   it opened stays open;
//! - a daemon frame whose descriptors the holder cannot take ends the link
//!   with an ERROR `NO_DESCRIPTORS`, and is no strike against the terminals
//!   the link streamed (before: a silent close, counted as a daemon crash);
//! - a connection the holder cannot accept waits without spinning the
//!   holder, and is served once a descriptor frees.
//!
//! The free count comes from the holder's own descriptor table, read at
//! points where it is idle (after a PONG): a probe holder with one daemon
//! link and no terminal gives the base, and each terminal holds two (its
//! master and its ring segment). A SPAWN takes four at its peak before the
//! fork (the PTY pair, then the start-report pipe), drops the slave and the
//! pipe's write end after it, makes its ring segment, and drops the pipe's
//! read end once the child runs.
//!
//! Every holder here inherits only its stdio ([`inherit_only_stdio`]), so
//! its table holds only what it opened. An inherited descriptor (one the
//! test runner left open without close-on-exec, or one another test thread
//! had not marked close-on-exec yet) counts in the table, but takes a slot
//! under the limit only when its number is below the limit: numbered above
//! it, it is in the probe's base and leaves the limited holder one more
//! free slot than the test sets, so each step passes where it must fail.

#![cfg(unix)]

use std::collections::BTreeSet;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_holder::SpawnRequest;
use cmux_holder::client::{Event, HolderClient, inherit_only_stdio, launch_with};
use cmux_holder::holder::error_code;
use cmux_holder::wire::{self, Kind, Out};

const TOKEN: [u8; 32] = [0x6d; 32];

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

fn temp_dir() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!(
        "cmhf-{}-{}",
        std::process::id(),
        stamp % 1_000_000_000
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn kill(mut holder: Child) {
    let _ = holder.kill();
    let _ = holder.wait();
}

fn shell(chan: u32) -> SpawnRequest {
    let mut id = [0u8; 16];
    id[..4].copy_from_slice(&chan.to_le_bytes());
    SpawnRequest {
        id,
        cols: 80,
        rows: 24,
        cwd: b"/tmp".to_vec(),
        argv: vec![
            b"/bin/sh".to_vec(),
            b"-c".to_vec(),
            format!("echo ready-{chan}; exec cat").into_bytes(),
        ],
        env: vec![b"PATH=/usr/bin:/bin".to_vec(), b"TERM=xterm-256color".to_vec()],
        ..SpawnRequest::default()
    }
}

/// The holder handled every frame sent before: the events that came
/// before its PONG.
fn settle(client: &mut HolderClient, nonce: u64) -> Vec<Event> {
    client.ping(nonce).unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut events = Vec::new();
    loop {
        match client.next_event(deadline).expect("the holder answers a PING") {
            Event::Pong { nonce: answered } if answered == nonce => return events,
            event => events.push(event),
        }
    }
}

/// Wait until `chan`'s output contains `needle`.
fn wait_output(client: &mut HolderClient, chan: u32, needle: &str) {
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut text = String::new();
    while !text.contains(needle) {
        match client.next_event(deadline) {
            Ok(Event::Data { chan: from, bytes, .. }) if from == chan => {
                text.push_str(&String::from_utf8_lossy(&bytes));
            }
            Ok(Event::Data { .. } | Event::Pong { .. }) => {}
            Ok(other) => panic!("terminal {chan}: unexpected {other:?} waiting for {needle:?}"),
            Err(error) => panic!("terminal {chan}: no {needle:?} in {text:?}: {error}"),
        }
    }
}

/// How many descriptors `pid` has open.
#[cfg(target_vendor = "apple")]
fn open_fds(pid: i32) -> usize {
    let entry = size_of::<libc::proc_fdinfo>();
    // SAFETY: a null buffer asks how many bytes the list needs.
    let needed =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    assert!(needed > 0, "list the holder's descriptors: {}", std::io::Error::last_os_error());
    let mut list: Vec<libc::proc_fdinfo> = Vec::with_capacity(needed as usize / entry + 64);
    // SAFETY: the buffer has room for `capacity` records; only the count
    // of records written is read back.
    let filled = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDLISTFDS,
            0,
            list.as_mut_ptr().cast(),
            (list.capacity() * entry) as libc::c_int,
        )
    };
    assert!(filled >= 0, "list the holder's descriptors: {}", std::io::Error::last_os_error());
    filled as usize / entry
}

#[cfg(not(target_vendor = "apple"))]
fn open_fds(pid: i32) -> usize {
    std::fs::read_dir(format!("/proc/{pid}/fd")).unwrap().count()
}

/// The children of `pid`, zombies included (a child not reaped yet).
#[cfg(target_vendor = "apple")]
fn children(pid: i32) -> BTreeSet<i32> {
    let mut pids = vec![0i32; 1024];
    // SAFETY: the buffer holds `pids.len()` pids; the call returns how many
    // it wrote.
    let count = unsafe {
        libc::proc_listchildpids(
            pid,
            pids.as_mut_ptr().cast(),
            (pids.len() * size_of::<i32>()) as libc::c_int,
        )
    };
    assert!(count >= 0, "list the holder's children: {}", std::io::Error::last_os_error());
    pids.truncate(count as usize);
    pids.into_iter().filter(|child| *child > 0).collect()
}

#[cfg(not(target_vendor = "apple"))]
fn children(pid: i32) -> BTreeSet<i32> {
    let mut found = BTreeSet::new();
    for entry in std::fs::read_dir("/proc").unwrap().flatten() {
        let Some(child) = entry.file_name().to_str().and_then(|name| name.parse::<i32>().ok())
        else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{child}/stat")) else { continue };
        // `pid (comm) state ppid ...`; the name may hold spaces or parens.
        let fields: Vec<&str> =
            stat.rsplit_once(')').map_or(vec![], |(_, rest)| rest.split_whitespace().collect());
        if fields.get(1).and_then(|ppid| ppid.parse::<i32>().ok()) == Some(pid) {
            found.insert(child);
        }
    }
    found
}

/// CPU time `pid` has used, user and system.
#[cfg(target_vendor = "apple")]
fn cpu_time(pid: i32) -> Duration {
    #[repr(C)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }
    unsafe extern "C" {
        fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
    }
    // SAFETY: a zeroed proc_taskinfo is a valid out-buffer of its size.
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: PROC_PIDTASKINFO fills one proc_taskinfo.
    let filled =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTASKINFO, 0, (&raw mut info).cast(), size) };
    assert_eq!(filled, size, "read the holder's CPU time: {}", std::io::Error::last_os_error());
    // The task's times are in Mach absolute time units (nanoseconds on Intel).
    let mut timebase = Timebase { numer: 0, denom: 0 };
    // SAFETY: fills one timebase.
    assert_eq!(unsafe { mach_timebase_info(&raw mut timebase) }, 0);
    let ticks = u128::from(info.pti_total_user + info.pti_total_system);
    let nanos = ticks * u128::from(timebase.numer) / u128::from(timebase.denom.max(1));
    Duration::from_nanos(u64::try_from(nanos).unwrap_or(u64::MAX))
}

#[cfg(not(target_vendor = "apple"))]
fn cpu_time(pid: i32) -> Duration {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).unwrap();
    // `pid (comm) state ...`: utime and stime are the 14th and 15th fields.
    let fields: Vec<&str> =
        stat.rsplit_once(')').map_or(vec![], |(_, rest)| rest.split_whitespace().collect());
    let ticks: u64 = fields[11].parse::<u64>().unwrap() + fields[12].parse::<u64>().unwrap();
    // SAFETY: sysconf takes no pointers.
    let per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
    Duration::from_nanos(ticks * 1_000_000_000 / per_second)
}

/// A holder whose soft `RLIMIT_NOFILE` is `limit`, inheriting only its
/// stdio, as the probe in [`base_descriptors`].
fn launch_limited(socket: &Path, limit: u64) -> Child {
    let mut current: libc::rlimit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: getrlimit fills one rlimit.
    assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut current) }, 0);
    let low = libc::rlimit { rlim_cur: limit as libc::rlim_t, rlim_max: current.rlim_max };
    launch_with(holder_binary(), socket, &TOKEN, move |command| {
        inherit_only_stdio(command);
        // SAFETY: setrlimit is async-signal-safe; it runs in the forked
        // child before exec and touches nothing else.
        unsafe {
            command.pre_exec(move || {
                if libc::setrlimit(libc::RLIMIT_NOFILE, &low) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    })
    .unwrap()
}

/// Descriptors a holder has open with one daemon link and no terminal,
/// inheriting only its stdio, as [`launch_limited`]'s holders do.
fn base_descriptors(dir: &Path) -> usize {
    let socket = dir.join("probe.sock");
    let probe = launch_with(holder_binary(), &socket, &TOKEN, inherit_only_stdio).unwrap();
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert!(listed.is_empty());
    settle(&mut client, 0);
    let base = open_fds(probe.id() as i32);
    drop(client);
    kill(probe);
    base
}

/// Spawn and attach terminals `1..=count`, each holding its master and its
/// ring segment once it runs.
fn spawn_shells(client: &mut HolderClient, count: u32) -> BTreeSet<i32> {
    let mut pids = BTreeSet::new();
    for chan in 1..=count {
        let (pid, _custody) = client.spawn(chan, &shell(chan)).unwrap();
        client.attach(chan, 0).unwrap();
        wait_output(client, chan, &format!("ready-{chan}"));
        pids.insert(pid);
    }
    pids
}

/// Holder-core deep review: a holder out of descriptors still lists every
/// terminal to a new daemon, with its master and ring segment, because a
/// listing passes the holder's own descriptors (shared until the frame is
/// written) and makes none. Before, it dup'd two per terminal for the
/// listing, so a holder short of descriptors refused every HELLO with
/// `NO_DESCRIPTORS`: the daemon that reconnected after a descriptor fault
/// could never get back in. A SPAWN the holder cannot open fails before it
/// forks, and leaves nothing open.
#[test]
fn a_holder_out_of_descriptors_lists_every_terminal_and_fails_only_the_spawn_it_cannot_open() {
    const TERMINALS: u32 = 4;
    let dir = temp_dir();
    let base = base_descriptors(&dir);
    // Two free with the terminals running (the last SPAWN's peak of four
    // fits): a new daemon's connection takes one. Once the superseded link
    // closed, a SPAWN's PTY pair fits in the two and its start-report pipe
    // does not.
    let limit = base + 2 * TERMINALS as usize + 2;
    let socket = dir.join("h.sock");
    let holder = launch_limited(&socket, limit as u64);
    let holder_pid = holder.id() as i32;
    let (mut first, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let shells = spawn_shells(&mut first, TERMINALS);
    settle(&mut first, 1);
    let used = open_fds(holder_pid);
    assert_eq!(used, base + 2 * TERMINALS as usize, "each terminal holds its master and ring");

    // A new daemon's HELLO: its connection takes one of the two, and the
    // listing takes none (before: eight dups). It lists every terminal with
    // its descriptors.
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN)
        .expect("a holder out of descriptors refused a HELLO it can list for free");
    assert_eq!(listed.len(), TERMINALS as usize, "a terminal is missing from the listing");
    for entry in &listed {
        assert!(entry.master.is_some(), "terminal {} listed without its master", entry.chan);
        assert!(entry.ring.is_some(), "terminal {} listed without its ring", entry.chan);
    }
    drop(first);
    settle(&mut client, 2);
    // The new link took the superseded one's place.
    assert_eq!(open_fds(holder_pid), used, "the listing left descriptors open");
    for entry in &listed {
        client.attach(entry.chan, entry.end).unwrap();
    }
    client.write(1, b"still-served\n").unwrap();
    wait_output(&mut client, 1, "still-served");

    // A SPAWN with two free: its PTY pair fits, its start-report pipe does
    // not, so it fails before it forks and closes the pair.
    let failed = client
        .spawn(TERMINALS + 1, &shell(TERMINALS + 1))
        .expect_err("a SPAWN started with no descriptor for its start report");
    let message = failed.to_string();
    assert!(message.contains(&format!("os error {}", libc::EMFILE)), "failed elsewhere: {message}");
    settle(&mut client, 3);
    assert_eq!(open_fds(holder_pid), used, "the failed SPAWN left descriptors open");
    assert_eq!(children(holder_pid), shells, "the failed SPAWN forked a child");
    client.write(2, b"after-spawn\n").unwrap();
    wait_output(&mut client, 2, "after-spawn");

    for chan in 1..=TERMINALS {
        client.close(chan, 200).unwrap();
    }
    drop(client);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Holder-core fix review: a daemon frame whose descriptors the holder
/// cannot take, because it is out of descriptors (macOS fails the read with
/// EMFILE, ENFILE or EMSGSIZE and drops them; Linux delivers what fits and
/// sets MSG_CTRUNC),
/// ends the link with an ERROR `NO_DESCRIPTORS` on channel 0 after the
/// frame the socket had taken part of, and is no strike against the
/// terminals the link streamed: the daemon did not die parsing them. Before,
/// the link just closed as a lost one, and two such links within the strike
/// window poisoned every terminal they streamed, so the next restore skipped
/// its ring (a GAP instead of the output the ring kept).
#[test]
fn a_frame_whose_descriptors_the_holder_cannot_take_ends_the_link_with_an_error_and_no_strike() {
    const TERMINALS: u32 = 2;
    const BALLAST: usize = 4;
    let dir = temp_dir();
    let base = base_descriptors(&dir);
    // One free once the ballast connections are accepted: an ADOPT passes two.
    let limit = base + 2 * TERMINALS as usize + BALLAST + 1;
    let socket = dir.join("h.sock");
    let holder = launch_limited(&socket, limit as u64);
    let holder_pid = holder.id() as i32;
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    spawn_shells(&mut client, TERMINALS);
    settle(&mut client, 1);
    assert_eq!(open_fds(holder_pid), base + 2 * TERMINALS as usize);
    let null = || OwnedFd::from(std::fs::File::open("/dev/null").unwrap());

    // Two links in a row end on the fault while they stream both terminals.
    for round in 0..2u64 {
        if round > 0 {
            let (next, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
            client = next;
            assert_eq!(listed.len(), TERMINALS as usize, "the holder lost a terminal");
            for entry in &listed {
                client.attach(entry.chan, entry.end).unwrap();
            }
        }
        // Connections that never say HELLO take one descriptor each. They
        // were queued before the PING, so the holder accepted them by its PONG.
        let ballast: Vec<UnixStream> =
            (0..BALLAST).map(|_| UnixStream::connect(&socket).unwrap()).collect();
        settle(&mut client, 10 + round);
        assert_eq!(open_fds(holder_pid), limit - 1, "round {round}: not one descriptor left");
        client.adopt_with_ring(9, &[9; 16], (0, 0, 0), &null(), &null(), b"").unwrap();
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            match client.next_event(deadline) {
                Ok(Event::Error { chan: 0, code, message, .. }) => {
                    assert_eq!(code, error_code::NO_DESCRIPTORS, "round {round}: {message}");
                    break;
                }
                Ok(Event::Data { .. }) => {}
                Ok(other) => panic!("round {round}: unexpected {other:?}"),
                Err(error) => panic!("round {round}: the link ended without telling why: {error}"),
            }
        }
        assert!(
            client.next_event(Instant::now() + Duration::from_secs(20)).is_err(),
            "round {round}: the link went on after the fault"
        );
        drop(ballast);
    }

    // The next daemon restores terminal 1 with its prologue: its ring
    // replays from the oldest byte, no strike having counted.
    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    let first = listed.iter().find(|entry| entry.chan == 1).expect("terminal 1 is listed");
    client.reattach(1, first.oldest).unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    match client.next_event(deadline).unwrap() {
        Event::Data { chan: 1, offset, .. } => assert_eq!(offset, first.oldest),
        Event::Gap { .. } => {
            panic!("two descriptor faults poisoned the terminal: its ring was skipped")
        }
        other => panic!("unexpected {other:?}"),
    }

    for chan in 1..=TERMINALS {
        client.close(chan, 200).unwrap();
    }
    drop(client);
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Holder-core deep review: a holder out of descriptors with a connection
/// it cannot accept sleeps until one of its descriptors frees, then serves
/// that connection. On Linux `accept` failing with EMFILE leaves the
/// connection queued, so the listener stays readable: before, every turn
/// polled it, failed the accept and polled again at once, and the one loop
/// that serves every terminal burned a core for as long as the holder was
/// full. (XNU drops a connection whose accept failed for want of a
/// descriptor, so there the listener goes quiet by itself and the test is
/// green either way.) The holder's CPU time across a quiet window is the
/// measure: a spinning holder is on a core for the whole window, a sleeping
/// one for a few turns.
#[test]
fn a_connection_the_holder_cannot_accept_waits_without_spinning_the_holder() {
    const BALLAST: usize = 4;
    /// The quiet window the holder's CPU time is read across: long against
    /// a few turns and Linux's 10 ms CPU accounting tick, short against
    /// the ballast's 5 s handshake deadline (which would free them).
    const WINDOW: Duration = Duration::from_millis(500);
    let dir = temp_dir();
    let base = base_descriptors(&dir);
    // Full once the ballast connections are accepted.
    let limit = base + BALLAST;
    let socket = dir.join("h.sock");
    let holder = launch_limited(&socket, limit as u64);
    let holder_pid = holder.id() as i32;
    let (mut client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    // Connections that never say HELLO take one descriptor each; queued
    // before the PING, so the holder accepted them by its PONG.
    let ballast: Vec<UnixStream> =
        (0..BALLAST).map(|_| UnixStream::connect(&socket).unwrap()).collect();
    settle(&mut client, 1);
    assert_eq!(open_fds(holder_pid), limit, "the holder is not at its limit");

    // A daemon's HELLO the holder has no descriptor to accept: it waits in
    // the listen queue. The PONG after it shows the holder had a turn with
    // it queued.
    let waiting = UnixStream::connect(&socket).unwrap();
    let hello = Out::default().u16(wire::VERSION).bytes(&TOKEN).0;
    wire::send_all(waiting.as_raw_fd(), &wire::encode(Kind::Hello, 0, &hello), &[]).unwrap();
    settle(&mut client, 2);
    let before = cpu_time(holder_pid);
    let started = Instant::now();
    // The measuring window, not a wait for a state: nothing is expected to
    // happen in it.
    std::thread::sleep(WINDOW);
    settle(&mut client, 3);
    let (used, window) = (cpu_time(holder_pid).saturating_sub(before), started.elapsed());
    assert!(
        used < window / 2,
        "the full holder spun on the connection it could not accept: {used:?} of CPU in {window:?}"
    );

    // Descriptors free once the holder read the ballast's ends of file. On
    // Linux the waiting connection is still queued: the holder takes it at
    // the end of that turn and serves its HELLO, which takes the holder
    // from `client` (SUPERSEDED, maybe before a PONG it had queued), so
    // the WELCOME is what shows it. XNU dropped the waiting connection: the
    // PONG after the ends of file shows the holder dropped them.
    drop(ballast);
    if cfg!(not(target_os = "linux")) {
        settle(&mut client, 4);
    } else {
        waiting.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = wire::Reader::default();
        let welcome = loop {
            if let Some(frame) = reader.next_frame().unwrap() {
                break frame;
            }
            let more =
                reader.fill(waiting.as_raw_fd()).expect("the waiting HELLO was never answered");
            assert!(more, "the holder closed the waiting connection unanswered");
        };
        assert_eq!(Kind::from_u16(welcome.kind), Some(Kind::Welcome));
    }
    // A new connection is served on every platform.
    let (next, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert!(listed.is_empty());

    drop((client, next, waiting));
    kill(holder);
    let _ = std::fs::remove_dir_all(&dir);
}
