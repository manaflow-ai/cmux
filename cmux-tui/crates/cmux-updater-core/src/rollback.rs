//! Which kept build a rollback goes to, or why it does not run (decision 2026-10-04: refuse
//! rather than lose data the old build cannot read), and where a slower ring sends this Mac
//! (the app's `RollbackDecision` and `RingReturn`).

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::{numeric, version};

/// A build kept for rollback, as the app knows it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Kept {
    pub build: String,
    /// `CmuxStoreSchemas`: every store it reads and the newest version; none predates rollback.
    #[serde(default)]
    pub store_schemas: Option<BTreeMap<String, i64>>,
    #[serde(default)]
    pub team_id: Option<String>,
    /// When this Mac kept it (seconds since 1970); none for a build kept before records.
    #[serde(default)]
    pub kept_at: Option<f64>,
}

/// Why a rollback does not run; `kept` is the target's index.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Refusal {
    NothingKept,
    NothingOlder { running: String },
    PredatesRollback { kept: usize },
    StoreTooNew { store: String, stored: i64, readable: i64, kept: usize },
    UnknownStore { store: String, kept: usize },
    Signature { kept: usize },
}

/// The kept build "go back" means: of those older than `running` (by number, never one above
/// it), the one kept most recently; builds with no keep date after those with one, the newest
/// number first. The first of equals wins (Swift's `min(by:)`).
pub fn previous(kept: &[Kept], running: &str) -> Option<usize> {
    let key = |item: &Kept| item.kept_at.unwrap_or(f64::NEG_INFINITY);
    let comes_first = |a: &Kept, b: &Kept| {
        let (x, y) = (key(a), key(b));
        if x != y { x > y } else { numeric::is_newer(&a.build, &b.build) }
    };
    let mut best: Option<(usize, &Kept)> = None;
    for (index, item) in kept.iter().enumerate() {
        if !numeric::is_newer(running, &item.build) {
            continue;
        }
        match best {
            Some((_, current)) if !comes_first(item, current) => {}
            _ => best = Some((index, item)),
        }
    }
    best.map(|(index, _)| index)
}

/// Picks the rollback target (its index in `kept`, newest first) or refuses.
/// - `build`: the build asked for, else the previous one of `running`, else the newest kept.
/// - `stored`: the daemon's stored version of every store it has.
pub fn decide(
    kept: &[Kept],
    build: Option<&str>,
    running: Option<&str>,
    stored: &BTreeMap<String, i64>,
    team_id: Option<&str>,
) -> Result<usize, Refusal> {
    let picked = match (build, running) {
        (Some(build), _) => kept.iter().position(|item| item.build == build),
        (None, Some(running)) => previous(kept, running),
        (None, None) => (!kept.is_empty()).then_some(0),
    };
    let Some(index) = picked else {
        if let (None, Some(running)) = (build, running)
            && !kept.is_empty()
        {
            return Err(Refusal::NothingOlder { running: running.to_owned() });
        }
        return Err(Refusal::NothingKept);
    };
    let Some(target) = kept.get(index) else { return Err(Refusal::NothingKept) };
    match team_id {
        Some(team) if target.team_id.as_deref() == Some(team) => {}
        _ => return Err(Refusal::Signature { kept: index }),
    }
    let Some(readable) = target.store_schemas.as_ref() else {
        return Err(Refusal::PredatesRollback { kept: index });
    };
    // In store order, so the message names the same store every time.
    for (store, version) in stored {
        let Some(reads) = readable.get(store) else {
            return Err(Refusal::UnknownStore { store: store.clone(), kept: index });
        };
        if version > reads {
            return Err(Refusal::StoreTooNew {
                store: store.clone(),
                stored: *version,
                readable: *reads,
                kept: index,
            });
        }
    }
    Ok(index)
}

/// What picking a slower ring does to the running build.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RingReturn {
    /// The running build is on the ring, or the ring offers a newer one.
    None,
    /// Restart into this kept build (its index), the newest one on the ring.
    GoBack { kept: usize },
    /// Nothing kept on the ring: the running build stays until the ring passes it.
    Waits,
}

