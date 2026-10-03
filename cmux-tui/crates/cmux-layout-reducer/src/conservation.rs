//! I1 (tab conservation) between two states, and the I1-I3 violations a
//! change introduces.

use std::collections::BTreeSet;

use crate::{LayoutOpKind, LayoutState, TabId, Violation, check_state};

/// I1 from `before` to `after`, where exactly the tabs in `closed` close.
pub fn check_conservation(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    check_conservation_creating(before, after, closed, &BTreeSet::new())
}

/// I1 from `before` to `after`, where exactly the tabs in `closed` close
/// and exactly the tabs in `created` appear (an op's explicit creations).
pub fn check_conservation_creating(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
    created: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    check_conservation_restarting(before, after, closed, created, &BTreeSet::new())
}

/// [`check_conservation_creating`] where exactly the tabs in `restarted`
/// may show new content in place (a restart). A restarted tab must stay;
/// it may gain content it did not have (a kept tab without a runtime).
pub fn check_conservation_restarting(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
    created: &BTreeSet<TabId>,
    restarted: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    let mut violations = BTreeSet::new();
    for (tab, content) in &before.tabs {
        match (closed.contains(tab), after.tabs.get(tab)) {
            (true, Some(_)) => {
                violations.insert(Violation::TabNotClosed { tab: *tab });
            }
            (false, None) => {
                violations.insert(Violation::TabLost { tab: *tab });
            }
            (false, Some(after)) if !after.same_identity(content) && !restarted.contains(tab) => {
                violations.insert(Violation::TabContentChanged { tab: *tab });
            }
            _ => {}
        }
    }
    for tab in after.tabs.keys() {
        if !before.tabs.contains_key(tab) && !created.contains(tab) && !restarted.contains(tab) {
            violations.insert(Violation::TabAdded { tab: *tab });
        }
    }
    for tab in created.iter().chain(restarted) {
        if !after.tabs.contains_key(tab) {
            violations.insert(Violation::TabLost { tab: *tab });
        }
    }
    violations
}

/// Every I1 violation from `before` to `after`, and every I2/I3 violation
/// of `after` that `before` did not already have. A state restored from an
/// older build that already breaks an invariant does not block later ops.
pub fn introduced_violations(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    introduced_violations_creating(before, after, closed, &BTreeSet::new())
}

/// [`introduced_violations`] where exactly the tabs in `created` may appear.
pub fn introduced_violations_creating(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
    created: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    let mut violations = check_conservation_creating(before, after, closed, created);
    let existing = check_state(before);
    violations.extend(check_state(after).into_iter().filter(|v| !existing.contains(v)));
    violations
}

/// [`introduced_violations`] for `kind`: its closes, creations and
/// restarts are the only tab changes allowed.
pub fn introduced_violations_for(
    before: &LayoutState,
    after: &LayoutState,
    kind: &LayoutOpKind,
) -> BTreeSet<Violation> {
    let mut violations = check_conservation_restarting(
        before,
        after,
        &kind.closed_tabs(),
        &kind.created_tabs(),
        &kind.restarted_tabs(),
    );
    let existing = check_state(before);
    violations.extend(check_state(after).into_iter().filter(|v| !existing.contains(v)));
    violations
}
