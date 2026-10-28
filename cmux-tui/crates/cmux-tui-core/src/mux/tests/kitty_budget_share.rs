//! The process Kitty share by viewers and recency: fifty
//! terminals stay under the total, the most recently shown keep their
//! images, and a viewed terminal's placements still render after critical
//! memory pressure clears the pixel maps.

use super::*;
use crate::memory::{DaemonMemory, MemorySetup};
use cmux_memory::PressureLevel;

const MIB: u64 = 1024 * 1024;
const TERMINALS: usize = 50;

fn owner(id: SurfaceId, viewed: bool, shown_at: u64) -> KittyShareOwner {
    KittyShareOwner { id, viewed, shown_at, grant: 0 }
}

fn reserved(limits: KittyGraphicsLimits) -> u64 {
    kitty_surface_byte_reservation(limits.image_bytes)
}

/// Each owner's limits for `total` over `capacity` slots.
fn shares(
    total: u64,
    capacity: usize,
    owners: &[KittyShareOwner],
) -> HashMap<SurfaceId, KittyGraphicsLimits> {
    let counts = kitty_image_limits_for_capacity_in(total, capacity);
    kitty_recency_shares(total, capacity, owners)
        .into_iter()
        .map(|(id, bytes)| (id, kitty_share_limits(bytes, counts)))
        .collect()
}

fn kitty_share_limits(bytes: u64, counts: KittyGraphicsLimits) -> KittyGraphicsLimits {
    kitty_share::kitty_image_limits_for_share(bytes, counts)
}

#[test]
fn kitty_budget_share_off_keeps_the_fixed_equal_total() {
    assert_eq!(KittyShare::default(), KittyShare::for_feature(false));
    assert_eq!(KittyShare::default().total_bytes, 128 * MIB);
    assert!(!KittyShare::default().by_recency);
    let on = KittyShare::for_feature(true);
    assert!(on.by_recency);
    assert_eq!(on.total_bytes, cmux_memory::DaemonBudget::for_host().kitty_total);
}

