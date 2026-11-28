//! Where the saved back/forward entries of a relaunched tab sit around the engine's own list
//! (Swift `BrowserRestoredHistory.session(around:shown:)`, `merged(with:shown:)` and
//! `position(of:)` in `CmuxNextBrowserCore`).
//!
//! The saved entries `back` come before the engine's first entry and `forward` right after it:
//! a step back into the saved entries replaces the engine's first entry, so the entries passed
//! over sit between it and the engine's next one. Pure: Swift reports counts and which of the
//! engine's entries have a URL, and gets back where each entry of the answer comes from; it
//! keeps the entries themselves (URLs, titles, scroll positions).
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_restored_history_position` | `{back, forward, current}` | the index of the engine's current entry |
//! | `browser_rules_restored_history_merged` | `{back, forward, count, current}` | `{slots, current}` |
//! | `browser_rules_restored_history_session` | `{back, forward, hasUrl, current}` | `{slots, current}` |
//!
//! A slot is `{source, index}`: `source` is `back`, `forward` (the saved lists) or `own` (the
//! engine's list), `index` the place in that list.

use crate::ops::OpError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Which list an entry of the answer comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    Back,
    Own,
    Forward,
}

/// One entry of the answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Slot {
    pub source: Source,
    pub index: usize,
}

/// The index of the engine's current entry (`own_current`) among the merged entries.
pub fn position(back: usize, forward: usize, own_current: i64) -> usize {
    if own_current == 0 { back } else { back + forward + own_current.max(0) as usize }
}

/// Every entry in order: `back`, the engine's first, `forward`, the engine's others.
fn arranged(back: usize, forward: usize, own_count: usize) -> Vec<Slot> {
    let slot = |source, index| Slot { source, index };
    let mut slots: Vec<Slot> = (0..back).map(|index| slot(Source::Back, index)).collect();
    if own_count > 0 {
        slots.push(slot(Source::Own, 0));
    }
    slots.extend((0..forward).map(|index| slot(Source::Forward, index)));
    slots.extend((1..own_count).map(|index| slot(Source::Own, index)));
    slots
}

/// The entries for the Back and Forward menus and where the engine's current one sits.
pub fn merged(
    back: usize,
    forward: usize,
    own_count: usize,
    own_current: i64,
) -> (Vec<Slot>, usize) {
    (arranged(back, forward, own_count), position(back, forward, own_current))
}

/// The entries to save: the same order, without the engine's entries that have no URL (nothing
/// committed). `current` is the saved entry the engine's current one is, kept in range.
pub fn session(
    back: usize,
    forward: usize,
    has_url: &[bool],
    own_current: i64,
) -> (Vec<Slot>, usize) {
    let all = arranged(back, forward, has_url.len());
    let kept = |slot: &Slot| slot.source != Source::Own || has_url[slot.index];
    let before =
        all.iter().take(position(back, forward, own_current)).filter(|slot| kept(slot)).count();
    let slots: Vec<Slot> = all.into_iter().filter(|slot| kept(slot)).collect();
    let current = before.min(slots.len().saturating_sub(1));
    (slots, current)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    #[serde(default)]
    back: usize,
    #[serde(default)]
    forward: usize,
    #[serde(default)]
    count: usize,
    #[serde(default)]
    has_url: Vec<bool>,
    #[serde(default)]
    current: i64,
}

fn answer((slots, current): (Vec<Slot>, usize)) -> Value {
    json!({"slots": slots, "current": current})
}

/// Answers the `browser_rules_restored_history_*` ops; `None` for any other op.
pub fn call(op: &str, request: Value) -> Option<Result<Value, OpError>> {
    let parse = |request: Value| {
        serde_json::from_value::<Request>(request)
            .map_err(|error| OpError::Invalid(error.to_string()))
    };
    let answer = match op {
        "browser_rules_restored_history_position" => {
            parse(request).map(|r| json!(position(r.back, r.forward, r.current)))
        }
        "browser_rules_restored_history_merged" => {
            parse(request).map(|r| answer(merged(r.back, r.forward, r.count, r.current)))
        }
        "browser_rules_restored_history_session" => {
            parse(request).map(|r| answer(session(r.back, r.forward, &r.has_url, r.current)))
        }
        _ => return None,
    };
    Some(answer)
}
