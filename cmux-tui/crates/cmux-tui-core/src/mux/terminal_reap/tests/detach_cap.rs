//! Keep-sessions quit of the frontend (the Mac app's update relaunch): terminals with no tab
//! that live only because the frontend holds an attach stream on them. The quit ends every
//! attach stream at once; no terminal a person or an agent still runs may end because of it.
//!
//! Reproduction of the 2026-11-24 05:34Z loss (1510 -> 1490 live sessions, 20 terminal agents
//! ended with status 143 at a `cmux app quit --keep-sessions` update).

use super::*;

/// `count` terminals with no tab, each closed `closed_for` ago and each attached by one
/// frontend client. Returns the placed anchor, the terminal ids and the frontend's clients.
fn attached_unplaced_terminals(
    mux: &Arc<Mux>,
    count: usize,
    closed_for: Duration,
    schedule: &mut ReapSchedule,
) -> (Arc<Surface>, Vec<String>, Vec<u64>) {
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let surfaces: Vec<_> = (0..count)
        .map(|index| mux.new_workspace(Some(format!("agent-{index}")), Some((80, 24))).unwrap())
        .collect();
    // The frontend is the app: it said hello with role main, which is what the reaper's
    // relaunch hold reads (`ClientRegistry::frontend_seen`).
    mux.control_clients.note_test_frontend();
    let mut terminals = Vec::new();
    let mut clients = Vec::new();
    for (index, surface) in surfaces.iter().enumerate() {
        let terminal_id = host_id(mux, surface);
        close_workspace_of(mux, surface);
        // The frontend attaches before the reaper next looks.
        clients.push(mux.control_clients.attach_test_stream(runtime_view(mux, &terminal_id)));
        assert!(
            mux.reap_unplaced_terminals(schedule, Instant::now()).is_empty(),
            "an attached terminal ended while its frontend was connected"
        );
        mux.workspace_registry
            .lock()
            .unwrap()
            .backdate_terminal_unplaced(
                &terminal_id,
                closed_for + Duration::from_millis(index as u64),
            )
            .unwrap();
        terminals.push(terminal_id);
    }
    (placed, terminals, clients)
}

fn running(mux: &Arc<Mux>, terminals: &[String]) -> usize {
    terminals
        .iter()
        .filter(|terminal_id| lifecycle(mux, terminal_id) == TerminalLifecycle::Running)
        .count()
}

/// The frontend quits (every attach stream ends) and the reaper runs once, as any topology
/// event makes it: how many of `count` attached terminals with no tab are still running, and
/// how many a relaunch that takes a whole grace finds.
fn survivors_of_a_frontend_quit(session: &str, count: usize) -> (usize, usize) {
    let mux = Mux::new_for_test(session, SurfaceOptions::default());
    let grace = mux.terminal_reap_grace();
    let mut schedule = ReapSchedule::default();
    let (placed, terminals, clients) =
        attached_unplaced_terminals(&mux, count, 20 * grace, &mut schedule);
    // While the frontend is connected nothing ends, a whole grace after the tabs went: every
    // attempt reads `Attached` and waits another grace.
    let connected = Instant::now() + grace + Duration::from_secs(1);
    assert!(mux.reap_unplaced_terminals(&mut schedule, connected).is_empty());
    assert_eq!(running(&mux, &terminals), count, "attached terminals ended before the quit");

    // `cmux app quit --keep-sessions`: the frontend's connections end, one second later.
    for client in clients {
        mux.control_clients.detach_test_client(client);
    }
    let quit = connected + Duration::from_secs(1);
    let ended_at_quit = mux.reap_unplaced_terminals(&mut schedule, quit).len();
    let after_quit = running(&mux, &terminals);
    assert_eq!(count - ended_at_quit, after_quit);
    // The relaunch has not attached again one grace later.
    mux.reap_unplaced_terminals(&mut schedule, quit + grace + Duration::from_secs(1));
    let after_grace = running(&mux, &terminals);
    eprintln!(
        "relaunch-loss: terminals={count} cap={MAX_TERMINALS_IN_REAP_GRACE} \
         running_after_quit={after_quit} ended_at_quit={ended_at_quit} \
         running_one_grace_later={after_grace}"
    );
    assert_eq!(lifecycle(&mux, &host_id(&mux, &placed)), TerminalLifecycle::Running);
    for terminal_id in &terminals {
        if lifecycle(&mux, terminal_id) == TerminalLifecycle::Running {
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
    (after_quit, after_grace)
}

/// 36 terminals with no tab, held by the frontend's attach streams: the quit must end none.
#[test]
fn relaunch_loss_frontend_quit_ends_no_attached_unplaced_terminal_past_the_cap() {
    let count = MAX_TERMINALS_IN_REAP_GRACE + 20;
    let (after_quit, _) = survivors_of_a_frontend_quit("relaunch-loss-past-cap", count);
    assert_eq!(
        after_quit,
        count,
        "the frontend's keep-sessions quit ended {} of {count} attached terminals with no tab \
         at once ({after_quit} still run; the grace cap is {MAX_TERMINALS_IN_REAP_GRACE})",
        count - after_quit,
    );
}

/// The same terminals when the relaunch takes longer than the reap grace to attach again.
#[test]
fn relaunch_loss_frontend_quit_keeps_attached_unplaced_terminals_for_a_slow_relaunch() {
    let count = MAX_TERMINALS_IN_REAP_GRACE + 20;
    let (after_quit, after_grace) = survivors_of_a_frontend_quit("relaunch-loss-slow", count);
    assert_eq!(
        after_grace, count,
        "one reap grace after the frontend's keep-sessions quit {after_grace} of {count} attached \
         terminals with no tab still run ({after_quit} right after the quit)"
    );
}

/// Control: within the cap the quit itself ends nothing at once.
#[test]
fn relaunch_loss_frontend_quit_within_the_cap_ends_nothing_at_once() {
    let count = MAX_TERMINALS_IN_REAP_GRACE;
    let (after_quit, _) = survivors_of_a_frontend_quit("relaunch-loss-within-cap", count);
    assert_eq!(after_quit, count, "{} of {count} ended at the quit", count - after_quit);
}
