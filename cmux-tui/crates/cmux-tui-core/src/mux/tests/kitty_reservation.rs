//! Creating a terminal waits for existing terminals to shrink their Kitty
//! image quota (the process budget must hold), but only briefly: a host that
//! never acknowledges its shrink must cost the new terminal its Kitty
//! graphics for a while, not 2 s of creation time.

use super::*;

#[test]
fn a_stalled_kitty_shrink_degrades_a_new_terminal_quickly() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    // The first terminal's next quota update never completes until released.
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let gate = gate.clone();
        let first_id = first.id;
        move |surface, limits, _deadline| {
            if surface.id == first_id {
                let (released, changed) = &*gate;
                let mut released = released.lock().unwrap();
                while !*released {
                    released = changed.wait(released).unwrap();
                }
            }
            surface.set_kitty_graphics_limits(
                limits.image_bytes,
                limits.inflight_bytes,
                limits.images,
                limits.placements,
            )
        }
    }));

    // The third terminal moves the budget from two shares to four.
    let started = Instant::now();
    let third = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let waited = started.elapsed();
    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    wait_for_kitty_image_budget(&mux);
    assert!(
        waited < Duration::from_secs(1),
        "creating a terminal waited {waited:?} for a stalled Kitty shrink"
    );
    assert!(
        third.with_terminal(|terminal| terminal.kitty_image_count_limit().unwrap()).unwrap() > 0,
        "the degraded terminal was not promoted after the shrink completed"
    );
    for surface in [third, second, first] {
        close_terminal_runtime_for_test(&mux, &surface);
    }
}

/// The process budget a set of reservations is given: bytes, then images
/// and placements (each limit counts once per screen).
fn granted(reservations: &[KittyImageBudgetReservation]) -> (u64, u64, u64) {
    reservations.iter().map(KittyImageBudgetReservation::initial_limits).fold(
        (0, 0, 0),
        |(bytes, images, placements), limits| {
            (
                bytes + kitty_surface_byte_reservation(limits.image_bytes),
                images + limits.images * KITTY_OBJECT_OWNERS_PER_SURFACE,
                placements + limits.placements * KITTY_OBJECT_OWNERS_PER_SURFACE,
            )
        },
    )
}

/// After a kill of everything, 12 terminals respawn at once. The first one
/// to reserve used to take the whole Kitty budget (it was alone), so every
/// other reservation waited for that first launch to finish and give its
/// share back (34-39 ms each on the fleet, cx REOPEN-F3), and here, where
/// it never finishes, 500 ms each and then graphics off: a respawned
/// terminal's restored Kitty images would be dropped for good. A wave that
/// declares its terminals first never waits, and every one starts with the
/// wave's final share, inside the process budget.
#[test]
fn a_respawn_wave_reserves_its_kitty_shares_without_waiting_for_a_launch_in_flight() {
    const WAVE: usize = 12;
    let mux = test_mux();
    let expectations = (0..WAVE).map(|_| mux.expect_kitty_image_surface()).collect::<Vec<_>>();
    let share = kitty_image_limits_for_capacity(WAVE.next_power_of_two());
    let mut reservations = Vec::new();
    let mut waits = Vec::new();
    // Each respawn drops its expectation right before it reserves. None of
    // these launches finishes (no commit): each one is still in flight.
    for expectation in expectations {
        drop(expectation);
        let started = Instant::now();
        reservations.push(mux.reserve_kitty_image_surface(mux.next_id()).unwrap());
        waits.push(started.elapsed());
    }
    let limits =
        reservations.iter().map(KittyImageBudgetReservation::initial_limits).collect::<Vec<_>>();
    assert!(
        waits.iter().all(|wait| *wait < Duration::from_millis(100)),
        "a wave reservation waited for a launch in flight: {waits:?}"
    );
    assert!(
        limits.iter().all(|limits| *limits == share),
        "a wave terminal did not start with the wave's share {share:?}: {limits:?}"
    );
    let (bytes, images, placements) = granted(&reservations);
    assert!(
        bytes <= KITTY_IMAGE_PROCESS_BUDGET_BYTES
            && images <= KITTY_IMAGE_PROCESS_BUDGET_COUNT
            && placements <= ghostty_vt::MAX_KITTY_PLACEMENTS,
        "the wave was given more than the process budget: {bytes} bytes, {images} images, \
         {placements} placements"
    );
    drop(reservations);
    wait_for_kitty_image_budget(&mux);
}

/// A wave given up halfway (its later respawns fail before they reserve)
/// gives back the shares of the terminals that never start: a new tab after
/// it gets the share of the terminals that exist, not of the wave.
#[test]
fn a_wave_given_up_halfway_gives_back_the_kitty_shares_it_never_used() {
    const WAVE: usize = 12;
    const STARTED: usize = 3;
    let mux = test_mux();
    let mut expectations = (0..WAVE).map(|_| mux.expect_kitty_image_surface()).collect::<Vec<_>>();
    let mut reservations = Vec::new();
    for expectation in expectations.drain(..STARTED) {
        drop(expectation);
        reservations.push(mux.reserve_kitty_image_surface(mux.next_id()).unwrap());
    }
    assert_eq!(
        reservations[0].initial_limits(),
        kitty_image_limits_for_capacity(WAVE.next_power_of_two()),
        "the wave did not size the budget for all of its terminals"
    );
    drop(expectations);
    let started = Instant::now();
    let new_tab = mux.reserve_kitty_image_surface(mux.next_id()).unwrap();
    let waited = started.elapsed();
    assert_eq!(
        new_tab.initial_limits(),
        kitty_image_limits_for_capacity((STARTED + 1).next_power_of_two()),
        "a new tab after a given-up wave got the share of terminals that never started"
    );
    assert!(waited < Duration::from_millis(100), "the new tab waited {waited:?}");
    reservations.push(new_tab);
    let (bytes, _, _) = granted(&reservations);
    assert!(bytes <= KITTY_IMAGE_PROCESS_BUDGET_BYTES, "{bytes} bytes over the process budget");
    drop(reservations);
    wait_for_kitty_image_budget(&mux);
}

/// An expectation dropped with no reservation (a respawn given up before it
/// starts) leaves the budget as it was: a lone terminal keeps its full share.
#[test]
fn a_dropped_kitty_expectation_gives_its_share_back() {
    let mux = test_mux();
    let expectations = (0..4).map(|_| mux.expect_kitty_image_surface()).collect::<Vec<_>>();
    let first = mux.reserve_kitty_image_surface(mux.next_id()).unwrap();
    assert_eq!(
        first.initial_limits(),
        kitty_image_limits_for_capacity(8),
        "the reservation was not sized for the four expected terminals"
    );
    drop(expectations);
    assert_eq!(mux.kitty_image_budget.lock().unwrap().capacity, 1);
    drop(first);
    wait_for_kitty_image_budget(&mux);
}
