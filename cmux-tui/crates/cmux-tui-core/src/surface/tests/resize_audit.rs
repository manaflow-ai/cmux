//! Resize audit (2026-10-19): an A-B-A resize of a hosted terminal must end
//! at A. The mux compares the engine target with `surface.size()`, which for
//! a hosted terminal is the daemon mirror. The mirror changes only when the
//! host publishes `Resized`, so a reversion inside that round trip is taken
//! for "already applied" and the host keeps the intermediate size B.

use super::*;
use crate::terminal_host_protocol::{MAX_FRAME_PAYLOAD, read_frame};
use std::os::unix::net::UnixStream;

fn viewer_sizes_sent(host: &mut UnixStream) -> Vec<(u16, u16)> {
    let mut sizes = Vec::new();
    while let Ok(Some(frame)) = read_frame(host, MAX_FRAME_PAYLOAD) {
        if frame.kind == MessageKind::ViewerSize && frame.payload.len() == 4 {
            let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
            let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]);
            sizes.push((cols, rows));
        }
    }
    sizes
}

#[test]
fn resize_audit_hosted_aba_reversion_reaches_the_host() {
    let mux = Mux::new_for_test("hosted-resize-aba", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
    let surface = Surface::spawn_hosted(
        4242,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        HostedSurfaceLaunch {
            adopted: false,
            attachment,
            kitty_reservation: None,
            terminate_on_error: false,
            defer_launch_activation: false,
            lifetime: PtyLifetime::SessionOwned,
            terminal_public_id: None,
            resource_identity: None,
        },
    )
    .unwrap();
    mux.insert_surface_runtime_for_test(surface.clone());
    host.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
    assert_eq!(surface.size(), (80, 24));

    // A drag grows the pane and returns it before the host answers.
    mux.resize_surface_for_client(surface.id, 0, 100, 30).unwrap();
    mux.resize_surface_for_client(surface.id, 0, 80, 24).unwrap();

    let sent = viewer_sizes_sent(&mut host);
    assert_eq!(
        sent.last(),
        Some(&(80, 24)),
        "the host was left at the intermediate size; viewer sizes sent: {sent:?}"
    );
}
