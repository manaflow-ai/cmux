//! Read-backs the engine does once an action settled
//! ([`crate::desktop::ActionOutcome::expect`]): posted keys and scroll
//! events land a little after they are posted, and an effect read back at
//! once can still be undone by the app a moment later (a field that
//! reformats or rejects a value, a list that reselects), so every confirmed
//! result is read again after the settle too.

use std::collections::VecDeque;

use super::ax::Ax;
use super::sys::CFRange;
use crate::desktop::Expect;

/// Read-backs kept at most (the engine reads each one once, right after the
/// action; older ones are dropped).
const KEPT: usize = 8;

/// How far up from the element under a scroll the scroll area is looked for.
const SCROLL_AREA_DEPTH: usize = 12;

/// One scroll bar of a scrolled view: its value before and the way it must
/// move (+1 toward the end: down or right; -1 toward the start).
pub(super) struct Bar {
    pub(super) el: Ax,
    pub(super) before: Option<f64>,
    pub(super) sign: f64,
}

pub(super) enum Check {
    /// `text` was typed into `el`: more of it is in the value than before.
    Text { el: Ax, before: String, text: String },
    /// The scrolled view's bars moved the way the scroll asked.
    Scroll { bars: Vec<Bar> },
    /// All of `el`'s text is selected.
    SelectAll { el: Ax },
    /// `el`'s value reads `wanted` (text, or a number within `tolerance`).
    Value { el: Ax, wanted: String, tolerance: f64 },
    /// `el`'s selected text range is `range`.
    Range { el: Ax, range: CFRange },
    /// `row` is selected, and the only one.
    Selected { row: Ax },
    /// A secure field holds `count` characters.
    Length { el: Ax, count: f64 },
}

#[derive(Default)]
pub(super) struct Checks {
    next: u64,
    pending: VecDeque<(u64, Check)>,
}

impl Checks {
    /// Keeps `check`; `already`: the state matched before the action.
    pub(super) fn add(&mut self, check: Check, already: bool) -> Expect {
        self.next += 1;
        let what = match &check {
            Check::Text { .. } | Check::Length { .. } => "text",
            Check::Scroll { .. } => "scroll",
            Check::SelectAll { .. } | Check::Range { .. } | Check::Selected { .. } => "selection",
            Check::Value { .. } => "value",
        };
        self.pending.push_back((self.next, check));
        while self.pending.len() > KEPT {
            self.pending.pop_front();
        }
        Expect { token: self.next, what: what.into(), already }
    }

    pub(super) fn take(&mut self, token: u64) -> Option<Check> {
        let i = self.pending.iter().position(|(t, _)| *t == token)?;
        self.pending.remove(i).map(|(_, c)| c)
    }
}

/// Times `needle` appears in `hay` (not overlapping).
fn occurrences(hay: &str, needle: &str) -> usize {
    if needle.is_empty() { 0 } else { hay.matches(needle).count() }
}

/// Whether typing `text` shows: the value now holds it more times than
/// before (a value that already held it, or a value the app rewrote without
/// it, does not count).
pub(super) fn typed_shows(before: &str, after: &str, text: &str) -> bool {
    occurrences(after, text) > occurrences(before, text)
}

/// Whether a scroll bar moved the way it was asked to: by more than
/// rounding, with the sign of `sign`.
pub(super) fn moved_toward(before: f64, after: f64, sign: f64) -> bool {
    (after - before) * sign > 1e-6
}

/// Whether a read value matches the wanted one: the same text, or numbers
/// within `tolerance`.
pub(super) fn value_matches(read: &str, wanted: &str, tolerance: f64) -> bool {
    if read == wanted {
        return true;
    }
    match (read.trim().parse::<f64>(), wanted.trim().parse::<f64>()) {
        (Ok(a), Ok(b)) => (a - b).abs() <= tolerance,
        _ => false,
    }
}

impl Check {
    /// A check of text typed into `el` (not a secure field: its value
    /// cannot be read).
    pub(super) fn text(el: &Ax, text: &str) -> Option<Check> {
        let role = el.string("AXRole").unwrap_or_default();
        if !super::roles::is_text_input(&role)
            || super::roles::is_secure(&role, el.string("AXSubrole").as_deref())
            || text.trim().is_empty()
        {
            return None;
        }
        let before = el.value_text().unwrap_or_default();
        Some(Check::Text { el: el.clone(), before, text: text.to_string() })
    }

