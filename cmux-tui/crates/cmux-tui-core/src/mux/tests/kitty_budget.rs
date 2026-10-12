//! Kitty graphics process budget, quota worker, and terminal admission under quota changes.

use super::*;

#[test]
fn kitty_image_storage_and_copied_pixels_share_one_process_budget() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut surfaces = vec![first];
    for _ in 1..8 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);

    let configured = surfaces
        .iter()
        .map(|surface| {
            surface.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap()
        })
        .map(|limits| {
            limits
                .image_bytes
                .saturating_mul(KITTY_IMAGE_PERSISTENT_COPIES_PER_SURFACE)
                .saturating_add(limits.inflight_bytes)
        })
        .sum::<u64>();

    assert!(
        configured <= KITTY_IMAGE_PROCESS_BUDGET_BYTES,
        "per-terminal limits allow {configured} bytes across native screen storage, copied caches, and in-flight uploads"
    );
}

#[test]
fn kitty_capacity_buckets_reserve_encoded_upload_bytes_inside_the_process_budget() {
    let mut capacity = 1;
    while capacity <= KITTY_IMAGE_BUDGET_OWNER_LIMIT {
        let limits = kitty_image_limits_for_capacity(capacity);
        assert_eq!(
            limits.inflight_bytes,
            ghostty_vt::kitty_inflight_replay_limit_for_image_bytes(limits.image_bytes)
        );
        assert!(
            kitty_surface_byte_reservation(limits.image_bytes).saturating_mul(capacity as u64)
                <= KITTY_IMAGE_PROCESS_BUDGET_BYTES,
            "capacity {capacity} exceeded the process byte budget with {limits:?}"
        );
        capacity = capacity.saturating_mul(2);
    }
}

#[cfg(unix)]
#[test]
fn exited_terminal_placeholders_do_not_consume_kitty_quota() {
    let mux = test_mux();
    let opts = mux.surface_options.lock().unwrap().clone();
    let live = Surface::spawn_for_test(mux.next_id(), opts.clone(), Arc::downgrade(&mux)).unwrap();
    wait_for_kitty_image_budget(&mux);
    let unconstrained =
        live.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap();

    let placeholder = Surface::exited_terminal_placeholder(
        mux.next_id(),
        opts,
        Arc::downgrade(&mux),
        TerminalHostIdentity {
            terminal_id: "00112233445566778899aabbccddeeff".into(),
            incarnation: "11111111111111111111111111111111".into(),
        },
    )
    .unwrap();
    wait_for_kitty_image_budget(&mux);

    assert_eq!(
        live.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap(),
        unconstrained,
        "an exited placeholder reduced a live terminal's graphics share"
    );
    assert_eq!(
        placeholder.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap(),
        KittyGraphicsLimits::disabled(),
        "an exited placeholder retained graphics resources it cannot use"
    );
}

#[test]
fn kitty_object_limits_cover_primary_and_alternate_screens() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut surfaces = vec![first];
    for _ in 1..8 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);
    let (configured_images, configured_placements) = surfaces
        .iter()
        .map(|surface| {
            surface
                .with_terminal(|terminal| {
                    let primary_images = terminal.kitty_image_count_limit().unwrap();
                    let primary_placements = terminal.kitty_placement_count_limit().unwrap();
                    terminal.vt_write(b"\x1b[?1049h");
                    let alternate_images = terminal.kitty_image_count_limit().unwrap();
                    let alternate_placements = terminal.kitty_placement_count_limit().unwrap();
                    terminal.vt_write(b"\x1b[?1049l");
                    (
                        primary_images.saturating_add(alternate_images),
                        primary_placements.saturating_add(alternate_placements),
                    )
                })
                .unwrap()
        })
        .fold((0u64, 0u64), |(images, placements), candidate| {
            (images.saturating_add(candidate.0), placements.saturating_add(candidate.1))
        });
    assert!(
        configured_images <= 4_096,
        "primary and alternate screens allow {configured_images} native image records process-wide"
    );
    assert!(
        configured_placements <= 16_384,
        "primary and alternate screens allow {configured_placements} native placements process-wide"
    );
}

