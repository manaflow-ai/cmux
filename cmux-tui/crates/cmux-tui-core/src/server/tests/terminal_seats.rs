//! The accept loop counts a connection as a terminal's from the terminals'
//! seats (`diagnostics/terminal_seats.rs`, `server/terminal_admission.rs`):
//! with no read of the session state, and also for a connection that came
//! before its terminal had its seat. The terminal of a host that the daemon
//! starts has no such connection: its host has a seat first.

use std::os::unix::net::UnixStream;

use super::*;
use crate::diagnostics::{
    ClientKind, ConnectionStats, HostSeating, KeptHost, LongConnectionsFull, SeatedTerminal,
};
use crate::platform::transport::Stream;
use crate::process_resources::{ProcessStart, process_start};
use crate::server::listen::ServedSession;
use crate::server::terminal_admission::{
    admit, admit_session, admit_session_by, parent_process, peer_session,
};

const LIMIT: u64 = MAX_SERVER_CONNECTIONS as u64;
const LANE: u64 = MAX_TERMINAL_CONNECTIONS as u64;
const LONG: u64 = message_writer::long_connection::MAX_LONG_TERMINAL_CONNECTIONS;

/// A process session that no process of the test holds.
const SESSION: u32 = 4_000_001;

/// The process of a terminal host that no process of the test holds.
const HOST: u32 = 4_100_001;

/// `(short connections, of them in the terminals' lane, long connections)`.
fn held(connections: &ConnectionStats) -> (u64, u64, u64) {
    (connections.active(), connections.terminal_active(), connections.long_active())
}

/// One connection of a client in process session `session`, as the accept
/// loop admits it, with the client's end.
fn connect(connections: &Arc<ConnectionStats>, session: u32) -> (ConnectionPermit, UnixStream) {
    let (daemon_side, client) = UnixStream::pair().unwrap();
    let permit = admit_session(connections, &daemon_side, Some(session)).expect("a free slot");
    (permit, client)
}

/// One connection of a client in process session `session` whose leader's
/// parent is `parent`, as the accept loop admits it, with the client's end.
/// The accept asks only for the parent of the session's leader.
fn connect_under(
    connections: &Arc<ConnectionStats>,
    session: u32,
    parent: Option<u32>,
) -> (ConnectionPermit, UnixStream) {
    let (daemon_side, client) = UnixStream::pair().unwrap();
    let parent_of = |leader| {
        assert_eq!(leader, session, "the accept asks for the parent of the session's leader");
        parent
    };
    let permit =
        admit_session_by(connections, &daemon_side, Some(session), parent_of).expect("a free slot");
    (permit, client)
}

/// The terminal of a client in process session `session` by the seats, for
/// a session that has a seat or while no host starts: the parent of the
/// session's leader is not read then.
fn seated_with_no_parent_read(connections: &ConnectionStats, session: u32) -> Option<Arc<str>> {
    let seated = connections.seated_terminal(session, |leader| {
        panic!("the accept read the parent of process {leader}")
    });
    seated.and_then(|terminal| terminal.id)
}

/// Starts a stream on the connection of `permit`, as a `subscribe` does.
fn start_stream(permit: &ConnectionPermit) -> std::io::Result<OutboundStream> {
    let (writer, _outbound) = captured_writer();
    writer.long.attach(permit);
    writer.start_stream(&json!({"event": "overflow"}))
}

/// The process session of this test's process, as the accept loop reads it
/// from a connection of its own.
fn own_session(stream: &UnixStream) -> u32 {
    let key = Stream::peer_process_key(stream).expect("peer key");
    let pid = origin_gate::peer_pid(&key);
    pid.and_then(origin_gate::peer_session_id).expect("our session")
}

/// The accept loop read the terminals from the session state when its lock
/// was free, and answered from the last set read when it was held: a new
/// terminal's connection was then an outside one for its whole life. The
/// count: the accept loop (`ServedSession::serve`) takes the state lock 0
/// times on its thread, for an outside client and for a terminal.
///
/// The count is made with the state lock FREE: a try on a held lock makes
/// no guard and is not counted, so a count under a held lock is always 0.
/// The last assert shows that the count is live: one read of the state on
/// this thread is 1.
#[test]
fn the_accept_loop_takes_the_state_lock_zero_times() {
    let mux = test_mux();
    let connections = mux.connection_stats().clone();
    let served = ServedSession { mux: mux.clone(), render_service: Arc::new(RenderService::new()) };
    let (outside_side, outside_client) = UnixStream::pair().unwrap();
    let (terminal_side, terminal_client) = UnixStream::pair().unwrap();
    let session = own_session(&outside_side);
    assert!(!connections.terminal_seated(session), "the test's process is in no terminal");

    let before = crate::mux::state_locks_taken_on_this_thread();
    served.serve(Box::new(outside_side));
    assert_eq!(held(&connections), (1, 0, 0), "no seat: an outside client");
    let seat = connections.seat_terminal(Some(session), None);
    served.serve(Box::new(terminal_side));
    assert_eq!(held(&connections), (2, 2, 0), "a seat: both are the terminal's");
    assert_eq!(
        crate::mux::state_locks_taken_on_this_thread() - before,
        0,
        "the accept loop took the session state lock"
    );
    mux.with_state(|_| ());
    assert_eq!(crate::mux::state_locks_taken_on_this_thread() - before, 1, "the count is live");
    drop((outside_client, terminal_client, seat));
}

