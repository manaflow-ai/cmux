//! A tab name outside the current pane.
//!
//! The CLI puts `current` workspace, screen and pane selectors above every
//! tab name (`cmux tab alpha show`), so a name was looked up only in the
//! current pane, and a tab named in another pane (an agent's split) was not
//! found. A name that the current pane does not have is now looked up in the
//! current screen, then the current workspace, then the session: the first
//! level with a match wins, and two or more tabs there are
//! `selector.ambiguous`. A name that the current pane has resolves as before.

use crate::model::State;
use crate::resource::{ResourceError, Selector, resolve_name};
use crate::{PaneId, ScreenId, SurfaceId, WorkspaceId};

use super::ResourceSelectors;

/// The tab `raw` names outside the current pane, for a `not_found` from the
/// pane lookup; `Ok(None)` when the selectors are not the `current` chain
/// or no tab has the name.
pub(super) fn tab_beyond_current_pane(
    state: &State,
    selectors: &ResourceSelectors,
    raw: &str,
    screen: Option<ScreenId>,
    workspace: Option<WorkspaceId>,
) -> Result<Option<SurfaceId>, ResourceError> {
    let current = |selector: Option<&str>| selector.is_none_or(|value| value == "current");
    if selectors.pane.as_deref() != Some("current")
        || !current(selectors.screen.as_deref())
        || !current(selectors.workspace.as_deref())
    {
        return Ok(None);
    }
    let Selector::Name(name) = Selector::parse(raw)? else { return Ok(None) };
    let screen_of = |pane: PaneId| state.resource_indexes.pane_screen.get(&pane).copied();
    let workspace_of = |pane: PaneId| {
        screen_of(pane)
            .and_then(|screen| state.resource_indexes.screen_workspace.get(&screen).copied())
    };
    let in_screen = |pane: PaneId| screen.is_some() && screen_of(pane) == screen;
    let in_workspace = |pane: PaneId| workspace.is_some() && workspace_of(pane) == workspace;
    let levels: [&dyn Fn(PaneId) -> bool; 3] = [&in_screen, &in_workspace, &|_| true];
    for in_level in levels {
        let candidates = state.panes.values().filter(|pane| in_level(pane.id)).flat_map(|pane| {
            pane.tabs.iter().filter_map(|tab| {
                let id = state.resource_indexes.tab_ids.get(tab)?;
                let name = state.surfaces.get(tab).and_then(|surface| surface.name());
                Some((id.to_string(), name, *tab))
            })
        });
        match resolve_name("tab", &name, candidates) {
            Ok(tab) => return Ok(Some(tab)),
            Err(error) if error.code == "selector.not_found" => {}
            Err(error) => return Err(error),
        }
    }
    Ok(None)
}
