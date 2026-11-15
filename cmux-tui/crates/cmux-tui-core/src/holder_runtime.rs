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
//! On by default on Linux (CMUX-571: one holder replaces a `cmux-tui-host`
//! per terminal; Leo, 2026-11-14: "separate the health of the overall
//! process from the falliability of crash prone bits"); off elsewhere unless
//! `CMUX_TUI_TERMINAL_HOST_MODEL=holder`. `CMUX_TUI_TERMINAL_HOST_MODEL=hosts`
//! keeps the per-terminal hosts (a diagnostic and test override, not a user
//! setting). A holder that cannot start never costs a terminal: the create
//! runs it on a host of its own ([`serves`]).

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
/// terminals on the holder: `holder` does, `hosts` does not, and anything
/// else (unset, empty, unknown) takes the platform's default: the holder on
/// Linux, per-terminal hosts elsewhere.
fn model_enabled(model: Option<&str>) -> bool {
    match model.map(str::trim) {
        Some("holder") => true,
        Some("hosts") => false,
        _ => cfg!(target_os = "linux"),
    }
}

#[cfg(test)]
mod model_tests {
    use super::model_enabled;

    #[test]
    fn the_holder_is_the_linux_default_and_hosts_stays_an_override() {
        assert!(model_enabled(Some("holder")));
        assert!(!model_enabled(Some("hosts")));
        assert_eq!(model_enabled(None), cfg!(target_os = "linux"));
        assert_eq!(model_enabled(Some("")), cfg!(target_os = "linux"));
        assert_eq!(model_enabled(Some("bogus")), cfg!(target_os = "linux"));
    }
}
