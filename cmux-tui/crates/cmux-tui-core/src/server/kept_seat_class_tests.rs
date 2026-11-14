//! The class that a client gets through the seat of a kept host
//! (`diagnostics/terminal_seats.rs`, `KeptHost`), at each end of that seat.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};

use crate::diagnostics::{HostSeating, KeptHost, KeptHostSeat};
use crate::process_resources::ProcessStart;
use crate::request_origin::LocalPeer;
use crate::server::*;
use crate::terminal_host_runtime::{TerminalHostLiveness, record_fixture};

/// The process session of a client of the terminal.
const SESSION: u32 = 4_000_001;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("kept-seat-class-{label}"), crate::SurfaceOptions::default())
}

/// A client in process session `session`, as the accept records it. The
/// parent of the session's leader is `parent`.
fn accept(mux: &Arc<Mux>, session: u32, parent: u32) -> u64 {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    let peer_key = Some("token:4242.1".to_string());
    let session_of = |_: u32| Some(session);
    let parent_of = |_: u32| Some(parent);
    let _kind = super::set_peer_identity_with(mux, client, peer_key, None, session_of, parent_of);
    client
}

/// The class in the record of `client`.
fn class(mux: &Arc<Mux>, client: u64) -> LocalPeer {
    let state = mux.control_clients.state.lock().unwrap();
    state.clients.get(&client).expect("a registered client").origin.local_peer.clone()
}

fn terminal(id: &str) -> LocalPeer {
    LocalPeer::Terminal(id.to_string())
}

/// The class from the seat of a kept host ends with that seat. A client that
/// the daemon counted as the terminal's through the seat is no terminal's
/// client after the seat ended, when the terminal has no seat of its session.
#[test]
fn the_class_from_a_kept_hosts_seat_ends_with_the_seat() {
    let mux = mux("ends");
    let (record_path, mut record, _lease) = record_fixture("kept-seat-class-ends");
    // A process that lives and that started before this one.
    record.host_pid = std::os::unix::process::parent_id();
    let public_id = TerminalPublicId::random().unwrap();
    let (liveness, seat) = mux.kept_host(&record_path, &record, Some(&public_id));
    assert_eq!(liveness, TerminalHostLiveness::Live);

    let client = accept(&mux, SESSION, record.host_pid);
    assert_eq!(class(&mux, client), terminal(public_id.as_str()), "the seat is there");
    drop(seat);
    assert_eq!(class(&mux, client), LocalPeer::Other, "the seat ended");
    if let Some(root) = record_path.parent() {
        let _ = std::fs::remove_dir_all(root);
    }
    mux.shutdown();
}

/// An adoption gives the terminal the seat of its session before the seat of
/// the kept host ends. The client keeps the terminal when the seat of its
/// session names that same terminal. A seat that names another terminal gives
/// the client no class: it is no terminal's client.
#[test]
fn the_class_after_the_end_of_a_kept_hosts_seat_is_the_same_terminal_or_no_terminal() {
    let mux = mux("adopted");
    let (record_path, mut record, _lease) = record_fixture("kept-seat-class-adopted");
    record.host_pid = std::os::unix::process::parent_id();
    let public_id = TerminalPublicId::random().unwrap();
    let (liveness, seat) = mux.kept_host(&record_path, &record, Some(&public_id));
    assert_eq!(liveness, TerminalHostLiveness::Live);

    let same = accept(&mux, SESSION, record.host_pid);
    let other = accept(&mux, SESSION + 1, record.host_pid);
    assert_eq!(class(&mux, same), terminal(public_id.as_str()));
    assert_eq!(class(&mux, other), terminal(public_id.as_str()));

    let connections = mux.connection_stats();
    let session_seats = (
        connections.seat_terminal(Some(SESSION), Some(public_id.as_str())),
        connections.seat_terminal(Some(SESSION + 1), Some("terminal-other")),
    );
    drop(seat);
    assert_eq!(class(&mux, same), terminal(public_id.as_str()), "the same terminal");
    assert_eq!(class(&mux, other), LocalPeer::Other, "a seat of another terminal");
    drop(session_seats);
    if let Some(root) = record_path.parent() {
        let _ = std::fs::remove_dir_all(root);
    }
    mux.shutdown();
}