/// - `offered`: the versions of the feed's items the ring sees.
/// - `promoted`: builds the canary passed (the Nightly ring's own after they leave the feed).
/// - `pulled`: builds on the feed's pulled list: never a way back.
/// - `kept`: kept builds, newest first.
pub fn ring_return(
    installed_build: &str,
    offered: &[String],
    promoted: &[String],
    pulled: &[String],
    kept: &[String],
) -> RingReturn {
    let pulled: HashSet<&str> = pulled.iter().map(String::as_str).collect();
    let on_ring: HashSet<&str> = offered
        .iter()
        .chain(promoted)
        .map(String::as_str)
        .filter(|build| !pulled.contains(build))
        .collect();
    if on_ring.contains(installed_build) {
        return RingReturn::None;
    }
    if offered.iter().any(|version| version::is_older(installed_build, version)) {
        return RingReturn::None;
    }
    kept.iter()
        .position(|build| {
            on_ring.contains(build.as_str()) && version::is_older(build, installed_build)
        })
        .map_or(RingReturn::Waits, |kept| RingReturn::GoBack { kept })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kept(build: &str, kept_at: Option<f64>) -> Kept {
        Kept {
            build: build.into(),
            store_schemas: Some(BTreeMap::from([("tabs".to_owned(), 3)])),
            team_id: Some("TEAM".into()),
            kept_at,
        }
    }

    fn stored(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
        pairs.iter().map(|(store, version)| ((*store).to_owned(), *version)).collect()
    }

    #[test]
    fn previous_is_the_most_recently_kept_older_build() {
        let list = [
            kept("1210", Some(50.0)),
            kept("1205", Some(10.0)),
            kept("1200", Some(20.0)),
            kept("1190", None),
        ];
        assert_eq!(previous(&list, "1206"), Some(2));
        assert_eq!(previous(&list, "1201"), Some(2));
        assert_eq!(previous(&list, "1195"), Some(3));
        assert_eq!(previous(&list, "1100"), None);
    }

    #[test]
    fn previous_without_dates_takes_the_newest_number() {
        let list = [kept("1190", None), kept("1200", None)];
        assert_eq!(previous(&list, "1300"), Some(1));
    }

    #[test]
    fn decide_picks_or_refuses() {
        let list = [kept("1205", Some(2.0)), kept("1200", Some(1.0))];
        let tabs = stored(&[("tabs", 3)]);
        assert_eq!(decide(&list, None, Some("1210"), &tabs, Some("TEAM")), Ok(0));
        assert_eq!(decide(&list, Some("1200"), Some("1210"), &tabs, Some("TEAM")), Ok(1));
        assert_eq!(decide(&list, None, None, &tabs, Some("TEAM")), Ok(0));
        assert_eq!(decide(&list, Some("9"), None, &tabs, Some("TEAM")), Err(Refusal::NothingKept));
        assert_eq!(decide(&[], None, Some("1"), &tabs, Some("TEAM")), Err(Refusal::NothingKept));
        assert_eq!(
            decide(&list, None, Some("1100"), &tabs, Some("TEAM")),
            Err(Refusal::NothingOlder { running: "1100".into() })
        );
        assert_eq!(
            decide(&list, None, Some("1210"), &tabs, Some("OTHER")),
            Err(Refusal::Signature { kept: 0 })
        );
        assert_eq!(
            decide(&list, None, Some("1210"), &tabs, None),
            Err(Refusal::Signature { kept: 0 })
        );
        assert_eq!(
            decide(&list, None, Some("1210"), &stored(&[("tabs", 4)]), Some("TEAM")),
            Err(Refusal::StoreTooNew { store: "tabs".into(), stored: 4, readable: 3, kept: 0 })
        );
        assert_eq!(
            decide(&list, None, Some("1210"), &stored(&[("zeta", 1), ("feed", 1)]), Some("TEAM")),
            Err(Refusal::UnknownStore { store: "feed".into(), kept: 0 })
        );
        let mut old = list;
        old[0].store_schemas = None;
        assert_eq!(
            decide(&old, None, Some("1210"), &tabs, Some("TEAM")),
            Err(Refusal::PredatesRollback { kept: 0 })
        );
    }

    fn strings(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    #[test]
    fn ring_return_goes_back_waits_or_stays() {
        let offered = strings(&["1200", "1198"]);
        assert_eq!(ring_return("1200", &offered, &[], &[], &[]), RingReturn::None);
        assert_eq!(ring_return("1150", &offered, &[], &[], &[]), RingReturn::None);
        assert_eq!(
            ring_return("1210", &offered, &strings(&["1205"]), &[], &strings(&["1205", "1200"])),
            RingReturn::GoBack { kept: 0 }
        );
        assert_eq!(
            ring_return(
                "1210",
                &offered,
                &strings(&["1205"]),
                &strings(&["1205"]),
                &strings(&["1205", "1200"])
            ),
            RingReturn::GoBack { kept: 1 }
        );
        assert_eq!(ring_return("1210", &offered, &[], &[], &strings(&["1209"])), RingReturn::Waits);
        assert_eq!(ring_return("1205", &offered, &strings(&["1205"]), &[], &[]), RingReturn::None);
    }
}
