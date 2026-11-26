//! What VoiceOver says when an agent in another chat needs the person, fails
//! or finishes while cmux is in front and no banner shows for it (WCAG 2.2 SC
//! 4.1.3 Status Messages): the kind of an agent notification, and whether an
//! arrival the policy decided is said. The app keeps the localized line, its
//! priority and the announcement itself.

use serde::Serialize;

/// What an agent notification says.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    NeedsYou,
    Failed,
    Finished,
}

/// The kind of an agent notification by its level (`info`, `warning` or
/// `error`), none for any other poster's or an unknown level.
pub fn kind(level: &str, source: Option<&str>) -> Option<Kind> {
    if source != Some("agent") {
        return None;
    }
    match level {
        "info" => Some(Kind::Finished),
        "warning" => Some(Kind::NeedsYou),
        "error" => Some(Kind::Failed),
        _ => None,
    }
}

/// The parts of the policy's decision [`speaks`] reads, and the facts beside it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Said {
    /// The decision rings for it (not muted, not read on sight).
    pub attention: bool,
    /// The decision marks it read at once.
    pub acknowledge: bool,
    /// The decision posts a banner.
    pub desktop: bool,
    /// macOS refuses cmux banners, so a decided banner never shows.
    pub banners_denied: bool,
    pub app_active: bool,
    pub pane_is_viewed: bool,
}

/// Whether an arrival is said: it rings, no banner shows for it, cmux is in
/// front, and its pane is not. A banner that shows is not said again
/// (VoiceOver reads the banner).
pub fn speaks(said: Said) -> bool {
    said.attention
        && !said.acknowledge
        && (!said.desktop || said.banners_denied)
        && said.app_active
        && !said.pane_is_viewed
}

#[cfg(test)]
#[path = "desktop_announce_tests.rs"]
mod tests;
