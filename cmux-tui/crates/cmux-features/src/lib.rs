//! The daemon's features (plans/cmux-next/chrome-parity/p12-perf-process.md 3.9).
//!
//! The registry (`schemas/features/features.d`) is generated into
//! [`generated`]: a static table of the `daemon` and `both` features and one
//! [`Feature`] handle per entry. The app resolves every feature and hands the
//! result to the daemon in two places:
//!
//! - at spawn, in `CMUX_FEATURES_SNAPSHOT=name=1,name=0` ([`Snapshot::from_env_value`]);
//! - in every client hello, as name/value pairs ([`Snapshot::from_pairs`]).
//!
//! The daemon builds its snapshot once and never changes it: a hello that
//! disagrees is reported, not applied (no mid-session flip). A read is one
//! array load. The signed `flags.json` reader (`cmux-tui/src/feature_flags.rs`)
//! stays the source of `DisabledFeatures`, applied on top with
//! [`Snapshot::with_disabled`].
//!
//! Chromium does the same job in `base/feature_list.cc`:
//! `FeatureList::InitFromCommandLine` reads `--enable-features` and
//! `--disable-features`, ignores names it does not know, and a feature on both
//! lists is disabled; `FeatureList::AddFeaturesToCommandLine` hands the state
//! to child processes ([`Snapshot::to_env_value`]).

mod generated;

pub use generated::feature;

/// The environment variable that carries the app's snapshot to the daemon at spawn.
pub const SNAPSHOT_ENV: &str = "CMUX_FEATURES_SNAPSHOT";

/// A handle to one generated feature: its index in the table.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Feature(usize);

impl Feature {
    #[allow(
        dead_code,
        reason = "the generated handles call it; the registry has no daemon feature yet"
    )]
    pub(crate) const fn at(index: usize) -> Self {
        Self(index)
    }
}

/// The build channel whose registry default applies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channel {
    Dev,
    Nightly,
    Release,
}

/// A feature's registry defaults, per channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Defaults {
    pub dev: bool,
    pub nightly: bool,
    pub release: bool,
}

impl Defaults {
    pub const fn for_channel(self, channel: Channel) -> bool {
        match channel {
            Channel::Dev => self.dev,
            Channel::Nightly => self.nightly,
            Channel::Release => self.release,
        }
    }
}

/// Which processes read a feature. The table holds only the daemon's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Process {
    Daemon,
    Both,
}

/// One registry entry, as the generator emits it.
#[derive(Debug, PartialEq, Eq)]
pub struct FeatureDef {
    pub name: &'static str,
    pub defaults: Defaults,
    pub process: Process,
}

/// Where a feature's resolved value came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The registry default for the channel.
    Default,
    /// The app's snapshot (spawn environment or client hello).
    App,
    /// Managed policy or the signed document's `DisabledFeatures`.
    Disabled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct State {
    enabled: bool,
    source: Source,
}

/// The resolved value of every daemon feature. Immutable once built.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    table: &'static [FeatureDef],
    states: Box<[State]>,
}

impl Snapshot {
    /// Every feature at its registry default for `channel`.
    pub fn defaults(channel: Channel) -> Self {
        Self::defaults_in(generated::TABLE, channel)
    }

    /// The spawn snapshot: `value` is `CMUX_FEATURES_SNAPSHOT`, `None` when unset.
    pub fn from_env_value(channel: Channel, value: Option<&str>) -> Self {
        Self::from_env_value_in(generated::TABLE, channel, value)
    }

    /// A client hello's snapshot, as `(name, enabled)` pairs.
    pub fn from_pairs<'a>(
        channel: Channel,
        pairs: impl IntoIterator<Item = (&'a str, bool)>,
    ) -> Self {
        Self::from_pairs_in(generated::TABLE, channel, pairs)
    }

    /// This snapshot with every named feature off (`DisabledFeatures`, which wins over the app).
    pub fn with_disabled<'a>(mut self, names: impl IntoIterator<Item = &'a str>) -> Self {
        for name in names {
            if let Some(index) = self.index_of(name) {
                self.states[index] = State { enabled: false, source: Source::Disabled };
            }
        }
        self
    }

    pub fn is_enabled(&self, feature: Feature) -> bool {
        self.states[feature.0].enabled
    }

    pub fn source(&self, feature: Feature) -> Source {
        self.states[feature.0].source
    }

    /// Each feature in table order with its value and source, for `features.list`.
    pub fn iter(&self) -> impl Iterator<Item = (&'static FeatureDef, bool, Source)> + '_ {
        self.table
            .iter()
            .zip(self.states.iter())
            .map(|(def, state)| (def, state.enabled, state.source))
    }

    /// The `CMUX_FEATURES_SNAPSHOT` value that hands this snapshot to a child process.
    pub fn to_env_value(&self) -> String {
        let entries: Vec<String> = self
            .iter()
            .map(|(def, enabled, _)| format!("{}={}", def.name, u8::from(enabled)))
            .collect();
        entries.join(",")
    }

    pub(crate) fn defaults_in(table: &'static [FeatureDef], channel: Channel) -> Self {
        let states = table
            .iter()
            .map(|def| State {
                enabled: def.defaults.for_channel(channel),
                source: Source::Default,
            })
            .collect();
        Self { table, states }
    }

    pub(crate) fn from_env_value_in(
        table: &'static [FeatureDef],
        channel: Channel,
        value: Option<&str>,
    ) -> Self {
        let pairs = value.into_iter().flat_map(|text| text.split(',')).filter_map(parse_entry);
        Self::from_pairs_in(table, channel, pairs)
    }

    pub(crate) fn from_pairs_in<'a>(
        table: &'static [FeatureDef],
        channel: Channel,
        pairs: impl IntoIterator<Item = (&'a str, bool)>,
    ) -> Self {
        let mut snapshot = Self::defaults_in(table, channel);
        for (name, enabled) in pairs {
            let Some(index) = snapshot.index_of(name) else { continue };
            let state = &mut snapshot.states[index];
            let disabled_by_app = state.source == Source::App && !state.enabled;
            if !disabled_by_app {
                *state = State { enabled, source: Source::App };
            }
        }
        snapshot
    }

    fn index_of(&self, name: &str) -> Option<usize> {
        self.table.iter().position(|def| def.name == name)
    }
}

