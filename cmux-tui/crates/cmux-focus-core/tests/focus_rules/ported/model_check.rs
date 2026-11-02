//! Exhaustive model check of the focus successor rules, ported from the
//! Swift `FocusAfterCloseModelCheckTests` (user 2026-10-01: "we need to
//! formally verify the correct behavior for when user closes
//! workspace/terminal/pane/etc. like what is the next thing to focus on").
//! Every reachable state of a small universe is explored breadth first to a
//! fixed depth; the invariants of close-focus.md are checked after every
//! step. Each mutant breaks one rule and must be caught.
//! `CMUX_MODELCHECK_DEPTH` and `CMUX_MODELCHECK_PANES` deepen a run.

use cmux_focus_core::close_focus::{neighbor, pane, tab, workspace};
use cmux_focus_core::state::CloseFocusPolicy;
use std::collections::{HashMap, HashSet};

type Id = u32;
type PaneRule<'a> =
    &'a dyn Fn(Option<&Id>, &[Vec<Id>], &[Vec<Id>], &[Id], CloseFocusPolicy) -> Option<Id>;

fn real(
    focused: Option<&Id>,
    before: &[Vec<Id>],
    after: &[Vec<Id>],
    history: &[Id],
    policy: CloseFocusPolicy,
) -> Option<Id> {
    pane(focused, before, after, history, policy)
}

/// A window's view of one screen: columns of pane ids, the focused pane,
/// the focus history (newest first) and the next fresh id.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct World {
    columns: Vec<Vec<Id>>,
    focused: Option<Id>,
    history: Vec<Id>,
    next_id: Id,
}

#[derive(Clone, Copy, Debug)]
enum Step {
    /// Any pane, by the user or anyone else.
    ClosePane(Id),
    /// A whole column at once (close-pane of its last pane, or a batch).
    CloseColumn(usize),
    /// A user focus change.
    Focus(Id),
    /// A new pane after the focused one in its column.
    Split,
    /// A new column right of the focused one.
    NewColumn,
    /// One snapshot in which `closed` closes and `moved` moves (another
    /// client's tab drag) to the end of column `to`, or to a new last column
    /// when `to` is the column count (LayoutRows.tla trace).
    CloseAndMove { closed: Id, moved: Id, to: usize },
}

/// The layout change of a close-like step: the columns after, aligned with
/// the columns before by identity (`aligned[i]` is column i's panes now,
/// empty when it is gone), plus a new column if one formed.
type Transition = (Vec<Vec<Id>>, Option<Id>);

fn transition(step: Step, world: &World) -> Option<Transition> {
    match step {
        Step::ClosePane(p) => Some((
            world.columns.iter().map(|c| c.iter().copied().filter(|x| *x != p).collect()).collect(),
            None,
        )),
        Step::CloseColumn(index) => {
            let gone: HashSet<Id> = world.columns[index].iter().copied().collect();
            Some((
                world
                    .columns
                    .iter()
                    .map(|c| c.iter().copied().filter(|x| !gone.contains(x)).collect())
                    .collect(),
                None,
            ))
        }
        Step::CloseAndMove { closed, moved, to } => {
            let mut aligned: Vec<Vec<Id>> = world
                .columns
                .iter()
                .map(|c| c.iter().copied().filter(|x| *x != closed && *x != moved).collect())
                .collect();
            let extra = if to < aligned.len() {
                aligned[to].push(moved);
                None
            } else {
                Some(moved)
            };
            Some((aligned, extra))
        }
        Step::Focus(_) | Step::Split | Step::NewColumn => None,
    }
}

/// Renames panes by their position (column-major), so states that differ
/// only in fresh ids are one state. The rules never compare ids by value,
/// only by identity, so this is a sound reduction.
fn canonical(world: &World) -> World {
    let mut map: HashMap<Id, Id> = HashMap::new();
    for p in world.columns.iter().flatten() {
        let next = map.len() as Id;
        map.entry(*p).or_insert(next);
    }
    World {
        columns: world.columns.iter().map(|c| c.iter().map(|p| map[p]).collect()).collect(),
        focused: world.focused.map(|f| map[&f]),
        history: world.history.iter().filter_map(|p| map.get(p).copied()).collect(),
        next_id: map.len() as Id,
    }
}

