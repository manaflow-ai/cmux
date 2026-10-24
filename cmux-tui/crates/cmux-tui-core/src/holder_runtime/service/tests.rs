//! Tests of the holder service: the ownership decision, and the service
//! against a real holder ([`harness`]).

use std::io::Read;
use std::os::fd::AsRawFd;
use std::time::{Duration, Instant};

use cmux_holder::client::{Event, HolderClient};
use cmux_holder::wire::Kind;

use self::harness::{TOKEN, Verdict, World};
use super::super::sink::SinkReader;
use super::*;

mod harness;

const A: [u8; 16] = [1; 16];
const B: [u8; 16] = [2; 16];
const C: [u8; 16] = [3; 16];

fn by_chan(mut claims: Vec<(u32, Claim)>) -> Vec<(u32, Claim)> {
    claims.sort_by_key(|(chan, _)| *chan);
    claims
}

/// Holder-core review: on a reconnect, a terminal the holder still runs
/// that no live terminal claims (a spawn whose SPAWNED the dropped link
/// lost, a terminal whose last CLOSE found no link) is ended, not left
/// running unseen, with its ring, for ever.
#[test]
fn a_reconnect_ends_what_the_holder_runs_that_nobody_claims() {
    let claims = ownership(&[(1, A), (2, B)], &[(1, A)], &[], false);
    assert_eq!(by_chan(claims), [(1, Claim::Resume), (2, Claim::Close)]);
}

/// Holder-core review: a startup-pass entry stays claimed across a
/// reconnect. The same holder keeps it (with its new listing); a new
/// holder, after the one that listed it died, gets its custody master
/// handed over, so the later re-attach does not ATTACH a channel only
/// the dead holder knew.
#[test]
fn a_reconnect_keeps_the_startup_pass_entries_and_hands_a_dead_holders_over() {
    let same = ownership(&[(3, C)], &[], &[(3, C)], false);
    assert_eq!(by_chan(same), [(3, Claim::Refresh)]);
    let new = ownership(&[], &[(1, A)], &[(3, C)], false);
    assert_eq!(by_chan(new), [(1, Claim::Adopt), (3, Claim::HandOver)]);
}

/// Holder-core review: only the startup pass keeps what nobody claims
/// yet (for it to re-attach); any other link ends it.
#[test]
fn only_the_startup_pass_keeps_what_nobody_claims() {
    let startup = ownership(&[(1, A), (2, B)], &[], &[], true);
    assert_eq!(by_chan(startup), [(1, Claim::Reserve), (2, Claim::Reserve)]);
    let other = ownership(&[(1, A), (2, B)], &[], &[], false);
    assert_eq!(by_chan(other), [(1, Claim::Close), (2, Claim::Close)]);
}

/// A live terminal resumes on the same holder and is adopted by a new
/// one; neither is ended.
#[test]
fn live_terminals_resume_on_the_same_holder_and_are_adopted_by_a_new_one() {
    let claims = ownership(&[(1, A)], &[(1, A), (2, B)], &[], false);
    assert_eq!(by_chan(claims), [(1, Claim::Resume), (2, Claim::Adopt)]);
}

/// Not a check: the holder process a [`harness::Holders`] starts, as the
/// only test of a run of this binary. It serves the socket
/// [`harness::HOLDER_SOCKET_ENV`] names (owner token on stdin, `ready` on
/// stdout) until the test that started it kills it. A normal run does not
/// set that variable, and it returns at once.
#[test]
fn holder_process() {
    let Some(socket) = std::env::var_os(harness::HOLDER_SOCKET_ENV) else { return };
    let args = ["--socket".to_string(), socket.to_string_lossy().into_owned()];
    if let Err(error) = cmux_holder::serve(&args) {
        panic!("the test holder: {error}");
    }
}

/// `cat` behind a `ready-TAG` line, as terminal id `[tag; 16]`.
fn shell(tag: u8) -> SpawnRequest {
    SpawnRequest {
        id: [tag; 16],
        cols: 80,
        rows: 24,
        cwd: b"/tmp".to_vec(),
        argv: vec![
            b"/bin/sh".to_vec(),
            b"-c".to_vec(),
            format!("echo ready-{tag}; exec cat").into_bytes(),
        ],
        env: vec![b"PATH=/usr/bin:/bin".to_vec(), b"TERM=xterm-256color".to_vec()],
        ..SpawnRequest::default()
    }
}

/// Read `sink` as the terminal's parser does until its output contains
/// `needle`; fails the test when it does not in time.
fn read_until(sink: &Arc<HolderSink>, needle: &str) {
    let (found, text) = std::sync::mpsc::channel();
    let (sink, wanted) = (sink.clone(), needle.to_string());
    std::thread::spawn(move || {
        let mut reader = SinkReader(sink);
        let (mut seen, mut buf) = (String::new(), [0u8; 4096]);
        while !seen.contains(&wanted) {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => seen.push_str(&String::from_utf8_lossy(&buf[..n])),
            }
        }
        let _ = found.send(seen);
    });
    let seen = text
        .recv_timeout(Duration::from_secs(20))
        .unwrap_or_else(|_| panic!("the terminal never showed {needle:?}"));
    assert!(seen.contains(needle), "the stream ended before {needle:?}: {seen:?}");
}

