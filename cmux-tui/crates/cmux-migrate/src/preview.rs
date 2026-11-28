//! What a confirmation shows before a plan is applied: the app's "Move this Mac to AutoCloud"
//! preview (RFD 0173) reads this from `cmux migrate plan SOURCE --out FILE --preview --json` and
//! only words it. Which projects move, what is already done, and how much of each list is shown
//! are decided here, once, for every surface.

use serde::{Deserialize, Serialize};

use crate::ledger::{Ledger, Stage};
use crate::plan::Plan;

/// The most rows of each list (projects, warnings, what stays) a preview shows.
pub const LISTED: usize = 8;
const NAME_CHARS: usize = 64;
const WARNING_CHARS: usize = 200;
const WHY_CHARS: usize = 120;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Preview {
    /// Checked projects an earlier run has not finished: what apply makes machines for now.
    pub moving: usize,
    /// The first [`LISTED`] of them, by machine name.
    pub names: Vec<String>,
    /// More are moving than `names` lists.
    pub more: bool,
    /// Checked projects an earlier run already moved: apply skips them.
    pub already: usize,
    /// Checked machine-wide items that come along (dotfiles, logins).
    pub carry: usize,
    /// The plan's warnings, as the reader wrote them.
    pub warnings: Vec<String>,
    /// How many things stay on the source, and the first [`LISTED`] as "what: why".
    pub left: usize,
    pub left_rows: Vec<String>,
}

impl Preview {
    pub fn of(plan: &Plan, ledger: &Ledger) -> Self {
        let done = |key: &str| {
            ledger.entry(&plan.source.id, key).is_some_and(|entry| entry.stage == Stage::Done)
        };
        let checked: Vec<_> = plan.projects.iter().filter(|p| p.checked).collect();
        let moving: Vec<_> = checked.iter().filter(|p| !done(&p.key)).collect();
        Self {
            moving: moving.len(),
            names: moving.iter().take(LISTED).map(|p| cut(&p.name, NAME_CHARS)).collect(),
            more: moving.len() > LISTED,
            already: checked.len() - moving.len(),
            carry: plan.carry.iter().filter(|c| c.checked).count(),
            warnings: plan.warnings.iter().take(LISTED).map(|w| cut(w, WARNING_CHARS)).collect(),
            left: plan.unsupported.len(),
            left_rows: plan
                .unsupported
                .iter()
                .take(LISTED)
                .map(|u| format!("{}: {}", cut(&u.what, NAME_CHARS), cut(&u.why, WHY_CHARS)))
                .collect(),
        }
    }
}

fn cut(text: &str, chars: usize) -> String {
    text.chars().take(chars).collect()
}

#[cfg(test)]
#[path = "preview_tests.rs"]
mod tests;
