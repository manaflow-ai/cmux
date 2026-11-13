//! The accept loop counts a connection as a terminal's from the terminals'
//! seats (`diagnostics/terminal_seats.rs`, `server/terminal_admission.rs`):
//! with no read of the session state, and also for a connection that came
//! before its terminal had its seat.

use std::os::unix::net::UnixStream;

use super::*;
use crate::diagnostics::{ClientKind, ConnectionStats};
use crate::platform::transport::Stream;
use crate::server::terminal_admission::{admit, admit_session};

const LIMIT: u64 = MAX_SERVER_CONNECTIONS as u64;
const LANE: u64 = MAX_TERMINAL_CONNECTIONS as u64;

/// A process session that no process of the test holds.
const SESSION: u32 = 4_000_001;

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
/// count: an accept takes the state lock 0 times, for an outside client and
/// for a terminal, and a terminal that takes its seat while another change
/// holds the state lock is a terminal at its next connection.
#[test]
fn an_accept_takes_no_state_lock_and_sees_a_seat_taken_under_it() {
    let mux = test_mux();
    let connections = mux.connection_stats().clone();
    let (daemon_side, _client) = UnixStream::pair().unwrap();
    let session = own_session(&daemon_side);
    assert!(!connections.terminal_seated(session), "the test's process is in no terminal");

    let state = mux.state.lock().unwrap();
    let before = crate::mux::state_locks_taken_on_this_thread();
    let outside = admit(&connections, &daemon_side).expect("a free slot");
    assert_eq!(held(&connections), (1, 0, 0), "no seat: an outside client");
    let seat = connections.seat_terminal(Some(session));
    let (second_daemon_side, _second_client) = UnixStream::pair().unwrap();
    let terminal = admit(&connections, &second_daemon_side).expect("a free slot");
    assert_eq!(crate::mux::state_locks_taken_on_this_thread() - before, 0);
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
    let old = connections.seat_terminal(Some(SESSION));
    let new = connections.seat_terminal(Some(SESSION));
    assert_eq!(old.process_id(), Some(SESSION));
    drop(old);
    assert!(connections.terminal_seated(SESSION));
    drop(new);
    assert!(!connections.terminal_seated(SESSION));
    let none = connections.seat_terminal(None);
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

    let seat = connections.seat_terminal(Some(SESSION));
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

    let seats: Vec<_> =
        holders.iter().map(|(_, _, session)| connections.seat_terminal(Some(*session))).collect();
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

    let seat = connections.seat_terminal(Some(SESSION));
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
    let _seat = connections.seat_terminal(Some(SESSION));
    let (daemon_side, _client) = UnixStream::pair().unwrap();
    let terminals: Vec<_> = (0..LANE)
        .map(|index| {
            let session = SESSION + 1 + u32::try_from(index).unwrap();
            (connections.seat_terminal(Some(session)), connect(&connections, session))
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
        let seat = connections.seat_terminal(Some(SESSION));
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
        let seat = connections.seat_terminal(Some(SESSION));
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
