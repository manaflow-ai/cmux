//! The pure focus transition function (plans/cmux-next/focus.md section 4):
//! `(state, event) -> (state, effects)`. No platform calls, no side
//! effects; the app applies the effects after it returns.

use crate::close_focus;
use crate::event::{DragOutcome, FocusEffect, FocusEvent, Responder, Source};
use crate::state::{
    DragRestore, Expectation, ExpectationKey, FocusState, HISTORY_LIMIT, Resolved, Target,
};
use crate::topology::{Column, Kind, Topology};

/// Reduces one event. The returned state's `derived` is current.
pub fn reduce(state: &FocusState, event: &FocusEvent) -> (FocusState, Vec<FocusEffect>) {
    let mut old = state.clone();
    old.derive();
    let mut next = old.clone();
    let mut effects = Vec::new();
    let mut force_responder = false;
    let mut force_context = false;
    if overrides_drag(event)
        && let Some(drag) = next.drag.as_mut()
    {
        drag.overridden = true;
    }

    match event {
        FocusEvent::Topology { topology } => apply_topology(topology, &mut next, &mut effects),
        FocusEvent::RestoredPane { pane, workspace } => {
            if !next.remembered.contains_key(workspace)
                && Some(workspace) != next.topology.workspace.as_ref()
            {
                remember(pane, workspace, &mut next);
            }
        }
        FocusEvent::FocusPane { pane, workspace, source } => {
            if source.is_user_intent() {
                bump(&mut next);
            }
            if let Some(workspace) = workspace
                && Some(workspace) != next.topology.workspace.as_ref()
            {
                remember(pane, workspace, &mut next);
            } else if next.topology.contains_pane(pane) {
                next.pane = Some(pane.clone());
                next.target = Target::Content {};
                force_responder = true;
            }
        }
        FocusEvent::SelectTab { pane, tab, workspace, source } => {
            if source.is_user_intent() {
                bump(&mut next);
            }
            if let Some(workspace) = workspace
                && Some(workspace) != next.topology.workspace.as_ref()
            {
                effects.push(FocusEffect::Select { pane: pane.clone(), tab: tab.clone() });
                remember(pane, workspace, &mut next);
            } else if !next.topology.contains_pane(pane) {
                // A pane this window does not show: remembered selection only.
                effects.push(FocusEffect::Select { pane: pane.clone(), tab: tab.clone() });
            } else if next.topology.pane(pane).and_then(|p| p.tab(tab)).is_some() {
                // Only a tab the pane holds (a stale CLI or menu request named
                // a tab that moved or closed; input-spec.md bug B1).
                effects.push(FocusEffect::Select { pane: pane.clone(), tab: tab.clone() });
                next.topology.select(tab, pane);
                next.pane = Some(pane.clone());
                next.target = Target::Content {};
                force_responder = true;
            }
        }
        FocusEvent::FocusTarget { target, source } => 'arm: {
            if next.sidebar_hidden && target.is_sidebar() {
                break 'arm;
            }
            if source.is_user_intent() {
                bump(&mut next);
            }
            if target.is_chrome()
                && next.topology.selected_kind(next.pane.as_deref()) != Some(Kind::Browser)
            {
                break 'arm;
            }
            next.target = *target;
            force_responder = true;
        }
        FocusEvent::Responder { responder, source } => {
            if next.overlays.is_empty() {
                force_responder = accept(responder, *source, &mut next);
            }
        }
        FocusEvent::WindowKey { key } => {
            next.window_key = *key;
            force_responder = *key;
            force_context = *key;
        }
        FocusEvent::AppActive { active } => next.app_active = *active,
        FocusEvent::OverlayOpened { overlay } => next.overlays.push(*overlay),
        FocusEvent::OverlayClosed { overlay } => {
            if let Some(index) = next.overlays.iter().rposition(|o| o == overlay) {
                next.overlays.remove(index);
                force_responder = next.overlays.is_empty();
            }
        }
        FocusEvent::BeginIntent {} => bump(&mut next),
        FocusEvent::Expect { key, target, away_from, generation } => {
            if *generation == next.generation {
                next.expectation = Some(Expectation {
                    key: key.clone(),
                    target: *target,
                    away_from: away_from.clone(),
                    generation: *generation,
                });
                land(&mut next, &mut effects);
            }
        }
        FocusEvent::DragBegan { tabs, pane } => {
            let tab =
                next.pane.as_deref().and_then(|p| next.topology.selected_of(p)).map(str::to_owned);
            next.drag = Some(DragRestore {
                tabs: tabs.clone(),
                source_pane: pane.clone(),
                pane: next.pane.clone(),
                target: next.target,
                tab,
                overridden: false,
            });
        }
        FocusEvent::DragEnded { outcome } => {
            let restore = next.drag.take();
            match outcome {
                DragOutcome::Cancelled {} => {
                    // Put back what the drag changed, unless the user chose
                    // something newer meanwhile. Only a pane-scoped target can
                    // be re-applied, and chrome targets only on the same tab
                    // (input-spec.md bug B6).
                    if let Some(restore) = restore
                        && !restore.overridden
                        && let Some(pane) = restore.pane.clone()
                        && next.topology.contains_pane(&pane)
                    {
                        if restore.target.is_pane_scoped() {
                            let same_tab =
                                next.topology.selected_of(&pane) == restore.tab.as_deref();
                            next.target =
                                if same_tab { restore.target } else { Target::Content {} };
                        }
                        next.pane = Some(pane);
                    }
                    force_responder = true;
                }
                DragOutcome::Dropped { tabs, away_from } => {
                    bump(&mut next);
                    if let Some(tab) = tabs.first() {
                        next.expectation = Some(Expectation {
                            key: ExpectationKey::Tab { id: tab.clone() },
                            target: Target::Content {},
                            away_from: away_from.clone(),
                            generation: next.generation,
                        });
                        land(&mut next, &mut effects);
                    }
                }
                DragOutcome::MovedAway {} => {}
            }
        }
        FocusEvent::ContentPresented { pane } => force_responder = Some(pane) == next.pane.as_ref(),
        FocusEvent::ToggleBrowserFocusMode { tab } => {
            // Only a tab this window shows (F6).
            let tab = tab.clone().or_else(|| browser_tab(&next));
            if let Some(tab) = tab
                && next.topology.all_tab_ids().contains(&tab)
            {
                if !next.browser_focus_mode.remove(&tab) {
                    next.browser_focus_mode.insert(tab.clone());
                }
                let active = next.browser_focus_mode.contains(&tab);
                effects.push(FocusEffect::BrowserFocusMode { tab, active });
            }
        }
        FocusEvent::SidebarVisibility { hidden } => {
            next.sidebar_hidden = *hidden;
            if *hidden && next.target.is_sidebar() {
                next.target = Target::Content {};
                force_responder = true;
            }
        }
    }

    finish(&old, &mut next, &mut effects, force_responder, force_context);
    (next, effects)
}

