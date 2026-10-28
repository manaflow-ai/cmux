//! The daemon's features for its life, and what an app's client hello may
//! change in them (p12-perf-process 3.9, task 150).
//!
//! The daemon outlives the app: an app that starts later may have resolved
//! the daemon's features differently (a remote kill switch, a Labs choice).
//! Its `client-hello` carries the hash and the values of its `daemon` and
//! `both` features. A verified app's off for a `process=daemon` kill switch
//! applies at once; every other difference stays pending until the daemon
//! restarts. The daemon keeps its own value for the session, and the app
//! takes the daemon's value for each pending `both` feature
//! (`DaemonFeatureHello`), so both processes run it the same. Chromium's child
//! processes likewise keep the feature state they started with
//! (`FeatureList::InitFromSharedMemory`, base/feature_list.cc).

use std::sync::atomic::{AtomicBool, Ordering};

use crate::{Feature, FeatureDef, Kind, Process, Snapshot, Source};

/// The daemon's start [`Snapshot`] and the kill switches hellos turned off
/// since. A kill is never undone in the session. A kill switch's reader asks
/// [`Live::is_enabled`] at each decision, so a kill applies at its next one.
#[derive(Debug)]
pub struct Live {
    snapshot: Snapshot,
    killed: Box<[AtomicBool]>,
}

/// A feature whose value in the app's hello differs from the daemon's: the
/// daemon keeps its value until it restarts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pending {
    pub name: &'static str,
    pub app: bool,
    pub daemon: bool,
}

/// What one hello changed and what it left pending.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reconciled {
    /// The daemon's [`values_hash`] after the hello.
    pub hash: String,
    /// The kill switches this hello turned off.
    pub applied: Vec<&'static str>,
    pub pending: Vec<Pending>,
}

impl Live {
    pub fn new(snapshot: Snapshot) -> Self {
        let killed = snapshot.states.iter().map(|_| AtomicBool::new(false)).collect();
        Self { snapshot, killed }
    }

    pub fn is_enabled(&self, feature: Feature) -> bool {
        self.snapshot.is_enabled(feature) && !self.killed[feature.0].load(Ordering::Relaxed)
    }

    pub fn source(&self, feature: Feature) -> Source {
        if self.killed[feature.0].load(Ordering::Relaxed) {
            return Source::Hello;
        }
        self.snapshot.source(feature)
    }

    /// The daemon's start snapshot, without the kills.
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }

    /// [`values_hash`] of the current values in table order.
    pub fn hash(&self) -> String {
        values_hash(self.current())
    }

    /// Compares an app's hello with the current values. Equal hashes mean
    /// equal values: nothing to walk. Otherwise each named feature the
    /// daemon knows is compared (an app newer than the daemon names
    /// features it lacks); with `may_kill` (a verified app) an off for an
    /// on `process=daemon` kill switch turns it off now, and every other
    /// difference is pending. Pure: no file, no network.
    pub fn reconcile<'a>(
        &self,
        hash: Option<&str>,
        values: impl IntoIterator<Item = (&'a str, bool)>,
        may_kill: bool,
    ) -> Reconciled {
        let before = self.hash();
        if hash == Some(before.as_str()) {
            return Reconciled { hash: before, applied: Vec::new(), pending: Vec::new() };
        }
        let (mut applied, mut pending) = (Vec::new(), Vec::new());
        for (name, app) in values {
            let Some(feature) = self.snapshot.feature(name) else { continue };
            let def = &self.snapshot.table[feature.0];
            let daemon = self.is_enabled(feature);
            if app == daemon {
                continue;
            }
            if may_kill && !app && is_kill_switch(def) {
                // A hello racing this one may have turned it off first.
                if !self.killed[feature.0].swap(true, Ordering::Relaxed) {
                    applied.push(def.name);
                }
            } else {
                pending.push(Pending { name: def.name, app, daemon });
            }
        }
        Reconciled { hash: self.hash(), applied, pending }
    }

    fn current(&self) -> impl Iterator<Item = (&'static str, bool)> + '_ {
        let table = self.snapshot.table;
        (0..table.len()).map(move |index| (table[index].name, self.is_enabled(Feature(index))))
    }
}

fn is_kill_switch(def: &FeatureDef) -> bool {
    def.process == Process::Daemon && def.kind == Kind::KillSwitch
}