/// A peer with no process session (no key, a key that names no process) is
/// an outside client, and no seat takes its connection over.
#[test]
fn a_peer_with_no_process_session_is_an_outside_client() {
    for key in [None, Some(""), Some("token:"), Some("token:0.1"), Some("pid:1.2")] {
        assert_eq!(peer_session(key), None, "{key:?}");
    }
    let connections = Arc::new(ConnectionStats::default());
    let (daemon_side, _client) = UnixStream::pair().unwrap();
    let permit = admit_session(&connections, &daemon_side, None).expect("a free slot");
    let seat = connections.seat_terminal(Some(SESSION), None);
    assert_eq!(held(&connections), (1, 0, 0));
    drop((permit, seat));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// A terminal that takes its seat while another change holds the state lock
/// is a terminal at its next connection: the accept does not wait for that
/// lock and does not need it.
#[test]
fn an_accept_under_a_held_state_lock_sees_a_seat_taken_under_it() {
    let mux = test_mux();
    let connections = mux.connection_stats().clone();
    let (daemon_side, _client) = UnixStream::pair().unwrap();
    let session = own_session(&daemon_side);
    assert!(!connections.terminal_seated(session), "the test's process is in no terminal");

    let state = mux.state.lock().unwrap();
    let outside = admit(&connections, &daemon_side).expect("a free slot");
    assert_eq!(held(&connections), (1, 0, 0), "no seat: an outside client");
    let seat = connections.seat_terminal(Some(session), None);
    let (second_daemon_side, _second_client) = UnixStream::pair().unwrap();
    let terminal = admit(&connections, &second_daemon_side).expect("a free slot");
    drop(state);

    // The first connection came before the seat: it joined the terminal too.
    assert_eq!(held(&connections), (2, 2, 0));
    drop((outside, terminal));
    assert_eq!(held(&connections), (0, 0, 0));

    drop(seat);
    let (third_daemon_side, _third_client) = UnixStream::pair().unwrap();
    let after = admit(&connections, &third_daemon_side).expect("a free slot");
    assert_eq!(held(&connections), (1, 0, 0), "the seat ends with the terminal's runtime");
    drop(after);
}

/// A terminal's surface takes the seat when its runtime is made: before the
/// surface is in the session state. Its process can connect from then on and
/// is a terminal's.
#[test]
fn a_terminal_has_its_seat_before_it_is_in_the_session_state() {
    let mux = test_mux();
    let connections = mux.connection_stats().clone();
    let id = 9_000_017;
    let surface =
        crate::Surface::spawn_for_test(id, SurfaceOptions::default(), Arc::downgrade(&mux))
            .unwrap();
    let session = surface.process_id().expect("the test surface's process");
    assert!(!mux.with_state(|state| state.surfaces.contains_key(&id)));
    assert!(connections.terminal_seated(session), "seated before it is in the session state");

    let (in_terminal, _client) = connect(&connections, session);
    assert_eq!(held(&connections), (1, 1, 0));
    drop(in_terminal);
    assert_eq!(held(&connections), (0, 0, 0));
}

/// Two runtimes of one terminal (it moves to another host) hold two seats
/// for one process session: the session stays seated until both are gone.
#[test]
fn a_session_stays_seated_until_its_last_seat_is_gone() {
    let connections = Arc::new(ConnectionStats::default());
    let old = connections.seat_terminal(Some(SESSION), None);
    let new = connections.seat_terminal(Some(SESSION), None);
    assert_eq!(old.process_id(), Some(SESSION));
    drop(old);
    assert!(connections.terminal_seated(SESSION));
    drop(new);
    assert!(!connections.terminal_seated(SESSION));
    let none = connections.seat_terminal(None, None);
    assert_eq!(none.process_id(), None);
}

/// A terminal's process starts before the daemon has its process id, so it
/// can connect first. That connection was an outside one for its whole life;
/// with a stream it held one of the session's 64 slots, and 63 of them held
/// every slot. It now joins its terminal when the terminal takes its seat: a
/// short one is counted in the terminals' lane, one with a stream gets a long
/// place and gives its slot back.
#[test]
fn a_connection_that_came_before_its_terminal_joins_it_at_the_seat() {
    let connections = Arc::new(ConnectionStats::default());
    let (short, _short_client) = connect(&connections, SESSION);
    let (long, _long_client) = connect(&connections, SESSION);
    let (other, _other_client) = connect(&connections, SESSION + 1);
    start_stream(&long).expect("an outside connection starts a stream with no gate");
    assert_eq!(held(&connections), (3, 0, 0), "three outside connections");

    let seat = connections.seat_terminal(Some(SESSION), None);
    assert_eq!(held(&connections), (2, 1, 1));
    assert!(long.lease().is_long() && !short.lease().is_long() && !other.lease().is_long());

    // From here the short one is a terminal's connection: a stream on it
    // takes a long place in the usual way.
    start_stream(&short).expect("a long place");
    assert_eq!(held(&connections), (1, 0, 2));
    start_stream(&other).expect("an outside connection");
    assert_eq!(held(&connections), (1, 0, 2), "another session's connection does not change");

    drop((short, long, other, seat));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// The red of the burst: 63 processes of new terminals connect and read the
/// session's events before the daemon has their terminals. They held 63 of
/// the 64 slots. When each terminal has its seat, the slots are free again.
#[test]
fn streams_that_came_before_their_terminals_give_the_slots_back() {
    let connections = Arc::new(ConnectionStats::default());
    let holders: Vec<_> = (0..LIMIT - 1)
        .map(|index| {
            let session = SESSION + u32::try_from(index).unwrap();
            let (permit, client) = connect(&connections, session);
            start_stream(&permit).expect("an outside connection");
            (permit, client, session)
        })
        .collect();
    assert_eq!(held(&connections), (LIMIT - 1, 0, 0));

    let seats: Vec<_> = holders
        .iter()
        .map(|(_, _, session)| connections.seat_terminal(Some(*session), None))
        .collect();
    assert_eq!(held(&connections), (0, 0, LIMIT - 1));

    // A hook or a typed command of each terminal finds the lane free, up to
    // the lane's own limit.
    let short: Vec<_> = holders
        .iter()
        .filter_map(|(_, _, session)| {
            let (daemon_side, client) = UnixStream::pair().unwrap();
            let permit = admit_session(&connections, &daemon_side, Some(*session)).ok()?;
            Some((permit, client))
        })
        .collect();
    assert_eq!(held(&connections), (LANE, LANE, LIMIT - 1));
    let snapshot = connections.snapshot(LIMIT);
    assert_eq!(snapshot.refused, LIMIT - 1 - LANE, "only the lane's own limit refuses");
    drop((short, holders, seats));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// The long lane's limit is not a hard one for a connection that came before
/// its terminal's seat: it is open already, so it enters above the limit
/// (`TerminalLane::enter`). Each later claim counts such connections: above
/// the limit and at the limit a stream does not start and the error names
/// the limit; one place under the limit, the stream starts. Three of the four
/// refusals come with fewer than 256 connections that claimed their place,
/// so they prove that a claim counts the early ones. Each step is a count of
/// the lane, with no clock.
#[test]
fn a_long_lane_above_its_limit_refuses_each_claim_until_it_is_under_it() {
    const EARLY: u64 = 3;
    let connections = Arc::new(ConnectionStats::default());
    let mut long: Vec<ConnectionPermit> = (1000u32..)
        .zip(0..LONG)
        .map(|(terminal, _)| {
            let permit = claim_terminal_connection_from(&connections, terminal)
                .expect("a short slot, free again after each stream");
            start_stream(&permit).expect("a long place below the bound");
            permit
        })
        .collect();
    assert_eq!(held(&connections), (0, 0, LONG), "the lane is at its limit");

    let mut early: Vec<_> = (0..EARLY)
        .map(|index| {
            let session = SESSION + u32::try_from(index).unwrap();
            let (permit, client) = connect(&connections, session);
            start_stream(&permit).expect("an outside connection starts a stream with no gate");
            (permit, client, session)
        })
        .collect();
    assert_eq!(held(&connections), (EARLY, 0, LONG));
    let seats: Vec<_> = early
        .iter()
        .map(|(_, _, session)| connections.seat_terminal(Some(*session), None))
        .collect();
    assert_eq!(held(&connections), (0, 0, LONG + EARLY), "the lane is above its limit");
    assert!(early.iter().all(|(permit, _, _)| permit.lease().is_long()));

    let next_seat = connections.seat_terminal(Some(SESSION + 500), None);
    let (next, _next_client) = connect(&connections, SESSION + 500);
    let refused_with_the_bound = |lane: u64| {
        assert_eq!(held(&connections), (1, 1, lane));
        let Err(error) = start_stream(&next) else {
            panic!("a stream started with {lane} long connections")
        };
        let full = error
            .get_ref()
            .and_then(|inner| inner.downcast_ref::<LongConnectionsFull>())
            .expect("the error of the bound");
        assert_eq!(full.limit, LONG);
        assert!(error.to_string().contains("limit 256"), "{error}");
        assert!(!next.lease().is_long());
        assert_eq!(held(&connections), (1, 1, lane), "a refused claim changes no count");
    };
    refused_with_the_bound(LONG + EARLY);
    // 255 that claimed their place and the 3 early ones: a claim that did not
    // count the early ones would get a place here.
    long.pop();
    refused_with_the_bound(LONG + EARLY - 1);
    early.pop();
    refused_with_the_bound(LONG + EARLY - 2);
    early.pop();
    refused_with_the_bound(LONG);

    early.clear();
    assert_eq!(held(&connections), (1, 1, LONG - 1), "one place under the limit");
    start_stream(&next).expect("the lane is under its limit: the claim is taken");
    assert!(next.lease().is_long());
    assert_eq!(held(&connections), (0, 0, LONG));
    drop((long, next, seats, next_seat));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// A connection that came before its terminal and whose client hung up gave
/// its slot back already: the seat changes nothing, and each count is zero
/// when the connection ends.
#[test]
fn a_hung_up_connection_does_not_join_a_terminal() {
    let connections = Arc::new(ConnectionStats::default());
    let (gone, gone_client) = connect(&connections, SESSION);
    let fill: Vec<_> = (1..LIMIT).map(|_| connect(&connections, SESSION + 1)).collect();
    drop(gone_client);
    let (next, _next_client) = connect(&connections, SESSION + 1);
    assert!(gone.lease().is_hung_up(), "the accept at the limit took the slot back");

    let seat = connections.seat_terminal(Some(SESSION), None);
    assert_eq!(held(&connections), (LIMIT, 0, 0));
    assert_eq!(connections.snapshot(LIMIT).hung_up, 1);
    drop((gone, fill, next, seat));
    assert_eq!(held(&connections), (0, 0, 0));
    assert_eq!(connections.snapshot(LIMIT).hung_up, 0);
}

/// A terminal's connection is refused by the lane it asked for.
#[test]
fn a_refused_connection_names_its_lane() {
    let connections = Arc::new(ConnectionStats::default());
    let _seat = connections.seat_terminal(Some(SESSION), None);
    let (daemon_side, _client) = UnixStream::pair().unwrap();
    let terminals: Vec<_> = (0..LANE)
        .map(|index| {
            let session = SESSION + 1 + u32::try_from(index).unwrap();
            (connections.seat_terminal(Some(session), None), connect(&connections, session))
        })
        .collect();
    let refused = admit_session(&connections, &daemon_side, Some(SESSION)).err();
    assert_eq!(refused, Some(ClientKind::Terminal));
    let outside: Vec<_> = (LANE..LIMIT).map(|_| connect(&connections, 1)).collect();
    let refused = admit_session(&connections, &daemon_side, None).err();
    assert_eq!(refused, Some(ClientKind::Local));
    drop((terminals, outside));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// The accept of a terminal's first connection and the terminal's seat at
/// one moment: in each order the connection ends in the terminals' lane.
/// The seat is taken before the terminal looks at the open connections, and
/// the connection writes its session before it looks at the seats. A test by
/// chance: without that order it fails only when the two threads meet.
#[test]
fn a_connection_and_its_terminals_seat_at_one_moment_meet() {
    for round in 0..300 {
        let connections = Arc::new(ConnectionStats::default());
        let (daemon_side, _client) = UnixStream::pair().unwrap();
        let start = Arc::new(std::sync::Barrier::new(2));
        let accept = {
            let (connections, start) = (connections.clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                admit_session(&connections, &daemon_side, Some(SESSION)).expect("a free slot")
            })
        };
        start.wait();
        let seat = connections.seat_terminal(Some(SESSION), None);
        let permit = accept.join().expect("the accept's thread");
        assert_eq!(held(&connections), (1, 1, 0), "round {round}");
        drop((permit, seat));
        assert_eq!(held(&connections), (0, 0, 0), "round {round}");
    }
}

/// A seat, a stream's start and a take-back after a hang-up at one moment on
/// one connection: each slot goes back one time. Whatever the order, the
/// connection ends as a long one or as a hung-up one, it holds no short slot
/// and no place of the lane, and each count is zero when it ends. A test by
/// chance, as above.
#[test]
fn a_seat_a_stream_and_a_hang_up_at_one_moment_keep_the_counts() {
    for round in 0..300 {
        let connections = Arc::new(ConnectionStats::default());
        let (permit, client) = connect(&connections, SESSION);
        let fill: Vec<_> = (1..LIMIT).map(|_| connect(&connections, SESSION + 1)).collect();
        drop(client);
        let start = Arc::new(std::sync::Barrier::new(3));
        let stream = {
            let (lease, start) = (permit.lease().clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                lease.become_long(1).expect("no bound for a connection that is open already");
            })
        };
        let take_back = {
            let (connections, start) = (connections.clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                // At the limit: this accept takes back the slot of the client
                // that hung up, or finds the slot that the stream gave back. It
                // is refused when the stream gives the slot back after its look.
                let (daemon_side, client) = UnixStream::pair().unwrap();
                let permit = admit_session(&connections, &daemon_side, Some(SESSION + 1)).ok()?;
                Some((permit, client))
            })
        };
        start.wait();
        let seat = connections.seat_terminal(Some(SESSION), None);
        stream.join().expect("the stream's thread");
        let next = take_back.join().expect("the accept's thread");

        let lease = permit.lease();
        let (short, lane, long) = held(&connections);
        let hung_up = connections.snapshot(LIMIT).hung_up;
        assert_eq!(hung_up, u64::from(lease.is_hung_up()), "round {round}");
        assert_eq!(long, u64::from(lease.is_long()), "round {round}");
        assert!(lease.is_long() != lease.is_hung_up(), "round {round}: one of the two");
        assert!(next.is_some() || lease.is_long(), "round {round}: a hang-up gives the slot");
        assert_eq!(short, LIMIT - 1 + u64::from(next.is_some()), "round {round}");
        assert_eq!(lane, 0, "round {round}: the connection left the lane");
        drop((permit, fill, next, seat));
        assert_eq!(held(&connections), (0, 0, 0), "round {round}");
        assert_eq!(connections.snapshot(LIMIT).hung_up, 0, "round {round}");
    }
}

/// The host of a new terminal takes its seat before it starts the terminal's
/// process, and that process leads its own session as the host's child. Its
/// first connection is then its terminal's: in the terminals' lane and with
/// the terminal's id, before the terminal has its own seat. The terminal's
/// seat takes nothing over (no count changes), and the host's seat ends with
/// no gap: the session is the same terminal's before, at and after it.
#[test]
fn a_new_terminals_first_connection_is_its_terminals_while_its_host_starts() {
    let connections = Arc::new(ConnectionStats::default());
    let seating = HostSeating::of(connections.clone(), Some("terminal-1"));
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None, "no host starts");
    let host_seat = seating.seat(HOST);
    assert!(!connections.terminal_seated(SESSION), "the terminal has no seat of its own yet");

    let (first, _first_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (1, 1, 0), "the first connection is in the terminals' lane");
    let terminal = Some(SeatedTerminal { id: Some(Arc::from("terminal-1")) });
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), terminal);

    // The child of a process that is no host, a process with no parent that
    // the daemon can read, and the host's own session are outside clients.
    let (other, _other_client) = connect_under(&connections, SESSION + 1, Some(HOST + 1));
    let (orphan, _orphan_client) = connect_under(&connections, SESSION + 2, None);
    let (host, _host_client) = connect_under(&connections, HOST, Some(1));
    assert_eq!(held(&connections), (4, 1, 0));
    assert_eq!(connections.seated_terminal(SESSION + 1, |_| Some(HOST + 1)), None);
    assert_eq!(connections.seated_terminal(HOST, |_| Some(1)), None);

    let seat = connections.seat_terminal(Some(SESSION), Some("terminal-1"));
    assert_eq!(held(&connections), (4, 1, 0), "the terminal's seat takes no connection over");
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), terminal);
    drop(host_seat);
    assert_eq!(seated_with_no_parent_read(&connections, SESSION).as_deref(), Some("terminal-1"));
    assert_eq!(seated_with_no_parent_read(&connections, SESSION + 1), None, "no host starts");

    start_stream(&first).expect("a long place");
    assert_eq!(held(&connections), (3, 0, 1), "the first connection is the terminal's long one");
    drop((first, other, orphan, host, seat));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// A host whose launch fails, or that ends before its terminal has a seat,
