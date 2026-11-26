//! Needs you banners: which marked tabs post a banner and which banners are
//! withdrawn when the marks change, the tab a banner names, and the banners
//! an earlier launch left in Notification Center.
//!
//! One banner per request: its id is [`BANNER_PREFIX`] and the mark's tab id
//! (a new request on a tab comes with a new id). The app sends the marks' tab
//! ids in its order and gets indices into them back, so it keeps its items.

use std::collections::HashSet;

use serde::Serialize;

/// The prefix of a Needs you banner's id.
pub const BANNER_PREFIX: &str = "cmux-attention.";
/// The longest tab id (in UTF-8 bytes) a banner names.
pub const MAX_TAB_BYTES: usize = 256;

/// The banner id of the mark on `tab`.
pub fn banner_id(tab: &str) -> String {
    format!("{BANNER_PREFIX}{tab}")
}

/// What changed in the marked tabs since the last list.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Changes {
    /// Indices into the current marks whose banner posts: a new mark, or a
    /// new request on a marked tab.
    pub post: Vec<usize>,
    /// Banner ids withdrawn: a mark that cleared or was replaced, in the
    /// previous list's order.
    pub withdraw: Vec<String>,
}

/// The changes from `previous` to `current` (tab ids). `previous` none is the
/// first list of this launch: marks made before it post nothing, as
/// notifications that arrived before launch do not.
pub fn changes(previous: Option<&[String]>, current: &[String]) -> Changes {
    let Some(previous) = previous else {
        return Changes::default();
    };
    let before: HashSet<&str> = previous.iter().map(String::as_str).collect();
    let now: HashSet<&str> = current.iter().map(String::as_str).collect();
    Changes {
        post: current
            .iter()
            .enumerate()
            .filter(|(_, tab)| !before.contains(tab.as_str()))
            .map(|(index, _)| index)
            .collect(),
        withdraw: previous
            .iter()
            .filter(|tab| !now.contains(tab.as_str()))
            .map(|tab| banner_id(tab))
            .collect(),
    }
}

/// Indices into `current` whose banner posts. `eligible` (the watch's
/// current-launch requests, per machine) may hold a request seen while the
/// tree was unready, so it is not diffed away: with it, every current mark it
/// holds posts; without it, [`changes`]' posts.
pub fn posts(
    previous: Option<&[String]>,
    current: &[String],
    eligible: Option<&[String]>,
) -> Vec<usize> {
    let Some(eligible) = eligible else {
        return changes(previous, current).post;
    };
    let eligible: HashSet<&str> = eligible.iter().map(String::as_str).collect();
    current
        .iter()
        .enumerate()
        .filter(|(_, tab)| eligible.contains(tab.as_str()))
        .map(|(index, _)| index)
        .collect()
}

/// The tab a Needs you banner names; none for any other banner, an empty tab
/// or one longer than [`MAX_TAB_BYTES`].
pub fn tab(banner: &str) -> Option<&str> {
    banner.strip_prefix(BANNER_PREFIX).filter(|tab| !tab.is_empty() && tab.len() <= MAX_TAB_BYTES)
}

/// The Needs you banners Notification Center still shows (`retained`) that
/// this launch did not post (`current_launch`), in `retained`'s order. Asked
/// after the center answers, with the latest set, so a concurrent new banner
/// is never withdrawn.
pub fn stale(retained: &[String], current_launch: &[String]) -> Vec<String> {
    let current: HashSet<&str> = current_launch.iter().map(String::as_str).collect();
    retained
        .iter()
        .filter(|id| id.starts_with(BANNER_PREFIX) && !current.contains(id.as_str()))
        .cloned()
        .collect()
}

#[cfg(test)]
#[path = "desktop_attention_tests.rs"]
mod tests;
