//! The rollback target, or why a rollback does not run (decision 2026-10-04:
//! refuse rather than lose data the old build cannot read). The app reads the
//! kept bundles, the stored schemas and the signing teams; this decides.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A kept version as the decision reads it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeptCandidate {
    pub build: String,
    /// `CmuxStoreSchemas`: every store the kept build reads, with the newest
    /// version it reads. None: the build predates rollback support.
    #[serde(default)]
    pub store_schemas: Option<BTreeMap<String, i64>>,
    #[serde(default)]
    pub team_id: Option<String>,
}

/// Why a rollback does not run. `kept` is the index of the kept version.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Refusal {
    /// The running daemon cannot report its stored formats.
    StoresUnknown,
    /// No kept version (or not the one asked for).
    NothingKept,
    /// The kept bundle is not signed by this app's team.
    Signature { kept: usize },
    /// The kept build has no `CmuxStoreSchemas`.
    PredatesRollback { kept: usize },
    /// A store the kept build does not know at all holds data.
    UnknownStore { kept: usize, store: String },
    /// A store holds a newer format than the kept build reads.
    StoreTooNew { kept: usize, store: String, stored: i64, readable: i64 },
}

/// - `kept`: kept versions, newest first.
/// - `build`: the build asked for, or none for the newest kept one.
/// - `stored`: the newest schema each store holds; none when unreadable.
/// - `team_id`: this app's signing team.
pub fn decide(
    kept: &[KeptCandidate],
    build: Option<&str>,
    stored: Option<&BTreeMap<String, i64>>,
    team_id: Option<&str>,
) -> Result<usize, Refusal> {
    let Some(stored) = stored else { return Err(Refusal::StoresUnknown) };
    let index = match build {
        Some(wanted) => kept.iter().position(|candidate| candidate.build == wanted),
        None => (!kept.is_empty()).then_some(0),
    };
    let Some((index, target)) =
        index.and_then(|index| kept.get(index).map(|target| (index, target)))
    else {
        return Err(Refusal::NothingKept);
    };
    if team_id.is_none() || target.team_id.as_deref() != team_id {
        return Err(Refusal::Signature { kept: index });
    }
    let Some(readable) = target.store_schemas.as_ref() else {
        return Err(Refusal::PredatesRollback { kept: index });
    };
    // In key order, so the message names the same store every time.
    for (store, version) in stored {
        let Some(reads) = readable.get(store) else {
            return Err(Refusal::UnknownStore { kept: index, store: store.clone() });
        };
        if version > reads {
            return Err(Refusal::StoreTooNew {
                kept: index,
                store: store.clone(),
                stored: *version,
                readable: *reads,
            });
        }
    }
    Ok(index)
}
