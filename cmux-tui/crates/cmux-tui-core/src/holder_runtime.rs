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
//! On by default on macOS, where cmux NEXT runs: one holder instead of a
//! `cmux-tui-host` per terminal (Leo's infinite-tabs ask: 500 tabs, 200
//! workspaces and 100 chats within 1.2x an empty app; the per-terminal hosts
//! cost 821 MB of it). `CMUX_TUI_TERMINAL_HOST_MODEL=hosts` keeps a host per
//! terminal; `=holder` turns the holder on elsewhere. Every other platform
//! keeps the hosts by default. With the holder on, a holder that cannot start never
//! costs a terminal: the create runs it on a host of its own ([`serves`]).

mod service;
mod sink;
mod terminal;

#[cfg(not(test))]
pub(crate) use service::prepare_in_background;
pub(crate) use service::{HolderReach, HolderService};
pub(crate) use sink::HolderSink;
pub(crate) use terminal::{HolderTerminal, holder_local_launch};

/// New session-owned terminals run on the holder (when it is available:
/// [`serves`]).
pub(crate) fn enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| {
        model_enabled(std::env::var("CMUX_TUI_TERMINAL_HOST_MODEL").ok().as_deref())
    })
}

/// Whether a new terminal of `host_root` runs on the holder: the model is
/// on and the holder runs or starts ([`HolderService::available`]). `false`
/// sends the create to a host process of its own, the path every terminal
/// took before the holder.
pub(crate) fn serves(host_root: &std::path::Path) -> bool {
    enabled() && HolderService::for_root(host_root).is_ok_and(|service| service.available())
}

/// Whether `model` (the value of `CMUX_TUI_TERMINAL_HOST_MODEL`) puts new
/// terminals on the holder: `holder` does, `hosts` does not, and unset, empty
/// or unknown take the platform's default ([`HOLDER_BY_DEFAULT`]).
fn model_enabled(model: Option<&str>) -> bool {
    model_enabled_with_default(model, HOLDER_BY_DEFAULT)
}

/// The holder is the default terminal model on macOS (cmux NEXT).
const HOLDER_BY_DEFAULT: bool = cfg!(target_os = "macos");

fn model_enabled_with_default(model: Option<&str>, default: bool) -> bool {
    match model.map(str::trim) {
        Some("holder") => true,
        Some("hosts") => false,
        _ => default,
    }
}

#[cfg(test)]
#[path = "holder_runtime_model_tests.rs"]
mod model_tests;