/// A second seat for the process of one kept host makes that process name
/// no terminal while a seat of it is there. The class that its seat gave ends
/// at the second seat, and the end of the two seats does not give it back.
#[test]
fn the_class_from_a_kept_hosts_seat_ends_when_the_host_is_seated_twice() {
    let mux = mux("twice");
    let (record_path, mut record, _lease) = record_fixture("kept-seat-class-twice");
    record.host_pid = std::os::unix::process::parent_id();
    let public_id = TerminalPublicId::random().unwrap();
    let (liveness, seat) = mux.kept_host(&record_path, &record, Some(&public_id));
    assert_eq!(liveness, TerminalHostLiveness::Live);

    let client = accept(&mux, SESSION, record.host_pid);
    assert_eq!(class(&mux, client), terminal(public_id.as_str()), "one seat");
    let (liveness, second) = mux.kept_host(&record_path, &record, Some(&public_id));
    assert_eq!(liveness, TerminalHostLiveness::Live);
    assert_eq!(class(&mux, client), LocalPeer::Other, "the host is seated twice");
    drop(second);
    drop(seat);
    assert_eq!(class(&mux, client), LocalPeer::Other, "the two seats ended");
    if let Some(root) = record_path.parent() {
        let _ = std::fs::remove_dir_all(root);
    }
    mux.shutdown();
}

/// A record has a class from the seat of a kept host only while that seat is
/// there. The count: the accept reads the host's start one time.
#[test]
fn a_record_has_the_class_from_a_kept_hosts_seat_only_while_the_seat_is_there() {
    const HOST: u32 = 4_100_001;
    static SEAT: Mutex<Option<KeptHostSeat>> = Mutex::new(None);
    static READS: AtomicU64 = AtomicU64::new(0);
    /// The start of the host. The test holds the seat to the second read.
    fn start_of(process: u32) -> Option<ProcessStart> {
        if READS.fetch_add(1, Ordering::SeqCst) == 1 {
            drop(SEAT.lock().unwrap_or_else(PoisonError::into_inner).take());
        }
        (process == HOST).then_some(ProcessStart(7))
    }
    let mux = mux("while-the-seat-is-there");
    let host = KeptHost::read_by(HOST, Some(ProcessStart(9)), start_of);
    let seat = HostSeating::of(mux.connection_stats().clone(), Some("terminal-1")).seat_kept(host);
    *SEAT.lock().unwrap_or_else(PoisonError::into_inner) = Some(seat);

    let client = accept(&mux, SESSION, HOST);
    assert_eq!(READS.load(Ordering::SeqCst), 2, "one read for the seat, one for the accept");
    assert_eq!(class(&mux, client), LocalPeer::Other, "the seat is not there");
    mux.shutdown();
}

/// The class from the seat of a kept host is the class of that one seat. A
/// later seat of the same process is another seat: it does not hold the
/// class, also when it is there at the record.
#[test]
fn a_later_seat_of_the_same_process_does_not_hold_the_class_from_a_kept_hosts_seat() {
    const HOST: u32 = 4_200_001;
    static LATER: Mutex<Option<HostSeating>> = Mutex::new(None);
    static SEAT: Mutex<Option<KeptHostSeat>> = Mutex::new(None);
    static READS: AtomicU64 = AtomicU64::new(0);
    /// The start of the host. The test holds the first seat to the second
    /// read, and the later seat from it.
    fn start_of(process: u32) -> Option<ProcessStart> {
        if READS.fetch_add(1, Ordering::SeqCst) == 1 {
            drop(SEAT.lock().unwrap_or_else(PoisonError::into_inner).take());
            let later = LATER.lock().unwrap_or_else(PoisonError::into_inner).take();
            let host = KeptHost::read_by(HOST, Some(ProcessStart(9)), start_of);
            let seat = later.map(|later| later.seat_kept(host));
            *SEAT.lock().unwrap_or_else(PoisonError::into_inner) = seat;
        }
        (process == HOST).then_some(ProcessStart(7))
    }
    let mux = mux("later-seat");
    let connections = mux.connection_stats().clone();
    let host = KeptHost::read_by(HOST, Some(ProcessStart(9)), start_of);
    let seat = HostSeating::of(connections.clone(), Some("terminal-1")).seat_kept(host);
    *SEAT.lock().unwrap_or_else(PoisonError::into_inner) = Some(seat);
    *LATER.lock().unwrap_or_else(PoisonError::into_inner) =
        Some(HostSeating::of(connections, Some("terminal-2")));

    let client = accept(&mux, SESSION, HOST);
    assert_eq!(READS.load(Ordering::SeqCst), 3, "one read for each seat, one for the accept");
    assert_eq!(class(&mux, client), LocalPeer::Other, "the later seat holds no class");
    let second = accept(&mux, SESSION + 1, HOST);
    assert_eq!(class(&mux, second), terminal("terminal-2"), "the later seat is there");
    drop(SEAT.lock().unwrap_or_else(PoisonError::into_inner).take());
    mux.shutdown();
}
