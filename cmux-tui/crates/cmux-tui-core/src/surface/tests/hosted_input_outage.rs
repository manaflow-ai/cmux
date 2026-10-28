//! Hosted input across a lost host connection: inputs queued
//! in a terminal's input FIFO while its host connection is lost wait out
//! one reconnect window together, not one window each in turn.

use super::*;
use crate::surface::input::{HOST_INPUT_RECONNECT_WAIT, host_connection_lost};
use std::os::unix::net::UnixStream;

const WRITERS: usize = 4;

#[test]
fn hosted_input_queued_during_a_lost_connection_fails_within_one_reconnect_wait() {
    let mux = Mux::new_for_test("hosted-input-outage", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, _host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    // The input side of the host connection is lost: every input frame
    // fails with EPIPE. The reader's side stays open, so the terminal stays
    // `connected` and no reconnect ends the wait.
    let (lost, peer) = UnixStream::pair().unwrap();
    drop(peer);
    *attachment.writer.lock().unwrap() = lost;
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

    let started = Instant::now();
    let results = std::thread::scope(|scope| {
        // Whichever input takes the first turn waits for a reconnect; the
        // others queue behind it from their own threads.
        let writers: Vec<_> = (0..WRITERS)
            .map(|_| scope.spawn(|| (surface.write_bytes(b"k"), started.elapsed())))
            .collect();
        writers.into_iter().map(|writer| writer.join().unwrap()).collect::<Vec<_>>()
    });

    assert_eq!(
        surface.terminal_host_connection_state(),
        Some(TerminalHostConnectionState::Connected),
        "the reader saw no loss, so only the input deadline ended the waits"
    );
    for (result, elapsed) in results {
        let error = result.expect_err("input to a lost host connection must fail");
        assert!(host_connection_lost(&error), "unexpected input error: {error}");
        assert!(
            elapsed >= HOST_INPUT_RECONNECT_WAIT - Duration::from_millis(100),
            "input failed after {elapsed:?}, before its reconnect wait"
        );
        assert!(
            elapsed < HOST_INPUT_RECONNECT_WAIT + HOST_INPUT_RECONNECT_WAIT / 2,
            "queued input failed after {elapsed:?}: it waited out the earlier inputs' \
             reconnect windows one after another"
        );
    }
}
