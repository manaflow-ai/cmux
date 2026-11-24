//! A new owner (a whole-app update, a daemon restart) inherits terminals with no tab whose
//! unplaced times are far past the grace: they lived because the app held an attach stream on
//! each. The new owner has no attach stream yet; none of them may end before the app had the
//! time to attach again, and one the app does not come back for must still end.
//!
//! Reproduction of the 2026-11-24 loss at an owner change: 18 of 18 terminals with no tab ended
//! by the incoming owner's reaper 3.5 s after it started.

use super::*;

/// `count` terminals with no tab, each unplaced for 20 graces, as the owner before this one left
/// them. Returns the placed anchor and the terminal ids.
fn inherited_unplaced_terminals(mux: &Arc<Mux>, count: usize) -> (Arc<Surface>, Vec<String>) {
    let grace = mux.terminal_reap_grace();
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let surfaces: Vec<_> = (0..count)
        .map(|index| mux.new_workspace(Some(format!("agent-{index}")), Some((80, 24))).unwrap())
        .collect();
    // The owner before: it saw each closed, and its reaper wrote the unplaced times.
    let mut before = ReapSchedule::default();
    let mut terminals = Vec::new();
    for surface in &surfaces {
        terminals.push(host_id(mux, surface));
        close_workspace_of(mux, surface);
    }
    assert!(mux.reap_unplaced_terminals(&mut before, Instant::now()).is_empty());
    for (index, terminal_id) in terminals.iter().enumerate() {
        mux.workspace_registry
            .lock()
            .unwrap()
            .backdate_terminal_unplaced(
                terminal_id,
                20 * grace + Duration::from_millis(index as u64),
            )
            .unwrap();
    }
    (placed, terminals)
}

fn running(mux: &Arc<Mux>, terminals: &[String]) -> usize {
    terminals
        .iter()
        .filter(|terminal_id| lifecycle(mux, terminal_id) == TerminalLifecycle::Running)
        .count()
}

fn end_all(mux: &Arc<Mux>, placed: &Arc<Surface>, terminals: &[String]) {
    for terminal_id in terminals {
        if lifecycle(mux, terminal_id) == TerminalLifecycle::Running {
            mux.close_terminal_with_mutation(
                terminal_id,
                None,
                None,
                None,
                &WorkspaceMutation::daemon_local("test-cleanup"),
            )
            .unwrap();
        }
    }
    mux.close_surface(placed.id).unwrap();
}

/// The frontend connects later than one grace after the new owner started. Nothing ends while
/// it is away; it then attaches to `returning` of them, and one grace after it connected those
/// run and the ones it did not come back for have ended.
#[test]
fn cold_owner_holds_inherited_terminals_past_the_cap_until_a_late_frontend_attaches() {
    let mux = Mux::new_for_test("cold-adoption-late-frontend", SurfaceOptions::default());
    let grace = mux.terminal_reap_grace();
    let count = MAX_TERMINALS_IN_REAP_GRACE + 20;
    let returning = MAX_TERMINALS_IN_REAP_GRACE + 2;
    let (placed, terminals) = inherited_unplaced_terminals(&mux, count);

    // The new owner: a new schedule, no client of any kind.
    let mut cold = ReapSchedule::default();
    let start = Instant::now();
    assert!(mux.reap_unplaced_terminals(&mut cold, start).is_empty());
    assert_eq!(running(&mux, &terminals), count, "the new owner's first pass ended terminals");
    let late = start + 2 * grace;
    assert!(mux.reap_unplaced_terminals(&mut cold, late).is_empty());
    assert_eq!(running(&mux, &terminals), count, "terminals ended before any frontend came");

    // The app's window connects, and one second later holds its attach streams again.
    mux.control_clients.connect_test_frontend();
    assert!(mux.reap_unplaced_terminals(&mut cold, late).is_empty());
    for terminal_id in &terminals[..returning] {
        mux.control_clients.attach_test_stream(runtime_view(&mux, terminal_id));
    }
    assert!(mux.reap_unplaced_terminals(&mut cold, late + Duration::from_secs(1)).is_empty());
    assert_eq!(running(&mux, &terminals), count);

    // One grace after the frontend connected: the hold of the rest is over.
    let ended = mux.reap_unplaced_terminals(&mut cold, late + grace + Duration::from_secs(1));
    assert_eq!(running(&mux, &terminals[..returning]), returning, "a returning terminal ended");
    assert_eq!(ended.len(), count - returning, "a terminal nobody came back for still runs");
    assert_eq!(running(&mux, &terminals[returning..]), 0);
    end_all(&mux, &placed, &terminals);
}

/// The other order: the frontend is already connected at the new owner's first pass, and has no
/// attach stream yet.
#[test]
fn cold_owner_holds_inherited_terminals_when_the_frontend_connected_before_its_first_pass() {
    let mux = Mux::new_for_test("cold-adoption-early-frontend", SurfaceOptions::default());
    let grace = mux.terminal_reap_grace();
    let count = MAX_TERMINALS_IN_REAP_GRACE + 20;
    let (placed, terminals) = inherited_unplaced_terminals(&mux, count);

    mux.control_clients.connect_test_frontend();
    let mut cold = ReapSchedule::default();
    let start = Instant::now();
    assert!(mux.reap_unplaced_terminals(&mut cold, start).is_empty());
    assert_eq!(running(&mux, &terminals), count, "the new owner's first pass ended terminals");
    assert_eq!(cold.deadline(&terminals[0]), Some(start + grace));
    for terminal_id in &terminals {
        mux.control_clients.attach_test_stream(runtime_view(&mux, terminal_id));
    }
    assert!(
        mux.reap_unplaced_terminals(&mut cold, start + grace + Duration::from_secs(1)).is_empty()
    );
    assert_eq!(running(&mux, &terminals), count);

    // The attach ended each hold durably: the next owner start holds them again.
    let mut next = ReapSchedule::default();
    assert!(mux.reap_unplaced_terminals(&mut next, Instant::now()).is_empty());
    assert_eq!(running(&mux, &terminals), count);
    end_all(&mux, &placed, &terminals);
}

/// No app comes back (a headless owner, or owners that restart faster than the hold): the hold
/// is given once, counted across restarts, and then every inherited terminal ends.
#[test]
fn cold_owner_ends_inherited_terminals_nobody_returns_for_once_the_hold_is_over() {
    let mux = Mux::new_for_test("cold-adoption-no-return", SurfaceOptions::default());
    let count = MAX_TERMINALS_IN_REAP_GRACE + 2;
    let (placed, terminals) = inherited_unplaced_terminals(&mux, count);

    let mut cold = ReapSchedule::default();
    let start = Instant::now();
    assert!(mux.reap_unplaced_terminals(&mut cold, start).is_empty());
    assert_eq!(cold.next_deadline(), Some(start + COLD_ADOPTION_HOLD));

    // Owners that restart every few seconds: each reads the same durable hold start.
    let mut restarted = ReapSchedule::default();
    assert!(mux.reap_unplaced_terminals(&mut restarted, Instant::now()).is_empty());
    assert_eq!(running(&mux, &terminals), count);
    mux.workspace_registry.lock().unwrap().backdate_terminal_adoptions(COLD_ADOPTION_HOLD).unwrap();
    let mut last = ReapSchedule::default();
    let ended = mux.reap_unplaced_terminals(&mut last, Instant::now());
    assert_eq!(ended.len(), count, "the adoption hold was given a second time");
    assert_eq!(running(&mux, &terminals), 0);
    end_all(&mux, &placed, &terminals);
}
