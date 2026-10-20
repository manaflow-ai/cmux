//! Property test for the pane active-tab invariant
//! (plans/cmux-next/pane-active-tab-DESIGN.md, I1-I4): after every topology
//! operation, in any order, every pane holds a non-empty, duplicate-free tab
//! list whose active index names one of its own tabs, every tab is indexed
//! to the pane that holds it, and every screen's active pane is one of its
//! own panes. Random op sequences from fixed seeds (deterministic, no new
//! dependency): new tab, close, move within and across panes, split, drag to
//! a split edge, drag with undo, select, tab groups (create, collapse,
//! expand, close) and a persistent restart.

use super::*;

const SIZE: Option<(u16, u16)> = Some((80, 24));

/// xorshift64*: a deterministic generator, so a failing seed replays.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }

    fn pick<T: Copy>(&mut self, items: &[T]) -> Option<T> {
        (!items.is_empty()).then(|| items[self.below(items.len())])
    }
}

/// The invariant. Returns the first violation, naming the pane.
pub(super) fn pane_active_tab_violation(state: &State) -> Option<String> {
    let mut placed = HashMap::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            let mut ids = Vec::new();
            screen.root.pane_ids(&mut ids);
            if !ids.is_empty() && !ids.contains(&screen.active_pane) {
                return Some(format!(
                    "screen {:?} active pane {:?} is not one of its panes {ids:?}",
                    screen.id, screen.active_pane
                ));
            }
            for id in ids {
                placed.insert(id, screen.id);
            }
        }
    }
    for (id, pane) in &state.panes {
        if pane.tabs.is_empty() {
            return Some(format!("pane {id:?} has no tabs (I1)"));
        }
        if pane.active_tab >= pane.tabs.len() {
            return Some(format!(
                "pane {id:?} active_tab {} is out of range of {} tabs (I2)",
                pane.active_tab,
                pane.tabs.len()
            ));
        }
        let mut seen = std::collections::HashSet::new();
        for tab in &pane.tabs {
            if !seen.insert(*tab) {
                return Some(format!("pane {id:?} lists tab {tab:?} twice (I3)"));
            }
            if state.resource_indexes.tab_pane.get(tab) != Some(id) {
                return Some(format!(
                    "pane {id:?} holds tab {tab:?} but the index puts it in {:?} (I3)",
                    state.resource_indexes.tab_pane.get(tab)
                ));
            }
        }
        if !placed.contains_key(id) {
            return Some(format!("pane {id:?} is in no screen (I4)"));
        }
    }
    None
}

fn panes(mux: &Arc<Mux>) -> Vec<PaneId> {
    mux.with_state(|state| {
        let mut ids = state.panes.keys().copied().collect::<Vec<_>>();
        ids.sort();
        ids
    })
}

fn tabs(mux: &Arc<Mux>) -> Vec<(PaneId, SurfaceId)> {
    mux.with_state(|state| {
        let mut all = state
            .panes
            .iter()
            .flat_map(|(pane, record)| record.tabs.iter().map(move |tab| (*pane, *tab)))
            .collect::<Vec<_>>();
        all.sort();
        all
    })
}