// MARK: Topology

fn apply_topology(topology: &Topology, state: &mut FocusState, effects: &mut Vec<FocusEffect>) {
    let old = std::mem::replace(&mut state.topology, topology.clone());
    if old.workspace != topology.workspace {
        if let (Some(workspace), Some(pane)) = (old.workspace.as_ref(), state.pane.clone()) {
            state.remembered.insert(workspace.clone(), pane);
        }
        state.pane = topology
            .workspace
            .as_ref()
            .and_then(|w| state.remembered.get(w))
            .filter(|p| topology.contains_pane(p))
            .cloned()
            .or_else(|| topology.panes.first().map(|p| p.id.clone()));
        if state.target != (Target::Sidebar { keyboard: true }) || state.sidebar_hidden {
            state.target = Target::Content {};
        }
        state.drag = None;
    } else if let Some(pane) = state.pane.clone()
        && !topology.contains_pane(&pane)
    {
        state.pane = successor(&pane, &state.recent_panes(), &old, topology, state.close_focus);
        if state.target.is_pane_scoped() {
            state.target = Target::Content {};
        }
    } else if state.pane.is_none() {
        state.pane = topology.panes.first().map(|p| p.id.clone());
    } else if let Some(pane) = state.pane.as_deref()
        && old.selected_of(pane) != topology.selected_of(pane)
        && state.target.is_chrome()
    {
        // Focus follows the selection; the old tab's chrome is gone.
        state.target = Target::Content {};
    }
    // Closed (or moved away) panes leave the shown workspace's history.
    if let Some(workspace) = topology.workspace.clone()
        && let Some(recent) = state.history.get(&workspace)
    {
        let kept: Vec<String> =
            recent.iter().filter(|p| topology.contains_pane(p)).cloned().collect();
        if kept.len() != recent.len() {
            if kept.is_empty() {
                state.history.remove(&workspace);
            } else {
                state.history.insert(workspace, kept);
            }
        }
    }
    let live = topology.all_tab_ids();
    let dead: Vec<String> =
        state.browser_focus_mode.iter().filter(|t| !live.contains(*t)).cloned().collect();
    for tab in dead {
        state.browser_focus_mode.remove(&tab);
        effects.push(FocusEffect::BrowserFocusMode { tab, active: false });
    }
    land(state, effects);
}

