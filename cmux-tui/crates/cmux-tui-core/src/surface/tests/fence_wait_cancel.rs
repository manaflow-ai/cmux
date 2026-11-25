//! A terminal's reader waits for the PTY fence of its dead host before it starts the replacement host (decision of
//! 2026-11-16). Only a close of the terminal or a shutdown of its owner cancels that wait. These tests prove the
//! cancel for a close and for a daemon shutdown's detach; the wait and its cancel have their own test beside the
//! fence (`terminal_host_runtime/unix/pty_lock.rs`).

use super::hosted::hosted_typing_surface;
use super::*;

#[test]
fn a_closed_terminal_cancels_the_wait_for_its_dead_hosts_pty_fence() {
    let mux = Mux::new_for_test("fence-wait-close", SurfaceOptions::default());
    let surface = Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux))
        .expect("test PTY should spawn");
    let pty = surface.as_pty().expect("a terminal");
    assert!(
        !pty.host_fence_wait.cancelled_for_test(),
        "a new terminal started with a cancelled wait"
    );
    surface.kill();
    assert!(pty.host_fence_wait.cancelled_for_test(), "the close left the fence wait live");
}

#[test]
fn a_daemon_shutdown_detach_cancels_the_wait_for_a_dead_hosts_pty_fence() {
    let (_mux, surface, _host) = hosted_typing_surface("fence-wait-shutdown-detach", true);
    let pty = surface.as_pty().expect("a terminal");
    assert!(
        !pty.host_fence_wait.cancelled_for_test(),
        "a new terminal started with a cancelled wait"
    );
    surface.disconnect_for_daemon_shutdown();
    assert!(pty.host_fence_wait.cancelled_for_test(), "the detach left the fence wait live");
}
