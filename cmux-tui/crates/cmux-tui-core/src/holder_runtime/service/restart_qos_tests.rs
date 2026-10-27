//! p05-ipc-150: the thread that reconnects to a lost holder runs at the
//! request class ([`RESTART_QOS`]), read live while it waits for the new
//! link's WELCOME (`pthread_get_qos_class_np` on macOS, the nice value on
//! Linux, through the thread registry).

use std::os::unix::net::UnixListener;
use std::sync::atomic::Ordering;
use std::sync::mpsc::sync_channel;
use std::time::Duration;

use cmux_holder::wire;

use super::RESTART_QOS;
use super::tests::{stand_in_service, welcome_granting};

#[test]
fn a_lost_holder_link_is_restarted_on_a_thread_at_the_request_class() {
    assert_eq!(RESTART_QOS, cmux_threads::ThreadQos::UserInitiated);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("chq-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (proceed, proceed_rx) = sync_channel::<()>(0);
    let (reconnected_tx, reconnected) = sync_channel::<()>(0);
    let stand_in = std::thread::spawn(move || {
        let (first, _) = listener.accept().unwrap();
        first.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        welcome_granting(&first, &mut wire::Reader::default(), &[], None);
        // The daemon holds the link: end it as a dying holder would.
        proceed_rx.recv().unwrap();
        first.shutdown(std::net::Shutdown::Both).unwrap();
        drop(first);
        let (second, _) = listener.accept().unwrap();
        second.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        reconnected_tx.send(()).unwrap();
        // The test reads the restart thread while it waits for this WELCOME.
        proceed_rx.recv().unwrap();
        welcome_granting(&second, &mut wire::Reader::default(), &[], None);
        second
    });

    let service = stand_in_service(socket);
    let link = service.link().expect("the stand-in holder");
    proceed.send(()).unwrap();
    reconnected.recv_timeout(Duration::from_secs(20)).expect("holder-restart reconnects");
    let rows: Vec<_> =
        cmux_threads::snapshot().into_iter().filter(|row| row.name == "holder-restart").collect();
    let live = if cmux_threads::reachable(RESTART_QOS) {
        crate::request_qos::tests::live_at(RESTART_QOS)
    } else {
        cmux_threads::current()
    };
    assert!(!rows.is_empty(), "holder-restart runs while it reconnects");
    for row in rows {
        assert_eq!((row.declared, row.live), (RESTART_QOS, live));
    }
    proceed.send(()).unwrap();
    let second = stand_in.join().expect("the stand-in welcomed the restart");

    // No restart may launch a holder once the stand-in's link ends.
    service.superseded.store(true, Ordering::Release);
    drop(link);
    drop(service);
    drop(second);
    let _ = std::fs::remove_dir_all(&dir);
}
