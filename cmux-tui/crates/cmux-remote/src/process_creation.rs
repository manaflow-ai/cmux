//! Process creation coordinated with non-atomic descriptor setup on macOS.

use std::io;

/// Starts a Tokio child while holding cmux-tui's process-wide creation guard.
pub(crate) fn spawn(command: &mut tokio::process::Command) -> io::Result<tokio::process::Child> {
    let _process_creation = cmux_tui_process::ProcessCreationGuard::acquire();
    command.spawn()
}
