//! The Chief home directory: which homes a build routes agent tabs into (CmuxNextHomeEngine
//! `ChiefHomeDirectory.swift`). Swift lists the directories; these ops decide.

use super::build::Identity;
use super::home::tab_host;
use super::path::{join, last_component, parent, standardized};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// `ChiefHomeDirectory.homeParents(of:root:)`: the home's parent, the Chief root and its `isolated/`.
pub fn home_parents(home_root: &str, chief_root: &str) -> Vec<String> {
    let mut seen = BTreeSet::new();
    [parent(home_root), chief_root.to_owned(), join(chief_root, "isolated")]
        .into_iter()
        .filter(|path| seen.insert(standardized(path)))
        .collect()
}

/// `ChiefHomeDirectory.admission(of:devBuild:)`: a DEV build admits only its own home; every other build
/// every home but a DEV or tagged staging build's.
pub fn admits(home_root: &str, dev_build: bool, root: &str) -> bool {
    let own = standardized(home_root) == standardized(root);
    if dev_build {
        return own;
    }
    own || !Identity::new(Some(last_component(root)), None).needs_build_space()
}

/// One parent's listing: its non-hidden directories and each one's `c/` directories.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Listing {
    pub parent: String,
    /// The parent's directory names, as listed.
    #[serde(default)]
    pub directories: Vec<String>,
    /// For a directory name, the directory names in its `c/`.
    #[serde(default)]
    pub brains: BTreeMap<String, Vec<String>>,
}

/// `ChiefHomeDirectory.Found`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Found {
    pub root: String,
    pub acpmux_owner: String,
}

/// `ChiefHomeDirectory.homes(in:)`: every home and named Chief brain by its tab host; the first one wins.
/// Hidden names are skipped here as Swift's `directories(in:)` does.
pub fn homes(listings: &[Listing]) -> BTreeMap<String, Found> {
    let mut homes = BTreeMap::new();
    let shown = |name: &&String| !name.starts_with('.');
    for listing in listings {
        for name in listing.directories.iter().filter(shown) {
            let root = join(&listing.parent, name);
            homes
                .entry(tab_host(&root))
                .or_insert_with(|| Found { root: root.clone(), acpmux_owner: root.clone() });
            let brains = listing.brains.get(name).map(Vec::as_slice).unwrap_or_default();
            let c = join(&root, "c");
            for brain in brains.iter().filter(shown) {
                let brain = join(&c, brain);
                homes
                    .entry(tab_host(&brain))
                    .or_insert_with(|| Found { root: brain, acpmux_owner: root.clone() });
            }
        }
    }
    homes
}

/// `ChiefHomeDirectory.owned(home:owner:)`'s inputs: what Swift read from the locks and the mark.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnedInputs {
    pub home_root: String,
    pub owner_root: String,
    #[serde(default)]
    pub home_host_runs: bool,
    #[serde(default)]
    pub owner_host_runs: bool,
    /// The owner's `state/host.acpmux` second line.
    #[serde(default)]
    pub owner_marked_home: Option<String>,
}

/// `ChiefHomeDirectory.owned`: whether a running host already holds the home's acpmux sessions.
pub fn owned(inputs: &OwnedInputs) -> bool {
    if inputs.home_host_runs {
        return true;
    }
    if inputs.owner_root == inputs.home_root || !inputs.owner_host_runs {
        return false;
    }
    let owner_acpmux = join(&inputs.owner_root, "acpmux");
    inputs.owner_marked_home.as_deref().is_none_or(|marked| marked == owner_acpmux)
}