/// One random operation. Errors are fine (a refused op must leave the state valid).
fn step(mux: &Arc<Mux>, rng: &mut Rng, groups: &mut Vec<String>) -> String {
    let panes = panes(mux);
    let tabs = tabs(mux);
    if panes.is_empty() {
        let _ = mux.new_workspace(None, SIZE);
        return "new_workspace (none left)".into();
    }
    match rng.below(12) {
        0 | 1 => {
            let pane = rng.pick(&panes).unwrap();
            let _ = mux.new_tab(Some(pane), None, SIZE);
            format!("new_tab in {pane:?}")
        }
        2 | 3 => {
            let (pane, tab) = rng.pick(&tabs).unwrap();
            let _ = mux.close_surface(tab);
            format!("close {tab:?} in {pane:?}")
        }
        4 | 5 => {
            let (from, tab) = rng.pick(&tabs).unwrap();
            let to = rng.pick(&panes).unwrap();
            let index = rng.below(6);
            mux.move_tab(tab, to, index);
            format!("move {tab:?} from {from:?} to {to:?} at {index}")
        }
        6 => {
            let pane = rng.pick(&panes).unwrap();
            let dir = if rng.below(2) == 0 { SplitDir::Right } else { SplitDir::Down };
            let _ = mux.split(pane, dir, SIZE);
            format!("split {pane:?}")
        }
        7 => {
            let (_, tab) = rng.pick(&tabs).unwrap();
            let to = rng.pick(&panes).unwrap();
            let edge =
                [TabDropEdge::Left, TabDropEdge::Right, TabDropEdge::Top, TabDropEdge::Bottom]
                    [rng.below(4)];
            let _ = mux.move_tab_to_split(tab, to, edge, None, None);
            format!("drag {tab:?} to {to:?} edge {edge:?}")
        }
        8 => {
            let (_, tab) = rng.pick(&tabs).unwrap();
            let to = rng.pick(&panes).unwrap();
            let index = rng.below(6);
            let _ = mux.move_tab_with_undo(tab, to, index, None);
            format!("move_with_undo {tab:?} to {to:?} at {index}")
        }
        9 => {
            let pane = rng.pick(&panes).unwrap();
            let index = rng.below(6);
            mux.select_tab(Some(pane), Some(index), None);
            format!("select {index} in {pane:?}")
        }
        10 => {
            let pane = rng.pick(&panes).unwrap();
            let members = mux.with_state(|state| state.panes[&pane].tabs.clone());
            let take = 1 + rng.below(members.len());
            let start = rng.below(members.len() + 1 - take);
            if let Ok(outcome) =
                mux.create_tab_group(&members[start..start + take], None, None, None, None)
                && let Some(group) = outcome.group
            {
                groups.push(group.id);
            }
            format!("group {take} tabs of {pane:?} from {start}")
        }
        _ => {
            let Some(group) =
                rng.pick(&groups.iter().map(String::as_str).collect::<Vec<_>>()).map(str::to_owned)
            else {
                return "no group".into();
            };
            match rng.below(3) {
                0 => {
                    let _ = mux.update_tab_group(&group, None, None, Some(true));
                    format!("collapse {group}")
                }
                1 => {
                    let _ = mux.update_tab_group(&group, None, None, Some(false));
                    format!("expand {group}")
                }
                _ => {
                    let _ = mux.close_tab_group(&group);
                    groups.retain(|candidate| *candidate != group);
                    format!("close group {group}")
                }
            }
        }
    }
}

fn run(mux: &Arc<Mux>, seed: u64, steps: usize) -> Result<(), String> {
    let mut rng = Rng(seed | 1);
    let mut groups = Vec::new();
    let mut trace = Vec::new();
    for _ in 0..steps {
        trace.push(step(mux, &mut rng, &mut groups));
        if let Some(violation) = mux.with_state(pane_active_tab_violation) {
            let tail = trace.iter().rev().take(8).rev().cloned().collect::<Vec<_>>().join("\n  ");
            return Err(format!(
                "seed {seed:#x} step {}: {violation}\n  last ops:\n  {tail}",
                trace.len()
            ));
        }
    }
    Ok(())
}

#[test]
fn every_pane_keeps_one_valid_active_tab_under_random_ops() {
    for seed in 1..=48u64 {
        let mux = test_mux();
        let first = mux.new_workspace(None, SIZE).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        for _ in 0..3 {
            mux.new_tab(Some(pane), None, SIZE).unwrap();
        }
        if let Err(failure) = run(&mux, seed.wrapping_mul(0x9E37_79B9_7F4A_7C15), 160) {
            panic!("{failure}");
        }
    }
}

#[test]
fn every_pane_keeps_one_valid_active_tab_across_a_persistent_restart() {
    for seed in 1..=12u64 {
        let root = std::env::temp_dir()
            .join(format!("cmux-pane-active-{}", crate::workspace_registry::new_uuid_v4()));
        let session = format!("pane-active-{seed}");
        {
            let mux = open_persistent_test_mux(&session, &root);
            if mux.with_state(|state| state.panes.is_empty()) {
                mux.new_workspace(None, SIZE).unwrap();
            }
            let pane = panes(&mux)[0];
            for _ in 0..3 {
                mux.new_tab(Some(pane), None, SIZE).unwrap();
            }
            if let Err(failure) = run(&mux, seed.wrapping_mul(0xD1B5_4A32_D192_ED03), 80) {
                panic!("before restart: {failure}");
            }
            mux.shutdown();
        }
        let mux = open_persistent_test_mux(&session, &root);
        if let Some(violation) = mux.with_state(pane_active_tab_violation) {
            panic!("seed {seed}: after restart: {violation}");
        }
        let result = run(&mux, seed, 40);
        mux.shutdown();
        drop(mux);
        let _ = std::fs::remove_dir_all(&root);
        if let Err(failure) = result {
            panic!("after restart: {failure}");
        }
    }
}
