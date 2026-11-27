//! Callbacks of a hosted terminal's daemon-side mirror.

use super::*;

/// The callbacks of the daemon's mirror of a terminal-host terminal.
/// `program_status` receives the mirror's OSC 7501 records: the daemon is
/// their owner, while only the host's own parser answers the support query.
pub(super) fn hosted_terminal_callbacks(
    bells: &PendingBells,
    title_changed: Arc<AtomicBool>,
    program_status: crate::program_status::SharedProgramStatus,
) -> Callbacks {
    Callbacks {
        // The terminal-host parser is authoritative and already writes query
        // responses (DA/DSR, Kitty graphics, OSC colors, ...) to the PTY. A
        // hosted Surface is only a mirror: answering here would inject one
        // duplicate reply per server/frontend mirror into the child input.
        on_pty_write: None,
        on_title_changed: Some(Box::new(move || {
            title_changed.store(true, Ordering::Relaxed);
        })),
        // Counted only: the reader emits after it releases the terminal lock.
        on_bell: Some(bells.callback()),
        on_clipboard_read: None,
        on_program_status: Some(crate::program_status::sink(program_status)),
    }
}
