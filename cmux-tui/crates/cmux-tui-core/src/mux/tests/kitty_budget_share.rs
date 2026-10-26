//! The process Kitty share by viewers and recency (p07-memory-073): fifty
//! terminals stay under the total, the most recently shown keep their
//! images, and a viewed terminal's placements still render after critical
//! memory pressure clears the pixel maps.

use super::*;
use crate::memory::{DaemonMemory, MemorySetup};
use cmux_memory::PressureLevel;

const MIB: u64 = 1024 * 1024;
const TERMINALS: usize = 50;

fn owner(id: SurfaceId, viewed: bool, shown_at: u64) -> KittyShareOwner {
    KittyShareOwner { id, viewed, shown_at }
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
    assert!(viewed.iter().all(|limits| *limits == viewed[0]), "{viewed:?}");
    assert!(viewed[0].image_bytes > equal.image_bytes);
    for hidden in 5..=TERMINALS as SurfaceId {
        assert!(limits[&hidden].image_bytes < viewed[0].image_bytes);
        assert_eq!(limits[&hidden].images, equal.images);
        assert_eq!(limits[&hidden].placements, equal.placements);
    }

    // A lone owner keeps the per-terminal maximum.
    let alone = shares(total, 1, &[owner(1, false, 1)]);
    assert_eq!(alone[&1].image_bytes, ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
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
/// shown one keeps its image, a render attach makes a terminal viewed, and
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

    // A client renders an older terminal: it is viewed now and takes most
    // of the total; the most recently shown hidden one keeps its image.
    let shown = surfaces[3].clone();
    let stream = shown.attach_render_stream().unwrap();
    wait_for_kitty_image_budget(&mux);
    let shown_limits = limits_of(&shown);
    assert_eq!(shown_limits.image_bytes, ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
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
