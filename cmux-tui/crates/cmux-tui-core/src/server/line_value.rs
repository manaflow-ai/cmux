//! A connection line's JSON value, parsed at most once on the frame path.
//!
//! Several hooks before the typed decode ask what a line is (a carrier
//! stamp, a `cmux.protocol/2` message, a `cloud.repo.*` frame). Each parsed
//! the whole line into a `Value` of its own, so every legacy request was
//! parsed three times (and one copy of its object made) before its typed
//! decode. They now share this one parse: the same `serde_json::from_str`
//! they ran, so each still gets the same answer.

use serde_json::{Map, Value};
use std::cell::OnceCell;

pub(super) struct LineValue<'a> {
    line: &'a str,
    value: OnceCell<Option<Value>>,
}

impl<'a> LineValue<'a> {
    pub(super) fn new(line: &'a str) -> Self {
        Self { line, value: OnceCell::new() }
    }

    /// The line's value, or `None` when it is not JSON.
    pub(super) fn value(&self) -> Option<&Value> {
        self.value
            .get_or_init(|| {
                #[cfg(test)]
                PARSES.with(|parses| parses.set(parses.get() + 1));
                serde_json::from_str(self.line).ok()
            })
            .as_ref()
    }

    /// The line's members, or `None` when it is not a JSON object.
    pub(super) fn object(&self) -> Option<&Map<String, Value>> {
        self.value()?.as_object()
    }

    /// The line's string `cmd`, if it has one.
    pub(super) fn cmd(&self) -> Option<&str> {
        self.object()?.get("cmd")?.as_str()
    }
}

#[cfg(test)]
thread_local! {
    static PARSES: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// The lines this thread parsed into a `LineValue` so far.
#[cfg(test)]
pub(super) fn parses_for_test() -> u64 {
    PARSES.with(std::cell::Cell::get)
}

#[cfg(test)]
#[path = "line_value_tests.rs"]
mod tests;