#[test]
fn kitty_inflight_uploads_share_the_process_byte_budget() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut surfaces = vec![first];
    for _ in 1..8 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);
    let per_surface_limit = surfaces[0]
        .with_terminal(|terminal| terminal.kitty_inflight_storage_limit())
        .unwrap() as usize;
    let segment_bytes = (per_surface_limit.saturating_mul(3) / 5) / 4 * 4;
    let first =
        format!("\x1b_Ga=t,t=d,f=24,i=991,s=1,v=1,m=1,q=2;{}\x1b\\", "A".repeat(segment_bytes));
    let second = format!("\x1b_Ga=t,t=d,f=24,i=991,m=1,q=2;{}", "A".repeat(segment_bytes));
    let inflight_is_bounded = surfaces[0]
        .with_terminal(|terminal| {
            terminal.vt_write(first.as_bytes());
            terminal.vt_write(second.as_bytes());
            terminal.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES).is_err()
        })
        .unwrap();
    assert!(
        inflight_is_bounded,
        "completed and current Kitty upload chunks retained more than one surface byte share"
    );
}

#[test]
fn kitty_mux_quota_replays_a_maximum_size_inflight_upload() {
    use base64::Engine as _;

    const IMAGE_WIDTH: usize = 2_500;
    const IMAGE_HEIGHT: usize = 1_000;
    const IMAGE_ID: u32 = 992;

    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    let pixels = vec![0xff; IMAGE_WIDTH * IMAGE_HEIGHT * 4];
    assert_eq!(pixels.len(), ghostty_vt::MAX_KITTY_IMAGE_BYTES);
    let payload = base64::engine::general_purpose::STANDARD.encode(&pixels);
    let (first_payload, final_payload) = payload.split_at(payload.len() - 4);
    let first_chunk = format!(
        "\x1b_Ga=t,t=d,f=32,i={IMAGE_ID},s={IMAGE_WIDTH},v={IMAGE_HEIGHT},m=1,q=2;{first_payload}\x1b\\"
    );
    let final_chunk = format!("\x1b_Gm=0,q=2;{final_payload}\x1b\\");
    assert!(first_chunk.len() <= ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES);

    surface
        .with_terminal(|terminal| {
            let limits = terminal.kitty_graphics_limits().unwrap();
            assert_eq!(limits.image_bytes, ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
            terminal.vt_write(first_chunk.as_bytes());
            terminal
                .preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                .expect("Mux quota rejected replay for a permitted maximum-size Kitty image");
            terminal.vt_write(final_chunk.as_bytes());
            assert_eq!(
                terminal
                    .kitty_graphics_snapshot()
                    .unwrap()
                    .image(IMAGE_ID)
                    .expect("maximum-size Kitty image was not admitted")
                    .data
                    .len(),
                pixels.len()
            );
        })
        .unwrap();
}

#[test]
fn closing_kitty_surfaces_rebalances_the_survivors_process_share() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut surfaces = vec![first.clone()];
    for _ in 1..8 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);
    let constrained = first
        .with_terminal(|terminal| {
            (
                terminal.kitty_image_storage_limit().unwrap(),
                terminal.kitty_image_count_limit().unwrap(),
                terminal.kitty_placement_count_limit().unwrap(),
            )
        })
        .unwrap();

    for surface in surfaces.iter().skip(1) {
        close_terminal_runtime_for_test(&mux, surface);
    }
    wait_for_kitty_image_budget(&mux);

    let survivor_limit = first
        .with_terminal(|terminal| {
            (
                terminal.kitty_image_storage_limit().unwrap(),
                terminal.kitty_image_count_limit().unwrap(),
                terminal.kitty_placement_count_limit().unwrap(),
            )
        })
        .unwrap();
    let expected = kitty_image_limits_for_capacity(1).image_bytes;
    assert!(
        survivor_limit.0 > constrained.0,
        "surviving terminal kept its peak-surface quota of {} bytes",
        survivor_limit.0
    );
    assert_eq!(survivor_limit.0, expected);
    assert!(
        survivor_limit.1 > constrained.1,
        "surviving terminal kept its peak-surface image count of {}",
        survivor_limit.1
    );
    assert!(
        survivor_limit.2 > constrained.2,
        "surviving terminal kept its peak-surface placement count of {}",
        survivor_limit.2
    );
    assert_eq!(survivor_limit.1, 2_048);
    assert_eq!(survivor_limit.2, 8_192);
}

