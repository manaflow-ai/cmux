//! What a feed offers this Mac, as Sparkle decides it: an item is offered only when
//! `minimumSystemVersion <= macOS <= maximumSystemVersion`, and the newest offered item (by
//! Sparkle's version order) wins. A newer item this macOS cannot run is reported, so the app
//! can say which macOS it needs.

use serde::{Deserialize, Serialize};

use crate::system_version::SystemVersion;
use crate::version::is_older;

/// What selection needs of an item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub version: String,
    #[serde(default)]
    pub minimum_system_version: Option<SystemVersion>,
    #[serde(default)]
    pub maximum_system_version: Option<SystemVersion>,
}

impl Candidate {
    fn supports(&self, system: SystemVersion) -> bool {
        self.minimum_system_version.is_none_or(|minimum| system >= minimum)
            && self.maximum_system_version.is_none_or(|maximum| system <= maximum)
    }
}

/// The decision; items are named by their index in the list asked about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Outcome {
    /// A newer build this macOS can run.
    UpdateAvailable { item: usize },
    /// Nothing newer this macOS can run, and nothing newer at all; `latest` is the newest item
    /// this macOS can run, if any.
    UpToDate { latest: Option<usize> },
    /// A newer build exists but needs a newer macOS (`required`: its minimum, else this one).
    #[serde(rename = "requires_newer_macos")]
    RequiresNewerSystem { item: usize, required: SystemVersion },
}

/// The newest of `items` by Sparkle's order; the first of equals (Swift's `max(by:)`).
fn newest<'a>(
    items: impl Iterator<Item = (usize, &'a Candidate)>,
) -> Option<(usize, &'a Candidate)> {
    let mut best: Option<(usize, &'a Candidate)> = None;
    for (index, item) in items {
        match best {
            Some((_, current)) if !is_older(&current.version, &item.version) => {}
            _ => best = Some((index, item)),
        }
    }
    best
}

/// Picks what `candidates` offer a Mac running `system` on build `current_build`.
pub fn select(candidates: &[Candidate], current_build: &str, system: SystemVersion) -> Outcome {
    let newest_any = newest(candidates.iter().enumerate());
    let newest_compatible =
        newest(candidates.iter().enumerate().filter(|(_, item)| item.supports(system)));
    if let Some((index, item)) = newest_compatible {
        if is_older(current_build, &item.version) {
            return Outcome::UpdateAvailable { item: index };
        }
    }
    if let Some((index, item)) = newest_any {
        if is_older(current_build, &item.version) && !item.supports(system) {
            return Outcome::RequiresNewerSystem {
                item: index,
                required: item.minimum_system_version.unwrap_or(system),
            };
        }
    }
    Outcome::UpToDate { latest: newest_compatible.map(|(index, _)| index) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(version: &str, minimum: Option<(i64, i64)>) -> Candidate {
        Candidate {
            version: version.into(),
            minimum_system_version: minimum
                .map(|(major, minor)| SystemVersion::new(major, minor, 0)),
            maximum_system_version: None,
        }
    }

    const TAHOE: SystemVersion = SystemVersion { major: 26, minor: 0, patch: 0 };
    const SEQUOIA: SystemVersion = SystemVersion { major: 15, minor: 6, patch: 0 };

    #[test]
    fn the_newest_runnable_build_is_offered() {
        let items = [item("1203", None), item("1205", Some((26, 0))), item("1204", None)];
        assert_eq!(select(&items, "1202", TAHOE), Outcome::UpdateAvailable { item: 1 });
        assert_eq!(select(&items, "1202", SEQUOIA), Outcome::UpdateAvailable { item: 2 });
    }

    #[test]
    fn a_newer_build_for_a_newer_macos_is_named() {
        let items = [item("1205", Some((26, 0))), item("1201", None)];
        assert_eq!(
            select(&items, "1202", SEQUOIA),
            Outcome::RequiresNewerSystem { item: 0, required: TAHOE }
        );
    }

    #[test]
    fn a_maximum_alone_requires_this_macos() {
        let items = [Candidate {
            version: "9".into(),
            minimum_system_version: None,
            maximum_system_version: Some(SystemVersion::new(15, 0, 0)),
        }];
        assert_eq!(
            select(&items, "1", TAHOE),
            Outcome::RequiresNewerSystem { item: 0, required: TAHOE }
        );
    }

    #[test]
    fn up_to_date_names_the_newest_runnable() {
        let items = [item("1202", None), item("1200", None)];
        assert_eq!(select(&items, "1202", TAHOE), Outcome::UpToDate { latest: Some(0) });
        assert_eq!(select(&[], "1202", TAHOE), Outcome::UpToDate { latest: None });
    }

    #[test]
    fn equal_versions_keep_the_first() {
        let items = [item("1.0", None), item("1.0.0", None)];
        assert_eq!(select(&items, "0.9", TAHOE), Outcome::UpdateAvailable { item: 0 });
    }

    #[test]
    fn the_outcome_reads_as_the_app_names_it() {
        assert_eq!(
            serde_json::to_value(Outcome::RequiresNewerSystem { item: 2, required: TAHOE })
                .unwrap(),
            serde_json::json!({"kind": "requires_newer_macos", "item": 2, "required": {"major": 26, "minor": 0, "patch": 0}})
        );
        assert_eq!(
            serde_json::to_value(Outcome::UpToDate { latest: None }).unwrap(),
            serde_json::json!({"kind": "up_to_date", "latest": null})
        );
    }
}