#[derive(Default)]
struct Stats {
    states: usize,
    transitions: usize,
    closes: usize,
    violations: Vec<String>,
}

fn column_of(world: &World, p: Id) -> Option<usize> {
    world.columns.iter().position(|c| c.contains(&p))
}

fn steps(world: &World, max_panes: usize, max_columns: usize) -> Vec<Step> {
    let panes: Vec<Id> = world.columns.iter().flatten().copied().collect();
    let mut result: Vec<Step> = panes.iter().map(|p| Step::ClosePane(*p)).collect();
    result.extend((0..world.columns.len()).map(Step::CloseColumn));
    result.extend(panes.iter().map(|p| Step::Focus(*p)));
    if let Some(focused) = world.focused
        && let Some(column) = column_of(world, focused)
    {
        // The focused pane closes while a pane of its column moves away.
        for moved in world.columns[column].iter().copied().filter(|m| *m != focused) {
            for to in (0..=world.columns.len()).filter(|to| *to != column) {
                result.push(Step::CloseAndMove { closed: focused, moved, to });
            }
        }
        if panes.len() < max_panes && world.columns[column].len() < 3 {
            result.push(Step::Split);
        }
        if panes.len() < max_panes && world.columns.len() < max_columns {
            result.push(Step::NewColumn);
        }
    }
    result
}

fn remember(p: Option<Id>, history: &[Id]) -> Vec<Id> {
    let Some(p) = p else { return history.to_vec() };
    std::iter::once(p).chain(history.iter().copied().filter(|x| *x != p)).collect()
}

/// One step. `change` is `transition(step, world)`, computed once by the
/// caller.
fn apply(
    step: Step,
    change: Option<&Transition>,
    world: &World,
    rule: PaneRule,
    policy: CloseFocusPolicy,
) -> World {
    let mut next = world.clone();
    if let Some((aligned, extra)) = change {
        next.columns = aligned.iter().filter(|c| !c.is_empty()).cloned().collect();
        if let Some(extra) = extra {
            next.columns.push(vec![*extra]);
        }
        let alive: HashSet<Id> = next.columns.iter().flatten().copied().collect();
        next.history = world.history.iter().copied().filter(|p| alive.contains(p)).collect();
        // As the app: focus that is still anywhere stays; else the rule.
        if let Some(f) = world.focused
            && alive.contains(&f)
        {
            next.focused = Some(f);
        } else {
            let in_columns: HashSet<Id> = aligned.iter().flatten().copied().collect();
            let history: Vec<Id> =
                next.history.iter().copied().filter(|p| in_columns.contains(p)).collect();
            next.focused = rule(world.focused.as_ref(), &world.columns, aligned, &history, policy)
                .or_else(|| next.history.first().copied())
                .or_else(|| next.columns.iter().flatten().next().copied());
        }
        next.history = remember(next.focused, &next.history);
        return next;
    }
    match step {
        Step::ClosePane(_) | Step::CloseColumn(_) | Step::CloseAndMove { .. } => {}
        Step::Focus(p) => {
            next.focused = Some(p);
            next.history = remember(Some(p), &world.history);
        }
        Step::Split => {
            let Some(focused) = world.focused else { return world.clone() };
            let Some(c) = column_of(world, focused) else { return world.clone() };
            let Some(i) = world.columns[c].iter().position(|p| *p == focused) else {
                return world.clone();
            };
            next.columns[c].insert(i + 1, world.next_id);
            next.focused = Some(world.next_id);
            next.history = remember(Some(world.next_id), &world.history);
            next.next_id += 1;
        }
        Step::NewColumn => {
            let Some(focused) = world.focused else { return world.clone() };
            let Some(c) = column_of(world, focused) else { return world.clone() };
            next.columns.insert(c + 1, vec![world.next_id]);
            next.focused = Some(world.next_id);
            next.history = remember(Some(world.next_id), &world.history);
            next.next_id += 1;
        }
    }
    next
}

