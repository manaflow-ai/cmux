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
