//! Names that the scoped rules do not find (W3-H, moved into the daemon by
//! W5-P).
//!
//! A name under `current` parents (what the CLI sends for `cmux tab alpha`,
//! `cmux terminal alpha`, `cmux pane alpha`, and `--tab`, `--terminal` or
//! `--pane` values) is first looked up where it always was: a screen name in
//! the current workspace, a pane name in the current screen, a tab name in the
//! current pane, the current tab's terminal title. A name only fills a gap, so
//! a selector that resolved before selects the same object.
//!
//! A name that the scoped rule does not find is looked up further, with
//! the rules every client had before (so a selector that resolved before
//! selects the same object):
//!
//! - a tab name: in the current screen, then the current workspace, then
//!   the session (the daemon's old tab-name levels). The first level with a
//!   match decides; in it a tab whose terminal runs wins over one whose
//!   terminal exited, and two or more at that step are `selector.ambiguous`;
//! - a pane: a pane name in the session, else the tab name in the session
//!   (the CLI's old W3-H rule): a live terminal tab first, then an exited
//!   one (so `terminal alpha resume` finds the kept tab of an agent that
//!   quit), two or more at one step ambiguous; then a browser tab;
//! - a terminal: a terminal title in the session, else the tab name with
//!   the W3-H rule (terminal tabs only);
//! - a screen: a screen name in the session.
//!
//! An agent name (`cmux agent start alpha`) is its tab's name. Under an
//! explicit parent (an id or a name) the scoped rule is the only rule.

use crate::model::State;
use crate::resource::{ContentPublicId, ResourceError, Selector, resolve_name};
use crate::{PaneId, ScreenId, SurfaceId, WorkspaceId};

use super::ResourceSelectors;

/// Whether every structural selector above `depth` (workspace 2, screen 3,
/// pane 4, tab 5) is `current` or absent: the CLI's implicit parents.
pub(super) fn implicit_parents(selectors: &ResourceSelectors, depth: usize) -> bool {
    let current = |selector: &Option<String>| selector.as_deref().is_none_or(|v| v == "current");
    [&selectors.workspace, &selectors.screen, &selectors.pane, &selectors.tab]
        .into_iter()
        .enumerate()
        .all(|(index, selector)| index + 2 >= depth || current(selector))
}

/// The name in `raw`, or `None` for an id or `current`.
fn name_of(raw: &str) -> Result<Option<String>, ResourceError> {
    Ok(match Selector::parse(raw)? {
        Selector::Name(name) => Some(name),
        Selector::Current | Selector::Id(_) => None,
    })
}

/// `Ok(None)` for a `not_found` (the next step looks), the error for any
/// other failure.
fn found<T>(result: Result<T, ResourceError>) -> Result<Option<T>, ResourceError> {
    match result {
        Ok(found) => Ok(Some(found)),
        Err(error) if error.code == "selector.not_found" => Ok(None),
        Err(error) => Err(error),
    }
}

/// The screen named `raw` anywhere in the session.
pub(super) fn screen(state: &State, raw: &str) -> Result<Option<ScreenId>, ResourceError> {
    let Some(name) = name_of(raw)? else { return Ok(None) };
    found(resolve_name(
        "screen",
        &name,
        state.workspaces.iter().flat_map(|workspace| {
            workspace
                .screens
                .iter()
                .map(|screen| (screen.public_id.to_string(), screen.name.clone(), screen.id))
        }),
    ))
}

/// The pane named `raw` anywhere in the session: a pane with that name,
/// else the pane of the tab with that name.
pub(super) fn pane(state: &State, raw: &str) -> Result<Option<PaneId>, ResourceError> {
    let Some(name) = name_of(raw)? else { return Ok(None) };
    let named = found(resolve_name(
        "pane",
        &name,
        state.panes.values().map(|pane| (pane.public_id.to_string(), pane.name.clone(), pane.id)),
    ))?;
    if named.is_some() {
        return Ok(named);
    }
    let tab = match named_tab(state, &name, true, &|_| true)? {
        Some(tab) => Some(tab),
        None => named_tab(state, &name, false, &|_| true)?,
    };
    Ok(tab.and_then(|tab| state.resource_indexes.tab_pane.get(&tab).copied()))
}