#[test]
fn killed_kitty_surface_cannot_block_the_next_terminal_reservation() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut survivors = Vec::new();
    for _ in 1..4 {
        survivors.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);

    let first_id = first.id;
    *mux.kitty_image_budget_operation.lock().unwrap() =
        Some(Arc::new(move |surface, limits, _deadline| {
            if surface.id == first_id {
                anyhow::bail!("a killed terminal host cannot acknowledge quota updates");
            }
            surface.set_kitty_graphics_limits(
                limits.image_bytes,
                limits.inflight_bytes,
                limits.images,
                limits.placements,
            )
        }));

    first.kill();
    let started = Instant::now();
    let replacement = mux
        .new_tab(Some(pane), None, Some((80, 24)))
        .expect("a killed surface retained quota and blocked terminal creation");
    assert!(
        started.elapsed() < Duration::from_millis(250),
        "terminal creation waited on a killed surface for {:?}",
        started.elapsed()
    );

    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    close_terminal_runtime_for_test(&mux, &replacement);
    for surface in survivors {
        close_terminal_runtime_for_test(&mux, &surface);
    }
    close_terminal_runtime_for_test(&mux, &first);
    wait_for_kitty_image_budget(&mux);
}

#[test]
fn kitty_quota_updates_delay_terminal_creation_until_startup_is_safe() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let gate = gate.clone();
        move |surface, limits, _deadline| {
            if surface.id == first.id {
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
    let (sender, receiver) = std::sync::mpsc::channel();
    let creating_mux = mux.clone();
    let creator = std::thread::spawn(move || {
        let result = creating_mux.new_tab(Some(pane), None, Some((80, 24)));
        let _ = sender.send(result);
    });

    let created_without_waiting = receiver.recv_timeout(Duration::from_millis(250)).ok();
    let returned_before_release = created_without_waiting.is_some();
    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    let surface = match created_without_waiting {
        Some(result) => result.unwrap(),
        None => receiver.recv_timeout(Duration::from_secs(2)).unwrap().unwrap(),
    };
    creator.join().unwrap();
    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    wait_for_kitty_image_budget(&mux);

    assert!(
        !returned_before_release,
        "terminal creation bypassed the in-flight Kitty quota shrink"
    );
    close_terminal_runtime_for_test(&mux, &surface);
}

#[test]
fn kitty_quota_timeout_degrades_a_new_terminal_instead_of_rejecting_it() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let (started_sender, started_receiver) = std::sync::mpsc::sync_channel(1);
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let gate = gate.clone();
        let first_id = first.id;
        move |surface, limits, _deadline| {
            if surface.id == first_id && limits == kitty_image_limits_for_capacity(1) {
                let _ = started_sender.try_send(());
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

    close_terminal_runtime_for_test(&mux, &second);
    started_receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("Kitty quota shrink did not start");

    let (sender, receiver) = std::sync::mpsc::channel();
    let creating_mux = mux.clone();
    let creator = std::thread::spawn(move || {
        let _ = sender.send(creating_mux.new_tab(Some(pane), None, Some((80, 24))));
    });
    let created = receiver
        .recv_timeout(
            crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT
                .saturating_add(Duration::from_secs(1)),
        )
        .expect("terminal creation did not resolve after the Kitty quota timeout")
        .expect("Kitty quota timeout rejected terminal creation");
    assert_eq!(
        created.with_terminal(|terminal| terminal.kitty_image_count_limit().unwrap()).unwrap(),
        0,
        "a timed-out Kitty quota reservation must start with graphics disabled"
    );
    {
        let budget = mux.kitty_image_budget.lock().unwrap();
        let entry = budget.entries.get(&created.id).expect("degraded reservation was removed");
        assert_eq!(
            entry.applied,
            KittyGraphicsLimits::disabled(),
            "a timed-out Kitty quota reservation must stay disabled while admitted"
        );
    }

    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    creator.join().unwrap();
    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    wait_for_kitty_image_budget(&mux);
    assert!(
        created.with_terminal(|terminal| terminal.kitty_image_count_limit().unwrap()).unwrap() > 0,
        "a degraded terminal was not promoted after the quota worker recovered"
    );
    close_terminal_runtime_for_test(&mux, &created);
    close_terminal_runtime_for_test(&mux, &first);
}

#[test]
fn kitty_quota_restoration_uses_linear_bucket_updates() {
    let mux = test_mux();
    let applications = Arc::new(AtomicUsize::new(0));
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let applications = applications.clone();
        move |surface, limits, _deadline| {
            applications.fetch_add(1, Ordering::AcqRel);
            surface.set_kitty_graphics_limits(
                limits.image_bytes,
                limits.inflight_bytes,
                limits.images,
                limits.placements,
            )
        }
    }));
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut surfaces = vec![first];
    for _ in 1..16 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }

    wait_for_kitty_image_budget(&mux);

    let applied = applications.load(Ordering::Acquire);
    assert!(
        applied <= surfaces.len() * 4,
        "restoring {} terminals applied {applied} Kitty quota updates",
        surfaces.len()
    );
}

