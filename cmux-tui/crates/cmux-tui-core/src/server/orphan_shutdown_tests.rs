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
    mux.add_client_presence_observer(move || {
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
fn idle_exit_and_orphan_exit_both_hear_client_presence() {
    // The DEV orphan exit and the leftover idle exit watch the same owner.
    let mux = mux("two-observers");
    let calls = [Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))];
    for seen in &calls {
        let seen = seen.clone();
        mux.add_client_presence_observer(move || {
            seen.fetch_add(1, Ordering::SeqCst);
        });
    }
    let client = connect(&mux);
    assert!(disconnect_client(&mux, client, false));
    for seen in &calls {
        assert_eq!(seen.load(Ordering::SeqCst), 2);
    }
}

/// cp/quit-chief-idle (fleet journey quit-leaves-helpers, job 6f526fc4f74984c414dbf470,
/// cmux19): 10 s after the quit the Chief's owner still ran. Its own screen-detection plugin
/// (the journal plugin it starts) is connected to it for its whole life, so the owner always had
/// one client, and neither its exit after the app nor any idle exit could fire. The daemon's own
/// plugin needs the daemon only while something else does: its connection keeps nothing.
#[test]
fn the_daemons_own_journal_plugin_is_no_client_that_keeps_it() {
    let mux = mux("own-plugin");
    mux.configure_journal_plugin(Some(crate::JournalPluginOptions {
        id: "test-plugin".into(),
        command: vec!["/bin/sleep".into(), "600".into()],
        cwd: None,
        revision: None,
    }));
    mux.start_journal_plugin(
        std::env::temp_dir().join(format!("orphan-own-plugin-{}.sock", std::process::id())),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    let pid = loop {
        if let Some(pid) = mux.journal_plugin_pid() {
            break pid;
        }
        assert!(Instant::now() < deadline, "the journal plugin never started");
        std::thread::sleep(Duration::from_millis(10));
    };
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    mux.add_client_presence_observer(move || {
        seen.fetch_add(1, Ordering::SeqCst);
    });
    let plugin = connect(&mux);
    origin_gate::set_peer_identity_at_accept(
        &mux,
        plugin,
        origin_gate::AcceptedPeer::classify(&mux, Some(format!("token:{pid}.1")), None, None),
    );
    assert_eq!(mux.client_count(), 0, "the daemon's own plugin counted as a client that keeps it");
    assert_eq!(
        calls.load(Ordering::SeqCst),
        2,
        "the watchers did not hear that the plugin keeps nothing"
    );
    // Any other process keeps it.
    let other = connect(&mux);
    origin_gate::set_peer_identity_at_accept(
        &mux,
        other,
        origin_gate::AcceptedPeer::classify(&mux, Some(format!("token:{}.1", pid + 1)), None, None),
    );
    assert_eq!(mux.client_count(), 1);
    assert!(!stop_orphaned_owner(&mux, || panic!("checked with a client connected")));
    assert!(disconnect_client(&mux, other, false));
    assert!(
        stop_orphaned_owner(&mux, || true),
        "the daemon's own plugin kept an owner nothing needs"
    );
    assert!(mux.daemon_shutdown_requested());
    mux.configure_journal_plugin(None);
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