/// The tab named `raw` outside the current pane: in the current `screen`,
/// then the current `workspace`, then the session; the first level with a
/// match decides.
pub(super) fn tab(
    state: &State,
    raw: &str,
    screen: Option<ScreenId>,
    workspace: Option<WorkspaceId>,
) -> Result<Option<SurfaceId>, ResourceError> {
    let Some(name) = name_of(raw)? else { return Ok(None) };
    let indexes = &state.resource_indexes;
    let screen_of = |pane: PaneId| indexes.pane_screen.get(&pane).copied();
    let workspace_of = |pane: PaneId| {
        screen_of(pane).and_then(|screen| indexes.screen_workspace.get(&screen).copied())
    };
    let in_screen = |pane: PaneId| screen.is_some() && screen_of(pane) == screen;
    let in_workspace = |pane: PaneId| workspace.is_some() && workspace_of(pane) == workspace;
    let levels: [&dyn Fn(PaneId) -> bool; 3] = [&in_screen, &in_workspace, &|_| true];
    for in_level in levels {
        if let Some(tab) = named_tab(state, &name, false, in_level)? {
            return Ok(Some(tab));
        }
    }
    Ok(None)
}

/// The tab of the terminal named `raw` anywhere in the session: the one
/// terminal with that title, else the terminal of the tab with that name.
pub(super) fn terminal(state: &State, raw: &str) -> Result<Option<SurfaceId>, ResourceError> {
    let Some(name) = name_of(raw)? else { return Ok(None) };
    let titled = found(resolve_name(
        "terminal",
        &name,
        state.panes.values().flat_map(|pane| &pane.tabs).filter_map(|tab| {
            let ContentPublicId::Terminal(id) = state.resource_indexes.content_ids.get(tab)? else {
                return None;
            };
            let title = state.surfaces.get(tab).map(|surface| surface.title());
            Some((id.to_string(), title, *tab))
        }),
    ))?;
    if titled.is_some() {
        return Ok(titled);
    }
    named_tab(state, &name, true, &|_| true)
}

/// The tab named `name` in the panes `in_level` takes: a live one first,
/// then one whose terminal exited; two or more at the first step that has
/// any are ambiguous. `terminals_only` leaves out tabs that show no
/// terminal.
fn named_tab(
    state: &State,
    name: &str,
    terminals_only: bool,
    in_level: &dyn Fn(PaneId) -> bool,
) -> Result<Option<SurfaceId>, ResourceError> {
    let candidates = state
        .panes
        .values()
        .filter(|pane| in_level(pane.id))
        .flat_map(|pane| &pane.tabs)
        .filter_map(|tab| {
            let id = state.resource_indexes.tab_ids.get(tab)?;
            let surface = state.surfaces.get(tab);
            if surface.and_then(|surface| surface.name()).as_deref() != Some(name) {
                return None;
            }
            let terminal = matches!(
                state.resource_indexes.content_ids.get(tab),
                Some(ContentPublicId::Terminal(_))
            );
            if terminals_only && !terminal {
                return None;
            }
            let exited = surface.is_some_and(|surface| surface.terminal_exit().is_some());
            Some((id.to_string(), *tab, exited))
        })
        .collect::<Vec<_>>();
    for exited in [false, true] {
        let mut step = candidates
            .iter()
            .filter(|(_, _, candidate)| *candidate == exited)
            .map(|(id, tab, _)| (id.clone(), *tab))
            .collect::<Vec<_>>();
        match step.len() {
            0 => {}
            1 => return Ok(step.pop().map(|(_, tab)| tab)),
            _ => {
                let mut ids = step.into_iter().map(|(id, _)| id).collect::<Vec<_>>();
                ids.sort();
                return Err(ResourceError::ambiguous("tab", name, ids));
            }
        }
    }
    Ok(None)
}
