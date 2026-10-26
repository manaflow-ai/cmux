//! Terminals held by the install's one holder process instead of a host
//! process each (terminal-host-model-DESIGN.md, option D).
//!
//! The holder (`cmux-tui __holder`, crate `cmux-holder`) starts each shell on
//! a PTY, keeps the master in one poll set and a byte ring per terminal, and
//! parses nothing. The daemon keeps a custody dup of every master, writes
//! input and resizes on it directly, and parses the output the holder
//! streams over one link: the terminal runs on the daemon's local runtime
//! (`PtyRuntime::Local`), so the daemon's parser is the only one outside the
//! app. A daemon restart re-attaches from the holder's rings
//! (`mux::holder_adoption`); a holder crash loses no shell, because the
//! daemon still holds every master and hands them to a new holder.
//!
//! Off unless `CMUX_TUI_TERMINAL_HOST_MODEL=holder` (slice 2: behind a flag,
//! the per-terminal hosts stay the default).

mod service;
mod sink;
mod terminal;

#[cfg(not(test))]
pub(crate) use service::prepare_in_background;
pub(crate) use service::{HOLDER_LINK_HANG, holder_frame_name};
pub(crate) use service::{HolderService, HolderTrace};
pub(crate) use sink::HolderSink;
pub(crate) use terminal::{HolderTerminal, holder_local_launch};

/// New session-owned terminals run on the holder.
pub(crate) fn enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("CMUX_TUI_TERMINAL_HOST_MODEL").is_ok_and(|model| model == "holder")
    })
}

/// Stand-in holders for the tests of other modules (surface echo flows).
#[cfg(test)]
pub(crate) mod test_support {
    pub(crate) use super::service::tests::{next_frame, stand_in_service, welcome_granting};
    pub(crate) use super::terminal::tests::{nonblocking_pty, stand_in_terminal};
}