#[test]
fn kitty_quota_expansion_delays_concurrent_terminal_until_reshrink() {
    let mux = test_mux();
    let survivor = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(survivor.id).unwrap());
    let mut surfaces = vec![survivor.clone()];
    for _ in 1..8 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);

    let expansion = kitty_image_limits_for_capacity(1);
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let (started_sender, started_receiver) = std::sync::mpsc::sync_channel(1);
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let gate = gate.clone();
        let survivor_id = survivor.id;
        move |surface, limits, _deadline| {
            if surface.id == survivor_id && limits == expansion {
                let _ = started_sender.try_send(());
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
    for surface in surfaces.iter().skip(1) {
        close_terminal_runtime_for_test(&mux, surface);
    }
    started_receiver.recv_timeout(Duration::from_secs(2)).unwrap();

    let (sender, receiver) = std::sync::mpsc::channel();
    let creating_mux = mux.clone();
    let creator = std::thread::spawn(move || {
        let _ = sender.send(creating_mux.new_tab(Some(pane), None, Some((80, 24))));
    });
    let returned_before_release = receiver.recv_timeout(Duration::from_millis(250)).ok();
    assert!(
        returned_before_release.is_none(),
        "terminal creation bypassed a stale expansion and consumed output without safe quota"
    );
    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    let concurrent = receiver.recv_timeout(Duration::from_secs(2)).unwrap().unwrap();
    creator.join().unwrap();
    wait_for_kitty_image_budget(&mux);
    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    let settled = kitty_image_limits_for_capacity(2).image_bytes;
    for surface in [&survivor, &concurrent] {
        assert_eq!(
            surface
                .with_terminal(|terminal| terminal.kitty_image_storage_limit().unwrap())
                .unwrap(),
            settled
        );
    }
}

#[test]
fn terminal_creation_never_exposes_a_disabled_kitty_quota() {
    let mux = test_mux();
    let survivor = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(survivor.id).unwrap());
    let mut surfaces = vec![survivor.clone()];
    for _ in 1..8 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);

    let expansion = kitty_image_limits_for_capacity(1);
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let (started_sender, started_receiver) = std::sync::mpsc::sync_channel(1);
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let gate = gate.clone();
        let survivor_id = survivor.id;
        move |surface, limits, _deadline| {
            if surface.id == survivor_id && limits == expansion {
                let _ = started_sender.try_send(());
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
    for surface in surfaces.iter().skip(1) {
        close_terminal_runtime_for_test(&mux, surface);
    }
    started_receiver.recv_timeout(Duration::from_secs(2)).unwrap();

    let (sender, receiver) = std::sync::mpsc::channel();
    let creating_mux = mux.clone();
    let creator = std::thread::spawn(move || {
        let _ = sender.send(creating_mux.new_tab(Some(pane), None, Some((80, 24))));
    });
    let created_before_rebalance = receiver.recv_timeout(Duration::from_millis(250)).ok();
    let startup_limit = created_before_rebalance.as_ref().map(|result| {
        result
            .as_ref()
            .unwrap()
            .with_terminal(|terminal| terminal.kitty_image_storage_limit().unwrap())
            .unwrap()
    });
    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    let concurrent = match created_before_rebalance {
        Some(result) => result.unwrap(),
        None => receiver.recv_timeout(Duration::from_secs(2)).unwrap().unwrap(),
    };
    creator.join().unwrap();
    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    wait_for_kitty_image_budget(&mux);

    let initial_limit = startup_limit.unwrap_or_else(|| {
        concurrent.with_terminal(|terminal| terminal.kitty_image_storage_limit().unwrap()).unwrap()
    });
    assert!(
        initial_limit > 0,
        "a newly launched terminal could consume startup output while Kitty graphics were disabled"
    );
}

#[test]
fn kitty_quota_exhaustion_disables_only_overflow_surfaces_and_promotes_them() {
    let mux = test_mux();
    let opts = mux.surface_options.lock().unwrap().clone();
    let owner_limit =
        usize::try_from(KITTY_IMAGE_PROCESS_BUDGET_COUNT / KITTY_OBJECT_OWNERS_PER_SURFACE)
            .unwrap();
    assert_eq!(owner_limit, 2_048);
    let mut surfaces = Vec::with_capacity(owner_limit + 1);
    for _ in 0..=owner_limit {
        surfaces.push(
            Surface::spawn_for_test(mux.next_id(), opts.clone(), Arc::downgrade(&mux)).unwrap(),
        );
    }
    wait_for_kitty_image_budget(&mux);

    let participating_limit =
        surfaces[0].with_terminal(|terminal| terminal.kitty_image_count_limit().unwrap()).unwrap();
    assert!(participating_limit > 0);
    assert_eq!(
        surfaces[owner_limit]
            .with_terminal(|terminal| terminal.kitty_image_count_limit().unwrap())
            .unwrap(),
        0,
        "quota exhaustion disabled terminals that already owned a graphics share"
    );

    mux.unregister_kitty_image_surface(&surfaces[0]).unwrap();
    wait_for_kitty_image_budget(&mux);
    assert_eq!(
        surfaces[owner_limit]
            .with_terminal(|terminal| terminal.kitty_image_count_limit().unwrap())
            .unwrap(),
        participating_limit,
        "an overflow terminal was not promoted when a graphics share became available"
    );
}

#[test]
fn kitty_quota_worker_retries_a_transient_update_failure() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    let attempts = Arc::new(AtomicUsize::new(0));
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let attempts = attempts.clone();
        move |surface, limits, _deadline| {
            if attempts.fetch_add(1, Ordering::AcqRel) == 0 {
                anyhow::bail!("injected transient Kitty quota failure");
            }
            surface.set_kitty_graphics_limits(
                limits.image_bytes,
                limits.inflight_bytes,
                limits.images,
                limits.placements,
            )
        }
    }));

    let events = mux.subscribe();
    close_terminal_runtime_for_test(&mux, &second);
    let deadline = Instant::now() + Duration::from_secs(1);
    while attempts.load(Ordering::Acquire) < 2 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }

    assert!(
        attempts.load(Ordering::Acquire) >= 2,
        "Kitty quota worker stopped after a transient failure"
    );
    assert!(
        !events.try_iter().any(|event| matches!(
            event,
            MuxEvent::GraphicsStatus(GraphicsStatus::KittyImageBudgetUpdateFailed { .. })
        )),
        "transient Kitty quota failures must stay out of the status bar"
    );
    wait_for_kitty_image_budget(&mux);
}

