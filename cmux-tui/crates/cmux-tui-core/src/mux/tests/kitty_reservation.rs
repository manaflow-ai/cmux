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
/// share back (34-39 ms each on the fleet, REOPEN-F3), and here, where it
/// never finishes, 500 ms each and then graphics off: a respawned terminal's
/// restored Kitty images would be dropped for good. A wave that declares its
/// terminals first never waits, and every one starts with the wave's final
/// share, inside the process budget.
#[test]
fn a_respawn_wave_reserves_its_kitty_shares_without_waiting_for_a_launch_in_flight() {
    const WAVE: usize = 12;
    let mux = test_mux();
    let slots = (0..WAVE).map(|_| mux.next_id()).collect::<Vec<_>>();
    let expectations =
        slots.iter().map(|slot| mux.expect_kitty_image_respawn(None, *slot)).collect::<Vec<_>>();
    let share = kitty_image_limits_for_capacity(WAVE.next_power_of_two());
    let mut reservations = Vec::new();
    let mut waits = Vec::new();
    // None of these launches finishes (no commit): each one is in flight.
    for slot in &slots {
        let started = Instant::now();
        reservations.push(mux.reserve_kitty_image_surface(*slot).unwrap());
        waits.push(started.elapsed());
    }
    drop(expectations);
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
    let slots = (0..WAVE).map(|_| mux.next_id()).collect::<Vec<_>>();
    let expectations =
        slots.iter().map(|slot| mux.expect_kitty_image_respawn(None, *slot)).collect::<Vec<_>>();
    let mut reservations = slots[..STARTED]
        .iter()
        .map(|slot| mux.reserve_kitty_image_surface(*slot).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        reservations[0].initial_limits(),
        kitty_image_limits_for_capacity(WAVE.next_power_of_two()),
        "the wave did not size the budget for all of its terminals"
    );
    // The rest fail before they reserve: their respawns drop the expectations.
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

/// Expectations dropped with no reservation (respawns given up before they
/// start) leave the budget as it was: a lone terminal keeps its full share.
#[test]
fn a_dropped_kitty_expectation_gives_its_share_back() {
    let mux = test_mux();
    let expectations =
        (0..4).map(|_| mux.expect_kitty_image_respawn(None, mux.next_id())).collect::<Vec<_>>();
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

/// The start sweep counts its lost terminals before it plans the first
/// respawn; a respawn that fails before it is planned (so it never names its
/// slot) is given back when the sweep ends: a new tab then gets the share of
/// the terminals that started, not of the wave.
#[test]
fn a_start_wave_is_sized_before_its_first_respawn_and_gives_back_the_unplanned() {
    const WAVE: usize = 12;
    const PLANNED: usize = 3;
    let mux = test_mux();
    let wave = mux.expect_kitty_image_wave(WAVE);
    let slots = (0..PLANNED).map(|_| mux.next_id()).collect::<Vec<_>>();
    let mut reservations = Vec::new();
    let mut expectations = Vec::new();
    // Each planned respawn names its slot and reserves at once: the ones not
    // planned yet are still counted.
    for slot in &slots {
        expectations.push(mux.expect_kitty_image_respawn(None, *slot));
        let started = Instant::now();
        reservations.push(mux.reserve_kitty_image_surface(*slot).unwrap());
        assert!(
            started.elapsed() < Duration::from_millis(100),
            "a wave respawn waited {:?} for a launch in flight",
            started.elapsed()
        );
    }
    assert!(
        reservations.iter().all(|reservation| reservation.initial_limits()
            == kitty_image_limits_for_capacity(WAVE.next_power_of_two())),
        "the start wave did not size the budget before its first respawn"
    );
    drop(wave);
    drop(expectations);
    let new_tab = mux.reserve_kitty_image_surface(mux.next_id()).unwrap();
    assert_eq!(
        new_tab.initial_limits(),
        kitty_image_limits_for_capacity((PLANNED + 1).next_power_of_two()),
        "a new tab after the sweep got the share of respawns that never started"
    );
    reservations.push(new_tab);
    drop(reservations);
    wait_for_kitty_image_budget(&mux);
}

/// One host lost while the session runs: its dead runtime still owns a
/// share when its respawn is expected. Counted twice (the old entry and the
/// expectation), two terminals moved the bucket from 2 to 4, and the
/// hysteresis kept it there: the live terminal lost half its Kitty share for
/// good (review of #32164). The dead runtime gives its share up in the same
/// step, so the live one keeps its share and the respawn reserves at once.
#[test]
fn a_runtime_respawn_does_not_count_its_terminal_twice() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let lost = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);
    let share = kitty_image_limits_for_capacity(2);
    assert_eq!(
        first.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap(),
        share
    );

    let slot = mux.next_id();
    let expectation = mux.expect_kitty_image_respawn(Some(&lost), slot);
    assert_eq!(
        mux.kitty_image_budget.lock().unwrap().capacity,
        2,
        "the respawn of one of two terminals counted it twice"
    );
    let started = Instant::now();
    let reservation = mux.reserve_kitty_image_surface(slot).unwrap();
    let waited = started.elapsed();
    drop(expectation);
    assert!(waited < Duration::from_millis(100), "the respawn reservation waited {waited:?}");
    assert_eq!(reservation.initial_limits(), share, "the respawn did not get its old share");
    drop(reservation);
    wait_for_kitty_image_budget(&mux);
    close_terminal_runtime_for_test(&mux, &lost);
    close_terminal_runtime_for_test(&mux, &first);
    wait_for_kitty_image_budget(&mux);
}
