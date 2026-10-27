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
//! Behind the `terminalHolder` feature (`schemas/features/features.d`), off
//! on every channel: the per-terminal hosts stay the default. The daemon
//! installs its resolved features ([`install`]) before it builds the mux, so
//! the managed policy and the signed document's `DisabledFeatures` turn it
//! off as they turn off any feature. [`MODEL_ENV`] stays as an alias entry of
//! the env lists.

mod service;
mod sink;
mod terminal;

use cmux_features::{Channel, Snapshot, Source, feature::TERMINAL_HOLDER};
use std::sync::OnceLock;

#[cfg(not(test))]
pub(crate) use service::prepare_in_background;
pub(crate) use service::{HOLDER_LINK_HANG, holder_frame_name};
pub(crate) use service::{HolderService, HolderTrace};
pub(crate) use sink::HolderSink;
pub(crate) use terminal::{HolderTerminal, holder_local_launch};

/// The env switch that predates `terminalHolder`: `holder` enables the
/// feature and `hosts` disables it.
pub(crate) const MODEL_ENV: &str = "CMUX_TUI_TERMINAL_HOST_MODEL";

/// This process's holder model, fixed at its first read: a session never
/// changes models after start (the feature is not `runtimeMutable`).
static ENABLED: OnceLock<bool> = OnceLock::new();

/// Fixes the holder model from the daemon's resolved `features` and returns
/// the model in effect. The daemon calls it once at start, before any
/// terminal exists; a read that came first has already fixed the model, and
/// that model stays.
pub fn install(features: &Snapshot) -> bool {
    *ENABLED.get_or_init(|| resolve(features, std::env::var(MODEL_ENV).ok().as_deref()))
}

/// New session-owned terminals run on the holder.
pub(crate) fn enabled() -> bool {
    // A process that installs nothing (unit tests, a mux outside the daemon)
    // reads the env lists at the default of an unbundled build.
    *ENABLED.get_or_init(|| {
        let env = |name: &str| std::env::var(name).ok();
        let channel = if cfg!(debug_assertions) { Channel::Dev } else { Channel::Release };
        let enable = env(cmux_features::ENABLE_ENV);
        let disable = env(cmux_features::DISABLE_ENV);
        let features = Snapshot::from_env(channel, enable.as_deref(), disable.as_deref());
        resolve(&features, env(MODEL_ENV).as_deref())
    })
}

/// `terminalHolder` with the alias as one more env-list entry: `holder` is an
/// enable and `hosts` a disable; any other value is ignored, like an unknown
/// feature name. A disable wins over an enable, and `DisabledFeatures` wins
/// over both, as in Chromium's `base/feature_list.cc` (a feature on both
/// lists is off).
fn resolve(features: &Snapshot, alias: Option<&str>) -> bool {
    let enabled = features.is_enabled(TERMINAL_HOLDER);
    match (features.source(TERMINAL_HOLDER), alias.map(str::trim)) {
        (Source::Disabled, _) | (Source::Override, _) if !enabled => false,
        (_, Some("holder")) => true,
        (_, Some("hosts")) => false,
        _ => enabled,
    }
}

/// Stand-in holders for the tests of other modules (surface echo flows).
#[cfg(test)]
pub(crate) mod test_support {
    pub(crate) use super::service::tests::{next_frame, stand_in_service, welcome_granting};
    pub(crate) use super::terminal::tests::{nonblocking_pty, stand_in_terminal};
}

#[cfg(test)]
mod model_tests {
    use super::*;

    fn lists(channel: Channel, enable: Option<&str>, disable: Option<&str>) -> Snapshot {
        Snapshot::from_env(channel, enable, disable)
    }

    #[test]
    fn the_default_is_the_terminal_hosts_on_every_channel() {
        for channel in [Channel::Dev, Channel::Nightly, Channel::Release] {
            assert!(!resolve(&Snapshot::defaults(channel), None), "{channel:?}");
            assert!(!resolve(&lists(channel, None, None), None), "{channel:?}");
        }
    }

    #[test]
    fn the_feature_lists_turn_the_holder_on_and_off() {
        let on = lists(Channel::Release, Some("terminalHolder"), None);
        assert!(resolve(&on, None));
        let both = lists(Channel::Release, Some("terminalHolder"), Some("terminalHolder"));
        assert!(!resolve(&both, None), "disable wins");
        let hello = Snapshot::from_pairs(Channel::Release, [("terminalHolder", true)]);
        assert!(resolve(&hello, None), "a hello's overrides resolve the same way");
    }

    #[test]
    fn the_env_alias_still_selects_the_model() {
        let defaults = Snapshot::defaults(Channel::Release);
        assert!(resolve(&defaults, Some("holder")));
        assert!(resolve(&defaults, Some(" holder\n")));
        assert!(!resolve(&defaults, Some("hosts")));
        assert!(!resolve(&defaults, Some("Holder")), "values are case-sensitive");
        assert!(!resolve(&defaults, Some("")));
        let on = lists(Channel::Release, Some("terminalHolder"), None);
        assert!(!resolve(&on, Some("hosts")), "the alias's disable wins over an enable");
        assert!(resolve(&on, Some("anything else")), "an unknown value is ignored");
    }

    #[test]
    fn a_disable_beats_the_alias() {
        let off = lists(Channel::Release, None, Some("terminalHolder"));
        assert!(!resolve(&off, Some("holder")));
        let killed =
            lists(Channel::Release, Some("terminalHolder"), None).with_disabled(["terminalHolder"]);
        assert!(!resolve(&killed, Some("holder")), "DisabledFeatures wins over everything");
    }
}