/// The invariants of a close step, stated from the spec independently of the
/// implementation (column indices, not the code's search).
fn check(
    change: Option<&Transition>,
    before: &World,
    after: &World,
    policy: CloseFocusPolicy,
    rule: PaneRule,
) -> Vec<String> {
    let mut bad = Vec::new();
    let Some((aligned, _)) = change else { return bad };
    let surviving: HashSet<Id> = after.columns.iter().flatten().copied().collect();
    // C3: none only when nothing survives.
    if after.focused.is_none() != surviving.is_empty() {
        bad.push(format!("C3 focus {:?} with {} panes", after.focused, surviving.len()));
    }
    // C2: the successor survives.
    if let Some(focus) = after.focused
        && !surviving.contains(&focus)
    {
        bad.push(format!("C2 focus {focus} removed"));
    }
    let Some(old) = before.focused else { return bad };
    // C1: focus that survives (anywhere) never moves, whoever closed what.
    let in_columns: HashSet<Id> = aligned.iter().flatten().copied().collect();
    let history: Vec<Id> =
        before.history.iter().copied().filter(|p| in_columns.contains(p)).collect();
    if surviving.contains(&old) {
        if after.focused != Some(old) {
            bad.push(format!("C1 {old} -> {:?} while it survives", after.focused));
        }
        // The function itself keeps a focus that is still in the columns.
        if in_columns.contains(&old)
            && rule(Some(&old), &before.columns, aligned, &history, policy) != Some(old)
        {
            bad.push(format!("C1 rule moved a surviving focus {old}"));
        }
        return bad;
    }
    // C4: deterministic.
    if rule(Some(&old), &before.columns, aligned, &history, policy)
        != rule(Some(&old), &before.columns, aligned, &history, policy)
    {
        bad.push("C4 nondeterministic".into());
    }
    let Some(focus) = after.focused else { return bad };
    // R: the configured rule; "in column i" means in column i now (aligned by
    // identity), not merely alive.
    if policy == CloseFocusPolicy::MostRecent
        && let Some(recent) = history.first()
    {
        if focus != *recent {
            bad.push(format!("RM expected most recent {recent}, got {focus}"));
        }
        return bad;
    }
    let Some(c) = before.columns.iter().position(|col| col.contains(&old)) else { return bad };
    let column = &before.columns[c];
    let stay: HashSet<Id> = aligned[c].iter().copied().collect();
    if !stay.is_empty() {
        // R1: the nearest previous pane still in the column, else the nearest
        // next one, else a pane that joined the column.
        let i = column.iter().position(|p| *p == old).unwrap_or(0);
        let expected = column[..i]
            .iter()
            .rev()
            .find(|p| stay.contains(p))
            .or_else(|| column[i + 1..].iter().find(|p| stay.contains(p)))
            .or_else(|| history.iter().find(|p| stay.contains(p)))
            .or_else(|| aligned[c].first())
            .copied();
        if Some(focus) != expected {
            bad.push(format!("R1 expected {expected:?} in column, got {focus}"));
        }
    } else {
        // R2: the nearest non-empty column to the left, else the right; inside
        // it the most recent pane, else its first.
        let left = aligned[..c].iter().rposition(|col| !col.is_empty());
        let right = aligned[c + 1..].iter().position(|col| !col.is_empty()).map(|i| i + c + 1);
        let Some(target) = left.or(right) else { return bad };
        let expected = history
            .iter()
            .find(|p| aligned[target].contains(p))
            .or_else(|| aligned[target].first())
            .copied();
        if Some(focus) != expected {
            bad.push(format!("R2 expected {expected:?} (column {target}), got {focus}"));
        }
    }
    bad
}

