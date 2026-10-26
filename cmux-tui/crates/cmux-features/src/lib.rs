//! The daemon's features (plans/cmux-next/chrome-parity/p12-perf-process.md 3.9).
//!
//! [`generated`] holds the registry's `daemon` and `both` features
//! (`schemas/features/features.d`) and one [`Feature`] handle per entry. The
//! daemon resolves them once into an immutable [`Snapshot`]: a read is one
//! array load, and a client hello that disagrees is reported, not applied (no
//! mid-session flip).
//!
//! Overrides are two lists of names, [`ENABLE_ENV`] and [`DISABLE_ENV`]: a
//! feature on both is disabled and an unknown name is ignored. The app puts
//! its resolved overrides in the daemon's spawn environment
//! ([`Snapshot::to_env`]), so a daemon the CLI starts without the app reads
//! the person's own lists. A client hello carries the same overrides as
//! name/value pairs ([`Snapshot::from_pairs`]). `DisabledFeatures` from the
//! signed `flags.json` reader (`cmux-tui/src/feature_flags.rs`) applies last
//! ([`Snapshot::with_disabled`]).
//!
//! This is Chromium's `base/feature_list.cc`: `FeatureList::InitFromCommandLine`
//! reads `--enable-features` and `--disable-features` the same way, and
//! `FeatureList::AddFeaturesToCommandLine` gives a child process only the
//! overridden features.

