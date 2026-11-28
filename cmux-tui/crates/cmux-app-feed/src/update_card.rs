//! The installed update's Feed card (`UpdateFeedPosting.card`): the changes it lists, the
//! version it came from, and how many it leaves out.

use serde::{Deserialize, Serialize};

/// The `UpdateHighlights` facts the card reads.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Highlights {
    pub version: String,
    #[serde(default)]
    pub from_version: String,
    /// The titles of `items`.
    #[serde(default)]
    pub items: Vec<String>,
    /// The titles of `rest`; nil for a record saved before `rest` existed.
    #[serde(default)]
    pub rest: Option<Vec<String>>,
    #[serde(default)]
    pub more_count: i64,
}

/// The card's content (`UpdateFeedCard` without its subject and time).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Card {
    pub from: Option<String>,
    pub to: String,
    pub changes: Vec<String>,
    pub unlisted: i64,
}

/// The card, or nil when it has no changes to list yet (its notes are still loading) or names no
/// update (the version it came from is this one). A record saved before `rest` existed counts
/// the changes it left out (`more_count`).
pub fn card(highlights: &Highlights) -> Option<Card> {
    let changes: Vec<String> = highlights
        .items
        .iter()
        .chain(highlights.rest.iter().flatten())
        .filter(|title| !title.is_empty())
        .cloned()
        .collect();
    if changes.is_empty() || highlights.from_version == highlights.version {
        return None;
    }
    Some(Card {
        from: (!highlights.from_version.is_empty()).then(|| highlights.from_version.clone()),
        to: highlights.version.clone(),
        changes,
        unlisted: if highlights.rest.is_none() { highlights.more_count } else { 0 },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(items: &[&str], rest: Option<&[&str]>, more: i64) -> Highlights {
        Highlights {
            version: "1.2.0".into(),
            from_version: "1.1.0".into(),
            items: items.iter().map(|s| (*s).to_owned()).collect(),
            rest: rest.map(|r| r.iter().map(|s| (*s).to_owned()).collect()),
            more_count: more,
        }
    }

    #[test]
    fn lists_items_then_rest_and_drops_empty_titles() {
        let c = card(&h(&["A", ""], Some(&["B"]), 5)).unwrap();
        assert_eq!(
            c,
            Card {
                from: Some("1.1.0".into()),
                to: "1.2.0".into(),
                changes: vec!["A".into(), "B".into()],
                unlisted: 0
            }
        );
    }

    #[test]
    fn old_record_counts_what_it_left_out() {
        assert_eq!(card(&h(&["A"], None, 3)).unwrap().unlisted, 3);
    }

    #[test]
    fn no_card_without_changes_or_update() {
        assert_eq!(card(&h(&[], None, 4)), None);
        assert_eq!(card(&h(&[""], Some(&[""]), 0)), None);
        let mut same = h(&["A"], None, 0);
        same.from_version = "1.2.0".into();
        assert_eq!(card(&same), None);
    }

    #[test]
    fn empty_from_version_is_no_from() {
        let mut fresh = h(&["A"], None, 0);
        fresh.from_version = String::new();
        assert_eq!(card(&fresh).unwrap().from, None);
    }
}
