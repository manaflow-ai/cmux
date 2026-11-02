//! Exhaustive model check of the column strip scroll after closes, creations
//! and focus moves (close-focus.md), ported from the Swift
//! ColumnScrollCloseModelCheckTests (deleted in 36f2381bf1a6). Strips of up
//! to 4 columns (widths 30, 55 or 100 percent of the viewport, two viewport
//! widths), every focused column and every reachable scroll offset, every
//! step to depth 6. The focus successor is cmux-focus-core's
//! `close_focus::pane` with `PreviousNeighbor`, which for one pane per column
//! is: a surviving focus stays, else the nearest live column to the left,
//! else to the right.
//!
//! After each step the spring settles (`animated: false` targets the same
//! offset an animation ends at) and S1-S6 are checked: S1 the focused column
//! is visible, S2 the offset is clamped, S3 a focused column that stays
//! focused and visible keeps its screen x unless the clamp forces a move, S4
//! a reveal is minimal (or the restore point is honored), S5 a close left of
//! the viewport does not move what the user sees, S6 a second sync of the
//! same strip does not scroll again. Four mutants of the reducer's result
//! must each be caught.

use super::*;
use crate::{ColumnId, PaneId};
use std::collections::HashSet;

const GAP: f64 = 8.;

fn c(id: u64) -> ColumnId {
    10_000 + id
}

fn p(id: u64) -> PaneId {
    20_000 + id
}