/// Defines `pub const HANDLE: Feature` for each `HANDLE = "name"` (with its doc
/// comment): the index of `name` in `table`. A name the table lacks fails the
/// build; every check is a `const` item, so none of it runs in the daemon.
macro_rules! feature_handles {
    ($table:path; $($(#[$meta:meta])* $handle:ident = $name:literal),* $(,)?) => {$(
        $(#[$meta])*
        pub const $handle: $crate::Feature = $crate::Feature($crate::position($table, $name));
        const _: () = assert!(
            $crate::position($table, $name) < $table.len(),
            concat!("no feature named ", $name, " in the table"),
        );
    )*};
}

mod generated;
/// The daemons' value sources (managed policy, the signed document, the channel).
#[cfg(feature = "sources")]
pub mod sources;

pub use generated::feature;

/// The comma-separated names to turn on (Chromium's `--enable-features`).
pub const ENABLE_ENV: &str = "CMUX_ENABLE_FEATURES";
/// The comma-separated names to turn off; wins over [`ENABLE_ENV`] (`--disable-features`).
pub const DISABLE_ENV: &str = "CMUX_DISABLE_FEATURES";

/// A handle to one generated feature: its index in the table.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Feature(usize);

const _: () = assert!(names_are_unique(generated::TABLE), "two features share a name");

/// The index of the first entry named `name`, or `table.len()` when there is none.
const fn position(table: &[FeatureDef], name: &str) -> usize {
    let mut index = 0;
    while index < table.len() && !same_name(table[index].name, name) {
        index += 1;
    }
    index
}

/// Every name is unique when each entry is the first with its name.
const fn names_are_unique(table: &[FeatureDef]) -> bool {
    let mut index = 0;
    while index < table.len() {
        if position(table, table[index].name) != index {
            return false;
        }
        index += 1;
    }
    true
}

const fn same_name(left: &str, right: &str) -> bool {
    let (left, right) = (left.as_bytes(), right.as_bytes());
    if left.len() != right.len() {
        return false;
    }
    let mut index = 0;
    while index < left.len() {
        if left[index] != right[index] {
            return false;
        }
        index += 1;
    }
    true
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
    /// The enable or disable list (spawn environment or client hello).
    Override,
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

    /// The spawn snapshot from the values of [`ENABLE_ENV`] and [`DISABLE_ENV`], `None` when unset.
    pub fn from_env(channel: Channel, enable: Option<&str>, disable: Option<&str>) -> Self {
        Self::from_env_in(generated::TABLE, channel, enable, disable)
    }

    /// A client hello's overrides, as `(name, enabled)` pairs.
    pub fn from_pairs<'a>(
        channel: Channel,
        pairs: impl IntoIterator<Item = (&'a str, bool)>,
    ) -> Self {
        Self::from_pairs_in(generated::TABLE, channel, pairs)
    }

    /// This snapshot with every named feature off (`DisabledFeatures`, which wins over overrides).
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

    /// The environment that hands this snapshot's overrides to a child process.
    /// Features at their default are left out, as in `AddFeaturesToCommandLine`.
    pub fn to_env(&self) -> [(&'static str, String); 2] {
        let list = |wanted: bool| {
            let names: Vec<&str> = self
                .iter()
                .filter(|&(_, enabled, source)| source != Source::Default && enabled == wanted)
                .map(|(def, _, _)| def.name)
                .collect();
            names.join(",")
        };
        [(ENABLE_ENV, list(true)), (DISABLE_ENV, list(false))]
    }

    fn defaults_in(table: &'static [FeatureDef], channel: Channel) -> Self {
        let states = table
            .iter()
            .map(|def| State {
                enabled: def.defaults.for_channel(channel),
                source: Source::Default,
            })
            .collect();
        Self { table, states }
    }

    fn from_env_in(
        table: &'static [FeatureDef],
        channel: Channel,
        enable: Option<&str>,
        disable: Option<&str>,
    ) -> Self {
        let enabled = names(enable).map(|name| (name, true));
        let disabled = names(disable).map(|name| (name, false));
        Self::from_pairs_in(table, channel, enabled.chain(disabled))
    }

    /// Applies each override; a feature named both ways is disabled.
    fn from_pairs_in<'a>(
        table: &'static [FeatureDef],
        channel: Channel,
        pairs: impl IntoIterator<Item = (&'a str, bool)>,
    ) -> Self {
        let mut snapshot = Self::defaults_in(table, channel);
        for (name, enabled) in pairs {
            let Some(index) = snapshot.index_of(name) else { continue };
            let state = &mut snapshot.states[index];
            let already_disabled = state.source == Source::Override && !state.enabled;
            if !already_disabled {
                *state = State { enabled, source: Source::Override };
            }
        }
        snapshot
    }

    fn index_of(&self, name: &str) -> Option<usize> {
        self.table.iter().position(|def| def.name == name)
    }
}

/// Whether the [`ENABLE_ENV`] and [`DISABLE_ENV`] lists of this process turn
/// on `name`, a daemon feature whose registry default is off on every channel.
/// The gate of such a feature until the generated registry lists it; then
/// [`Snapshot::is_enabled`] replaces it.
pub fn listed_in_env(name: &str) -> bool {
    let list = |variable: &str| std::env::var(variable).ok();
    listed(name, list(ENABLE_ENV).as_deref(), list(DISABLE_ENV).as_deref())
}

/// Whether `enable` names `name` and `disable` does not (disable wins), split
/// the way [`Snapshot::from_env`] splits the lists.
pub fn listed(name: &str, enable: Option<&str>, disable: Option<&str>) -> bool {
    let named = |list: Option<&str>| names(list).any(|listed| listed == name);
    named(enable) && !named(disable)
}

/// The names in one comma-separated list; empty entries are skipped.
fn names(list: Option<&str>) -> impl Iterator<Item = &str> {
    list.into_iter().flat_map(|text| text.split(',')).map(str::trim).filter(|name| !name.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABLE: &[FeatureDef] = &[
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
    feature_handles!(TABLE; HOLDER = "terminalHolder", DAEMON_ONLY = "daemonOnly");

    fn values(snapshot: &Snapshot) -> Vec<(bool, Source)> {
        snapshot.iter().map(|(_, enabled, source)| (enabled, source)).collect()
    }

    #[test]
    fn listed_reads_the_lists_like_a_snapshot() {
        assert!(!listed("daemonOnly", None, None));
        assert!(!listed("daemonOnly", Some("terminalHolder"), None));
        assert!(listed("daemonOnly", Some("a,, daemonOnly ,"), None));
        assert!(!listed("daemonOnly", Some("daemononly"), None), "names are case-sensitive");
        assert!(!listed("daemonOnly", Some("daemonOnly"), Some(" daemonOnly")), "disable wins");
        assert!(listed("daemonOnly", Some("daemonOnly"), Some("terminalHolder")));
    }

    #[test]
    fn handles_find_their_entry_by_name() {
        assert_eq!((HOLDER, DAEMON_ONLY), (Feature(0), Feature(1)));
        assert!(names_are_unique(TABLE));
        assert!(!names_are_unique(&[TABLE[0], TABLE[1], TABLE[0]]));
    }

    #[test]
    fn an_unknown_name_is_not_a_handle() {
        assert_eq!(position(TABLE, "terminal"), TABLE.len());
    }

    #[test]
    fn the_env_lists_set_each_named_feature() {
        let snapshot = Snapshot::from_env_in(
            TABLE,
            Channel::Release,
            Some("terminalHolder"),
            Some("daemonOnly"),
        );
        assert!(snapshot.is_enabled(HOLDER));
        assert_eq!(snapshot.source(HOLDER), Source::Override);
        assert!(!snapshot.is_enabled(DAEMON_ONLY));
        assert_eq!(snapshot.source(DAEMON_ONLY), Source::Override);
    }

    #[test]
    fn unknown_and_empty_names_are_ignored() {
        let snapshot = Snapshot::from_env_in(
            TABLE,
            Channel::Nightly,
            Some("noSuchFeature,, daemonOnly ,"),
            Some("terminalholder,"),
        );
        assert_eq!(values(&snapshot), [(true, Source::Default), (true, Source::Override)]);
    }

    #[test]
    fn defaults_apply_when_the_lists_are_absent() {
        for (channel, holder) in
            [(Channel::Dev, true), (Channel::Nightly, true), (Channel::Release, false)]
        {
            let snapshot = Snapshot::from_env_in(TABLE, channel, None, None);
            assert_eq!(snapshot, Snapshot::defaults_in(TABLE, channel));
            assert_eq!(values(&snapshot), [(holder, Source::Default), (false, Source::Default)]);
        }
        let empty = Snapshot::from_env_in(TABLE, Channel::Dev, Some(""), Some(""));
        assert_eq!(empty, Snapshot::defaults_in(TABLE, Channel::Dev));
    }

    #[test]
    fn a_feature_on_both_lists_is_disabled() {
        let env = Snapshot::from_env_in(
            TABLE,
            Channel::Dev,
            Some("terminalHolder"),
            Some("terminalHolder"),
        );
        assert_eq!(values(&env)[0], (false, Source::Override));
        let orders = [
            [("terminalHolder", false), ("terminalHolder", true)],
            [("terminalHolder", true), ("terminalHolder", false)],
        ];
        for pairs in orders {
            let hello = Snapshot::from_pairs_in(TABLE, Channel::Dev, pairs);
            assert!(!hello.is_enabled(HOLDER), "{pairs:?}");
        }
    }

    #[test]
    fn a_hello_resolves_like_the_env_lists() {
        let hello = Snapshot::from_pairs_in(
            TABLE,
            Channel::Release,
            [("terminalHolder", true), ("appOnly", false)],
        );
        let env =
            Snapshot::from_env_in(TABLE, Channel::Release, Some("terminalHolder"), Some("appOnly"));
        assert_eq!(hello, env);
        assert_eq!(values(&hello), [(true, Source::Override), (false, Source::Default)]);
    }

    #[test]
    fn disabled_features_win_over_overrides() {
        let snapshot =
            Snapshot::from_env_in(TABLE, Channel::Dev, Some("terminalHolder,daemonOnly"), None)
                .with_disabled(["terminalHolder", "noSuchFeature"]);
        assert_eq!(values(&snapshot), [(false, Source::Disabled), (true, Source::Override)]);
    }

    #[test]
    fn a_child_gets_only_the_overrides() {
        let defaults = Snapshot::defaults_in(TABLE, Channel::Release);
        assert_eq!(defaults.to_env(), [(ENABLE_ENV, String::new()), (DISABLE_ENV, String::new())]);

        let parent = Snapshot::from_env_in(TABLE, Channel::Release, Some("daemonOnly"), None)
            .with_disabled(["terminalHolder"]);
        let env = parent.to_env();
        assert_eq!(
            env,
            [(ENABLE_ENV, "daemonOnly".to_owned()), (DISABLE_ENV, "terminalHolder".to_owned())]
        );
        let child =
            Snapshot::from_env_in(TABLE, Channel::Release, Some(&env[0].1), Some(&env[1].1));
        assert_eq!(values(&child), [(false, Source::Override), (true, Source::Override)]);

        let untouched = Snapshot::from_env_in(TABLE, Channel::Dev, Some("daemonOnly"), None);
        let [(_, enable), (_, disable)] = untouched.to_env();
        let child = Snapshot::from_env_in(TABLE, Channel::Dev, Some(&enable), Some(&disable));
        assert_eq!(values(&child), [(true, Source::Default), (true, Source::Override)]);
    }
}