    /// A check of `text` inserted into `el` whose value was `before`.
    pub(super) fn text_from(el: &Ax, before: &str, text: &str) -> Option<Check> {
        (!text.is_empty()).then(|| Check::Text {
            el: el.clone(),
            before: before.to_string(),
            text: text.to_string(),
        })
    }

    /// A check of a posted scroll at the global point (`x`, `y`) in `pid`'s
    /// app: the bars of the scroll area under it, moving as asked.
    pub(super) fn scroll(pid: i32, x: f64, y: f64, dx: f64, dy: f64) -> Option<Check> {
        let app = Ax::application(pid)?;
        app.set_timeout(0.25);
        let mut el = app.element_at(x, y)?;
        for _ in 0..SCROLL_AREA_DEPTH {
            if el.string("AXRole").as_deref() == Some("AXScrollArea") {
                let bars: Vec<Bar> = [("AXVerticalScrollBar", dy), ("AXHorizontalScrollBar", dx)]
                    .iter()
                    .filter(|(_, lines)| *lines != 0.0)
                    .filter_map(|(a, lines)| {
                        let bar = el.element(a)?;
                        let before = bar.number("AXValue");
                        Some(Bar { el: bar, before, sign: lines.signum() })
                    })
                    .collect();
                return (!bars.is_empty()).then_some(Check::Scroll { bars });
            }
            el = el.element("AXParent")?;
        }
        None
    }

    /// `Some(true)`: the effect shows; `Some(false)`: it does not; `None`:
    /// unreadable.
    pub(super) fn holds(&self) -> Option<bool> {
        match self {
            Check::Text { el, before, text } => {
                let after = el.value_text()?;
                Some(typed_shows(before, &after, text))
            }
            Check::Scroll { bars } => {
                let mut read = false;
                for bar in bars {
                    let (Some(before), Some(after)) = (bar.before, bar.el.number("AXValue")) else {
                        continue;
                    };
                    read = true;
                    if moved_toward(before, after, bar.sign) {
                        return Some(true);
                    }
                }
                read.then_some(false)
            }
            Check::SelectAll { el } => {
                let n = el.number("AXNumberOfCharacters")?;
                let r = el.selected_range()?;
                Some(n > 0.0 && r.location == 0 && r.length as f64 == n)
            }
            Check::Value { el, wanted, tolerance } => {
                Some(value_matches(&el.value_text()?, wanted, *tolerance))
            }
            Check::Range { el, range } => Some(el.selected_range()? == *range),
            Check::Selected { row } => {
                Some(row.bool("AXSelected") == Some(true) && super::actions::only_selected(row))
            }
            Check::Length { el, count } => Some(el.number("AXNumberOfCharacters")? == *count),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_text_shows_only_when_more_of_it_is_there() {
        assert!(typed_shows("", "Zed", "Zed"));
        assert!(typed_shows("Zed", "ZedZed", "Zed"));
        assert!(!typed_shows("Zed", "Zed", "Zed"));
        assert!(!typed_shows("abc", "abd", "x"));
        assert!(!typed_shows("", "", ""));
    }

    /// Review 9 (7): a scroll down that moved the view up, or not at all,
    /// is not the scroll asked for.
    #[test]
    fn a_scroll_confirms_only_moving_the_way_asked() {
        assert!(moved_toward(0.2, 0.3, 1.0));
        assert!(!moved_toward(0.3, 0.2, 1.0));
        assert!(!moved_toward(0.3, 0.3, 1.0));
        assert!(moved_toward(0.3, 0.2, -1.0));
        assert!(!moved_toward(0.0, 0.0, -1.0));
    }

    #[test]
    fn values_match_as_text_or_within_the_tolerance() {
        assert!(value_matches("abc", "abc", 0.0));
        assert!(!value_matches("abc", "abd", 1.0));
        assert!(value_matches("60.4", "60", 1.0));
        assert!(!value_matches("62", "60", 1.0));
        assert!(value_matches("1", "1.0", 0.0));
    }

    #[test]
    fn checks_are_taken_once_and_bounded() {
        let mut checks = Checks::default();
        let first = checks.add(Check::Scroll { bars: vec![] }, false);
        assert_eq!(first.what, "scroll");
        for _ in 0..KEPT {
            checks.add(Check::Scroll { bars: vec![] }, false);
        }
        assert!(checks.take(first.token).is_none(), "the oldest is dropped");
        let last = checks.add(Check::Scroll { bars: vec![] }, true);
        assert!(last.already);
        assert!(checks.take(last.token).is_some());
        assert!(checks.take(last.token).is_none());
    }
}