#[derive(Clone, Debug)]
struct World {
    /// Percent of the viewport, by column order.
    widths: Vec<u32>,
    ids: Vec<u64>,
    /// Column id (one pane per column).
    focused: Option<u64>,
    viewport: u32,
    state: ColumnScrollState,
    next_id: u64,
    history: Vec<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    Close(u64),
    NewColumn(u32),
    FocusLeft,
    FocusRight,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mutant {
    NoReveal,
    Center,
    NoClamp,
    NoAnchor,
}

fn build_strip(world: &World) -> ColumnStrip {
    let viewport = f64::from(world.viewport);
    let mut strip = ColumnStrip::new(viewport, viewport, GAP);
    let mut x = GAP;
    for (percent, id) in world.widths.iter().zip(&world.ids) {
        let width = f64::from(*percent) * viewport / 100.;
        let frame = Rect::new(x, 0., width, 600.);
        strip.push_framed(c(*id), frame, &[(p(*id), frame)]);
        x += width + GAP;
    }
    strip.content_width = if strip.columns.is_empty() { viewport } else { x };
    strip
}

fn sync_event(
    strip: ColumnStrip,
    focused: Option<u64>,
    source: ColumnFocusSource,
) -> ColumnScrollEvent {
    ColumnScrollEvent::Sync {
        strip,
        focused: focused.map(p),
        source,
        animated: false,
        reveals: true,
        anchor: None,
    }
}

fn steps(world: &World) -> Vec<Step> {
    let mut result: Vec<Step> = world.ids.iter().map(|id| Step::Close(*id)).collect();
    result.extend([Step::FocusLeft, Step::FocusRight]);
    if world.ids.len() < 4 {
        result.extend([Step::NewColumn(55), Step::NewColumn(100)]);
    }
    result
}

/// `close_focus::pane` with `PreviousNeighbor`, one pane per column.
fn focus_after_close(
    focused: Option<u64>,
    before: &[u64],
    closed: u64,
    history: &[u64],
) -> Option<u64> {
    let survives = |id: &u64| *id != closed && before.contains(id);
    let Some(focused) = focused else {
        return history
            .iter()
            .copied()
            .find(survives)
            .or_else(|| before.iter().copied().find(survives));
    };
    if survives(&focused) {
        return Some(focused);
    }
    let index = before.iter().position(|id| *id == focused)?;
    before[..index]
        .iter()
        .rev()
        .copied()
        .find(survives)
        .or_else(|| before[index + 1..].iter().copied().find(survives))
}

fn apply(step: Step, world: &World, mutant: Option<Mutant>) -> World {
    let mut next = world.clone();
    let mut source = ColumnFocusSource::Keyboard;
    match step {
        Step::Close(id) => {
            let Some(index) = world.ids.iter().position(|x| *x == id) else { return world.clone() };
            next.ids.remove(index);
            next.widths.remove(index);
            next.history = world.history.iter().copied().filter(|x| *x != id).collect();
            next.focused = focus_after_close(world.focused, &world.ids, id, &next.history);
            source = ColumnFocusSource::Programmatic;
        }
        Step::NewColumn(width) => {
            let at = world
                .focused
                .and_then(|f| world.ids.iter().position(|x| *x == f))
                .map_or(world.ids.len(), |i| i + 1);
            next.ids.insert(at, world.next_id);
            next.widths.insert(at, width);
            next.focused = Some(world.next_id);
            next.next_id += 1;
        }
        Step::FocusLeft | Step::FocusRight => {
            let Some(index) = world.focused.and_then(|f| world.ids.iter().position(|x| *x == f))
            else {
                return world.clone();
            };
            let target =
                if step == Step::FocusLeft { index.checked_sub(1) } else { Some(index + 1) };
            let Some(target) = target.filter(|t| *t < world.ids.len()) else {
                return world.clone();
            };
            next.focused = Some(world.ids[target]);
        }
    }
    if let Some(f) = next.focused {
        let mut history = vec![f];
        history.extend(next.history.iter().copied().filter(|x| *x != f));
        next.history = history;
    }
    let old = next.state.spring.target;
    let built = build_strip(&next);
    next.state.reduce(sync_event(built, next.focused, source));
    if let Some(mutant) = mutant {
        mutate(&mut next, mutant, world, old);
    }
    next
}

/// Broken variants of the reducer's result; each must be caught.
fn mutate(world: &mut World, mutant: Mutant, before: &World, previous_target: f64) {
    let strip = build_strip(world);
    let focused_index = world.focused.and_then(|f| world.ids.iter().position(|x| *x == f));
    let mut target = world.state.spring.target;
    match mutant {
        Mutant::NoReveal => target = strip.clamp(previous_target),
        Mutant::Center => {
            if let Some(i) = focused_index {
                target = center(strip.columns[i].frame, target, &strip);
            }
        }
        Mutant::NoClamp => target -= 1.,
        Mutant::NoAnchor => {
            if world.focused == before.focused
                && let Some(i) = focused_index
            {
                target = fit(strip.columns[i].frame, strip.clamp(previous_target), &strip);
            }
        }
    }
    world.state.spring.target = target;
    world.state.spring.value = target;
}

fn check(step: Step, before: &World, after: &World) -> Vec<String> {
    let mut bad = Vec::new();
    let strip = build_strip(after);
    let offset = after.state.spring.target;
    let position = |world: &World, id: u64| world.ids.iter().position(|x| *x == id);
    if after.state.spring.value != offset {
        bad.push(format!("settle value {} != target {offset}", after.state.spring.value));
    }
    // S2
    if offset < -0.01 || offset > strip.max_offset() + 0.01 {
        bad.push(format!("S2 offset {offset} outside 0...{}", strip.max_offset()));
    }
    // S1
    if let Some(f) = after.focused
        && let Some(i) = position(after, f)
        && !strip.is_column_visible(i, offset)
    {
        bad.push(format!("S1 focused column {f} not visible at {offset}"));
    }
    let old = build_strip(before);
    let old_offset = before.state.spring.target;
    let old_screen =
        |id: u64| old.index_of(c(id)).map(|i| old.columns[i].frame.min_x() - old_offset);
    let new_screen =
        |id: u64| strip.index_of(c(id)).map(|i| strip.columns[i].frame.min_x() - offset);
    // S3: same focus, visible before, unclamped: no jump.
    if let Some(f) = before.focused
        && before.focused == after.focused
        && let Some(i) = position(before, f)
        && old.is_column_visible(i, old_offset)
        && let (Some(a), Some(b)) = (old_screen(f), new_screen(f))
        && (a - b).abs() > 0.01
        && let Some(j) = strip.index_of(c(f))
    {
        let unclamped = strip.columns[j].frame.min_x() - a;
        if (strip.clamp(unclamped) - unclamped).abs() < 0.01 {
            bad.push(format!("S3 focused {f} jumped {a} -> {b} on {step:?}"));
        }
    }
    // S4: a changed focus is revealed with the least motion from the
    // anchored offset (the old focus keeps its screen x when it survives);
    // closing the column just opened right of the focused one puts back the
    // offset from before the open instead (close-focus.md decision 5).
    let restore_case = match (step, before.state.restore) {
        (Step::Close(id), Some(restore))
            if before.focused == Some(id) && restore.opened == c(id) =>
        {
            after
                .focused
                .filter(|f| c(*f) == restore.column)
                .and_then(|_| strip.index_of(restore.column))
                .map(|i| (i, restore))
        }
        _ => None,
    };
    if let Some((i, restore)) = restore_case {
        let expected = strip.clamp(strip.columns[i].frame.min_x() + restore.relative_offset);
        if (offset - expected).abs() > 0.01 {
            bad.push(format!("S4r restore expected {expected}, got {offset}"));
        }
    } else if after.focused != before.focused
        && let Some(i) = after.focused.and_then(|f| position(after, f))
    {
        let anchor = before
            .focused
            .and_then(|id| {
                let a = old_screen(id)?;
                strip.index_of(c(id)).map(|j| strip.columns[j].frame.min_x() - a)
            })
            .unwrap_or(old_offset);
        let minimal = fit(strip.columns[i].frame, strip.clamp(anchor), &strip);
        if (offset - minimal).abs() > 0.01 {
            bad.push(format!("S4 {step:?}: offset {offset}, minimal {minimal} from {anchor}"));
        }
    }
    // S5: closing a column wholly left of the viewport keeps the visible columns put.
    if let Step::Close(id) = step
        && Some(id) != before.focused
        && let Some(i) = position(before, id)
        && old.columns[i].frame.max_x() + GAP <= old_offset + 0.01
        && let Some(survivor) =
            before.ids.iter().copied().find(|x| *x != id && old_screen(*x).unwrap_or(-1.) >= -0.01)
        && let (Some(a), Some(b)) = (old_screen(survivor), new_screen(survivor))
        && (a - b).abs() > 0.01
    {
        let unclamped = old_offset - (old.columns[i].frame.w() + GAP);
        if (strip.clamp(unclamped) - unclamped).abs() < 0.01 {
            bad.push(format!("S5 column {survivor} moved {a} -> {b}"));
        }
    }
    // S6: a second identical sync does not scroll.
    let mut again = after.state.clone();
    again.reduce(sync_event(strip.clone(), after.focused, ColumnFocusSource::Programmatic));
    if (again.spring.target - offset).abs() > 0.01 {
        bad.push(format!("S6 second sync {offset} -> {}", again.spring.target));
    }
    bad
}

/// Renames columns by position so states that differ only in fresh ids are
/// one state (the reducer compares ids only by identity).
fn canonical(world: &World) -> World {
    let rename = |id: u64| world.ids.iter().position(|x| *x == id).map(|i| i as u64);
    let col = |column: ColumnId| column.checked_sub(10_000).and_then(rename).map(c);
    let pane = |pane: PaneId| pane.checked_sub(20_000).and_then(rename).map(p);
    let mut next = world.clone();
    next.ids = (0..world.ids.len() as u64).collect();
    next.focused = world.focused.and_then(rename);
    next.history = world.history.iter().copied().filter_map(rename).collect();
    next.next_id = world.ids.len() as u64;
    let renamed_strip = build_strip(&next);
    let state = &mut next.state;
    if state.strip.is_some() {
        state.strip = Some(renamed_strip);
    }
    state.focused_pane = state.focused_pane.and_then(pane);
    state.focused_column = state.focused_column.and_then(col);
    state.remembered =
        state.remembered.iter().filter_map(|(k, v)| Some((col(*k)?, pane(*v)?))).collect();
    state.remembered.sort_unstable_by_key(|(k, _)| *k);
    state.restore = state.restore.and_then(|r| {
        Some(RestorePoint {
            column: col(r.column)?,
            opened: col(r.opened)?,
            relative_offset: r.relative_offset,
        })
    });
    next
}

/// Everything the next step reads, as a hashable key (the strip follows
/// from widths, ids and viewport).
fn key(world: &World) -> Vec<u64> {
    let s = &world.state;
    let mut key =
        vec![u64::from(world.viewport), world.next_id, world.focused.map_or(0, |f| f + 1)];
    key.extend(world.widths.iter().map(|w| u64::from(*w)));
    key.push(u64::MAX);
    key.extend(&world.ids);
    key.push(u64::MAX);
    key.extend(&world.history);
    key.push(u64::MAX);
    key.extend([s.spring.value.to_bits(), s.spring.velocity.to_bits(), s.spring.target.to_bits()]);
    key.extend([
        u64::from(s.strip.is_some()),
        s.focused_pane.map_or(0, |x| x + 1),
        s.focused_column.map_or(0, |x| x + 1),
        s.mode as u64,
        u64::from(s.reveal_deferred),
        u64::from(s.gesture.is_some()),
    ]);
    for (k, v) in &s.remembered {
        key.extend([*k, *v]);
    }
    key.push(u64::MAX);
    if let Some(r) = s.restore {
        key.extend([r.column, r.opened, r.relative_offset.to_bits()]);
    }
    key
}

struct Exploration {
    states: usize,
    transitions: usize,
    violations: Vec<String>,
}

fn insert(world: World, seen: &mut HashSet<Vec<u64>>, frontier: &mut Vec<World>) {
    if seen.insert(key(&world)) {
        frontier.push(world);
    }
}

fn explore(depth: usize, mutant: Option<Mutant>, stop_after_violation: bool) -> Exploration {
    let mut frontier: Vec<World> = Vec::new();
    let mut seen: HashSet<Vec<u64>> = HashSet::new();
    let choices = [30, 55, 100];
    for n in 1..=4usize {
        let mut lists: Vec<Vec<u32>> = vec![vec![]];
        for _ in 0..n {
            lists = lists
                .iter()
                .flat_map(|l| choices.iter().map(move |c| [l.clone(), vec![*c]].concat()))
                .collect();
        }
        for widths in &lists {
            for viewport in [1000, 1400] {
                for focused in 0..n as u64 {
                    let ids: Vec<u64> = (0..n as u64).collect();
                    let fresh = |f: u64| World {
                        widths: widths.clone(),
                        ids: ids.clone(),
                        focused: Some(f),
                        viewport,
                        state: ColumnScrollState::new(),
                        next_id: n as u64,
                        history: vec![f],
                    };
                    let mut world = fresh(focused);
                    let built = build_strip(&world);
                    world.state.reduce(sync_event(
                        built,
                        Some(focused),
                        ColumnFocusSource::Programmatic,
                    ));
                    insert(world, &mut seen, &mut frontier);
                    // The same focus reached from each side: the other reachable offsets.
                    for other in (0..n as u64).filter(|o| *o != focused) {
                        let mut w = fresh(other);
                        let built = build_strip(&w);
                        w.state.reduce(sync_event(
                            built,
                            Some(other),
                            ColumnFocusSource::Programmatic,
                        ));
                        w.focused = Some(focused);
                        w.history = vec![focused, other];
                        let built = build_strip(&w);
                        w.state.reduce(sync_event(
                            built,
                            Some(focused),
                            ColumnFocusSource::Keyboard,
                        ));
                        insert(w, &mut seen, &mut frontier);
                    }
                }
            }
        }
    }
    let mut transitions = 0;
    let mut violations = Vec::new();
    for _ in 0..depth {
        let mut next = Vec::new();
        for world in &frontier {
            for step in steps(world) {
                let after = apply(step, world, mutant);
                transitions += 1;
                let bad = check(step, world, &after);
                if !bad.is_empty() && violations.len() < 8 {
                    violations.push(format!(
                        "ids {:?} w {:?} vp {} off {} f {:?} {step:?}: {bad:?}",
                        world.ids,
                        world.widths,
                        world.viewport,
                        world.state.spring.target,
                        world.focused
                    ));
                    if stop_after_violation {
                        return Exploration { states: seen.len(), transitions, violations };
                    }
                }
                insert(canonical(&after), &mut seen, &mut next);
            }
        }
        frontier = next;
    }
    Exploration { states: seen.len(), transitions, violations }
}

#[test]
fn model_check_every_reachable_strip_state_keeps_the_scroll_rules() {
    let result = explore(6, None, false);
    assert!(result.violations.is_empty(), "{:#?}", result.violations);
    assert!(result.states > 1000, "explored only {} states", result.states);
    println!(
        "ColumnScroll close model check: {} states, {} transitions",
        result.states, result.transitions
    );
}

#[test]
fn model_check_catches_every_mutant() {
    for mutant in [Mutant::NoReveal, Mutant::Center, Mutant::NoClamp, Mutant::NoAnchor] {
        assert!(
            !explore(3, Some(mutant), true).violations.is_empty(),
            "mutant {mutant:?} not caught"
        );
    }
}
