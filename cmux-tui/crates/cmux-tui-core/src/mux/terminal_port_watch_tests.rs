//! The terminal ports rules without live servers: the entry's text, and
//! which entries a pass writes.

use std::collections::BTreeSet;

use super::*;

fn stored(text: &str, icon: Option<&str>) -> StoredPorts {
    StoredPorts { text: text.into(), icon: icon.map(str::to_owned) }
}

#[test]
fn the_entry_text_lists_ports_in_order_and_reads_back() {
    let ports = BTreeSet::from([5173, 3000]);
    assert_eq!(ports_text(&ports), ":3000, :5173");
    assert_eq!(parse_ports_text(":3000, :5173"), ports);
    assert_eq!(parse_ports_text(":8080, :x, :0"), BTreeSet::from([8080]));
}

#[test]
fn a_pass_writes_only_the_daemons_own_entry() {
    let ours = |text: &str| stored(text, Some(PORTS_ICON));
    // No entry yet: the daemon's goes in.
    assert_eq!(plan(None, Some(":1234")), Some(PortsChange::Set(":1234".into())));
    // Its own entry follows the ports, and goes when none accepts.
    assert_eq!(
        plan(Some(&ours(":3000")), Some(":3000, :3001")),
        Some(PortsChange::Set(":3000, :3001".into()))
    );
    assert_eq!(plan(Some(&ours(":4000")), Some(":4000")), None);
    assert_eq!(plan(Some(&ours(":5000")), None), Some(PortsChange::Clear));
    assert_eq!(plan(None, None), None);
    // A person's or a hook's entry (another icon, or none) stays.
    assert_eq!(plan(Some(&stored("api :8080", None)), Some(":9000")), None);
    assert_eq!(plan(Some(&stored("api :8080", Some("server"))), None), None);
}

#[test]
fn a_mark_queues_once_until_the_pass_takes_it() {
    let mark = PortMark::default();
    assert!(mark.mark(), "the first output queues the terminal");
    assert!(!mark.mark(), "more output before the pass queues nothing");
    mark.take();
    assert!(mark.mark(), "output after the pass queues it again");
}