#[test]
fn kitty_quota_worker_disables_graphics_but_admits_terminals_after_persistent_failure() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    let attempts = Arc::new(AtomicUsize::new(0));
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let attempts = attempts.clone();
        move |_surface, _limits, _deadline| {
            attempts.fetch_add(1, Ordering::AcqRel);
            anyhow::bail!("injected persistent Kitty quota failure")
        }
    }));

    close_terminal_runtime_for_test(&mux, &second);
    let deadline = Instant::now() + Duration::from_secs(2);
    while mux.kitty_image_budget.lock().unwrap().worker_running && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }

    assert!(
        !mux.kitty_image_budget.lock().unwrap().worker_running,
        "Kitty quota worker retried a permanent failure forever"
    );
    assert!(attempts.load(Ordering::Acquire) <= 4, "Kitty quota worker exceeded its retry budget");

    let started = Instant::now();
    let replacement = mux
        .new_tab(Some(pane), None, Some((80, 24)))
        .expect("an optional Kitty quota failure blocked terminal creation");
    assert!(
        started.elapsed() < Duration::from_millis(250),
        "a blocked Kitty quota transition waited for the control timeout"
    );
    assert_eq!(
        replacement.with_terminal(|terminal| terminal.kitty_image_count_limit().unwrap()).unwrap(),
        0,
        "a terminal admitted during a blocked quota transition retained graphics quota"
    );
    let budget = mux.kitty_image_budget.lock().unwrap();
    assert!(
        !budget.entries.get(&replacement.id).unwrap().owns_quota,
        "a terminal admitted during a blocked quota transition became a quota owner"
    );
}