/// leaves no seat: a process that has its process id as its parent after
/// that is an outside client, and the parent is not read.
#[test]
fn a_host_that_ends_before_its_terminal_leaves_no_seat() {
    let connections = Arc::new(ConnectionStats::default());
    let seating = HostSeating::of(connections.clone(), Some("terminal-1"));
    let first = seating.seat(HOST);
    let again = seating.seat(HOST);
    drop(first);
    let (inside, _inside_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (1, 1, 0), "one seat of the host is left");
    drop(again);
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None);
    let (outside, _outside_client) = connect(&connections, SESSION);
    assert_eq!(held(&connections), (2, 1, 0), "no seat: an outside client");

    // A terminal with no session to seat it (`HostSeating::default`) seats
    // no host.
    let unseated = HostSeating::default().seat(HOST);
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None);
    drop((inside, outside, unseated));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// The parent that the accept reads is the system's: this test's process
/// has the parent that `getppid` names.
#[test]
fn the_parent_of_a_process_is_the_systems() {
    // SAFETY: `getppid` has no arguments and cannot fail.
    let parent = unsafe { libc::getppid() };
    assert_eq!(parent_process(std::process::id()), u32::try_from(parent).ok());
}

/// The parent of a process is read whatever bytes the name of its program
/// has. The system keeps 15 bytes of that name.
#[cfg(target_os = "linux")]
#[test]
fn the_parent_is_read_for_each_program_name() {
    use std::os::unix::process::CommandExt;
    let dir = std::env::temp_dir().join(format!("cmux-parent-name-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // 8 characters of 2 bytes: byte 15 is the first half of the last one.
    let program = dir.join("\u{e9}".repeat(8));
    std::os::unix::fs::symlink("/bin/sleep", &program).unwrap();
    let mut child = std::process::Command::new(&program).arg0("sleep").arg("30").spawn().unwrap();
    let line = std::fs::read(format!("/proc/{}/stat", child.id())).unwrap();
    let parent = parent_process(child.id());
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        std::str::from_utf8(&line).is_err(),
        "setup: the name was not cut inside a character: {}",
        String::from_utf8_lossy(&line)
    );
    assert_eq!(parent, Some(std::process::id()), "the parent of a child of this test");
}

/// A burst of 300 terminals whose hosts the daemon starts, each with one
/// event stream that its process opens before the terminal has its seat.
/// The counts, with no clock:
/// - 0 connections come as outside ones (each is in the terminals' lane at
///   its accept);
/// - 0 connections join a terminal at its seat (no count changes there);
/// - the long lane is never above its limit of 256: the 44 streams above it
///   are refused with the limit's error.
///
/// The last part shows that the count is live: a terminal that starts
/// another way has no host seat, its early stream joins at the seat, and
/// the lane is then above its limit by that one.
#[test]
fn a_burst_of_300_hosted_terminals_joins_nothing_and_keeps_the_long_lane_at_its_limit() {
    const TERMINALS: u32 = 300;
    let connections = Arc::new(ConnectionStats::default());
    let mut streams = Vec::new();
    let mut refused = Vec::new();
    let mut seats = Vec::new();
    for index in 0..TERMINALS {
        let (host, session) = (HOST + index, SESSION + index);
        let id = format!("terminal-{index}");
        let host_seat = HostSeating::of(connections.clone(), Some(id.as_str())).seat(host);
        let long = u64::from(index).min(LONG);
        let short = u64::try_from(refused.len()).unwrap();
        assert_eq!(held(&connections), (short, short, long), "terminal {index}: before");

        let (permit, client) = connect_under(&connections, session, Some(host));
        assert_eq!(
            held(&connections),
            (short + 1, short + 1, long),
            "terminal {index}: its first connection came as an outside one"
        );
        match start_stream(&permit) {
            Ok(_) => {
                assert!(long < LONG, "terminal {index}: a stream started above the limit");
                assert!(permit.lease().is_long());
                streams.push((permit, client));
            }
            Err(error) => {
                assert_eq!(long, LONG, "terminal {index}: refused under the limit: {error}");
                let full = error
                    .get_ref()
                    .and_then(|inner| inner.downcast_ref::<LongConnectionsFull>())
                    .expect("the error of the bound");
                assert_eq!(full.limit, LONG);
                refused.push((permit, client));
            }
        }
        let at_the_seat = held(&connections);
        assert!(at_the_seat.2 <= LONG, "terminal {index}: the long lane is above its limit");
        seats.push(connections.seat_terminal(Some(session), Some(id.as_str())));
        assert_eq!(held(&connections), at_the_seat, "terminal {index}: a join at its seat");
        drop(host_seat);
        assert_eq!(seated_with_no_parent_read(&connections, session).as_deref(), Some(id.as_str()));
    }
    let above = u64::from(TERMINALS) - LONG;
    assert_eq!((streams.len(), refused.len()), (256, 44));
    assert_eq!(held(&connections), (above, above, LONG));
    drop(refused);
    assert_eq!(held(&connections), (0, 0, LONG));

    // The count is live: with no host seat the early stream is an outside
    // one, and it joins above the limit at its terminal's seat.
    let (early, _early_client) = connect(&connections, SESSION + TERMINALS);
    start_stream(&early).expect("an outside connection starts a stream with no gate");
    assert_eq!(held(&connections), (1, 0, LONG));
    let late_seat = connections.seat_terminal(Some(SESSION + TERMINALS), None);
    assert_eq!(held(&connections), (0, 0, LONG + 1), "one join above the limit");
    drop((streams, early, seats, late_seat));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// Each connection that a client in process session `session`, whose
/// leader's parent is `parent`, gets from now to its first refusal: the rest
/// of its terminal's share of the terminals' lane.
fn fill_the_share(
    connections: &Arc<ConnectionStats>,
    session: u32,
    parent: Option<u32>,
) -> Vec<(ConnectionPermit, UnixStream)> {
    let mut taken = Vec::new();
    loop {
        let (daemon_side, client) = UnixStream::pair().unwrap();
        match admit_session_by(connections, &daemon_side, Some(session), |_| parent) {
            Ok(permit) => taken.push((permit, client)),
            Err(lane) => {
                assert_eq!(lane, ClientKind::Terminal, "the terminals' lane refuses");
                return taken;
            }
        }
    }
}

/// A connection that comes while its terminal's host starts counts in that
/// terminal's own share of the terminals' lane, by the client's process
/// session: the share is the same before and after the terminal's seat. The
/// count: beside one connection of another terminal, a terminal that has
/// only its host's seat gets as many connections as a terminal with its own
/// seat. Its own seat then changes no count and opens no new place. A
/// connection that is counted for no terminal, or under another key, is
/// outside the share: the terminal then gets more places than its share.
#[test]
fn an_early_connection_counts_in_its_own_terminals_share() {
    let connections = Arc::new(ConnectionStats::default());
    let other_seat = connections.seat_terminal(Some(SESSION + 1), None);
    let (other, _other_client) = connect(&connections, SESSION + 1);
    let host_seat = HostSeating::of(connections.clone(), Some("terminal-1")).seat(HOST);
    assert!(!connections.terminal_seated(SESSION), "only the terminal's host has a seat");
    let early = fill_the_share(&connections, SESSION, Some(HOST));
    let early_ones = u64::try_from(early.len()).unwrap();
    assert_eq!(held(&connections), (early_ones + 1, early_ones + 1, 0));

    let reference = Arc::new(ConnectionStats::default());
    let reference_seats = (
        reference.seat_terminal(Some(SESSION + 1), None),
        reference.seat_terminal(Some(SESSION), Some("terminal-1")),
    );
    let reference_other = connect(&reference, SESSION + 1);
    let share = u64::try_from(fill_the_share(&reference, SESSION, None).len()).unwrap();
    assert!(share > 1 && share < LANE - 1, "the share of one terminal is {share} of {LANE}");
    assert_eq!(
        early_ones, share,
        "a terminal with only its host's seat holds {early_ones} places of the lane; its share \
         is {share}"
    );

    // The terminal's seat takes nothing over, and the share is as full
    // after it as before.
    let seat = connections.seat_terminal(Some(SESSION), Some("terminal-1"));
    drop(host_seat);
    assert_eq!(held(&connections), (share + 1, share + 1, 0), "a join at the terminal's seat");
    let after_the_seat = fill_the_share(&connections, SESSION, None);
    assert!(after_the_seat.is_empty(), "the terminal's seat opened a new place");

    // The other terminal still finds a place.
    let (next, _next_client) = connect(&connections, SESSION + 1);
    drop((early, other, next, seat, other_seat, reference_other, reference_seats));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// A daemon for which the system does not keep the process id of an ended
/// child (`SIGCHLD` ignored) seats no host: the id of a host that ended
/// could name another process there. The count: 0 seats, and a child of
/// that process id is an outside client, with no read of its parent.
#[test]
fn a_daemon_whose_ended_children_lose_their_ids_seats_no_host() {
    let connections = Arc::new(ConnectionStats::default());
    let seating = HostSeating::of(connections.clone(), Some("terminal-1"));
    let unseated = seating.seat_when(HOST, false);
    let (outside, _outside_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (1, 0, 0), "no seat: a child of that process is outside");
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None);

    // The count is live: the same call for a daemon that keeps the id.
    let seated = seating.seat_when(HOST, true);
    let (inside, _inside_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (2, 1, 0), "the host's seat: its terminal's");
    drop((unseated, seated));
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None);
    drop((outside, inside));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// The start of this daemon in the tests of a kept host. A kept host started
/// before it.
const DAEMON_STARTED: Option<ProcessStart> = Some(ProcessStart(9));

/// The read of a process's start that a test gives.
type StartOf = fn(u32) -> Option<ProcessStart>;

/// A host that an earlier daemon started has its seat from this daemon's
/// start. A client whose session's leader is the host's child is in the
/// host's terminal before the adoption gives the terminal the seat of its
/// session. The counts: one read of the host's start for the seat, one for
/// each look of a client under the host, none for a client under another
/// parent or with a seat of its session.
#[test]
fn a_client_under_a_kept_host_is_its_terminals_before_the_adoption_ends() {
    static READS: AtomicU64 = AtomicU64::new(0);
    fn start_of(process: u32) -> Option<ProcessStart> {
        READS.fetch_add(1, Ordering::SeqCst);
        (process == HOST).then_some(ProcessStart(7))
    }
    let connections = Arc::new(ConnectionStats::default());
    let seating = HostSeating::of(connections.clone(), Some("terminal-1"));
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None, "no host has a seat");
    let host = KeptHost::read_by(HOST, DAEMON_STARTED, start_of);
    assert_eq!(READS.swap(0, Ordering::SeqCst), 1, "one read of the host's start for the seat");
    let host_seat = seating.seat_kept(host);
    assert!(!connections.terminal_seated(SESSION), "the terminal has no seat of its own yet");

    let (first, _first_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (1, 1, 0), "the connection is in the terminals' lane");
    assert_eq!(READS.swap(0, Ordering::SeqCst), 1, "one read of the start for the lane");
    let terminal = Some(SeatedTerminal { id: Some(Arc::from("terminal-1")) });
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), terminal);
    assert_eq!(READS.swap(0, Ordering::SeqCst), 1, "one read of the start for the class");

    // The child of a process that has no seat, a process with no parent that
    // the daemon can read, and the host's own session are outside clients.
    let (other, _other_client) = connect_under(&connections, SESSION + 1, Some(HOST + 1));
    let (orphan, _orphan_client) = connect_under(&connections, SESSION + 2, None);
    let (host, _host_client) = connect_under(&connections, HOST, Some(1));
    assert_eq!(held(&connections), (4, 1, 0));
    assert_eq!(connections.seated_terminal(SESSION + 1, |_| Some(HOST + 1)), None);
    assert_eq!(READS.swap(0, Ordering::SeqCst), 0, "no start is read for a parent with no seat");

    // The adoption: the terminal takes the seat of its session, and then the
    // host's seat ends.
    let seat = connections.seat_terminal(Some(SESSION), Some("terminal-1"));
    assert_eq!(seated_with_no_parent_read(&connections, SESSION).as_deref(), Some("terminal-1"));
    drop(host_seat);
    assert_eq!(seated_with_no_parent_read(&connections, SESSION).as_deref(), Some("terminal-1"));
    assert_eq!(seated_with_no_parent_read(&connections, SESSION + 1), None, "no host has a seat");
    assert_eq!(READS.load(Ordering::SeqCst), 0, "no start is read after the adoption");
    drop((first, other, orphan, host, seat));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// The seat of a kept host is for the process that had the host's start. A
