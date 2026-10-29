//! The process Kitty share (memoryKittyShare) through the
//! real `attach-surface` and `release-surface-size` commands: a sized attach
//! shows the terminal with its limits applied before the attach answers,
//! another show never moves the limits of a terminal already on screen, and
//! a released size hides a terminal that stays attached.

use super::*;
use crate::memory::{DaemonMemory, MemorySetup};
use crate::mux::KittyShare;

const MIB: u64 = 1024 * 1024;

fn kitty_share_mux() -> Arc<Mux> {
    let mux = Mux::new_for_test_with_memory(
        "kitty-share-attach",
        SurfaceOptions::default(),
        MemorySetup {
            memory: Arc::new(DaemonMemory::without_system_source()),
            scrollback_pressure: false,
            kitty_share: true,
        },
    );
    mux.set_kitty_share_for_test(KittyShare::by_recency(128 * MIB));
    mux
}

fn limits_of(surface: &crate::Surface) -> ghostty_vt::KittyGraphicsLimits {
    surface.with_terminal(|terminal| terminal.kitty_graphics_limits().unwrap()).unwrap()
}

fn settle(mux: &Mux) {
    assert!(
        mux.wait_for_kitty_image_budget_idle_for_test(Duration::from_secs(30)),
        "Kitty image budget worker did not converge"
    );
}

fn sized_attach(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, surface: SurfaceId) {
    let params = serde_json::from_value::<terminal_io_wire::AttachSurfaceParams>(json!({
        "surface": surface,
        "cols": 80,
        "rows": 24,
        "expected_generation": null,
        "expected_terminal_id": null,
    }))
    .unwrap();
    handle_command(mux, client, Command::AttachSurface(params), writer).unwrap();
}

#[test]
fn kitty_share_attach_keeps_every_shown_terminal_at_its_share() {
    let mux = kitty_share_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut surfaces = vec![first];
    for _ in 1..6 {
        surfaces.push(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    }
    settle(&mux);
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    // Two terminals on screen.
    for surface in &surfaces[..2] {
        sized_attach(&mux, client, &writer, surface.id);
    }
    settle(&mux);
    let equal = mux.kitty_equal_share_for_test();
    let on_screen = surfaces[..2].iter().map(|surface| limits_of(surface)).collect::<Vec<_>>();
    for limits in &on_screen {
        assert!(limits.image_bytes >= equal.image_bytes, "{limits:?} under {equal:?}");
    }

    // A third shows through the real attach: its limits are in place when
    // the attach answers, so its replay already carries them.
    let third = &surfaces[4];
    sized_attach(&mux, client, &writer, third.id);
    let third_limits = limits_of(third);
    assert!(
        third_limits.image_bytes >= equal.image_bytes,
        "the attached terminal got {third_limits:?} under {equal:?}"
    );
    settle(&mux);
    assert_eq!(
        limits_of(third),
        third_limits,
        "the attached terminal's limits moved after its replay"
    );
    for (surface, before) in surfaces[..2].iter().zip(&on_screen) {
        assert_eq!(
            &limits_of(surface),
            before,
            "a terminal on screen changed limits on another show"
        );
    }
    for surface in [&surfaces[0], &surfaces[1], third] {
        assert!(mux.kitty_share_view_for_test(surface.id).unwrap().0);
    }

    // Released to the background, still attached: no longer viewed.
    handle_command(&mux, client, Command::ReleaseSurfaceSize { surface: surfaces[0].id }, &writer)
        .unwrap();
    settle(&mux);
    let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    assert!(listed[0]["attached"].as_array().unwrap().contains(&json!(surfaces[0].id)));
    assert!(
        !mux.kitty_share_view_for_test(surfaces[0].id).unwrap().0,
        "a released size stayed viewed"
    );
    assert!(mux.kitty_applied_reservation_for_test() <= 128 * MIB);
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
