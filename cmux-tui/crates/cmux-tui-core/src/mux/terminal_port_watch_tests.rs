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
    // The reconcile pass ran and the worker is in its idle wait.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = mux.terminal_port_watch.lock();
        if state.worker && !state.reconcile && state.last_pass.is_some() {
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