/// The pane that takes focus after the focused `pane` left the topology:
/// the close-focus rule over the columns of the screen that showed it, so a
/// successor on another (hidden) screen is chosen only when that screen has
/// no pane left. Then the newest surviving pane in the history, else the
/// first pane.
pub fn successor(
    pane: &str,
    history: &[String],
    old: &Topology,
    new: &Topology,
    policy: crate::state::CloseFocusPolicy,
) -> Option<String> {
    let columns = old.columns_containing(pane).unwrap_or_else(|| {
        vec![Column { id: String::new(), panes: old.panes.iter().map(|p| p.id.clone()).collect() }]
    });
    let before: Vec<Vec<String>> = columns.iter().map(|c| c.panes.clone()).collect();
    // Aligned by column id: a pane that moved to another column is not in
    // its old column any more (close-focus.md; LayoutRows.tla).
    let now = new.columns_by_id();
    let after: Vec<Vec<String>> =
        columns.iter().map(|c| now.get(&c.id).cloned().unwrap_or_default()).collect();
    let on_screen: std::collections::HashSet<&String> = after.iter().flatten().collect();
    let shown_history: Vec<String> =
        history.iter().filter(|p| on_screen.contains(p)).cloned().collect();
    if let Some(pick) = close_focus::pane(Some(pane), &before, &after, &shown_history, policy)
        && new.contains_pane(&pick)
    {
        return Some(pick);
    }
    history
        .iter()
        .find(|p| new.contains_pane(p))
        .cloned()
        .or_else(|| new.panes.first().map(|p| p.id.clone()))
}

// MARK: Helpers

/// `pane` is now the focused pane of `workspace`: restored on switching
/// back, and newest in that workspace's history.
fn remember(pane: &str, workspace: &str, state: &mut FocusState) {
    state.remembered.insert(workspace.to_owned(), pane.to_owned());
    let mut recent = state.history.get(workspace).cloned().unwrap_or_default();
    if recent.first().map(String::as_str) == Some(pane) {
        return;
    }
    recent.retain(|p| p != pane);
    recent.insert(0, pane.to_owned());
    recent.truncate(HISTORY_LIMIT);
    state.history.insert(workspace.to_owned(), recent);
}

/// A user intent that did not come from the drag's own mouse events.
fn overrides_drag(event: &FocusEvent) -> bool {
    match event {
        FocusEvent::FocusPane { source, .. }
        | FocusEvent::SelectTab { source, .. }
        | FocusEvent::FocusTarget { source, .. }
        | FocusEvent::Responder { source, .. } => {
            source.is_user_intent() && *source != Source::Mouse
        }
        FocusEvent::BeginIntent {} => true,
        _ => false,
    }
}

fn bump(state: &mut FocusState) {
    state.generation = state.generation.wrapping_add(1);
    state.expectation = None;
}

