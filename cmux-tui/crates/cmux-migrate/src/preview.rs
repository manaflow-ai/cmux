//! What a confirmation shows before a plan is applied: the app's "Move this Mac to AutoCloud"
//! preview (RFD 0173) reads this from `cmux migrate plan SOURCE --out FILE --preview --json` and
//! only words it. Which projects move, what is already done, and how much of each list is shown
//! are decided here, once, for every surface. So are an apply's progress ([`progress`], on each
//! `--json` event line) and its end ([`Applied`], in its `--json` answer): how many projects a run
//! really moved, and how many are still not on AutoCloud.

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

/// How an apply ended, for the app's card: what it moved and what is still not moved.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Applied {
    /// Checked projects this run finished moving (their machine made).
    pub moved: usize,
    /// Checked projects still not moved after it: a rerun picks them up.
    pub left: usize,
}

impl Applied {
    /// The ledger `before` and `after` the run, read the way [`Preview::of`] reads one.
    pub fn of(plan: &Plan, before: &Ledger, after: &Ledger) -> Self {
        let (before, after) = (Preview::of(plan, before), Preview::of(plan, after));
        Self { moved: after.already.saturating_sub(before.already), left: after.moving }
    }
}

/// How far an apply is, 0 to 1: the steps reported over the steps it runs
/// ([`crate::apply::step_count`]). A run with no steps is done.
pub fn progress(reported: usize, steps: usize) -> f64 {
    if steps == 0 { 1.0 } else { reported.min(steps) as f64 / steps as f64 }
}

fn cut(text: &str, chars: usize) -> String {
    text.chars().take(chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::{Carry, CarryKind, Project, Source, SourceKind, Unsupported};

    fn plan(projects: usize) -> Plan {
        let mut plan = Plan::new(Source {
            kind: SourceKind::Laptop,
            label: "this Mac".into(),
            id: "laptop:mac".into(),
        });
        for i in 0..projects {
            plan.projects.push(Project {
                key: format!("/code/p{i}"),
                name: format!("p{i}"),
                checked: true,
                ..Project::default()
            });
        }
        plan
    }

    #[test]
    fn counts_checked_projects_not_yet_moved() {
        let mut plan = plan(3);
        plan.projects[2].checked = false;
        let mut ledger = Ledger::new();
        ledger.entry_mut("laptop:mac", "/code/p0").stage = Stage::Done;
        ledger.entry_mut("laptop:mac", "/code/p1").stage = Stage::Failed;
        let preview = Preview::of(&plan, &ledger);
        assert_eq!((preview.moving, preview.already), (1, 1));
        assert_eq!(preview.names, ["p1"]);
        assert!(!preview.more);
    }

    #[test]
    fn lists_at_most_listed_rows_and_cuts_long_text() {
        let mut plan = plan(LISTED + 2);
        plan.warnings.push("w".repeat(300));
        plan.unsupported
            .push(Unsupported { what: "Docker volumes".into(), why: "not copied".into() });
        plan.carry.push(Carry {
            kind: CarryKind::Shell,
            path: "~/.zshrc".into(),
            bytes: 0,
            agent: None,
            checked: true,
        });
        plan.carry.push(Carry {
            kind: CarryKind::Shell,
            path: "~/.bashrc".into(),
            bytes: 0,
            agent: None,
            checked: false,
        });
        let preview = Preview::of(&plan, &Ledger::new());
        assert_eq!(preview.moving, LISTED + 2);
        assert_eq!(preview.names.len(), LISTED);
        assert!(preview.more);
        assert_eq!(preview.carry, 1);
        assert_eq!(preview.warnings[0].chars().count(), WARNING_CHARS);
        assert_eq!(
            (preview.left, preview.left_rows.as_slice()),
            (1, &["Docker volumes: not copied".to_owned()][..])
        );
    }

    #[test]
    fn applied_counts_what_this_run_moved_and_what_is_left() {
        let plan = plan(3);
        let mut before = Ledger::new();
        before.entry_mut("laptop:mac", "/code/p0").stage = Stage::Done;
        let mut after = before.clone();
        after.entry_mut("laptop:mac", "/code/p1").stage = Stage::Done;
        after.entry_mut("laptop:mac", "/code/p2").stage = Stage::Failed;
        assert_eq!(Applied::of(&plan, &before, &after), Applied { moved: 1, left: 1 });
        assert_eq!(Applied::of(&plan, &after, &after), Applied { moved: 0, left: 1 });
    }

    #[test]
    fn progress_runs_from_zero_to_one() {
        assert_eq!((progress(0, 4), progress(1, 4), progress(4, 4)), (0.0, 0.25, 1.0));
        assert_eq!((progress(9, 4), progress(0, 0)), (1.0, 1.0));
    }

    #[test]
    fn an_empty_plan_moves_nothing() {
        assert_eq!(Preview::of(&plan(0), &Ledger::new()), Preview::default());
    }
}
