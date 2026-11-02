//! What a feed offers this Mac, as Sparkle decides it: an item is offered only
//! when `minimumSystemVersion <= macOS <= maximumSystemVersion`, and the newest
//! offered item wins (Sparkle's version order).

use crate::appcast::AppcastItem;
use crate::version::{SystemVersion, is_older};
use serde::Serialize;

/// The selection, naming items by their index in the list it was given.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Outcome {
    /// A newer build this macOS can run.
    UpdateAvailable { item: usize },
    /// Nothing newer this macOS can run, and nothing newer at all. `latest`
    /// is the newest item this macOS can run, if any.
    UpToDate { latest: Option<usize> },
    /// A newer build exists but needs a newer macOS; `required` is its minimum
    /// (this Mac's system when the item names none).
    #[serde(rename = "requires_newer_macos")]
    RequiresNewerSystem { item: usize, required: SystemVersion },
}

/// The first of the newest items (Swift's `max(by:)` keeps the first of equals).
fn newest<'a>(
    items: impl Iterator<Item = (usize, &'a AppcastItem)>,
) -> Option<(usize, &'a AppcastItem)> {
    items.fold(None, |best, candidate| match best {
        Some((_, current)) if !is_older(&current.version, &candidate.1.version) => best,
        _ => Some(candidate),
    })
}

/// `AppcastSelector.select(from:currentBuild:system:)`.
pub fn select(items: &[AppcastItem], current_build: &str, system: SystemVersion) -> Outcome {
    let newest_any = newest(items.iter().enumerate());
    let newest_compatible =
        newest(items.iter().enumerate().filter(|(_, item)| item.supports(system)));
    if let Some((index, item)) = newest_compatible
        && is_older(current_build, &item.version)
    {
        return Outcome::UpdateAvailable { item: index };
    }
    if let Some((index, item)) = newest_any
        && is_older(current_build, &item.version)
        && !item.supports(system)
    {
        return Outcome::RequiresNewerSystem {
            item: index,
            required: item.minimum_system_version.unwrap_or(system),
        };
    }
    Outcome::UpToDate { latest: newest_compatible.map(|(index, _)| index) }
}