/// One `name=1` or `name=0` entry; anything else is ignored.
fn parse_entry(entry: &str) -> Option<(&str, bool)> {
    let (name, value) = entry.split_once('=')?;
    let enabled = match value.trim() {
        "1" => true,
        "0" => false,
        _ => return None,
    };
    Some((name.trim(), enabled))
}

#[cfg(test)]
mod tests {
    use super::*;

    static TABLE: &[FeatureDef] = &[
        FeatureDef {
            name: "terminalHolder",
            defaults: Defaults { dev: true, nightly: true, release: false },
            process: Process::Both,
        },
        FeatureDef {
            name: "daemonOnly",
            defaults: Defaults { dev: false, nightly: false, release: false },
            process: Process::Daemon,
        },
    ];
    const HOLDER: Feature = Feature::at(0);
    const DAEMON_ONLY: Feature = Feature::at(1);

    fn values(snapshot: &Snapshot) -> Vec<(bool, Source)> {
        snapshot.iter().map(|(_, enabled, source)| (enabled, source)).collect()
    }

    #[test]
    fn the_env_snapshot_sets_each_named_feature() {
        let snapshot = Snapshot::from_env_value_in(
            TABLE,
            Channel::Release,
            Some("terminalHolder=1,daemonOnly=0"),
        );
        assert!(snapshot.is_enabled(HOLDER));
        assert_eq!(snapshot.source(HOLDER), Source::App);
        assert!(!snapshot.is_enabled(DAEMON_ONLY));
        assert_eq!(snapshot.source(DAEMON_ONLY), Source::App);
    }

    #[test]
    fn unknown_and_malformed_entries_are_ignored() {
        let snapshot = Snapshot::from_env_value_in(
            TABLE,
            Channel::Nightly,
            Some("noSuchFeature=1,,daemonOnly,daemonOnly=yes,terminalHolder=2, daemonOnly = 1 "),
        );
        assert_eq!(values(&snapshot), [(true, Source::Default), (true, Source::App)]);
    }

    #[test]
    fn defaults_apply_when_the_snapshot_is_absent() {
        for (channel, holder) in
            [(Channel::Dev, true), (Channel::Nightly, true), (Channel::Release, false)]
        {
            let snapshot = Snapshot::from_env_value_in(TABLE, channel, None);
            assert_eq!(snapshot, Snapshot::defaults_in(TABLE, channel));
            assert_eq!(values(&snapshot), [(holder, Source::Default), (false, Source::Default)]);
        }
        let empty = Snapshot::from_env_value_in(TABLE, Channel::Dev, Some(""));
        assert_eq!(empty, Snapshot::defaults_in(TABLE, Channel::Dev));
    }

    #[test]
    fn a_feature_named_both_ways_is_disabled() {
        for text in ["terminalHolder=0,terminalHolder=1", "terminalHolder=1,terminalHolder=0"] {
            let snapshot = Snapshot::from_env_value_in(TABLE, Channel::Dev, Some(text));
            assert!(!snapshot.is_enabled(HOLDER), "{text}");
        }
    }

    #[test]
    fn a_hello_snapshot_parses_like_the_env_snapshot() {
        let hello = Snapshot::from_pairs_in(
            TABLE,
            Channel::Release,
            [("terminalHolder", true), ("appOnly", false)],
        );
        let env = Snapshot::from_env_value_in(
            TABLE,
            Channel::Release,
            Some("terminalHolder=1,appOnly=0"),
        );
        assert_eq!(hello, env);
        assert_eq!(values(&hello), [(true, Source::App), (false, Source::Default)]);
    }

    #[test]
    fn disabled_features_win_over_the_app() {
        let snapshot =
            Snapshot::from_env_value_in(TABLE, Channel::Dev, Some("terminalHolder=1,daemonOnly=1"))
                .with_disabled(["terminalHolder", "noSuchFeature"]);
        assert_eq!(values(&snapshot), [(false, Source::Disabled), (true, Source::App)]);
    }

    #[test]
    fn the_env_value_round_trips() {
        let snapshot = Snapshot::from_env_value_in(TABLE, Channel::Release, Some("daemonOnly=1"));
        assert_eq!(snapshot.to_env_value(), "terminalHolder=0,daemonOnly=1");
        let child =
            Snapshot::from_env_value_in(TABLE, Channel::Dev, Some(&snapshot.to_env_value()));
        assert_eq!(values(&child), [(false, Source::App), (true, Source::App)]);
    }

    #[test]
    fn the_generated_table_has_unique_names_and_a_snapshot_per_entry() {
        let mut names: Vec<&str> = generated::TABLE.iter().map(|def| def.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), generated::TABLE.len());
        assert_eq!(Snapshot::defaults(Channel::Release).iter().count(), generated::TABLE.len());
        assert_eq!(Snapshot::from_env_value(Channel::Dev, None), Snapshot::defaults(Channel::Dev));
    }
}
