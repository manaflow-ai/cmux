//! The update card the Feed posts after an update (`UpdateFeedPosting`, `UpdateFeedCard`'s posting
//! step): which changes it lists and when it is posted, skipped or waited for.

use crate::json::str_at;
use serde::Serialize;
use serde_json::Value;

/// An app update card.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Card {
    pub subject: &'static str,
    pub from: Option<String>,
    pub to: String,
    pub changes: Vec<String>,
    /// Changes the notes count but do not list.
    pub unlisted: i64,
    /// When (ms since 1970).
    pub at: f64,
}

fn titles(list: Option<&Value>) -> Vec<String> {
    list.and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| str_at(entry, "title"))
        .map(str::to_owned)
        .collect()
}

/// The card of `highlights` (`{version, from_version, items: [{title}], rest: [{title}]|null,
/// more_count}`): `None` with no named change or no version change.
pub fn card(highlights: &Value, at: f64) -> Option<Card> {
    let rest = highlights.get("rest").filter(|rest| rest.is_array());
    let mut changes = titles(highlights.get("items"));
    changes.extend(titles(rest));
    changes.retain(|title| !title.is_empty());
    let version = str_at(highlights, "version").unwrap_or_default();
    let from = str_at(highlights, "from_version").unwrap_or_default();
    if changes.is_empty() || from == version {
        return None;
    }
    Some(Card {
        subject: "app",
        from: (!from.is_empty()).then(|| from.to_owned()),
        to: version.to_owned(),
        changes,
        unlisted: if rest.is_none() {
            highlights.get("more_count").and_then(Value::as_i64).unwrap_or(0)
        } else {
            0
        },
        at,
    })
}

/// What the poster does now.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "step", rename_all = "snake_case")]
pub enum Step {
    /// Not yet known: look again when something changes.
    Wait,
    /// This version's card was posted.
    Done,
    /// The person turned the card off: record `version` as posted.
    Skip {
        version: String,
    },
    Post {
        card: Card,
    },
}

/// The posting step for `highlights` (none yet: wait), the version last `posted` and whether the
/// card is `enabled` (`None`: not known yet).
pub fn step(
    highlights: Option<&Value>,
    posted: Option<&str>,
    enabled: Option<bool>,
    at: f64,
) -> Step {
    let Some(version) = highlights.and_then(|highlights| str_at(highlights, "version")) else {
        return Step::Wait;
    };
    if posted == Some(version) {
        return Step::Done;
    }
    match enabled {
        None => Step::Wait,
        Some(false) => Step::Skip { version: version.to_owned() },
        Some(true) => highlights
            .and_then(|highlights| card(highlights, at))
            .map_or(Step::Wait, |card| Step::Post { card }),
    }
}