/// Lands the expectation when its tab exists and no newer intent happened
/// since it was made.
fn land(state: &mut FocusState, effects: &mut Vec<FocusEffect>) {
    let Some(expectation) = state.expectation.clone() else { return };
    if expectation.generation != state.generation {
        state.expectation = None;
        return;
    }
    let location = match &expectation.key {
        ExpectationKey::Surface { id } => state.topology.location_of_surface(id),
        ExpectationKey::Tab { id } => state.topology.location_of_tab(id),
    };
    let Some((pane, tab)) = location else { return };
    if Some(&pane) == expectation.away_from.as_ref() {
        return;
    }
    state.expectation = None;
    if state.topology.selected_of(&pane) != Some(tab.as_str()) {
        state.topology.select(&tab, &pane);
    }
    effects.push(FocusEffect::Select { pane: pane.clone(), tab });
    state.pane = Some(pane);
    state.target = expectation.target;
}

/// Accepts a platform responder change as the user's choice. Returns
/// whether the responder must be re-applied (a view left the window).
fn accept(responder: &Responder, source: Source, state: &mut FocusState) -> bool {
    let mut pane = state.pane.clone();
    let target = match responder {
        Responder::WindowOrNone {} => return true,
        Responder::Content { pane: reported }
        | Responder::AddressBar { pane: reported }
        | Responder::FindBar { pane: reported }
        | Responder::DevTools { pane: reported } => {
            if !state.topology.contains_pane(reported) {
                return true;
            }
            pane = Some(reported.clone());
            match responder {
                Responder::Content { .. } => Target::Content {},
                Responder::AddressBar { .. } => Target::AddressBar {},
                Responder::FindBar { .. } => Target::FindBar {},
                _ => Target::DevTools {},
            }
        }
        Responder::Sidebar {} | Responder::SidebarField {} => {
            // A hidden sidebar cannot hold the keyboard: re-apply the target.
            if state.sidebar_hidden {
                return true;
            }
            if matches!(responder, Responder::Sidebar {}) {
                Target::Sidebar { keyboard: source == Source::Keyboard }
            } else {
                Target::SidebarField {}
            }
        }
        Responder::TextField {} => Target::TextField {},
    };
    if pane == state.pane && target == state.target {
        return false;
    }
    if source.is_user_intent() {
        bump(state);
    }
    state.pane = pane;
    state.target = target;
    false
}

fn browser_tab(state: &FocusState) -> Option<String> {
    match state.resolved() {
        Resolved::BrowserPage { tab, .. }
        | Resolved::AddressBar { tab, .. }
        | Resolved::FindBar { tab, .. }
        | Resolved::DevTools { tab, .. } => Some(tab),
        _ => None,
    }
}

/// Diffs old and new state into the generic effects, and recomputes the
/// new state's `derived`.
fn finish(
    old: &FocusState,
    new: &mut FocusState,
    effects: &mut Vec<FocusEffect>,
    force_responder: bool,
    force_context: bool,
) {
    // A chrome target exists only on a browser tab (an expectation or a
    // restore may name one on a tab that changed kind or closed; F4).
    if matches!(new.target, Target::AddressBar {} | Target::FindBar {})
        && new.topology.selected_kind(new.pane.as_deref()) != Some(Kind::Browser)
    {
        new.target = Target::Content {};
    }
    if let (Some(workspace), Some(pane)) = (new.topology.workspace.clone(), new.pane.clone())
        && new.topology.contains_pane(&pane)
    {
        remember(&pane, &workspace, new);
    }
    if let Some(pane) = new.pane.clone()
        && (Some(&pane) != old.pane.as_ref() || force_responder)
        && new.topology.contains_pane(&pane)
    {
        effects.push(FocusEffect::RevealPane { pane });
    }
    new.derive();
    if new.derived.resolved != old.derived.resolved || force_responder {
        effects.push(FocusEffect::MoveResponder { resolved: new.derived.resolved.clone() });
    }
    if new.derived.context != old.derived.context || force_context {
        effects.push(FocusEffect::PublishContext { context: new.derived.context });
    }
}
