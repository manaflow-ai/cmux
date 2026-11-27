//! Make cmux Yours as variant slots: every contested screen of the intro walk
//! is a slot with named arms, each install gets one bundle (an arm per slot)
//! assigned once at the front door, and each walk's end is recorded against
//! that bundle, so a contested step can run as a split instead of a single
//! daily pick (Leo, ask-b9fd9d4f9c: "i think we can hill climb user-facing
//! decisions").
//!
//! The assignment is a pure function of the install key: the same install
//! always gets the same bundle (FNV-1a 64 over a per-slot salt, never std's
//! randomized hasher), so a relaunch or a replay of the walk never reshuffles
//! it. Every slot ships with its split off: everyone gets today's arm until a
//! slot's `split_permille` is raised. The app sends the install key
//! (`onboarding_walk_bundle`) and logs each walk's outcome as the record built
//! here (`onboarding_walk_outcome`); `tally` folds those records into the
//! per-bundle counts a split is judged on.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One contested screen and its arms. `arms[0]` is the arm that ships today.
#[derive(Clone, Copy, Debug)]
pub struct Slot {
    pub id: &'static str,
    pub arms: &'static [&'static str],
    /// Share of installs (per mille) shown `arms[1]` instead of `arms[0]`.
    /// 0 is off; 500 is a 50/50 split.
    pub split_permille: u16,
}

/// The walk's contested screens, with the arms the gallery draws for each
/// (webviews `MakeItYoursStep` looks and `walkArms.tsx`). All splits are off.
pub const SLOTS: &[Slot] = &[
    Slot {
        id: "screen",
        arms: &["preview", "segmented", "form", "cards", "rows"],
        split_permille: 0,
    },
    Slot { id: "look", arms: &["grid", "hero", "list"], split_permille: 0 },
    Slot { id: "trust", arms: &["rows", "cards"], split_permille: 0 },
    Slot { id: "tune", arms: &["three", "five", "twoTone"], split_permille: 0 },
    Slot { id: "exit", arms: &["chat", "summary", "tryIt"], split_permille: 0 },
    Slot { id: "footer", arms: &["today", "undoRedo"], split_permille: 0 },
];

/// Bumped when the slot table changes meaning, so old and new bundles never
/// count together.
pub const VERSION: u32 = 1;

/// One install's bundle: the arm it sees on each slot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bundle {
    /// `wb1-` then each slot's arm index, in slot order (`wb1-000000` is today's walk).
    pub id: String,
    pub arms: BTreeMap<String, String>,
}

fn fnv1a(parts: &[&[u8]]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for part in parts {
        for byte in part.iter().chain(std::iter::once(&0u8)) {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
    }
    hash
}

/// The arm index `slot` shows the install with `install_key`.
fn arm_index(slot: &Slot, install_key: &str) -> usize {
    if slot.split_permille == 0 || slot.arms.len() < 2 {
        return 0;
    }
    let bucket =
        fnv1a(&[b"cmux-walk", &VERSION.to_le_bytes(), slot.id.as_bytes(), install_key.as_bytes()])
            % 1000;
    usize::from(bucket < u64::from(slot.split_permille))
}

fn bundle_for(slots: &[Slot], install_key: &str) -> Bundle {
    let indices: Vec<usize> = slots.iter().map(|slot| arm_index(slot, install_key)).collect();
    let id = format!("wb{VERSION}-{}", indices.iter().map(|i| i.to_string()).collect::<String>());
    let arms = slots
        .iter()
        .zip(&indices)
        .map(|(slot, &i)| (slot.id.to_string(), slot.arms[i].to_string()))
        .collect();
    Bundle { id, arms }
}

/// The bundle for one install.
pub fn bundle(install_key: &str) -> Bundle {
    bundle_for(SLOTS, install_key)
}

/// How a walk ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Ending {
    Started,
    Completed,
    Skipped,
}

/// The record the app logs at a walk's start and end.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub version: u32,
    pub bundle: String,
    pub ending: Ending,
    /// The screen the walk was on (its index in the walk) when it ended.
    pub screen: u32,
}

pub fn outcome(bundle: &str, ending: Ending, screen: u32) -> Outcome {
    Outcome { version: VERSION, bundle: bundle.to_string(), ending, screen }
}

/// Per-bundle counts: started, completed, skipped.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tally {
    pub started: u64,
    pub completed: u64,
    pub skipped: u64,
}

/// Folds outcome records into per-bundle counts, current version only.
pub fn tally(records: &[Outcome]) -> BTreeMap<String, Tally> {
    let mut counts: BTreeMap<String, Tally> = BTreeMap::new();
    for record in records.iter().filter(|record| record.version == VERSION) {
        let entry = counts.entry(record.bundle.clone()).or_default();
        match record.ending {
            Ending::Started => entry.started += 1,
            Ending::Completed => entry.completed += 1,
            Ending::Skipped => entry.skipped += 1,
        }
    }
    counts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_split_ships_off_so_everyone_gets_todays_walk() {
        assert!(SLOTS.iter().all(|slot| slot.split_permille == 0));
        for key in ["", "a", "install-1", "5f0c"] {
            let b = bundle(key);
            assert_eq!(b.id, "wb1-000000");
            assert_eq!(b.arms["screen"], "preview");
        }
    }

    #[test]
    fn a_split_is_stable_per_install_and_near_its_share() {
        let slots = [Slot { id: "trust", arms: &["rows", "cards"], split_permille: 500 }];
        let first = bundle_for(&slots, "install-42");
        assert_eq!(first, bundle_for(&slots, "install-42"));
        let challengers = (0..10_000)
            .filter(|i| bundle_for(&slots, &format!("install-{i}")).arms["trust"] == "cards")
            .count();
        assert!((4_700..=5_300).contains(&challengers), "{challengers}");
    }

    #[test]
    fn slots_split_independently() {
        let slots = [
            Slot { id: "a", arms: &["x", "y"], split_permille: 500 },
            Slot { id: "b", arms: &["x", "y"], split_permille: 500 },
        ];
        let ids: std::collections::BTreeSet<String> =
            (0..400).map(|i| bundle_for(&slots, &format!("k{i}")).id).collect();
        assert_eq!(ids.len(), 4, "{ids:?}");
    }

    #[test]
    fn tally_counts_per_bundle_and_drops_old_versions() {
        let mut records = vec![
            outcome("wb1-000000", Ending::Started, 0),
            outcome("wb1-000000", Ending::Completed, 3),
            outcome("wb1-001000", Ending::Started, 0),
            outcome("wb1-001000", Ending::Skipped, 1),
        ];
        records.push(Outcome { version: 0, ..outcome("wb1-000000", Ending::Skipped, 0) });
        let counts = tally(&records);
        assert_eq!(counts["wb1-000000"], Tally { started: 1, completed: 1, skipped: 0 });
        assert_eq!(counts["wb1-001000"], Tally { started: 1, completed: 0, skipped: 1 });
    }

    #[test]
    fn outcome_record_round_trips() {
        let json = serde_json::to_string(&outcome("wb1-000000", Ending::Completed, 3)).unwrap();
        assert_eq!(json, r#"{"version":1,"bundle":"wb1-000000","ending":"completed","screen":3}"#);
        assert_eq!(
            serde_json::from_str::<Outcome>(&json).unwrap(),
            outcome("wb1-000000", Ending::Completed, 3)
        );
    }
}
