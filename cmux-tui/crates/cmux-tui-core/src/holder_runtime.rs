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
//! Off by default on every platform: a `cmux-tui-host` per terminal stays
//! the default until Leo's words turn the holder on (CMUX-571; Leo,
//! 2026-11-14: "separate the health of the overall process from the
//! falliability of crash prone bits"). `CMUX_TUI_TERMINAL_HOST_MODEL=holder`
//! turns it on; `=hosts`, unset, empty or anything else keeps the
//! per-terminal hosts. With the holder on, a holder that cannot start never
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
/// terminals on the holder: only `holder` does. `hosts` and anything else
/// (unset, empty, unknown) keep a host per terminal, the default everywhere
/// until Leo turns the holder on.
fn model_enabled(model: Option<&str>) -> bool {
    matches!(model.map(str::trim), Some("holder"))
}

#[cfg(test)]
mod model_tests {
    use super::model_enabled;

    #[test]
    fn the_holder_is_off_unless_the_model_names_it() {
        assert!(model_enabled(Some("holder")));
        assert!(model_enabled(Some(" holder ")));
        assert!(!model_enabled(Some("hosts")));
        assert!(!model_enabled(None));
        assert!(!model_enabled(Some("")));
        assert!(!model_enabled(Some("bogus")));
    }
}