/// FNV-1a 64 of `name=1\n` (or `=0`) for each value in order, as 16 hex
/// digits. The app hashes its `daemon` and `both` features in registry
/// order the same way (`FeatureList.daemonHello`), so equal tables with
/// equal values give equal hashes.
pub fn values_hash<'a>(values: impl IntoIterator<Item = (&'a str, bool)>) -> String {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = OFFSET;
    let mut add = |bytes: &[u8]| {
        for &byte in bytes {
            hash = (hash ^ u64::from(byte)).wrapping_mul(PRIME);
        }
    };
    for (name, enabled) in values {
        add(name.as_bytes());
        add(if enabled { b"=1\n" } else { b"=0\n" });
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Channel, Defaults};

    const TABLE: &[FeatureDef] = &[
        FeatureDef {
            name: "flagsFetch",
            defaults: Defaults { dev: true, nightly: true, release: true },
            kind: Kind::KillSwitch,
            process: Process::Daemon,
        },
        FeatureDef {
            name: "coldScrollback",
            defaults: Defaults { dev: true, nightly: true, release: true },
            kind: Kind::PerfPath,
            process: Process::Daemon,
        },
        FeatureDef {
            name: "holderKill",
            defaults: Defaults { dev: true, nightly: true, release: true },
            kind: Kind::KillSwitch,
            process: Process::Both,
        },
    ];
    feature_handles!(TABLE; FETCH = "flagsFetch", COLD = "coldScrollback", HOLDER = "holderKill");

    fn live() -> Live {
        Live::new(Snapshot::defaults_in(TABLE, Channel::Release))
    }

    #[test]
    fn a_verified_hello_turns_a_daemon_kill_switch_off_at_once() {
        let live = live();
        let reconciled = live.reconcile(None, [("flagsFetch", false)], true);
        assert_eq!(reconciled.applied, ["flagsFetch"]);
        assert!(reconciled.pending.is_empty());
        assert!(!live.is_enabled(FETCH));
        assert_eq!(live.source(FETCH), Source::Hello);
        assert_eq!(reconciled.hash, live.hash());
        assert!(live.snapshot().is_enabled(FETCH), "the start snapshot is unchanged");

        let again = live.reconcile(None, [("flagsFetch", true)], true);
        assert!(!live.is_enabled(FETCH), "a kill is never undone in the session");
        assert_eq!(again.pending, [Pending { name: "flagsFetch", app: true, daemon: false }]);
    }

    #[test]
    fn an_unverified_hello_kills_nothing() {
        let live = live();
        let reconciled = live.reconcile(None, [("flagsFetch", false)], false);
        assert!(reconciled.applied.is_empty());
        assert_eq!(reconciled.pending, [Pending { name: "flagsFetch", app: false, daemon: true }]);
        assert!(live.is_enabled(FETCH));
    }

    #[test]
    fn a_perf_path_mismatch_is_pending() {
        let live = live();
        let reconciled = live.reconcile(None, [("coldScrollback", false)], true);
        assert!(reconciled.applied.is_empty());
        assert_eq!(
            reconciled.pending,
            [Pending { name: "coldScrollback", app: false, daemon: true }]
        );
        assert!(live.is_enabled(COLD));
    }

    #[test]
    fn a_both_feature_keeps_the_daemon_value_even_as_a_kill_switch() {
        let live = live();
        let reconciled = live.reconcile(None, [("holderKill", false)], true);
        assert_eq!(reconciled.pending, [Pending { name: "holderKill", app: false, daemon: true }]);
        assert!(live.is_enabled(HOLDER));
        assert_eq!(live.source(HOLDER), Source::Default);
    }

    #[test]
    fn equal_hashes_skip_the_walk_and_unknown_names_are_ignored() {
        let live = live();
        let hash = live.hash();
        // Values that would kill, under the daemon's own hash: equal values by contract.
        let same = live.reconcile(Some(&hash), [("flagsFetch", false)], true);
        assert_eq!(same, Reconciled { hash: hash.clone(), applied: vec![], pending: vec![] });
        assert!(live.is_enabled(FETCH));
        let newer_app =
            live.reconcile(Some("0"), [("appOnlyFeature", false), ("coldScrollback", true)], true);
        assert_eq!(newer_app, Reconciled { hash, applied: vec![], pending: vec![] });
    }

    /// A hello never reads the flags document or any file: this module's
    /// code (its tests aside) names no std path but `std::sync::atomic` and
    /// nothing of `sources`, the flags-document reader. The client-hello
    /// step hands it only the hello's values (cmux-tui-core
    /// `the_daemon_never_fetches_on_a_hello`).
    #[test]
    fn the_reconcile_module_does_no_io() {
        let code = include_str!("hello.rs").split("#[cfg(test)]").next().unwrap();
        assert!(!code.contains("sources"), "hello.rs must not reach the flags-document reader");
        for (at, _) in code.match_indices("std::") {
            assert!(
                code[at..].starts_with("std::sync::atomic"),
                "hello.rs names {}",
                code[at..].lines().next().unwrap_or_default()
            );
        }
        assert!(!code.contains("Command") && !code.contains("File"), "hello.rs does I/O");
    }

    #[test]
    fn the_hash_is_fnv1a_of_the_ordered_values() {
        // The vector FeatureListDaemonHelloTests checks on the Swift side.
        assert_eq!(values_hash([]), "cbf29ce484222325");
        assert_eq!(values_hash([("a", true)]), values_hash([("a", true)]));
        assert_ne!(values_hash([("a", true)]), values_hash([("a", false)]));
        assert_ne!(
            values_hash([("a", true), ("b", false)]),
            values_hash([("b", false), ("a", true)])
        );
        assert_eq!(
            values_hash([("terminalHolder", false), ("energySaver", true)]),
            "40dd6db15aa26b63"
        );
    }
}