/// Type `text` into `terminal`'s custody master, as the surface does.
fn type_into(terminal: &HolderTerminal, text: &str) {
    // SAFETY: writes from a live slice to the master this terminal keeps.
    let written =
        unsafe { libc::write(terminal.custody.as_raw_fd(), text.as_ptr().cast(), text.len()) };
    assert_eq!(written, text.len() as isize, "{}", std::io::Error::last_os_error());
}

/// A previous daemon of the session left terminal `chan` (`cat`, id
/// `[chan; 16]`) running on the holder: it started it, read its first
/// line, then DETACHed and exited. Returns its terminal id.
fn leave_a_terminal(world: &World, chan: u32) -> [u8; 16] {
    let request = shell(chan as u8);
    let (mut client, _) = HolderClient::connect(world.holder_socket(), &TOKEN).unwrap();
    client.spawn(chan, &request).unwrap();
    client.attach(chan, 0).unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut text = String::new();
    while !text.contains(&format!("ready-{chan}")) {
        if let Event::Data { bytes, .. } = client.next_event(deadline).unwrap() {
            text.push_str(&String::from_utf8_lossy(&bytes));
        }
    }
    client.detach(chan).unwrap();
    request.id
}

/// Holder-core review (the ownership rule, 9da66822087): a reconnect to
/// the same holder ends what it runs that no live terminal claims. The
/// link is cut at the frame that answers a SPAWN, so the spawn fails while
/// the holder runs its shell; the next link the service makes CLOSEs it.
/// Red before the rule: a reconnect re-adopted live terminals only, and the
/// shell ran on with its ring, owned by nobody, for ever.
#[test]
fn a_reconnect_to_the_same_holder_ends_the_shell_of_a_spawn_whose_answer_the_link_lost() {
    let world = World::new();
    world.proxy.set_rule(|seen| {
        if seen.conn == 1 && !seen.to_holder && seen.kind == Some(Kind::Spawned) {
            Verdict::Cut
        } else {
            Verdict::Forward
        }
    });
    let failed = world.service.spawn(&shell(1), b"").err();
    assert!(failed.is_some(), "a spawn whose SPAWNED never arrived succeeded");
    let lost = world.proxy.wait_for("the SPAWNED the link lost", |seen| {
        !seen.to_holder && seen.kind == Some(Kind::Spawned)
    });
    world.proxy.wait_for("the CLOSE of the shell nobody owns, on the next link", |seen| {
        seen.conn > lost.conn && seen.sent(Kind::Close, lost.chan)
    });
}

/// Holder-core review (the ownership rule): only the first link the startup
/// pass makes keeps what the holder runs that nobody claims yet, for that
/// pass to re-attach. A first link a spawn makes ends a shell a previous
/// daemon left, before the spawn. Red when any first link keeps it (the
/// code before the rule, or `first` alone in `link_or_launch`).
#[test]
fn a_first_link_a_spawn_makes_ends_what_a_previous_daemon_left() {
    let world = World::new();
    world.holders.start(&TOKEN).unwrap();
    leave_a_terminal(&world, 7);
    let terminal = world.service.spawn(&shell(1), b"").unwrap();
    let frames = world
        .proxy
        .frames_until("the new terminal's SPAWN", |seen| seen.sent(Kind::Spawn, terminal.chan));
    assert!(
        frames.iter().any(|seen| seen.sent(Kind::Close, 7)),
        "the first link kept the left shell: {frames:?}"
    );
    read_until(&terminal.sink, "ready-1");
}

/// Holder-core review (the ownership rule): a terminal the startup pass
/// keeps for its re-attach stays claimed when its holder dies before the
/// re-attach. The next holder gets its custody master and ring (an ADOPT
/// without ATTACH), and the re-attach then streams it from the ring the
/// dead holder kept. Red before the rule: the reconnect re-adopted live
/// terminals only, and the re-attach ATTACHed a channel only the dead
/// holder knew, so its stream never started.
#[test]
fn a_startup_entry_whose_holder_died_is_handed_to_the_next_holder_and_reattaches() {
    let world = World::new();
    world.holders.start(&TOKEN).unwrap();
    let id = leave_a_terminal(&world, 7);
    assert!(world.service.lists(&id), "the startup pass did not find the left terminal");
    world.holders.crash();
    world.proxy.wait_for("the entry's ADOPT on the next holder", |seen| seen.sent(Kind::Adopt, 7));
    let terminal = world.service.reattach(&id).unwrap().expect("the next holder runs the entry");
    read_until(&terminal.sink, "ready-7");
    type_into(&terminal, "after-crash\n");
    read_until(&terminal.sink, "after-crash");
}