/// process that has the host's process id at the accept and another start,
/// or no start that the daemon can read, is not the host: its child is an
/// outside client.
#[test]
fn a_process_with_a_kept_hosts_id_and_another_start_is_not_the_host() {
    static START: AtomicU64 = AtomicU64::new(7);
    fn start_of(_process: u32) -> Option<ProcessStart> {
        Some(ProcessStart(START.load(Ordering::SeqCst))).filter(|start| start.0 != 0)
    }
    let connections = Arc::new(ConnectionStats::default());
    let seating = HostSeating::of(connections.clone(), Some("terminal-1"));
    let host_seat = seating.seat_kept(KeptHost::read_by(HOST, DAEMON_STARTED, start_of));
    let terminal = Some(SeatedTerminal { id: Some(Arc::from("terminal-1")) });
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), terminal, "the host");

    // The host ended, and a process that started later has its process id.
    START.store(12, Ordering::SeqCst);
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), None);
    let (later, _later_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (1, 0, 0), "the child of the later process is outside");

    // No process has the id.
    START.store(0, Ordering::SeqCst);
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), None);
    let (gone, _gone_client) = connect_under(&connections, SESSION + 1, Some(HOST));
    assert_eq!(held(&connections), (2, 0, 0), "the child of no process is outside");

    // The count is live: the same looks while the host has its start.
    START.store(7, Ordering::SeqCst);
    let (inside, _inside_client) = connect_under(&connections, SESSION + 2, Some(HOST));
    assert_eq!(held(&connections), (3, 1, 0), "the host's child is its terminal's");
    drop(host_seat);
    assert_eq!(seated_with_no_parent_read(&connections, SESSION + 2), None, "the seat ended");
    drop((later, gone, inside));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// A process is a kept host only when the daemon reads its start and that
