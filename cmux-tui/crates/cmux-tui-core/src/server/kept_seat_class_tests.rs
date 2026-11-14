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
/// the kept host ends. The client then has the class that the seat of its
/// session gives: the same terminal, or the public id that the terminal has
/// from then on.
#[test]
fn the_class_from_a_kept_hosts_seat_is_the_session_seats_after_the_adoption() {
    let mux = mux("adopted");
    let (record_path, mut record, _lease) = record_fixture("kept-seat-class-adopted");
    record.host_pid = std::os::unix::process::parent_id();
    let public_id = TerminalPublicId::random().unwrap();
    let (liveness, seat) = mux.kept_host(&record_path, &record, Some(&public_id));
    assert_eq!(liveness, TerminalHostLiveness::Live);

    let same = accept(&mux, SESSION, record.host_pid);
    let renamed = accept(&mux, SESSION + 1, record.host_pid);
    assert_eq!(class(&mux, same), terminal(public_id.as_str()));
    assert_eq!(class(&mux, renamed), terminal(public_id.as_str()));

    let connections = mux.connection_stats();
    let session_seats = (
        connections.seat_terminal(Some(SESSION), Some(public_id.as_str())),
        connections.seat_terminal(Some(SESSION + 1), Some("terminal-new")),
    );
    drop(seat);
    assert_eq!(class(&mux, same), terminal(public_id.as_str()), "the same terminal");
    assert_eq!(class(&mux, renamed), terminal("terminal-new"), "the terminal's new id");
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

/// An accept records a class from the seat of a kept host only when the seat
/// is there at the record. For a seat that ended before the record, the
/// accept gives the class that an end of the seat gives. The count: the
/// accept reads the host's start one time.
#[test]
fn an_accept_that_meets_the_end_of_a_kept_hosts_seat_gives_no_class_from_it() {
    const HOST: u32 = 4_100_001;
    static SEAT: Mutex<Option<KeptHostSeat>> = Mutex::new(None);
    static READS: AtomicU64 = AtomicU64::new(0);
    /// The start of the host. The second read is the accept's: the seat ends
    /// in it.
    fn start_of(process: u32) -> Option<ProcessStart> {
        if READS.fetch_add(1, Ordering::SeqCst) == 1 {
            drop(SEAT.lock().unwrap_or_else(PoisonError::into_inner).take());
        }
        (process == HOST).then_some(ProcessStart(7))
    }
    let mux = mux("meets-the-end");
    let host = KeptHost::read_by(HOST, Some(ProcessStart(9)), start_of);
    let seat = HostSeating::of(mux.connection_stats().clone(), Some("terminal-1")).seat_kept(host);
    *SEAT.lock().unwrap_or_else(PoisonError::into_inner) = Some(seat);

    let client = accept(&mux, SESSION, HOST);
    assert_eq!(READS.load(Ordering::SeqCst), 2, "one read for the seat, one for the accept");
    assert_eq!(class(&mux, client), LocalPeer::Other, "the seat ended in the accept");
    mux.shutdown();
}
