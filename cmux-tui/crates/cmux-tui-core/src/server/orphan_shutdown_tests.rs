//! `stop_orphaned_owner` and the client presence signal it relies on
//! (server/orphan_shutdown.rs).

use std::sync::atomic::{AtomicUsize, Ordering};

use crate::server::*;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("orphan-{label}"), crate::SurfaceOptions::default())
}

fn connect(mux: &Arc<Mux>) -> u64 {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    mux.control_clients.register(ClientTransport::Unix, writer)
}

#[test]
fn client_presence_is_signalled_on_every_connect_and_leave() {
    let mux = mux("presence");
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    mux.set_client_presence_observer(move || {
        seen.fetch_add(1, Ordering::SeqCst);
    });
    let client = connect(&mux);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(mux.client_count(), 1);
    assert!(disconnect_client(&mux, client, false));
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_eq!(mux.client_count(), 0);
}

#[test]
fn an_orphan_exit_never_stops_an_owner_with_a_client_connected() {
    let mux = mux("connected");
    let client = connect(&mux);
    assert!(!stop_orphaned_owner(&mux, || panic!("checked with a client connected")));
    assert!(!mux.daemon_shutdown_requested());
    assert!(mux.control_clients.contains(client));
    // No fence stays behind: new clients still register.
    let later = connect(&mux);
    assert!(mux.control_clients.contains(later));
}

#[test]
fn a_failed_recheck_keeps_the_owner_and_releases_the_fence() {
    let mux = mux("recheck");
    assert!(!stop_orphaned_owner(&mux, || false));
    assert!(!mux.daemon_shutdown_requested());
    let later = connect(&mux);
    assert!(mux.control_clients.contains(later), "the fence was left behind");
}

#[test]
fn a_panicking_recheck_releases_the_fence() {
    let mux = mux("panic");
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        stop_orphaned_owner(&mux, || panic!("policy check failed"))
    }));
    assert!(caught.is_err());
    assert!(!mux.daemon_shutdown_requested());
    let later = connect(&mux);
    assert!(mux.control_clients.contains(later), "the fence was left behind");
}

#[test]
fn an_orphan_exit_stops_the_owner_and_leaves_every_terminal_running() {
    let mux = mux("hosts-live");
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let alive = |mux: &Arc<Mux>| mux.surface(terminal).is_some_and(|surface| !surface.is_dead());
    assert!(alive(&mux));
    let during = Arc::new(AtomicUsize::new(0));
    let seen = during.clone();
    assert!(stop_orphaned_owner(&mux, move || {
        seen.fetch_add(1, Ordering::SeqCst);
        true
    }));
    assert_eq!(during.load(Ordering::SeqCst), 1, "the policy is checked under the fence");
    assert!(mux.daemon_shutdown_requested());
    assert!(alive(&mux), "the orphan exit must not end a terminal");
    let late = connect(&mux);
    assert!(!mux.control_clients.contains(late), "a client arriving during the exit is refused");
}