/// Fifty terminals that each could hold 10 MB of images stay under every
/// RAM row's total; the most recently shown hidden terminal gets the most,
/// and the order follows recency.
#[test]
fn kitty_budget_share_keeps_fifty_terminals_under_the_total_by_recency() {
    let full = kitty_surface_byte_reservation(ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
    assert!(full.saturating_mul(TERMINALS as u64) > 512 * MIB, "the cap would not bind");
    for total in [64 * MIB, 128 * MIB, 256 * MIB, 512 * MIB] {
        let owners = (0..TERMINALS)
            .map(|index| owner(index as SurfaceId + 1, false, index as u64 + 1))
            .collect::<Vec<_>>();
        let capacity = kitty_image_budget_capacity(TERMINALS, 0);
        let limits = shares(total, capacity, &owners);
        let sum = limits.values().copied().map(reserved).sum::<u64>();
        assert!(sum <= total, "{sum} reserved over the {total} total");
        let newest = limits[&(TERMINALS as SurfaceId)];
        let oldest = limits[&1];
        assert!(
            newest.image_bytes > kitty_image_limits_for_capacity_in(total, capacity).image_bytes
        );
        assert!(oldest.image_bytes > 0, "the least recently shown keeps a floor");
        for index in 1..TERMINALS as SurfaceId {
            assert!(
                limits[&(index + 1)].image_bytes >= limits[&index].image_bytes,
                "terminal {} shown after {index} got less at {total}",
                index + 1
            );
        }
    }
}

/// Viewed terminals split what hidden ones do not keep equally, never below
/// the equal share they had before the share by recency, whatever their
/// order of showing.
#[test]
fn kitty_budget_share_never_lowers_a_viewed_terminal_below_an_equal_share() {
    let total = 128 * MIB;
    let capacity = kitty_image_budget_capacity(TERMINALS, 0);
    let equal = kitty_image_limits_for_capacity_in(total, capacity);
    let owners = (0..TERMINALS)
        .map(|index| owner(index as SurfaceId + 1, index < 4, (TERMINALS - index) as u64))
        .collect::<Vec<_>>();
    let limits = shares(total, capacity, &owners);
    assert!(limits.values().copied().map(reserved).sum::<u64>() <= total);
    let viewed = (1..=4).map(|id| limits[&id]).collect::<Vec<_>>();
    assert!(viewed.iter().all(|limits| limits.image_bytes > equal.image_bytes), "{viewed:?}");
    let least_viewed = viewed.iter().map(|limits| limits.image_bytes).min().unwrap();
    for hidden in 5..=TERMINALS as SurfaceId {
        assert!(limits[&hidden].image_bytes < least_viewed);
        assert_eq!(limits[&hidden].images, equal.images);
        assert_eq!(limits[&hidden].placements, equal.placements);
    }

    // A lone owner keeps the per-terminal maximum.
    let alone = shares(total, 1, &[owner(1, false, 1)]);
    assert_eq!(alone[&1].image_bytes, ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
}

/// A viewed terminal keeps the share it was granted when another terminal
/// becomes viewed: its limits (and its mirrors) do not move on another
/// show. The new one takes what hidden terminals held above their floors.
#[test]
fn kitty_budget_share_keeps_a_viewed_terminals_grant_on_another_show() {
    let total = 128 * MIB;
    let capacity = kitty_image_budget_capacity(8, 0);
    let mut owners = (0..8)
        .map(|index| owner(index as SurfaceId + 1, index < 2, index as u64 + 1))
        .collect::<Vec<_>>();
    let first =
        kitty_recency_shares(total, capacity, &owners).into_iter().collect::<HashMap<_, _>>();
    owners[0].grant = first[&1];
    owners[1].grant = first[&2];
    // Terminal 8 becomes viewed, shown last.
    owners[7].viewed = true;
    owners[7].shown_at = 100;
    let second =
        kitty_recency_shares(total, capacity, &owners).into_iter().collect::<HashMap<_, _>>();
    assert_eq!(second[&1], first[&1], "a viewed terminal's share moved on another show");
    assert_eq!(second[&2], first[&2], "a viewed terminal's share moved on another show");
    let equal = total / capacity as u64;
    assert!(second[&8] >= equal, "the new viewed terminal got {} under {equal}", second[&8]);
    assert!(second.values().sum::<u64>() <= total);
}

/// An attach is not a show: a terminal that stays attached but whose size
/// lease is released stops counting as viewed, and claiming the lease again
/// makes it the most recently shown.
#[test]
fn kitty_budget_share_follows_size_leases_not_attaches() {
    let (mux, _memory) = kitty_share_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let third = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);
    let client = 7;
    // A script waits on the first terminal: an attach without a size.
    let _script = first.attach_stream().unwrap();
    wait_for_kitty_image_budget(&mux);
    assert!(!mux.kitty_share_view_for_test(first.id).unwrap().0, "a bare attach counted");

    mux.resize_surface_for_client(first.id, client, 80, 24).unwrap();
    wait_for_kitty_image_budget(&mux);
    let (viewed, shown_first) = mux.kitty_share_view_for_test(first.id).unwrap();
    assert!(viewed, "a size lease did not show the terminal");
    assert!(shown_first > mux.kitty_share_view_for_test(third.id).unwrap().1);
    let viewed_limits = limits_of(&first);
    assert!(viewed_limits.image_bytes >= mux.kitty_equal_share_for_test().image_bytes);

    // The tab goes to the background: its lease ends, its attach stays. It
    // is the most recently shown hidden terminal now.
    mux.remove_surface_size_client(first.id, client);
    wait_for_kitty_image_budget(&mux);
    let (viewed, hidden_at) = mux.kitty_share_view_for_test(first.id).unwrap();
    assert!(!viewed, "a released lease stayed viewed");
    assert!(hidden_at > shown_first);

    mux.resize_surface_for_client(second.id, client, 80, 24).unwrap();
    mux.remove_surface_size_client(second.id, client);
    mux.resize_surface_for_client(first.id, client, 80, 24).unwrap();
    wait_for_kitty_image_budget(&mux);
    let (viewed, shown_again) = mux.kitty_share_view_for_test(first.id).unwrap();
    assert!(viewed);
    for other in [&second, &third] {
        assert!(
            shown_again > mux.kitty_share_view_for_test(other.id).unwrap().1,
            "a terminal shown again is not the most recently shown"
        );
    }
    assert!(limits_of(&first).image_bytes >= mux.kitty_equal_share_for_test().image_bytes);
}

/// A shrink that passed its deadline still holds its larger limits: no other
/// terminal grows until it took effect, so the applied limits never add up
/// to more than the total.
#[test]
fn kitty_budget_share_grows_nothing_while_a_shrink_is_pending() {
    let (mux, _memory) = kitty_share_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let client = 7;
    mux.resize_surface_for_client(first.id, client, 80, 24).unwrap();
    wait_for_kitty_image_budget(&mux);
    let total = 128 * MIB;
    assert!(mux.kitty_applied_reservation_for_test() <= total);
    let viewed_bytes = limits_of(&first).image_bytes;

    // The first terminal's next shrink stalls past its deadline.
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let (started_sender, started) = std::sync::mpsc::sync_channel(1);
    *mux.kitty_image_budget_operation.lock().unwrap() = Some(Arc::new({
        let gate = gate.clone();
        let first_id = first.id;
        move |surface, limits, _deadline| {
            if surface.id == first_id && limits.image_bytes < viewed_bytes {
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

    // The person switches to the second terminal: the first shrinks, the
    // second grows.
    mux.remove_surface_size_client(first.id, client);
    mux.resize_surface_for_client(second.id, client, 80, 24).unwrap();
    started
        .recv_timeout(Duration::from_secs(5))
        .expect("the first terminal's shrink did not start");
    // The shrink passes its deadline and the worker retries until it gives
    // up on that terminal; through every wave the applied limits stay under
    // the total.
    let give_up = Instant::now() + Duration::from_secs(15);
    {
        let mut budget = mux.kitty_image_budget.lock().unwrap();
        loop {
            let applied = budget
                .entries
                .values()
                .map(|entry| kitty_surface_byte_reservation(entry.applied.image_bytes))
                .sum::<u64>();
            assert!(applied <= total, "applied limits reserve {applied} over {total}");
            let remaining = give_up.saturating_duration_since(Instant::now());
            if !budget.worker_running || remaining.is_zero() {
                break;
            }
            budget = cmux_threads::checked::sync::wait_timeout(
                &mux.kitty_image_budget_changed,
                budget,
                remaining,
            )
            .unwrap()
            .0;
        }
        assert!(!budget.worker_running, "the worker did not give up on the stalled shrink");
    }
    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    // The stalled terminal is blocked until its host reconnects
    // (kitty_quota_worker_stops_waiting_for_an_operation_that_ignores_its_deadline).
    *mux.kitty_image_budget_operation.lock().unwrap() = None;
    assert!(mux.kitty_applied_reservation_for_test() <= total);
}

fn kitty_share_mux() -> (Arc<Mux>, Arc<DaemonMemory>) {
    let memory = Arc::new(DaemonMemory::without_system_source());
    let mux = Mux::new_for_test_with_memory(
        "kitty-share",
        SurfaceOptions::default(),
        MemorySetup { memory: memory.clone(), scrollback_pressure: false, kitty_share: true },
    );
    // The 16 GB row, whatever this machine has.
    mux.set_kitty_share_for_test(KittyShare::by_recency(128 * MIB));
    (mux, memory)
}

fn limits_of(surface: &Surface) -> KittyGraphicsLimits {
    surface.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap()
}

/// An RGB image of `bytes` decoded bytes, transmitted and placed at the cursor.
fn write_image(surface: &Surface, id: u32, bytes: usize) {
    use base64::Engine as _;
    let width = 256;
    let height = bytes / (width * 3);
    let pixels = vec![0x7f; width * height * 3];
    let payload = base64::engine::general_purpose::STANDARD.encode(&pixels);
    let command =
        format!("\x1b_Ga=T,t=d,f=24,i={id},s={width},v={height},c=4,r=2,q=2;{payload}\x1b\\");
    surface.write_rendered_output_for_test(command.as_bytes());
}

fn image_len(surface: &Surface, id: u32) -> Option<usize> {
    surface
        .with_terminal(|terminal| {
            terminal.kitty_graphics_snapshot().unwrap().image(id).map(|image| image.data.len())
        })
        .unwrap()
}

/// The real wiring: fifty terminals under the total, the most recently
/// shown one keeps its image, a size report makes a terminal viewed, and
/// critical pressure clears the pixel maps while the viewed terminal's
/// placement still renders.
#[test]
fn kitty_budget_share_keeps_recent_images_and_renders_visible_placements() {
    let (mux, memory) = kitty_share_mux();
    let names = memory.registry().report().into_iter().map(|line| line.name).collect::<Vec<_>>();
    assert!(names.iter().any(|name| name == kitty_share::PIXEL_CONSUMER_NAME));

    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut surfaces = vec![first];
    for _ in 1..TERMINALS {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    wait_for_kitty_image_budget(&mux);
    let total = 128 * MIB;
    let sum = surfaces.iter().map(|surface| reserved(limits_of(surface))).sum::<u64>();
    assert!(sum <= total, "{TERMINALS} terminals reserve {sum} over {total}");

    // The terminal created last was shown last: it has the most room.
    let newest = surfaces.last().unwrap().clone();
    let newest_limits = limits_of(&newest);
    assert!(
        surfaces.iter().all(|surface| limits_of(surface).image_bytes <= newest_limits.image_bytes)
    );
    write_image(&newest, 71, 512 * 1024);
    let newest_image = image_len(&newest, 71).expect("the most recent terminal keeps its image");

    // A client shows (its size lease) and renders an older terminal: it is
    // viewed now and takes most of the total; the most recently shown
    // hidden one keeps its image.
    let shown = surfaces[3].clone();
    let stream = shown.attach_render_stream().unwrap();
    mux.resize_surface_for_client(shown.id, 7, 80, 24).unwrap();
    wait_for_kitty_image_budget(&mux);
    let shown_limits = limits_of(&shown);
    assert!(shown_limits.image_bytes >= mux.kitty_equal_share_for_test().image_bytes);
    assert!(shown_limits.image_bytes > limits_of(&newest).image_bytes);
    assert_eq!(image_len(&newest, 71), Some(newest_image));
    let sum = surfaces.iter().map(|surface| reserved(limits_of(surface))).sum::<u64>();
    assert!(sum <= total, "after the show {sum} over {total}");
    let oldest_hidden = limits_of(&surfaces[0]);
    assert!(oldest_hidden.image_bytes < limits_of(&newest).image_bytes);

    write_image(&shown, 72, 2 * 1024 * 1024);
    let shown_image = image_len(&shown, 72).expect("the viewed terminal stores its image");
    let before = shown.render_frame().unwrap();
    assert_eq!(
        before.frame.kitty_graphics.image(72).map(|image| image.data.len()),
        Some(shown_image)
    );

    // Critical pressure clears both pixel maps of every terminal; nothing
    // libghostty stores is lost, and the viewed placement renders again.
    assert_eq!(newest.render_frame().unwrap().frame.kitty_graphics.images.len(), 1);
    assert!(newest.kitty_render_pixel_bytes_for_test() > 0);
    let voter = memory.registry().voter();
    voter.set_level(PressureLevel::Critical);
    wait_for_kitty_image_budget(&mux);
    assert!(!mux.kitty_image_budget.lock().unwrap().pixel_release_due);
    newest
        .try_with_hot_terminal(|terminal| assert_eq!(terminal.kitty_replay_pixel_cache_bytes(), 0))
        .unwrap();
    assert_eq!(newest.kitty_render_pixel_bytes_for_test(), 0, "a hidden renderer keeps pixels");
    assert_eq!(image_len(&newest, 71), Some(newest_image));
    assert_eq!(image_len(&shown, 72), Some(shown_image));
    let rebuilt = newest.render_frame().unwrap();
    assert_eq!(
        rebuilt.frame.kitty_graphics.image(71).map(|image| image.data.len()),
        Some(newest_image)
    );
    let after = shown.render_frame().unwrap();
    assert_eq!(
        after.frame.kitty_graphics.image(72).map(|image| image.data.len()),
        Some(shown_image)
    );
    assert_eq!(after.frame.kitty_graphics.placements, before.frame.kitty_graphics.placements);
    drop(stream);
    drop(voter);
}