/// The worker lets the mux go while it waits: a mux dropped while the
/// worker idles frees the session at once, so the next daemon of the same
/// session (a restart in the same process) opens it. A strong mux held
/// across the idle wait kept the registry's session lease for
/// [`IDLE_LINGER`], and every restart test failed with "workspace session is
/// already owned by another daemon".
#[test]
fn cmux_next_an_idle_port_watch_worker_does_not_keep_a_dropped_mux() {
    let root = std::env::temp_dir()
        .join(format!("cmux-port-watch-reopen-{}", WorkspacePublicId::random().unwrap()));
    let open = || {
        let registry = WorkspaceRegistry::open(&root, "port-watch").unwrap();
        Mux::from_workspace_registry(
            "port-watch".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    let mux = open();
    mux.reconcile_terminal_ports();
    // The reconcile pass ran and the worker gave its mux back. The worker
    // takes its mux before it takes the request, with the watch locked, and
    // a pass that met a busy registry puts the request back before it gives
    // its mux back. So a taken request with one mux left, read under that
    // lock, is a pass that ended (it ran to its end or it panicked).
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = mux.terminal_port_watch.lock();
        let pass_ran = state.worker && !state.reconcile && state.last_pass.is_some();
        if pass_ran && Arc::strong_count(&mux) == 1 {
            break;
        }
        drop(state);
        assert!(Instant::now() < deadline, "the reconcile pass never ran");
        std::thread::sleep(Duration::from_millis(10));
    }
    let weak = Arc::downgrade(&mux);
    drop(mux);
    assert!(weak.upgrade().is_none(), "the port watch worker still holds the mux");
    drop(open());
    let _ = std::fs::remove_dir_all(&root);
}

/// The worker lets the mux go while the registry is busy: a pass that
/// meets a busy registry holds no mux while it waits for it. The pass
/// stays queued and runs when the registry is free, and the mux dropped
/// after it frees the session at once. A worker that waited for the
/// registry with a strong mux kept the session for that wait: a daemon
/// dropped in it left its end to the worker, and the next daemon of the
/// same session can fail with "workspace session is already owned by
/// another daemon".
#[test]
fn cmux_next_a_port_watch_worker_that_waits_for_the_registry_does_not_keep_the_mux() {
    let root = std::env::temp_dir()
        .join(format!("cmux-port-watch-busy-registry-{}", WorkspacePublicId::random().unwrap()));
    let open = || {
        let registry = WorkspaceRegistry::open(&root, "port-watch").unwrap();
        Mux::from_workspace_registry(
            "port-watch".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    // True when `ready` held within the bound. It reads the watch's state
    // and the count of strong muxes under the watch's lock.
    let reached = |mux: &Arc<Mux>, ready: &dyn Fn(&WatchState, usize) -> bool| {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if ready(&mux.terminal_port_watch.lock(), Arc::strong_count(mux)) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    let mux = open();
    mux.reconcile_terminal_ports();
    // The worker took the first request: that pass ended, or it runs now
    // and meets the hold below as the busy pass.
    assert!(
        reached(&mux, &|state, _| state.worker && !state.reconcile && state.last_pass.is_some()),
        "the first pass never ran"
    );
    let first_pass = mux.terminal_port_watch.lock().last_pass;
    // The registry is busy when the next pass comes to it.
    let registry_busy = mux.workspace_registry.lock().unwrap();
    mux.reconcile_terminal_ports();
    let let_go = reached(&mux, &|state, muxes| state.last_pass != first_pass && muxes == 1);
    drop(registry_busy);
    assert!(let_go, "the port watch worker keeps the mux while it waits for the registry");
    // The pass that met the busy registry runs now.
    assert!(
        reached(&mux, &|state, muxes| state.worker && !state.reconcile && muxes == 1),
        "the pass that waited for the registry never ran"
    );
    let weak = Arc::downgrade(&mux);
    drop(mux);
    assert!(weak.upgrade().is_none(), "the port watch worker still holds the mux");
    drop(open());
    let _ = std::fs::remove_dir_all(&root);
}

/// The worker holds no registry lock while it waits for the store's
/// connection: a pass that meets a busy connection puts its request back,
/// lets the registry and the mux go, and looks again. The journal writer
/// has the connection for the time of its commit. A worker that waited for
/// the connection with the registry's lock made each thread that takes the
/// registry wait for that commit too, and it kept its mux for that wait.
#[test]
fn cmux_next_a_port_watch_worker_that_meets_a_busy_connection_holds_no_registry_lock() {
    let root = std::env::temp_dir()
        .join(format!("cmux-port-watch-busy-connection-{}", WorkspacePublicId::random().unwrap()));
    let open = || {
        let registry = WorkspaceRegistry::open(&root, "port-watch").unwrap();
        Mux::from_workspace_registry(
            "port-watch".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    // True when `ready` held within the bound. It reads the watch's state
    // and the count of strong muxes under the watch's lock.
    let reached = |mux: &Arc<Mux>, ready: &dyn Fn(&WatchState, usize) -> bool| {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if ready(&mux.terminal_port_watch.lock(), Arc::strong_count(mux)) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    // True when each take of the registry's lock in a window of 500 ms came
    // within 2 s. The worker looks again each `REGISTRY_BUSY_LOOK`, so the
    // window has many looks of the worker.
    let registry_stays_free = |mux: &Arc<Mux>| {
        let window = Instant::now() + Duration::from_millis(500);
        while Instant::now() < window {
            let bound = Instant::now() + Duration::from_secs(2);
            loop {
                if let Some(registry) = mux.workspace_registry.try_lock_free() {
                    drop(registry);
                    break;
                }
                if Instant::now() >= bound {
                    return false;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        true
    };
    let mux = open();
    mux.reconcile_terminal_ports();
    assert!(
        reached(&mux, &|state, muxes| {
            state.worker && !state.reconcile && state.last_pass.is_some() && muxes == 1
        }),
        "the first pass never ran to its end"
    );
    let first_pass = mux.terminal_port_watch.lock().last_pass;
    // Another thread has the store's connection when the next pass comes to
    // it, as the journal writer has at a commit. It has no mux.
    let connection = Arc::clone(&mux.registry_connection);
    let (held, is_held) = std::sync::mpsc::sync_channel(1);
    let (let_go, go) = std::sync::mpsc::sync_channel::<()>(1);
    let holder = std::thread::spawn(move || {
        let hold = connection.get();
        let _ = held.send(());
        let _ = go.recv();
        drop(hold);
    });
    is_held.recv_timeout(Duration::from_secs(10)).expect("the holder never had the connection");
    mux.reconcile_terminal_ports();
    let pass_came = reached(&mux, &|state, _| state.last_pass != first_pass);
    let registry_free = pass_came && registry_stays_free(&mux);
    // The request is in the watch again and the worker has no mux, read
    // under the watch's lock while the connection is still held: the pass
    // gave its request back before it let its mux go.
    let mux_free = registry_free
        && reached(&mux, &|state, muxes| {
            state.last_pass != first_pass && state.reconcile && muxes == 1
        });
    drop(let_go);
    holder.join().unwrap();
    assert!(pass_came, "the pass after the hold of the connection never came");
    assert!(
        registry_free,
        "the port watch worker keeps the registry's lock while it waits for the store's connection"
    );
    assert!(
        mux_free,
        "the port watch worker keeps the mux or loses its request while it waits for the connection"
    );
    // The pass that met the busy connection runs now.
    assert!(
        reached(&mux, &|state, muxes| state.worker && !state.reconcile && muxes == 1),
        "the pass that waited for the connection never ran"
    );
    let weak = Arc::downgrade(&mux);
    drop(mux);
    assert!(weak.upgrade().is_none(), "the port watch worker still holds the mux");
    drop(open());
    let _ = std::fs::remove_dir_all(&root);
}