fn env(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn depth() -> usize {
    env("CMUX_MODELCHECK_DEPTH", 6)
}

fn max_panes() -> usize {
    env("CMUX_MODELCHECK_PANES", 6)
}

/// Every composition of `columns` columns of 1 to 3 panes.
fn layouts(columns: usize) -> Vec<Vec<usize>> {
    if columns == 0 {
        return vec![Vec::new()];
    }
    layouts(columns - 1)
        .into_iter()
        .flat_map(|prefix| {
            (1..=3).map(move |size| {
                let mut sizes = prefix.clone();
                sizes.push(size);
                sizes
            })
        })
        .collect()
}

/// Breadth-first exploration from every initial layout of up to
/// `max_columns` columns of up to 3 panes, to `depth` steps.
fn explore_panes(
    depth: usize,
    max_columns: usize,
    max_panes: usize,
    policy: CloseFocusPolicy,
    rule: PaneRule,
    stop_after_violation: bool,
) -> Stats {
    let mut stats = Stats::default();
    let mut seen: HashSet<World> = HashSet::new();
    let mut layer: Vec<World> = Vec::new();
    for count in 1..=max_columns {
        for sizes in layouts(count).into_iter().filter(|s| s.iter().sum::<usize>() <= max_panes) {
            let mut id: Id = 0;
            let columns: Vec<Vec<Id>> = sizes
                .iter()
                .map(|size| {
                    let column: Vec<Id> = (id..id + *size as Id).collect();
                    id += *size as Id;
                    column
                })
                .collect();
            for focused in columns.iter().flatten() {
                let world = World {
                    columns: columns.clone(),
                    focused: Some(*focused),
                    history: vec![*focused],
                    next_id: id,
                };
                if seen.insert(world.clone()) {
                    layer.push(world);
                }
            }
        }
    }
    stats.states = seen.len();
    for _ in 0..depth {
        let mut next = Vec::new();
        for world in &layer {
            for step in steps(world, max_panes, max_columns) {
                let change = transition(step, world);
                let after = apply(step, change.as_ref(), world, rule, policy);
                stats.transitions += 1;
                if change.is_some() {
                    stats.closes += 1;
                }
                let bad = check(change.as_ref(), world, &after, policy, rule);
                if !bad.is_empty() {
                    if stats.violations.len() < 5 {
                        stats.violations.push(format!("{world:?} {step:?}: {bad:?}"));
                    }
                    if stop_after_violation {
                        return stats;
                    }
                }
                let key = canonical(&after);
                if seen.insert(key.clone()) {
                    next.push(key);
                }
            }
        }
        layer = next;
        stats.states = seen.len();
    }
    stats
}

#[test]
fn pane_rule_previous_neighbor_holds_in_every_reachable_state() {
    let stats =
        explore_panes(depth(), 4, max_panes(), CloseFocusPolicy::PreviousNeighbor, &real, false);
    assert!(stats.violations.is_empty(), "{:?}", stats.violations);
    assert!(stats.states > 10_000, "{} states", stats.states);
    println!(
        "close_focus::pane previousNeighbor: {} states, {} transitions, {} closes",
        stats.states, stats.transitions, stats.closes
    );
}

#[test]
fn pane_rule_most_recent_holds_in_every_reachable_state() {
    let stats = explore_panes(depth(), 4, max_panes(), CloseFocusPolicy::MostRecent, &real, false);
    assert!(stats.violations.is_empty(), "{:?}", stats.violations);
    println!(
        "close_focus::pane mostRecent: {} states, {} transitions, {} closes",
        stats.states, stats.transitions, stats.closes
    );
}

#[allow(clippy::type_complexity, reason = "the pane rule's own signature, as a closure")]
fn mutant(
    name: &'static str,
) -> impl Fn(Option<&Id>, &[Vec<Id>], &[Vec<Id>], &[Id], CloseFocusPolicy) -> Option<Id> {
    move |focused, before, after, history, policy| {
        let picked = real(focused, before, after, history, policy);
        let surviving: HashSet<Id> = after.iter().flatten().copied().collect();
        let gone = |f: &Id| !surviving.contains(f);
        match name {
            "livenessNotMembership" => {
                // The rule before LayoutRows.tla: a pane alive anywhere counted
                // as still in its old column.
                let still: Vec<Vec<Id>> = before
                    .iter()
                    .map(|c| c.iter().copied().filter(|p| surviving.contains(p)).collect())
                    .collect();
                real(focused, before, &still, history, policy)
            }
            "historyAlways" => {
                // The old app rule: the most recently focused survivor anywhere.
                match (focused, history.iter().find(|p| surviving.contains(p))) {
                    (Some(f), Some(recent)) if gone(f) => Some(*recent),
                    _ => picked,
                }
            }
            "nextFirst" => {
                let Some(f) = focused.filter(|f| gone(f)) else { return picked };
                let Some(c) = before.iter().position(|col| col.contains(f)) else { return picked };
                neighbor(f, &before[c], true, |p| surviving.contains(p)).copied().or(picked)
            }
            "rightColumnFirst" => {
                let Some(f) = focused.filter(|f| gone(f)) else { return picked };
                let Some(c) = before.iter().position(|col| col.contains(f)) else { return picked };
                if before[c].iter().any(|p| surviving.contains(p)) {
                    return picked;
                }
                match before[c + 1..].iter().find(|col| col.iter().any(|p| surviving.contains(p))) {
                    Some(right) => right.iter().find(|p| surviving.contains(p)).copied(),
                    None => picked,
                }
            }
            "firstPaneOfColumn" => {
                let Some(p) = picked else { return picked };
                match after.iter().find(|col| col.contains(&p)) {
                    Some(column) => column.first().copied(),
                    None => picked,
                }
            }
            "moveOnUnfocusedClose" => match focused {
                Some(f) if surviving.contains(f) && surviving.len() > 1 => {
                    after.iter().flatten().find(|p| *p != f).copied()
                }
                _ => picked,
            },
            "nilWhenColumnGone" => {
                let Some(f) = focused else { return picked };
                let Some(c) = before.iter().position(|col| col.contains(f)) else { return picked };
                if before[c].iter().any(|p| surviving.contains(p)) { picked } else { None }
            }
            _ => picked,
        }
    }
}

/// Mutants: each breaks one rule and must be caught.
#[test]
fn pane_mutants_are_caught() {
    for name in [
        "historyAlways",
        "nextFirst",
        "rightColumnFirst",
        "firstPaneOfColumn",
        "moveOnUnfocusedClose",
        "nilWhenColumnGone",
        "livenessNotMembership",
    ] {
        let rule = mutant(name);
        let stats =
            explore_panes(4, 4, max_panes(), CloseFocusPolicy::PreviousNeighbor, &rule, true);
        assert!(!stats.violations.is_empty(), "mutant {name} not caught");
    }
}

type TabRule<'a> = &'a dyn Fn(Option<Id>, &[Id], &[Id], &HashSet<Id>) -> Option<Id>;

/// Strips of up to 5 tabs, any subset hidden (collapsed group members),
/// every close sequence to depth 5.
fn explore_tabs(rule: TabRule) -> (usize, Vec<String>) {
    fn walk(
        tabs: &[Id],
        selected: Option<Id>,
        hidden: &HashSet<Id>,
        depth: usize,
        rule: TabRule,
        sequences: &mut usize,
        violations: &mut Vec<String>,
    ) {
        if depth == 0 || tabs.is_empty() {
            *sequences += 1;
            return;
        }
        for &closed in tabs {
            let surviving: Vec<Id> = tabs.iter().copied().filter(|t| *t != closed).collect();
            let shown: HashSet<Id> =
                surviving.iter().copied().filter(|t| !hidden.contains(t)).collect();
            let picked = rule(selected, tabs, &surviving, &shown);
            let mut bad = Vec::new();
            if let Some(s) = selected
                && s != closed
                && picked != Some(s)
            {
                bad.push("T1 moved on unselected close".to_owned());
            }
            if picked.is_none() != surviving.is_empty() {
                bad.push("T3 none with survivors".into());
            }
            if let Some(p) = picked
                && !surviving.contains(&p)
            {
                bad.push("T2 picked removed".into());
            }
            if selected == Some(closed)
                && let Some(p) = picked
                && !shown.is_empty()
                && !shown.contains(&p)
            {
                bad.push(format!("T2 picked hidden {p}"));
            }
            if selected == Some(closed)
                && let Some(i) = tabs.iter().position(|t| *t == closed)
                && !shown.is_empty()
            {
                let expected = tabs[i + 1..]
                    .iter()
                    .find(|t| shown.contains(t))
                    .or_else(|| tabs[..i].iter().rev().find(|t| shown.contains(t)))
                    .copied();
                if picked != expected {
                    bad.push(format!("TR expected {expected:?} got {picked:?}"));
                }
            }
            if !bad.is_empty() && violations.len() < 5 {
                violations.push(format!(
                    "{tabs:?} sel {selected:?} hidden {hidden:?} close {closed}: {bad:?}"
                ));
            }
            walk(&surviving, picked, hidden, depth - 1, rule, sequences, violations);
        }
    }
    let mut sequences = 0;
    let mut violations = Vec::new();
    for count in 1..=5u32 {
        let tabs: Vec<Id> = (0..count).collect();
        for mask in 0..(1u32 << count) {
            let hidden: HashSet<Id> =
                tabs.iter().copied().filter(|t| mask & (1 << t) != 0).collect();
            for &selected in tabs.iter().filter(|t| !hidden.contains(t)) {
                walk(&tabs, Some(selected), &hidden, 5, rule, &mut sequences, &mut violations);
            }
        }
    }
    (sequences, violations)
}

#[test]
fn tab_rule_holds_for_every_close_sequence() {
    let (sequences, violations) = explore_tabs(&|selected, old, surviving, shown| {
        tab(selected.as_ref(), old, surviving, shown, &HashMap::new())
    });
    assert!(violations.is_empty(), "{violations:?}");
    println!("close_focus::tab: {sequences} close sequences");
}

#[test]
fn tab_mutants_are_caught() {
    // The old rule ignored hidden tabs; another picks the left neighbor first.
    let (_, ignores_hidden) = explore_tabs(&|selected, old, surviving, _| {
        let all: HashSet<Id> = surviving.iter().copied().collect();
        tab(selected.as_ref(), old, surviving, &all, &HashMap::new())
    });
    assert!(!ignores_hidden.is_empty());
    let (_, left_first) = explore_tabs(&|selected, old, surviving, shown| {
        let selected = selected?;
        if surviving.contains(&selected) {
            return Some(selected);
        }
        neighbor(&selected, old, false, |t| shown.contains(t)).or(surviving.first()).copied()
    });
    assert!(!left_first.is_empty());
}

#[test]
fn workspace_rule_holds_for_every_close_sequence() {
    fn walk(
        list: &[Id],
        shown: Option<Id>,
        depth: usize,
        sequences: &mut usize,
        violations: &mut Vec<String>,
    ) {
        if depth == 0 || list.is_empty() {
            *sequences += 1;
            return;
        }
        for &closed in list {
            let surviving: Vec<Id> = list.iter().copied().filter(|w| *w != closed).collect();
            let picked = workspace(shown.as_ref(), list, &surviving, &[]);
            if let Some(s) = shown
                && s != closed
                && picked != Some(s)
            {
                violations.push(format!("W1 {list:?} {s} close {closed}"));
            }
            if picked.is_none() != surviving.is_empty() {
                violations.push(format!("W3 {list:?}"));
            }
            if shown == Some(closed)
                && let Some(i) = list.iter().position(|w| *w == closed)
            {
                let expected =
                    list.get(i + 1).or_else(|| i.checked_sub(1).and_then(|j| list.get(j))).copied();
                if picked != expected {
                    violations.push(format!("WR {list:?} close {closed} got {picked:?}"));
                }
            }
            walk(&surviving, picked, depth - 1, sequences, violations);
        }
    }
    let mut sequences = 0;
    let mut violations = Vec::new();
    for selected in 0..5 {
        walk(&[0, 1, 2, 3, 4], Some(selected), 5, &mut sequences, &mut violations);
    }
    assert!(violations.is_empty(), "{:?}", &violations[..violations.len().min(5)]);
    println!("close_focus::workspace: {sequences} close sequences");
}
