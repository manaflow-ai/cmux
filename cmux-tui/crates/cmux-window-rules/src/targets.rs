//! How an action finds what it acts on: the one ordinal pick ("9 means the
//! last", Cmd-9), the one wrap-around step (next and previous), the one "id,
//! then folded name" lookup, the explicit target an invocation names, the
//! tab list a tab group action names, and the one table from a handler's
//! thrown failure to the refusal it shows. Whether an action is available
//! (its reason, then its daemon's capability) stays in the app: menus and
//! the palette ask it per row, on every validation. The app reads its models and its
//! invocation, asks here, and refuses with the localized reason or acts.

use serde::{Deserialize, Serialize};

/// What a number past the end of the list picks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PastEnd {
    /// The last one (tabs, spaces): 9 and above are the last; a number past
    /// the end is the last too.
    #[default]
    Clamp,
    /// Nothing (screens): 9 is the last; any other number past the end
    /// picks nothing, and the app says how many there are.
    Refuse,
}

/// The index `number` (1-based, as Cmd-1 to Cmd-9 name them) picks among
/// `count`, or None (no item, a number below 1, or past the end under
/// [`PastEnd::Refuse`]).
pub fn ordinal(number: i64, count: usize, past_end: PastEnd) -> Option<usize> {
    if count == 0 || number < 1 {
        return None;
    }
    let last = count.checked_sub(1)?;
    let wanted = usize::try_from(number.checked_sub(1)?).ok()?;
    match past_end {
        PastEnd::Clamp if number >= 9 => Some(last),
        PastEnd::Clamp => Some(wanted.min(last)),
        PastEnd::Refuse if number == 9 => Some(last),
        PastEnd::Refuse => (wanted < count).then_some(wanted),
    }
}

/// The index `offset` steps from `index` among `count`, wrapping around both
/// ends (next and previous). None for an empty list.
pub fn step(index: usize, offset: i64, count: usize) -> Option<usize> {
    let count = i64::try_from(count).ok().filter(|&count| count > 0)?;
    let index = i64::try_from(index).ok()?;
    usize::try_from(index.checked_add(offset)?.checked_rem_euclid(count)?).ok()
}

/// One candidate of a named lookup: its id and its name as the app folds it
/// (case and diacritics, Foundation's folding, which stays in the app).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Named {
    pub id: String,
    pub folded: String,
}

/// The candidate `text` names: the one whose id is `text`, else the first
/// whose folded name is `folded` (the CLI's `--arg space=Work`). None when
/// nothing matches (the app refuses it as not found).
pub fn named(text: &str, folded: &str, candidates: &[Named]) -> Option<usize> {
    candidates
        .iter()
        .position(|candidate| candidate.id == text)
        .or_else(|| candidates.iter().position(|candidate| candidate.folded == folded))
}

/// An object an invocation names (`ActionTargetRef`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TargetRef {
    pub kind: String,
    pub id: String,
}

/// The explicit target among `candidates` (the invocation's target, then its
/// arguments, in that order; None where one is absent): the first of one of
/// `kinds`. An explicit target that does not resolve is refused by the app,
/// never replaced by the focused object.
pub fn explicit(candidates: &[Option<TargetRef>], kinds: &[String]) -> Option<usize> {
    candidates
        .iter()
        .position(|candidate| candidate.as_ref().is_some_and(|target| kinds.contains(&target.kind)))
}

/// The tab ids a `tabs` argument names: comma-separated, trimmed, empty
/// entries left out.
pub fn tab_ids(list: &str) -> Vec<String> {
    list.split(',').map(trim_spaces).filter(|id| !id.is_empty()).map(str::to_owned).collect()
}

/// `text` without leading and trailing spaces and tabs (Foundation's
/// `.whitespaces`: line breaks stay).
pub fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

/// Why the tabs a `tabs` argument found cannot act together.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TabsRefusal {
    /// The list named no tab.
    NoTab,
    /// The tabs sit in more than one pane.
    TabsInDifferentPanes,
}

/// Whether tabs in `panes` (each found tab's pane, in list order) act
/// together: a tab group action takes tabs of one pane.
pub fn one_pane(panes: &[String]) -> Result<(), TabsRefusal> {
    let first = panes.first().ok_or(TabsRefusal::NoTab)?;
    if panes.iter().all(|pane| pane == first) {
        Ok(())
    } else {
        Err(TabsRefusal::TabsInDifferentPanes)
    }
}

/// What a handler threw, as its refusal reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Failure {
    /// An explicit target that names nothing (`not_found` on the socket).
    pub not_found: bool,
    /// A navigation or focus move with nowhere to go (R136).
    pub quiet: bool,
}

/// How a refusal reaches the person and the caller.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    /// `not_found` for a caller; shown like any refusal.
    NotFound,
    /// The caller gets the reason; a keyboard or menu run shows nothing.
    Quiet,
    /// Shown, and returned to a caller.
    Shown,
}

/// The refusal a thrown failure becomes: not found first, then quiet.
pub fn refusal(failure: Failure) -> Refusal {
    if failure.not_found {
        Refusal::NotFound
    } else if failure.quiet {
        Refusal::Quiet
    } else {
        Refusal::Shown
    }
}

#[cfg(test)]
#[path = "targets_tests.rs"]
mod tests;
