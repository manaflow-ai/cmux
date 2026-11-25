//! The focus cases of plans/cmux-next/formal/closefocus.tla, run against
//! the Rust rules: its three configurations (closefocus-strip.cfg,
//! closefocus-strip-recent.cfg, closefocus-list.cfg), every behavior of
//! `MaxSteps` user steps (Close, Focus, Create) from every initial focus,
//! with the model's focus properties checked on each step: FocusLive and
//! FocusNotRemoved (C2, C3), UnfocusedCloseKeepsFocus (C1) and
//! SuccessorRule. The scroll half of the model (Anchor, Reveal, Animate) is
//! the viewport's and is not in these rules. The model's "history" mutant
//! must be caught.

use cmux_focus_core::close_focus::{pane, workspace};
use cmux_focus_core::state::CloseFocusPolicy;
use std::collections::HashSet;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Strip,
    List,
}

struct Config {
    kind: Kind,
    policy: CloseFocusPolicy,
    items: &'static [&'static str],
    init: &'static [&'static [&'static str]],
    max_steps: usize,
}

const STRIP_INIT: &[&[&str]] = &[&["a", "b"], &["c"], &["d"]];
const LIST_INIT: &[&[&str]] = &[&["w1"], &["w2"], &["w3"], &["w4"], &["w5"]];

const STRIP: Config = Config {
    kind: Kind::Strip,
    policy: CloseFocusPolicy::PreviousNeighbor,
    items: &["a", "b", "c", "d", "e"],
    init: STRIP_INIT,
    max_steps: 5,
};
const STRIP_RECENT: Config = Config { policy: CloseFocusPolicy::MostRecent, ..STRIP };
const LIST: Config = Config {
    kind: Kind::List,
    policy: CloseFocusPolicy::PreviousNeighbor,
    items: &["w1", "w2", "w3", "w4", "w5", "w6"],
    init: LIST_INIT,
    max_steps: 5,
};

type Cols = Vec<Vec<String>>;

#[derive(Clone, PartialEq, Eq, Hash)]
struct State {
    cols: Cols,
    focus: Option<String>,
    hist: Vec<String>,
}

fn all_items(cols: &Cols) -> Vec<String> {
    cols.iter().flatten().cloned().collect()
}

fn col_of(cols: &Cols, p: &str) -> usize {
    cols.iter().position(|c| c.iter().any(|q| q == p)).unwrap()
}

fn remove(seq: &[String], x: &str) -> Vec<String> {
    seq.iter().filter(|y| *y != x).cloned().collect()
}

fn push(h: &[String], p: Option<&String>) -> Vec<String> {
    match p {
        None => h.to_vec(),
        Some(p) => std::iter::once(p.clone()).chain(remove(h, p)).collect(),
    }
}

fn first_in(h: &[String], set: &HashSet<String>) -> Option<String> {
    h.iter().find(|x| set.contains(*x)).cloned()
}

/// The successor of the closed focused item `p`, by the Rust rules: the pane
/// rule for the strip (the columns aligned by identity, a gone column left
/// empty), the workspace rule for the list. `history_mutant` is the model's
/// MUTANT "history": the most recent survivor anywhere, always.
fn successor(
    config: &Config,
    cols: &Cols,
    p: &String,
    h: &[String],
    history_mutant: bool,
) -> Option<String> {
    let all: HashSet<String> = all_items(cols).into_iter().filter(|x| x != p).collect();
    if history_mutant && let Some(recent) = first_in(h, &all) {
        return Some(recent);
    }
    match config.kind {
        Kind::Strip => {
            let aligned: Cols = cols.iter().map(|c| remove(c, p)).collect();
            pane(Some(p), cols, &aligned, h, config.policy)
        }
        Kind::List => {
            let old = all_items(cols);
            let surviving = remove(&old, p);
            workspace(Some(p), &old, &surviving, &[])
        }
    }
}

/// SuccessorRule, stated on column indices independently of the rules.
fn successor_rule(config: &Config, before: &State, after: &State) -> Result<(), String> {
    let (Some(focus), Some(next)) = (&before.focus, &after.focus) else { return Ok(()) };
    let cols = &before.cols;
    let c = col_of(cols, focus);
    let col = &cols[c];
    let k = col.iter().position(|q| q == focus).unwrap();
    let h = remove(&before.hist, focus);
    let live: HashSet<String> = all_items(&after.cols).into_iter().collect();
    let ok = match config.kind {
        Kind::List => {
            let expected = if c + 1 < cols.len() { &cols[c + 1][0] } else { &cols[c - 1][0] };
            next == expected
        }
        Kind::Strip => {
            if let Some(recent) =
                first_in(&h, &live).filter(|_| config.policy == CloseFocusPolicy::MostRecent)
            {
                *next == recent
            } else if col.len() > 1 {
                next == if k > 0 { &col[k - 1] } else { &col[k + 1] }
            } else if c > 0 {
                cols[c - 1].contains(next)
            } else {
                cols[c + 1].contains(next)
            }
        }
    };
    if ok {
        Ok(())
    } else {
        Err(format!("SuccessorRule: {focus} closed in {cols:?}, focus went to {next}"))
    }
}