#[test]
fn kitty_quota_reconnect_clears_its_block_and_rebalances() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    let first_id = first.id;
    *mux.kitty_image_budget_operation.lock().unwrap() =
        Some(Arc::new(move |surface, limits, _deadline| {
            if surface.id == first_id {
                anyhow::bail!("injected disconnected Kitty quota surface");
            }
            surface.set_kitty_graphics_limits(
                limits.image_bytes,
                limits.inflight_bytes,
                limits.images,
                limits.placements,
            )
        }));

    close_terminal_runtime_for_test(&mux, &second);
    let deadline = Instant::now() + Duration::from_secs(2);
    while mux.kitty_image_budget.lock().unwrap().worker_running && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(mux.kitty_image_budget.lock().unwrap().blocked_surfaces.contains(&first.id));

    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    let authoritative =
        first.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap();
    assert!(mux.reconcile_reconnected_kitty_image_surface(&first, authoritative));
    wait_for_kitty_image_budget(&mux);

    let replacement = mux
        .new_tab(Some(pane), None, Some((80, 24)))
        .expect("a reconciled reconnect must admit later terminals");
    wait_for_kitty_image_budget(&mux);
    close_terminal_runtime_for_test(&mux, &replacement);
}

#[test]
fn kitty_quota_worker_stops_waiting_for_an_operation_that_ignores_its_deadline() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let (started_sender, started_receiver) = std::sync::mpsc::sync_channel(1);
    let (finished_sender, finished_receiver) = std::sync::mpsc::sync_channel(1);
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let gate = gate.clone();
        move |_surface, _limits, _deadline| {
            let _ = started_sender.try_send(());
            let (released, changed) = &*gate;
            let mut released = released.lock().unwrap();
            while !*released {
                released = changed.wait(released).unwrap();
            }
            let _ = finished_sender.try_send(());
            anyhow::bail!("released persistent Kitty quota operation")
        }
    }));

    close_terminal_runtime_for_test(&mux, &second);
    started_receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    while mux.kitty_image_budget.lock().unwrap().worker_running && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let stopped = !mux.kitty_image_budget.lock().unwrap().worker_running;
    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    finished_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

    assert!(stopped, "Kitty quota worker waited forever for an operation past its deadline");
}

#[test]
fn kitty_quota_worker_exhausts_deadline_pool_admission_rejections() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);

    {
        let mut state = mux
            .deadline_fanout_pool
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        assert_eq!(state.admitted_jobs, 0);
        state.admitted_jobs = CELL_PIXEL_FANOUT_MAX_WORKERS;
    }

    close_terminal_runtime_for_test(&mux, &second);
    let deadline = Instant::now() + Duration::from_secs(2);
    while mux.kitty_image_budget.lock().unwrap().worker_running && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let (stopped, survivor_blocked, closed_retired) = {
        let budget = mux.kitty_image_budget.lock().unwrap();
        (
            !budget.worker_running,
            budget.blocked_surfaces.contains(&first.id),
            !budget.entries.contains_key(&second.id),
        )
    };

    {
        let mut state = mux
            .deadline_fanout_pool
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.admitted_jobs = 0;
        mux.deadline_fanout_pool.inner.changed.notify_all();
    }
    let cleanup_deadline = Instant::now() + Duration::from_secs(1);
    while mux.kitty_image_budget.lock().unwrap().worker_running && Instant::now() < cleanup_deadline
    {
        std::thread::sleep(Duration::from_millis(5));
    }

    assert!(stopped, "Kitty quota worker retried pool admission forever");
    assert!(survivor_blocked, "pool admission exhaustion did not fail closed for the live surface");
    assert!(closed_retired, "a closed surface remained in the Kitty quota registry");
}
