//! The update hold against the reaper as the app's update quit meets it: 36 terminals with no
//! tab, each held only by the frontend's attach stream, and a reaper that ends every one past
//! its cap of 16 at the quit and the rest one grace later (the 2026-11-24 05:34Z loss).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::*;
use crate::mux::terminal_reap::{MAX_TERMINALS_IN_REAP_GRACE, ReapSchedule};
use crate::mux::*;

const COUNT: usize = MAX_TERMINALS_IN_REAP_GRACE + 20;

fn host_id(mux: &Arc<Mux>, surface: &Arc<Surface>) -> String {
    mux.resource_terminal_host_identity(surface).expect("test terminal is hosted").terminal_id
}

fn lifecycle(mux: &Arc<Mux>, terminal_id: &str) -> TerminalLifecycle {
    mux.resolve_terminal(terminal_id).unwrap().unwrap().terminal.lifecycle
}

fn running(mux: &Arc<Mux>, terminals: &[String]) -> usize {
    terminals
        .iter()
        .filter(|terminal_id| lifecycle(mux, terminal_id) == TerminalLifecycle::Running)
        .count()
}

fn runtime_view(mux: &Arc<Mux>, terminal_id: &str) -> crate::SurfaceId {
    let state = mux.state.lock().unwrap();
    state
        .terminal_catalog
        .values()
        .find(|runtime| {
            mux.resource_terminal_host_identity(runtime)
                .is_some_and(|identity| identity.terminal_id == terminal_id)
        })
        .map(|runtime| runtime.id)
        .expect("the terminal has a runtime")
}

fn attach_all(mux: &Arc<Mux>, terminals: &[String]) -> Vec<u64> {
    terminals
        .iter()
        .map(|terminal_id| mux.control_clients.attach_test_stream(runtime_view(mux, terminal_id)))
        .collect()
}

fn hold_file(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-update-hold-{}-{name}.json", std::process::id()))
}

/// The state the old app leaves at its quit: a placed anchor and `COUNT` terminals with no tab,
/// each closed 20 graces ago and attached by one frontend client, on a reaper that has seen
/// them a whole grace past their tabs.
struct OldState {
    mux: Arc<Mux>,
    grace: Duration,
    schedule: ReapSchedule,
    placed: Arc<Surface>,
    terminals: Vec<String>,
    clients: Vec<u64>,
    connected: Instant,
}

fn old_state(session: &str) -> OldState {
    let mux = Mux::new_for_test(session, SurfaceOptions::default());
    let grace = mux.terminal_reap_grace();
    let mut schedule = ReapSchedule::default();
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let surfaces: Vec<_> = (0..COUNT)
        .map(|index| mux.new_workspace(Some(format!("agent-{index}")), Some((80, 24))).unwrap())
        .collect();
    let mut terminals = Vec::new();
    let mut clients = Vec::new();
    for (index, surface) in surfaces.iter().enumerate() {
        let terminal_id = host_id(&mux, surface);
        let workspace = mux.surface_workspace(surface.id).expect("terminal has a workspace");
        assert!(mux.close_workspace_at_revision(workspace, None).unwrap().is_some());
        clients.push(mux.control_clients.attach_test_stream(runtime_view(&mux, &terminal_id)));
        assert!(
            mux.reap_unplaced_terminals(&mut schedule, Instant::now()).is_empty(),
            "an attached terminal ended while its frontend was connected"
        );
        mux.workspace_registry
            .lock()
            .unwrap()
            .backdate_terminal_unplaced(
                &terminal_id,
                20 * grace + Duration::from_millis(index as u64),
            )
            .unwrap();
        terminals.push(terminal_id);
    }
    let connected = Instant::now() + grace + Duration::from_secs(1);
    assert!(mux.reap_unplaced_terminals(&mut schedule, connected).is_empty());
    assert_eq!(running(&mux, &terminals), COUNT, "attached terminals ended before the quit");
    OldState { mux, grace, schedule, placed, terminals, clients, connected }
}

