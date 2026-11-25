//! Where Computer Use's live preview card sits in its cmux surface, and
//! whether it shows (Leo, 2026-11-22, asked where the preview of the running
//! situation was, and for "the ability to drag it around and" hide it). The daemon keeps it per Computer Use session, so every surface
//! that draws the card (an agent chat's page, a terminal pane's card) reads
//! one answer, and a page that loads again puts the card back where the
//! person left it.
//!
//! - A place is two fractions of the room the surface leaves around the card
//!   (`x`: 0 at the left edge, 1 at the right; `y`: 0 at the top, 1 at the
//!   bottom), so the card stays inside the surface at any size. A new
//!   session's card starts at the top right (1, 0), where it always sat.
//! - `size`: `small` (the card), `large` (the enlarged card) or `full` (the
//!   whole surface).
//! - Hidden, the card's line still goes out once with `hidden: true` (the
//!   surface shows a small chip to bring it back), then its frames stop until
//!   it shows again; showing it sends its newest frame at once.
//!
//! The surfaces send the person's moves as `remote-host-call
//! computer_use.preview {session, x?, y?, size?, hidden?}`; every relayed
//! `computer-use-preview` line carries the place as `card.place {x, y, size}`
//! and `card.hidden`.

use std::collections::HashMap;

use serde_json::{Value, json};

/// The most sessions remembered; the least recently touched goes first.
pub(crate) const MAX_PLACES: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Size {
    Small,
    Large,
    Full,
}

impl Size {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "small" => Some(Self::Small),
            "large" => Some(Self::Large),
            "full" => Some(Self::Full),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Small => "small",
            Self::Large => "large",
            Self::Full => "full",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Place {
    pub(crate) x: f64,
    pub(crate) y: f64,
    pub(crate) size: Size,
    pub(crate) hidden: bool,
}

impl Default for Place {
    /// The top right, small, shown: where the card sat before it could move.
    fn default() -> Self {
        Self { x: 1.0, y: 0.0, size: Size::Small, hidden: false }
    }
}

/// A fraction of the room, clamped into it; None for a value that is no number.
fn fraction(value: &Value) -> Result<Option<f64>, String> {
    match value {
        Value::Null => Ok(None),
        Value::Number(number) => match number.as_f64() {
            Some(x) if x.is_finite() => Ok(Some(x.clamp(0.0, 1.0))),
            _ => Err("computer_use.preview x and y are numbers from 0 to 1".into()),
        },
        _ => Err("computer_use.preview x and y are numbers from 0 to 1".into()),
    }
}

#[derive(Default)]
struct Entry {
    place: Place,
    /// The session's newest card line from the worker (undecorated), so a
    /// move or a show goes out at once with the frame it has.
    last: Option<Value>,
    /// While hidden, the done state of the hidden line that went out last
    /// (None: none went out hidden): a hidden card sends one line, then only
    /// when it turns done.
    sent_hidden: Option<bool>,
    touched: u64,
}

/// The places of the sessions' cards (see the module docs).
#[derive(Default)]
pub(crate) struct PreviewPlaces {
    entries: HashMap<String, Entry>,
    tick: u64,
}

impl PreviewPlaces {
    /// The place of `session`'s card (the default for one never moved).
    #[cfg(test)]
    fn place(&self, session: &str) -> Place {
        self.entries.get(session).map(|entry| entry.place).unwrap_or_default()
    }

    fn entry(&mut self, session: &str) -> &mut Entry {
        self.tick = self.tick.wrapping_add(1);
        let tick = self.tick;
        if !self.entries.contains_key(session) && self.entries.len() >= MAX_PLACES {
            let oldest = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.touched)
                .map(|(key, _)| key.clone());
            if let Some(oldest) = oldest {
                self.entries.remove(&oldest);
            }
        }
        let entry = self.entries.entry(session.to_string()).or_default();
        entry.touched = tick;
        entry
    }

    /// The person moved, resized, hid or showed `session`'s card
    /// (`{x?, y?, size?, hidden?}`; a missing key keeps its value). Returns
    /// the card's line to send now (decorated), when the session has one.
    pub(crate) fn update(
        &mut self,
        session: &str,
        update: &Value,
    ) -> Result<Option<Value>, String> {
        if session.is_empty() || session.len() > 256 {
            return Err("computer_use.preview needs a session".into());
        }
        let x = fraction(update.get("x").unwrap_or(&Value::Null))?;
        let y = fraction(update.get("y").unwrap_or(&Value::Null))?;
        let size = match update.get("size") {
            None | Some(Value::Null) => None,
            Some(value) => Some(
                value
                    .as_str()
                    .and_then(Size::parse)
                    .ok_or("computer_use.preview size is small, large or full")?,
            ),
        };
        let hidden = match update.get("hidden") {
            None | Some(Value::Null) => None,
            Some(Value::Bool(hidden)) => Some(*hidden),
            Some(_) => return Err("computer_use.preview hidden is true or false".into()),
        };
        let entry = self.entry(session);
        let mut place = entry.place;
        if let Some(x) = x {
            place.x = x;
        }
        if let Some(y) = y {
            place.y = y;
        }
        if let Some(size) = size {
            place.size = size;
        }
        if let Some(hidden) = hidden {
            place.hidden = hidden;
        }
        entry.place = place;
        let Some(last) = entry.last.clone() else { return Ok(None) };
        let done = last.pointer("/card/done").and_then(Value::as_bool).unwrap_or(false);
        entry.sent_hidden = place.hidden.then_some(done);
        Ok(Some(decorate(last, place)))
    }

    /// One preview line from the worker: the line to relay (with the card's
    /// place), or None when it only brings a new frame to a hidden card.
    pub(crate) fn relay(&mut self, line: Value) -> Option<Value> {
        let session = line.get("session").and_then(Value::as_str).unwrap_or_default().to_string();
        let has_card = line.get("card").is_some_and(|card| card.is_object());
        if session.is_empty() {
            return Some(line);
        }
        if !has_card {
            // Gone: the place stays for the session's next card.
            if let Some(entry) = self.entries.get_mut(&session) {
                entry.last = None;
                entry.sent_hidden = None;
            }
            return Some(line);
        }
        let done = line.pointer("/card/done").and_then(Value::as_bool).unwrap_or(false);
        let entry = self.entry(&session);
        entry.last = Some(line.clone());
        let place = entry.place;
        if place.hidden {
            // `sent_hidden` is the done state of the hidden line sent last.
            if entry.sent_hidden == Some(done) {
                return None;
            }
            entry.sent_hidden = Some(done);
        } else {
            entry.sent_hidden = None;
        }
        Some(decorate(line, place))
    }
}

/// `line` with its card's place: `card.place {x, y, size}` and `card.hidden`.
pub(crate) fn decorate(mut line: Value, place: Place) -> Value {
    if let Some(card) = line.get_mut("card").and_then(Value::as_object_mut) {
        card.insert("place".into(), json!({"x": place.x, "y": place.y, "size": place.size.name()}));
        card.insert("hidden".into(), json!(place.hidden));
    }
    line
}

#[cfg(test)]
#[path = "computer_use_preview_place_tests.rs"]
mod tests;