/// start is before the daemon's own. A process that started with the daemon
/// or after it, a process with no start that the daemon can read, and each
/// process for a daemon that does not read its own start have no seat.
#[test]
fn a_process_that_did_not_start_before_the_daemon_is_no_kept_host() {
    fn started_at_9(_process: u32) -> Option<ProcessStart> {
        Some(ProcessStart(9))
    }
    fn no_start(_process: u32) -> Option<ProcessStart> {
        None
    }
    let connections = Arc::new(ConnectionStats::default());
    let seating = HostSeating::of(connections.clone(), Some("terminal-1"));
    let not_kept: [(Option<ProcessStart>, StartOf, &str); 4] = [
        (Some(ProcessStart(9)), started_at_9, "it started with the daemon"),
        (Some(ProcessStart(8)), started_at_9, "it started after the daemon"),
        (None, started_at_9, "the daemon does not read its own start"),
        (Some(ProcessStart(9)), no_start, "the daemon does not read its start"),
    ];
    for (daemon_started, start_of, why) in not_kept {
        let host = KeptHost::read_by(HOST, daemon_started, start_of);
        // The question of a child of that process: a seat names the terminal.
        let unseated = seating.seat_kept(host);
        assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), None, "{why}");
        drop(unseated);
        assert!(host.is_none(), "{why}");
    }

    // The count is live: the same process for a daemon that started later.
    let host = KeptHost::read_by(HOST, Some(ProcessStart(10)), started_at_9);
    let seated = seating.seat_kept(host);
    let (inside, _inside_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (1, 1, 0), "the kept host's seat: its terminal's");

    // A terminal with no session to seat it seats no kept host.
    let unseated = HostSeating::default().seat_kept(host);
    drop((seated, unseated));
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None);
    drop(inside);
    assert_eq!(held(&connections), (0, 0, 0));
}

