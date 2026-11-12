//! A hosted reader whose frame demultiplexer does not start.

use super::hosted::wait_until;
use super::*;

/// The demultiplexer's socket clone or thread spawn failed, so nobody reads
/// the host connection. It used to stay `Connected` with its attachment in
/// place: a receipted write waited out `CONTROL_RESPONSE_TIMEOUT` and output
/// stopped for good. It must end as a lost connection does: the link leaves
/// `Connected`, the host sees the daemon leave, and a write fails at once.
#[test]
fn a_frame_demultiplexer_that_does_not_start_ends_the_connection() {
    let mux = Mux::new_for_test("hosted-frames-spawn-failure", SurfaceOptions::default());
    mux.fail_host_frames_spawns_for_test(1);
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
    let surface = Surface::spawn_hosted(
        1,
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

    wait_until("the link leaves Connected after the demultiplexer failed to start", || {
        surface.terminal_host_connection_state() != Some(TerminalHostConnectionState::Connected)
    });
    host.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    loop {
        match crate::terminal_host_protocol::read_frame(
            &mut host,
            crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
        ) {
            Ok(Some(_)) => {}
            Ok(None) => break,
            Err(error) => panic!("the host connection nobody reads stayed open: {error}"),
        }
    }
    let started = Instant::now();
    surface
        .write_bytes_confirmed(b"after")
        .expect_err("a receipted write to a connection nobody reads answered ok");
    let took = started.elapsed();
    assert!(
        took < crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT,
        "a receipted write to a connection nobody reads waited {took:?} for its receipt"
    );
}