fn clean_up(mux: &Arc<Mux>, placed: &Arc<Surface>, terminals: &[String]) {
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

/// Control: this is the old behaviour. With no hold the quit ends every terminal past the cap
/// at once, and the rest one grace later.
#[test]
fn update_hold_control_without_a_hold_the_quit_ends_the_terminals() {
    let OldState { mux, grace, mut schedule, placed, terminals, clients, connected } =
        old_state("update-hold-control");
    for client in clients {
        mux.control_clients.detach_test_client(client);
    }
    let quit = connected + Duration::from_secs(1);
    mux.reap_unplaced_terminals(&mut schedule, quit);
    let after_quit = running(&mux, &terminals);
    mux.reap_unplaced_terminals(&mut schedule, quit + grace + Duration::from_secs(1));
    let after_grace = running(&mux, &terminals);
    eprintln!(
        "update-hold control: terminals={COUNT} cap={MAX_TERMINALS_IN_REAP_GRACE} \
         running_after_quit={after_quit} running_one_grace_later={after_grace}"
    );
    assert_eq!(after_quit, MAX_TERMINALS_IN_REAP_GRACE, "the old reaper keeps only its cap");
    assert_eq!(after_grace, 0, "the old reaper ends the rest one grace later");
    clean_up(&mux, &placed, &terminals);
}

/// The hold is set before the quit; the frontend's streams end; the reaper runs at the quit,
/// one grace later and again as a new owner's reaper would after the handoff; the frontend
/// attaches again and the hold lifts. All 36 run throughout, and none is left marked `keep`.
#[test]
fn update_hold_keeps_every_attached_unplaced_terminal_through_the_quit_and_reattach() {
    let OldState { mux, grace, mut schedule, placed, terminals, clients, connected } =
        old_state("update-hold-survives");
    let path = hold_file("survives");
    let placed_id = host_id(&mux, &placed);
    // A terminal kept on purpose before the update: the hold must not name it.
    let kept_before = terminals[0].clone();
    mux.set_terminal_keep(&kept_before, true).unwrap();

    // `server hold-terminals`, before the app quits.
    let mut held = mux.hold_terminals_for_update(&path, 1_000).unwrap();
    held.sort();
    let mut expected: Vec<String> = terminals[1..].to_vec();
    expected.sort();
    assert_eq!(held, expected, "the hold names every unplaced, unkept terminal and no other");
    assert!(!held.contains(&placed_id) && !held.contains(&kept_before));

    // The old app's keep-sessions quit: every attach stream ends.
    for client in clients {
        mux.control_clients.detach_test_client(client);
    }
    let quit = connected + Duration::from_secs(1);
    let ended_at_quit = mux.reap_unplaced_terminals(&mut schedule, quit);
    let after_quit = running(&mux, &terminals);
    let ended_later =
        mux.reap_unplaced_terminals(&mut schedule, quit + grace + Duration::from_secs(1));
    let after_grace = running(&mux, &terminals);
    // The next owner's reaper starts with an empty schedule and the durable unplaced times.
    let mut next_owner = ReapSchedule::default();
    let handed_off = quit + 3 * grace;
    let ended_after_handoff = mux.reap_unplaced_terminals(&mut next_owner, handed_off);
    let after_handoff = running(&mux, &terminals);
    // Before the app is back, the hold lifts nothing.
    let waiting = mux.lift_update_hold(&path, 2_000, UPDATE_HOLD_MAX).unwrap();
    assert_eq!((waiting.lifted.len(), waiting.expired.len(), waiting.held), (0, 0, COUNT - 1));

    // The relaunched app attaches again; the hold lifts and the reaper runs twice more.
    let reattached = attach_all(&mux, &terminals);
    let lifted = mux.lift_update_hold(&path, 3_000, UPDATE_HOLD_MAX).unwrap();
    let ended_after_lift = mux.reap_unplaced_terminals(&mut next_owner, handed_off + grace);
    mux.reap_unplaced_terminals(&mut next_owner, handed_off + 3 * grace);
    let after_reattach = running(&mux, &terminals);
    eprintln!(
        "update-hold: terminals={COUNT} cap={MAX_TERMINALS_IN_REAP_GRACE} held={} \
         running_after_quit={after_quit} running_one_grace_later={after_grace} \
         running_after_handoff={after_handoff} lifted={} running_after_reattach={after_reattach}",
        held.len(),
        lifted.lifted.len(),
    );
    assert!(ended_at_quit.is_empty() && ended_later.is_empty(), "the quit ended a held terminal");
    assert!(ended_after_handoff.is_empty() && ended_after_lift.is_empty());
    assert_eq!((after_quit, after_grace, after_handoff), (COUNT, COUNT, COUNT));
    assert_eq!(after_reattach, COUNT, "{after_reattach} of {COUNT} run after the re-attach");
    assert_eq!((lifted.lifted.len(), lifted.expired.len(), lifted.held), (COUNT - 1, 0, 0));
    assert!(!path.exists(), "a hold with no terminal left removes its file");
    for terminal_id in &terminals[1..] {
        assert!(!mux.terminal_keep(terminal_id).unwrap(), "{terminal_id} is still marked keep");
    }
    assert!(mux.terminal_keep(&kept_before).unwrap(), "the hold unmarked a kept terminal");
    for client in reattached {
        mux.control_clients.detach_test_client(client);
    }
    clean_up(&mux, &placed, &terminals);
}

/// A held terminal nobody attaches to again loses its mark when the hold expires, so the hold
/// never keeps a PTY for ever; until then it keeps its mark.
#[test]
fn update_hold_expires_for_terminals_nobody_attaches_to_again() {
    let OldState { mux, placed, terminals, clients, .. } = old_state("update-hold-expires");
    let path = hold_file("expires");
    let held = mux.hold_terminals_for_update(&path, 1_000).unwrap();
    assert_eq!(held.len(), COUNT);
    for client in clients {
        mux.control_clients.detach_test_client(client);
    }
    let max_ms = UPDATE_HOLD_MAX.as_millis() as u64;
    let early = mux.lift_update_hold(&path, 1_000 + max_ms - 1, UPDATE_HOLD_MAX).unwrap();
    assert_eq!((early.lifted.len(), early.expired.len(), early.held), (0, 0, COUNT));
    assert!(terminals.iter().all(|terminal_id| mux.terminal_keep(terminal_id).unwrap()));
    let late = mux.lift_update_hold(&path, 1_000 + max_ms, UPDATE_HOLD_MAX).unwrap();
    assert_eq!((late.lifted.len(), late.expired.len(), late.held), (0, COUNT, 0));
    assert!(terminals.iter().all(|terminal_id| !mux.terminal_keep(terminal_id).unwrap()));
    assert!(!path.exists());
    clean_up(&mux, &placed, &terminals);
}
