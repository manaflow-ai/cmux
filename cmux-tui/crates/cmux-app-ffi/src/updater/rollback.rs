//! Going back to a kept build (CmuxNextUpdater's `RollbackDecision`, the pick
//! every drop-back entry point makes through `UpdateDropBack`): which kept
//! build "go back" or "go back to N" means, or why it does not run (decision
//! 2026-10-04: refuse rather than lose data the old build cannot read).
//!
//! The ops (`call`, through `updater::call`):
//!
//! - `rollback.decide` `{kept, build?, running?, stored, teamID?}` →
//!   `{"pick": i}` (the index into `kept`) or `{"refusal": {kind, ...}}`.
//! - `rollback.previous` `{kept, running}` → the index of the build "go back"
//!   means, or null.
//!
//! `kept` is newest first, each `{build, storeSchemas?, teamID?, keptAt?}`
//! (`keptAt` in seconds since 1970; other fields of the app's `KeptVersion`
//! are ignored). The reply names a kept build by its index, so the app keeps
//! its own `KeptVersion` (bundle URL, dates) and reads none back.

use super::{OpError, de};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::cmp::Ordering;
use std::collections::BTreeMap;

/// A kept build, as far as the pick reads it.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Kept {
    pub build: String,
    /// `CmuxStoreSchemas` from its Info.plist: the newest version of each
    /// store it reads. None: the build predates rollback support.
    #[serde(default)]
    pub store_schemas: Option<BTreeMap<String, i64>>,
    #[serde(default, rename = "teamID")]
    pub team_id: Option<String>,
    /// When this Mac kept it; None for a build kept before records.
    #[serde(default)]
    pub kept_at: Option<f64>,
}

/// Why a rollback does not run (`RollbackRefusal`'s cases the pick answers;
/// `index` is the kept build it refused).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Refusal {
    /// No kept build (or not the one asked for).
    NothingKept,
    /// Builds are kept, none older than the running one.
    NothingOlder { running: String },
    /// The kept build has no `CmuxStoreSchemas`.
    PredatesRollback { index: usize },
    /// A store holds a newer format than the kept build reads.
    StoreTooNew { store: String, stored: i64, readable: i64, index: usize },
    /// A store the kept build does not know holds data.
    UnknownStore { store: String, index: usize },
    /// The kept bundle is not signed by this app's team.
    Signature { index: usize },
}

/// `a` is a newer build number than `b`: Foundation's numeric compare
/// (`String.compare(_:options: .numeric)`), digit runs by their value and every
/// other character by its own.
pub fn is_newer(a: &str, b: &str) -> bool {
    numeric_compare(a, b) == Ordering::Greater
}

fn numeric_compare(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(p), Some(q)) if p.is_ascii_digit() && q.is_ascii_digit() => {
                let run = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut digits = String::new();
                    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(c);
                        it.next();
                    }
                    digits.trim_start_matches('0').to_owned()
                };
                let (m, n) = (run(&mut x), run(&mut y));
                let order = m.len().cmp(&n.len()).then_with(|| m.cmp(&n));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(p), Some(q)) => {
                if p != q {
                    return p.cmp(&q);
                }
                x.next();
                y.next();
            }
        }
    }
}

/// The build "go back" means: of the kept builds older than `running` (never
/// one above it), the one kept most recently, which is the build this Mac
/// updated from; builds with no keep date after those with one, the newest
/// number first. On a tie the first listed wins (Swift's `min(by:)`).
pub fn previous(kept: &[Kept], running: &str) -> Option<usize> {
    let before = |a: &Kept, b: &Kept| {
        let (x, y) =
            (a.kept_at.unwrap_or(f64::NEG_INFINITY), b.kept_at.unwrap_or(f64::NEG_INFINITY));
        if x != y { x > y } else { is_newer(&a.build, &b.build) }
    };
    let mut best: Option<usize> = None;
    for (i, k) in kept.iter().enumerate() {
        if !is_newer(running, &k.build) {
            continue;
        }
        if best.is_none_or(|b| before(k, &kept[b])) {
            best = Some(i);
        }
    }
    best
}

/// Picks the rollback target or refuses.
/// - `build`: the build asked for, or None for the previous one ([`previous`]).
/// - `running`: the running build; None only in old callers, which took the
///   newest kept one.
/// - `stored`: the daemon's stored version of every store it has.
/// - `team_id`: this app's signing team.
pub fn decide(
    kept: &[Kept],
    build: Option<&str>,
    running: Option<&str>,
    stored: &BTreeMap<String, i64>,
    team_id: Option<&str>,
) -> Result<usize, Refusal> {
    let picked = match (build, running) {
        (Some(build), _) => kept.iter().position(|k| k.build == build),
        (None, Some(running)) => previous(kept, running),
        (None, None) => (!kept.is_empty()).then_some(0),
    };
    let Some(index) = picked else {
        return Err(match (build, running) {
            (None, Some(running)) if !kept.is_empty() => {
                Refusal::NothingOlder { running: running.to_owned() }
            }
            _ => Refusal::NothingKept,
        });
    };
    let target = &kept[index];
    if team_id.is_none() || target.team_id.as_deref() != team_id {
        return Err(Refusal::Signature { index });
    }
    let Some(readable) = &target.store_schemas else {
        return Err(Refusal::PredatesRollback { index });
    };
    // In key order, so the message names the same store every time.
    for (store, &version) in stored {
        let Some(&reads) = readable.get(store) else {
            return Err(Refusal::UnknownStore { store: store.clone(), index });
        };
        if version > reads {
            return Err(Refusal::StoreTooNew {
                store: store.clone(),
                stored: version,
                readable: reads,
                index,
            });
        }
    }
    Ok(index)
}

