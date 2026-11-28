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
