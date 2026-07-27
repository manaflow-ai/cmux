//! Process creation coordination shared by every cmux-tui runtime crate.

use std::io;
use std::process::{Child, Command};

#[cfg(target_os = "macos")]
static PROCESS_CREATION_BARRIER: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Holds the process-wide child-creation barrier.
///
/// macOS cannot create Unix sockets with close-on-exec set atomically. Socket
/// setup holds this guard until `FD_CLOEXEC` is set, while every child launch
/// holds the same guard until the child exists. Library-backed process launch
/// paths, such as PTY creation, must acquire this guard around their spawn
/// call.
#[must_use = "dropping the guard releases process creation"]
pub struct ProcessCreationGuard {
    #[cfg(target_os = "macos")]
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl ProcessCreationGuard {
    pub fn acquire() -> Self {
        #[cfg(target_os = "macos")]
        {
            let guard =
                PROCESS_CREATION_BARRIER.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            Self { _guard: guard }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self {}
        }
    }
}

/// Spawn a child while excluding non-atomic close-on-exec descriptor setup.
pub fn spawn(command: &mut Command) -> io::Result<Child> {
    let _guard = ProcessCreationGuard::acquire();
    command.spawn()
}
