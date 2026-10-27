//! The holder service thread QoS tests (p01-process-139), beside the
//! service tests whose stand-in holder helpers they use.

use std::os::unix::net::UnixListener;
use std::sync::atomic::Ordering;
use std::time::Duration;

use cmux_holder::wire;

use super::tests::{stand_in_service, welcome};
use super::{RESTART_QOS, ThreadType};

/// p01-process-139: a lost holder is restarted on a registered
/// `holder-restart` thread at the request class, not at the echo class
/// of the link reader whose end starts it. Before, it was a plain
/// thread with no registry row that inherited user-interactive.
#[test]
fn a_lost_holder_restarts_on_a_registered_request_class_thread() {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("chq-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let stand_in = std::thread::spawn(move || {
        let (first, _) = listener.accept().unwrap();
        first.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        welcome(&first, &mut wire::Reader::default(), &[]);
        // A plain end, as when the holder dies.
        first.shutdown(std::net::Shutdown::Both).unwrap();
        drop(first);

        // Only the restart thread connects again, and it waits in its
        // handshake for this WELCOME: its row is in the registry now.
        let (second, _) = listener.accept().unwrap();
        second.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let restart: Vec<_> = cmux_threads::snapshot()
            .into_iter()
            .filter(|thread| thread.name == "holder-restart")
            .map(|thread| thread.declared)
            .collect();
        welcome(&second, &mut wire::Reader::default(), &[]);
        (restart, second)
    });

    let service = stand_in_service(socket);
    let link = service.link().expect("the stand-in holder");
    let (restart, second) = stand_in.join().expect("the restart reconnected");
    assert!(!restart.is_empty(), "the restart thread is not registered");
    assert!(
        restart.iter().all(|declared| *declared == RESTART_QOS),
        "holder-restart declared {restart:?}"
    );
    assert_eq!(RESTART_QOS, ThreadType::Interactive.qos());

    // No restart may launch a holder once the stand-in's link ends.
    service.superseded.store(true, Ordering::Release);
    drop(link);
    drop(service);
    drop(second);
    let _ = std::fs::remove_dir_all(&dir);
}