/// Checks every step of every behavior; returns the first violation.
fn explore(config: &Config, history_mutant: bool) -> Result<usize, String> {
    let init: Cols =
        config.init.iter().map(|c| c.iter().map(|s| (*s).to_owned()).collect()).collect();
    let mut layer: Vec<State> = all_items(&init)
        .into_iter()
        .map(|f| State { cols: init.clone(), focus: Some(f.clone()), hist: vec![f] })
        .collect();
    let mut steps = 0;
    for _ in 0..config.max_steps {
        let mut next_layer: HashSet<State> = HashSet::new();
        for state in &layer {
            let items = all_items(&state.cols);
            for p in config.items.iter().map(|s| (*s).to_owned()) {
                // Close(p): anyone closes item p (the focused one or not).
                if items.contains(&p) {
                    let cols: Cols = state
                        .cols
                        .iter()
                        .map(|c| remove(c, &p))
                        .filter(|c| !c.is_empty())
                        .collect();
                    let h = remove(&state.hist, &p);
                    let focus = if state.focus.as_ref() == Some(&p) {
                        successor(config, &state.cols, &p, &h, history_mutant)
                    } else {
                        state.focus.clone()
                    };
                    let after = State { hist: push(&h, focus.as_ref()), cols, focus };
                    steps += 1;
                    check_close(config, state, &p, &after)?;
                    next_layer.insert(after);
                }
                // Focus(p): the user focuses item p.
                if items.contains(&p) && state.focus.as_ref() != Some(&p) {
                    next_layer.insert(State {
                        cols: state.cols.clone(),
                        focus: Some(p.clone()),
                        hist: push(&state.hist, Some(&p)),
                    });
                    steps += 1;
                }
                // Create(p): a new column (strip) or row (list) right after
                // the focused one, focused.
                if !items.contains(&p)
                    && let Some(focus) = &state.focus
                {
                    let c = col_of(&state.cols, focus);
                    let mut cols = state.cols.clone();
                    cols.insert(c + 1, vec![p.clone()]);
                    next_layer.insert(State {
                        cols,
                        focus: Some(p.clone()),
                        hist: push(&state.hist, Some(&p)),
                    });
                    steps += 1;
                }
            }
        }
        layer = next_layer.into_iter().collect();
    }
    Ok(steps)
}

fn check_close(config: &Config, before: &State, closed: &str, after: &State) -> Result<(), String> {
    let live: HashSet<String> = all_items(&after.cols).into_iter().collect();
    // FocusLive (C3): focus is none exactly when no item is left.
    if after.focus.is_none() != live.is_empty() {
        return Err(format!("FocusLive: focus {:?} with {} items", after.focus, live.len()));
    }
    // FocusNotRemoved (C2).
    if let Some(f) = &after.focus
        && !live.contains(f)
    {
        return Err(format!("FocusNotRemoved: {f}"));
    }
    // UnfocusedCloseKeepsFocus (C1).
    if before.focus.as_deref() != Some(closed) {
        if after.focus != before.focus {
            return Err(format!(
                "UnfocusedCloseKeepsFocus: {closed} closed, {:?} -> {:?}",
                before.focus, after.focus
            ));
        }
        return Ok(());
    }
    successor_rule(config, before, after)
}

#[test]
fn the_strip_configuration_holds() {
    let steps = explore(&STRIP, false).unwrap();
    assert!(steps > 1000, "{steps} steps");
}

#[test]
fn the_strip_recent_configuration_holds() {
    explore(&STRIP_RECENT, false).unwrap();
}

#[test]
fn the_list_configuration_holds() {
    explore(&LIST, false).unwrap();
}

#[test]
fn the_history_mutant_is_caught() {
    // The run script expects MUTANT "history" to break SuccessorRule on the
    // strip with the previous-neighbor policy.
    let error = explore(&STRIP, true).unwrap_err();
    assert!(error.starts_with("SuccessorRule"), "{error}");
}
