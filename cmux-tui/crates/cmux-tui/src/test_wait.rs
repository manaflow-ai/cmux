//! Bounded waits for tests that block on an event the code under test sends.

use std::time::Duration;

/// How long a test waits for one awaited app event before it fails. The
/// wait is event-driven, so a passing run never sleeps; the bound only has
/// to exceed a loaded full-suite runner, where 1 s timed out
/// (viewport_pane_overflows_the_existing_tiled_layout on a Linux Testbox).
pub(crate) const EVENT: Duration = Duration::from_secs(10);

/// Surface options whose child writes nothing until it reads a line. A live
/// shell prints while a test inspects the terminal; the busy terminal lock
/// makes `try_pointer_semantics` report contention and the app then falls
/// back to the last applied capture, so tests that read terminal state
/// without a frame must not race a shell
/// (desired_host_mouse_capture_follows_scoped_inner_terminal, 1 of 3 full runs).
pub(crate) fn quiet_surface() -> cmux_tui_core::SurfaceOptions {
    cmux_tui_core::SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "IFS= read -r line".into()]),
        ..Default::default()
    }
}
