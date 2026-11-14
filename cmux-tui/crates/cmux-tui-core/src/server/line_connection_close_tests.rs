//! A line connection that the daemon ends (a kick, a revoked link guest, a
//! close from our side) closes every descriptor of its socket, also while
//! another part of the daemon still holds a clone of the connection's writer.
//! On macOS a peer that is blocked in a read can miss the wake from our
//! shutdown while we keep any descriptor of our end open; only the last close
//! wakes it for certain (opt-tools probes/shutdown_wake.rs). Then a kicked
//! client stays "connected" with no data and does not reconnect.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::Duration;

use super::*;
use crate::panic_free::RecoverPoison;

/// Whether any process still holds a descriptor of the other end of `peer`.
/// macOS answers the other end's pid until its last descriptor closes, and
/// "not connected" after that; a shutdown alone does not change the answer.
fn other_end_open(peer: &UnixStream) -> bool {
    let mut pid: libc::pid_t = 0;
    let mut len = size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: `peer` is an open socket for this call; `pid` and `len`
    // describe a live buffer of the size that getsockopt may write.
    let status = unsafe {
        libc::getsockopt(
            peer.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&raw mut pid).cast(),
            &raw mut len,
        )
    };
    status == 0
}

/// One connection served by the line loop on a socket pair, registered (its
/// first request has its reply), and a clone of its writer that the test
/// holds the way a subscriber or a request thread can.
struct Served {
    mux: Arc<Mux>,
    peer: UnixStream,
    server: JoinHandle<()>,
    client: u64,
    held_writer: MessageWriter,
}

fn serve(label: &str) -> Served {
    let mux = Mux::new_for_test(format!("line-close-{label}"), crate::SurfaceOptions::default());
    let (ours, peer) = UnixStream::pair().unwrap();
    let server_mux = mux.clone();
    let server = std::thread::spawn(move || {
        serve_line_connection(
            server_mux,
            Box::new(ours),
            Arc::new(RenderService::new()),
            None,
            ClientTransport::Unix,
            &admission::LocalAdmission,
        );
    });
    peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    (&peer).write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n").unwrap();
    let mut reply = String::new();
    BufReader::new(&peer).read_line(&mut reply).unwrap();
    assert!(reply.contains("\"ok\":true"), "{reply}");
    let ids = mux.control_clients.client_ids();
    assert_eq!(ids.len(), 1, "{ids:?}");
    let client = ids[0];
    let held_writer = mux
        .control_clients
        .state
        .lock()
        .recover_poison()
        .clients
        .get(&client)
        .map(|record| record.writer.clone())
        .expect("the registered connection's writer");
    Served { mux, peer, server, client, held_writer }
}

#[test]
fn an_aborted_connection_closes_its_socket_while_its_writer_is_still_held() {
    let served = serve("abort");
    served.mux.control_clients.abort_connection(served.client);
    served.server.join().unwrap();
    assert!(
        !other_end_open(&served.peer),
        "the kicked client's socket is still open in the daemon after its connection ended"
    );
    drop(served.held_writer);
}

#[test]
fn a_connection_closed_by_the_daemon_closes_its_socket_while_its_writer_is_still_held() {
    let served = serve("close");
    served.held_writer.close();
    served.server.join().unwrap();
    assert!(
        !other_end_open(&served.peer),
        "the client's socket is still open in the daemon after its connection ended"
    );
    drop(served.held_writer);
}

#[test]
fn the_check_sees_a_descriptor_that_stays_open_after_a_shutdown() {
    let (ours, peer) = UnixStream::pair().unwrap();
    let dup = ours.try_clone().unwrap();
    ours.shutdown(Shutdown::Both).unwrap();
    drop(ours);
    assert!(other_end_open(&peer));
    drop(dup);
    assert!(!other_end_open(&peer));
}

/// Open descriptors of this process: all of them, and the kqueues among them.
fn open_descriptors() -> (usize, usize) {
    const PROC_PIDLISTFDS: libc::c_int = 1;
    const PROX_FDTYPE_KQUEUE: u32 = 5;
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FdInfo {
        fd: i32,
        kind: u32,
    }
    let mut list = vec![FdInfo { fd: 0, kind: 0 }; 65_536];
    let bytes = libc::c_int::try_from(list.len() * size_of::<FdInfo>()).unwrap();
    // SAFETY: `list` is a live buffer of `bytes` bytes that proc_pidinfo
    // fills with proc_fdinfo records of this process.
    let used = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            PROC_PIDLISTFDS,
            0,
            list.as_mut_ptr().cast(),
            bytes,
        )
    };
    let count = usize::try_from(used).unwrap() / size_of::<FdInfo>();
    let list = &list[..count];
    (count, list.iter().filter(|info| info.kind == PROX_FDTYPE_KQUEUE).count())
}

/// Each line reader waits in a kqueue of its own (transport::ReadWaiter); it
/// closes with the reader. 500 connections that each send a request, read the
/// reply and close leave no descriptor behind. The bound of 100 allows for
/// descriptors that tests running beside this one hold for a moment; a leaked
/// kqueue (or socket) for each connection adds 500.
#[test]
fn line_connections_that_end_leave_no_descriptor_behind() {
    const CYCLES: usize = 500;
    let mux =
        Mux::new_for_test("line-close-descriptors".to_string(), crate::SurfaceOptions::default());
    let cycle = |round: usize| {
        let (ours, peer) = UnixStream::pair().unwrap();
        let server_mux = mux.clone();
        let server = std::thread::spawn(move || {
            serve_line_connection(
                server_mux,
                Box::new(ours),
                Arc::new(RenderService::new()),
                None,
                ClientTransport::Unix,
                &admission::LocalAdmission,
            );
        });
        peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        (&peer).write_all(format!("{{\"id\":{round},\"cmd\":\"identify\"}}\n").as_bytes()).unwrap();
        let mut reply = String::new();
        BufReader::new(&peer).read_line(&mut reply).unwrap();
        assert!(reply.contains("\"ok\":true"), "{reply}");
        drop(peer);
        server.join().unwrap();
    };
    // The first connection sets up what the mux keeps for its life.
    cycle(0);
    let (start_all, start_kqueues) = open_descriptors();
    for round in 1..=CYCLES {
        cycle(round);
    }
    let (end_all, end_kqueues) = open_descriptors();
    assert!(
        end_kqueues < start_kqueues + 100,
        "kqueues {start_kqueues} -> {end_kqueues} after {CYCLES} line connections"
    );
    assert!(
        end_all < start_all + 100,
        "descriptors {start_all} -> {end_all} after {CYCLES} line connections"
    );
}
