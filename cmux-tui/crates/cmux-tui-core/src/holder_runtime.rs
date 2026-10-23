//! Terminals held by the install's one holder process instead of a host
//! process each (terminal-host-model-DESIGN.md, option D).
//!
//! The holder (the standalone `cmux-holder`, else `cmux-tui-host __holder`;
//! crate `cmux-holder`) starts each shell on
//! a PTY, keeps the master in one poll set and a byte ring per terminal, and
//! parses nothing. The daemon keeps a custody dup of every master, writes
//! input and resizes on it directly, and parses the output the holder
//! streams over one link: the terminal runs on the daemon's local runtime
//! (`PtyRuntime::Local`), so the daemon's parser is the only one outside the
//! app. A daemon restart re-attaches from the holder's rings
//! (`mux::holder_adoption`); a holder crash loses no shell, because the
//! daemon still holds every master and hands them to a new holder.
//!
//! The default since holder item 5 (2026-10-23); `CMUX_TUI_TERMINAL_HOST_MODEL=hosts`
//! opts out to a terminal host process per terminal, kept for one release.
//! Terminal hosts an older build started keep running and are adopted as
//! before.

mod service;
mod sink;
mod terminal;

pub(crate) use service::HolderService;
#[cfg(not(test))]
pub(crate) use service::prepare_in_background;
pub(crate) use sink::HolderSink;
pub(crate) use terminal::{HolderTerminal, holder_local_launch};

/// New session-owned terminals run on the holder: the default (holder item
/// 5). `CMUX_TUI_TERMINAL_HOST_MODEL=hosts` opts out and starts a terminal
/// host process per terminal, as before; that path stays for one release.
/// The daemon library's own unit tests keep the hosts unless they name the
/// holder (they start no holder binary).
pub(crate) fn enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| {
        let model = std::env::var("CMUX_TUI_TERMINAL_HOST_MODEL").ok();
        if cfg!(test) {
            model.as_deref() == Some("holder")
        } else {
            model.as_deref() != Some("hosts")
        }
    })
}