/// One `rollback.*` op on its JSON request.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Decide {
        kept: Vec<Kept>,
        #[serde(default)]
        build: Option<String>,
        #[serde(default)]
        running: Option<String>,
        #[serde(default)]
        stored: BTreeMap<String, i64>,
        #[serde(default, rename = "teamID")]
        team_id: Option<String>,
    }
    #[derive(Deserialize)]
    struct Previous {
        kept: Vec<Kept>,
        running: String,
    }
    match op {
        "rollback.decide" => {
            let d: Decide = de(request)?;
            Ok(
                match decide(
                    &d.kept,
                    d.build.as_deref(),
                    d.running.as_deref(),
                    &d.stored,
                    d.team_id.as_deref(),
                ) {
                    Ok(index) => json!({ "pick": index }),
                    Err(refusal) => json!({ "refusal": refusal }),
                },
            )
        }
        "rollback.previous" => {
            let p: Previous = de(request)?;
            Ok(json!(previous(&p.kept, &p.running)))
        }
        _ => Err(OpError::Unknown),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kept(build: &str, at: Option<f64>) -> Kept {
        Kept {
            build: build.into(),
            store_schemas: Some(BTreeMap::from([("sessions".into(), 3)])),
            team_id: Some("T".into()),
            kept_at: at,
        }
    }

    fn stored(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
        pairs.iter().map(|(k, v)| ((*k).into(), *v)).collect()
    }

    #[test]
    fn numeric_compare_reads_digit_runs_by_value() {
        assert!(is_newer("100", "99"));
        assert!(is_newer("0.10.1", "0.9.9"));
        assert!(!is_newer("99", "100"));
        assert!(!is_newer("42", "42"));
        assert!(!is_newer("007", "7"));
        assert!(is_newer("1.2b", "1.2a"));
    }

    #[test]
    fn previous_is_the_most_recently_kept_older_build() {
        let list = [kept("120", Some(10.0)), kept("110", Some(30.0)), kept("100", Some(20.0))];
        // 120 is above the running 115: never picked.
        assert_eq!(previous(&list, "115"), Some(1));
        assert_eq!(previous(&list, "100"), None);
    }

    #[test]
    fn previous_puts_undated_builds_last_newest_number_first() {
        let list = [kept("90", None), kept("95", None), kept("80", Some(1.0))];
        assert_eq!(previous(&list, "100"), Some(2));
        let undated = [kept("90", None), kept("95", None)];
        assert_eq!(previous(&undated, "100"), Some(1));
    }

    #[test]
    fn decide_refuses_with_the_case_the_app_shows() {
        let list = [kept("110", Some(1.0))];
        let none = BTreeMap::new();
        assert_eq!(decide(&[], None, Some("120"), &none, Some("T")), Err(Refusal::NothingKept));
        assert_eq!(
            decide(&list, None, Some("100"), &none, Some("T")),
            Err(Refusal::NothingOlder { running: "100".into() })
        );
        assert_eq!(decide(&list, Some("9"), None, &none, Some("T")), Err(Refusal::NothingKept));
        assert_eq!(
            decide(&list, None, Some("120"), &none, Some("U")),
            Err(Refusal::Signature { index: 0 })
        );
        assert_eq!(
            decide(&list, None, Some("120"), &none, None),
            Err(Refusal::Signature { index: 0 })
        );
        let mut old = list.clone();
        old[0].store_schemas = None;
        assert_eq!(
            decide(&old, None, Some("120"), &none, Some("T")),
            Err(Refusal::PredatesRollback { index: 0 })
        );
        assert_eq!(
            decide(&list, None, Some("120"), &stored(&[("sessions", 4)]), Some("T")),
            Err(Refusal::StoreTooNew {
                store: "sessions".into(),
                stored: 4,
                readable: 3,
                index: 0
            })
        );
        assert_eq!(
            decide(&list, None, Some("120"), &stored(&[("zeta", 1), ("alpha", 1)]), Some("T")),
            Err(Refusal::UnknownStore { store: "alpha".into(), index: 0 })
        );
        assert_eq!(decide(&list, None, Some("120"), &stored(&[("sessions", 3)]), Some("T")), Ok(0));
        // An old caller with no running build takes the newest kept one.
        assert_eq!(decide(&list, None, None, &none, Some("T")), Ok(0));
    }

    #[test]
    fn ops_answer_json() {
        let request = json!({
            "kept": [{"build": "110", "storeSchemas": {"sessions": 3}, "teamID": "T", "keptAt": 1.0,
                      "shortVersion": "0.1", "bundle": "/x"}],
            "running": "120", "stored": {"sessions": 4}, "teamID": "T"
        });
        assert_eq!(
            call("rollback.decide", &request),
            Ok(
                json!({"refusal": {"kind": "storeTooNew", "store": "sessions", "stored": 4, "readable": 3, "index": 0}})
            )
        );
        assert_eq!(call("rollback.previous", &request), Ok(json!(0)));
        assert_eq!(call("rollback.nope", &request), Err(OpError::Unknown));
        assert!(matches!(call("rollback.decide", &json!({})), Err(OpError::Invalid(_))));
    }
}
