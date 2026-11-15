//! Read-backs the engine asks for once an action settled
//! ([`crate::desktop::ActionOutcome::expect`]): posted keys and scroll
//! events land a little after they are posted, so the route cannot read its
//! effect back at once the way an AX press or set can.

use std::collections::VecDeque;

use super::ax::Ax;
use crate::desktop::Expect;

/// Read-backs kept at most (the engine reads each one once, right after the
/// action; older ones are dropped).
const KEPT: usize = 8;

/// How far up from the element under a scroll the scroll area is looked for.
const SCROLL_AREA_DEPTH: usize = 12;

pub(super) enum Check {
    /// `text` was typed into `el`: more of it is in the value than before.
    Text { el: Ax, before: String, text: String },
    /// The scroll bars of the scrolled view and their values before.
    Scroll { bars: Vec<(Ax, Option<String>)> },
    /// All of `el`'s text is selected.
    SelectAll { el: Ax },
}

#[derive(Default)]
pub(super) struct Checks {
    next: u64,
    pending: VecDeque<(u64, Check)>,
}

impl Checks {
    pub(super) fn add(&mut self, check: Check) -> Expect {
        self.next += 1;
        let what = match &check {
            Check::Text { .. } => "text",
            Check::Scroll { .. } => "scroll",
            Check::SelectAll { .. } => "selection",
        };
        self.pending.push_back((self.next, check));
        while self.pending.len() > KEPT {
            self.pending.pop_front();
        }
        Expect { token: self.next, what: what.into() }
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

    /// A check of a scroll at the global point (`x`, `y`) in `pid`'s app: the
    /// scroll bars of the scroll area under it.
    pub(super) fn scroll(pid: i32, x: f64, y: f64) -> Option<Check> {
        let app = Ax::application(pid)?;
        app.set_timeout(0.25);
        let mut el = app.element_at(x, y)?;
        for _ in 0..SCROLL_AREA_DEPTH {
            if el.string("AXRole").as_deref() == Some("AXScrollArea") {
                let bars: Vec<(Ax, Option<String>)> =
                    ["AXVerticalScrollBar", "AXHorizontalScrollBar"]
                        .iter()
                        .filter_map(|a| el.element(a))
                        .map(|bar| {
                            let v = bar.value_text();
                            (bar, v)
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
                for (bar, before) in bars {
                    let Some(after) = bar.value_text() else { continue };
                    read = true;
                    if before.as_deref() != Some(after.as_str()) {
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

    #[test]
    fn checks_are_taken_once_and_bounded() {
        let mut checks = Checks::default();
        let first = checks.add(Check::Scroll { bars: vec![] });
        assert_eq!(first.what, "scroll");
        for _ in 0..KEPT {
            checks.add(Check::Scroll { bars: vec![] });
        }
        assert!(checks.take(first.token).is_none(), "the oldest is dropped");
        let last = checks.add(Check::Scroll { bars: vec![] });
        assert!(checks.take(last.token).is_some());
        assert!(checks.take(last.token).is_none());
    }
}