/// One host has one terminal. Two seats for one process name two: one of
/// them is wrong, so the process names no terminal while one of the two
/// seats is there.
#[test]
fn two_seats_for_one_kept_host_name_no_terminal() {
    fn started_at_7(_process: u32) -> Option<ProcessStart> {
        Some(ProcessStart(7))
    }
    let connections = Arc::new(ConnectionStats::default());
    let host = KeptHost::read_by(HOST, DAEMON_STARTED, started_at_7);
    let first = HostSeating::of(connections.clone(), Some("terminal-1")).seat_kept(host);
    let terminal = Some(SeatedTerminal { id: Some(Arc::from("terminal-1")) });
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), terminal, "one seat");

    let second = HostSeating::of(connections.clone(), Some("terminal-2")).seat_kept(host);
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), None, "two seats");
    drop(first);
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), None, "one of two is left");
    let (outside, _outside_client) = connect_under(&connections, SESSION, Some(HOST));
    assert_eq!(held(&connections), (1, 0, 0), "no terminal: an outside client");
    drop(second);
    assert_eq!(seated_with_no_parent_read(&connections, SESSION), None, "no host has a seat");

    // The count is live: one seat for the process after the two ended.
    let again = HostSeating::of(connections.clone(), Some("terminal-2")).seat_kept(host);
    let terminal = Some(SeatedTerminal { id: Some(Arc::from("terminal-2")) });
    assert_eq!(connections.seated_terminal(SESSION, |_| Some(HOST)), terminal);
    drop((again, outside));
    assert_eq!(held(&connections), (0, 0, 0));
}

/// The start that the daemon reads is the system's: this test's process has
/// one, and each read gives the same. A process is no kept host of itself:
/// it did not start before its own start.
#[test]
fn the_start_of_a_process_is_read_and_stays() {
    let own = process_start(std::process::id());
    assert!(own.is_some(), "this process has a start");
    assert_eq!(process_start(std::process::id()), own);
    assert!(KeptHost::read(std::process::id()).is_none());
}
