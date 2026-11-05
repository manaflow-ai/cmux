//! `layout.bulk` (plans/cmux-next/reopen-closed.md section 5.1, cx-gzh.5):
//! the one op behind every bulk close preset (Close Other Tabs, Close Tabs
//! to the Right, Close Other Panes, Close Screens to the Right, Close Other
//! Workspaces, ...), so the app, the CLI and MCP agree.
//!
//! A level and a selector choose objects; their tabs close through the
//! shared batch close in ONE commit, so the gesture is ONE closed-history
//! group and Reopen Closed (Cmd-Shift-T) restores it whole. The containers
//! the close empties close in the same plan and join the group.
//!
//! Anchored selectors (`this`, `others`, `to_right`, `to_left`, `all`) work
//! in the anchor's container (`anchor`, else the request's selectors at the
//! level, as `cmux tab current close --others` sends them), in its order: the pane's tabs, the screen's
//! panes, the workspace's screens, the session's workspaces. `selection`
//! names the objects (any container), for a client that knows a scope the
//! daemon does not, such as the workspaces of the current space in sidebar
//! order. Pinned tabs, screens and workspaces are skipped by every selector but `this`
//! and `selection`, unless `include_pinned`. The home workspace anchors a
//! selector but never closes. A tab, pane or screen with no tab has nothing
//! to close; a workspace with no tab still closes, in the same commit and
//! group (`layout-bulk-bare-v1`: one call closes every chosen workspace, so a
//! client never falls back to one request per empty workspace). A
//! `selection` id that is already gone counts as closed (`gone_ids`), and a
//! chosen tab that leaves before the commit is skipped: a close asks for the
//! objects to be gone, so neither refuses the rest (Lawrence 2026-11-05, 919
//! workspaces "all suddenly came back" after one stale tab failed the call).
//! A call with nothing to close commits nothing, writes no group and keeps
//! no idempotency receipt (a retry chooses again).

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::mux::*;
use crate::state::prelude::*;
use crate::state::store::StateCommit;
use crate::workspace_registry::PresentationSnapshot;
use cmux_json::JsonSet as _;

/// The daemon serves `layout.bulk`.
pub(crate) const CAPABILITY: &str = "layout-bulk-v1";

/// A workspace-level `layout.bulk` closes the chosen workspaces with no tab
/// too, reports already-gone selection ids as `gone_ids`, and skips a chosen
/// tab that left before the commit.
pub(crate) const BARE_CAPABILITY: &str = "layout-bulk-bare-v1";

/// The most tabs one call closes, as for `close-tabs`.
const MAX_BULK_TABS: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BulkVerb {
    /// Archive: the objects leave the layout as one closed group.
    Close,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BulkLevel {
    Tab,
    Pane,
    Screen,
    Workspace,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BulkSelector {
    This,
    Others,
    ToRight,
    ToLeft,
    All,
    Selection,
}

/// One `layout.bulk` request.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub(crate) struct BulkRequest {
    pub(crate) verb: BulkVerb,
    pub(crate) level: BulkLevel,
    pub(crate) selector: BulkSelector,
    /// The object the selector is relative to (public id at `level`); None:
    /// the request's selectors name it.
    #[serde(default)]
    pub(crate) anchor: Option<String>,
    /// The objects of `selection` (public ids at `level`).
    #[serde(default)]
    pub(crate) ids: Option<Vec<String>>,
    #[serde(default)]
    pub(crate) include_pinned: bool,
    /// End the terminals whose every view closes (as a workspace close does).
    #[serde(default)]
    pub(crate) end_terminals: bool,
}

impl BulkRequest {
    /// The request in `fields`; a bad field is a `bad request`.
    pub(crate) fn from_fields(fields: &serde_json::Map<String, Value>) -> anyhow::Result<Self> {
        let mut fields = fields.clone();
        fields.remove("expected_revision");
        let request: Self = serde_json::from_value(Value::Object(fields))
            .map_err(|error| anyhow::anyhow!("bad request: {error}"))?;
        anyhow::ensure!(
            request.selector != BulkSelector::Selection
                || request.ids.as_ref().is_some_and(|ids| !ids.is_empty()),
            "bad request: selection needs ids"
        );
        anyhow::ensure!(
            request.level != BulkLevel::Pane
                || !matches!(request.selector, BulkSelector::ToRight | BulkSelector::ToLeft),
            "bad request: panes have no order; use others, all or selection"
        );
        Ok(request)
    }
}

/// An object a selector can choose: its public id, its container (the
/// anchored selectors stay in it), its tabs, whether it is pinned, and
/// whether it may close (the home workspace anchors but never closes).
/// `dock_pinned`: it holds the pinned tab of a pinned column (Home's dock,
/// `pinned-dock-v1`); a preset skips it, an explicit choice is refused.
struct Item {
    id: String,
    /// The workspace, for a workspace-level item (it closes when it has no tab).
    workspace: Option<WorkspaceId>,
    container: u64,
    tabs: Vec<SurfaceId>,
    pinned: bool,
    closable: bool,
    dock_pinned: bool,
}

fn pane_tabs(state: &State, pane: PaneId) -> Vec<SurfaceId> {
    state.panes.get(&pane).map(|pane| pane.tabs.clone()).unwrap_or_default()
}

fn screen_tabs(state: &State, screen: &crate::model::Screen) -> Vec<SurfaceId> {
    let mut panes = Vec::new();
    screen.root.pane_ids(&mut panes);
    panes.into_iter().flat_map(|pane| pane_tabs(state, pane)).collect()
}

/// Every object at `level`, container by container, each in its order.
fn items(state: &State, presentation: &PresentationSnapshot, level: BulkLevel) -> Vec<Item> {
    let mut items = Vec::new();
    let dock = pinned_dock_tabs(state);
    let dock_pinned = |tabs: &[SurfaceId]| tabs.iter().any(|tab| dock.contains(tab));
    for workspace in &state.workspaces {
        let home = presentation.home_workspace.as_deref() == Some(workspace.key.as_str());
        if level == BulkLevel::Workspace {
            items.push(Item {
                id: workspace.public_id.to_string(),
                workspace: Some(workspace.id),
                container: 0,
                tabs: workspace
                    .screens
                    .iter()
                    .flat_map(|screen| screen_tabs(state, screen))
                    .collect(),
                pinned: presentation
                    .workspaces
                    .get(&workspace.key)
                    .is_some_and(|record| record.pinned),
                closable: !home,
                // A whole workspace closes with its dock: no removal.
                dock_pinned: false,
            });
            continue;
        }
        for screen in &workspace.screens {
            if level == BulkLevel::Screen {
                let tabs = screen_tabs(state, screen);
                items.push(Item {
                    id: screen.public_id.to_string(),
                    workspace: None,
                    container: workspace.id,
                    dock_pinned: dock_pinned(&tabs),
                    tabs,
                    pinned: presentation.screens.is_pinned(screen.public_id.as_str()),
                    closable: true,
                });
                continue;
            }
            let mut panes = Vec::new();
            screen.root.pane_ids(&mut panes);
            for pane in panes {
                let Some(public) = state.resource_indexes.pane_ids.get(&pane) else { continue };
                if level == BulkLevel::Pane {
                    let tabs = pane_tabs(state, pane);
                    items.push(Item {
                        id: public.to_string(),
                        workspace: None,
                        container: screen.id,
                        dock_pinned: dock_pinned(&tabs),
                        tabs,
                        pinned: false,
                        closable: true,
                    });
                    continue;
                }
                for tab in pane_tabs(state, pane) {
                    let Some(id) = state.resource_indexes.tab_ids.get(&tab) else { continue };
                    items.push(Item {
                        id: id.to_string(),
                        workspace: None,
                        container: pane,
                        tabs: vec![tab],
                        pinned: presentation.pinned_tabs.contains(id.as_str()),
                        closable: true,
                        dock_pinned: dock.contains(&tab),
                    });
                }
            }
        }
    }
    items
}

fn level_name(level: BulkLevel) -> &'static str {
    match level {
        BulkLevel::Tab => "tab",
        BulkLevel::Pane => "pane",
        BulkLevel::Screen => "screen",
        BulkLevel::Workspace => "workspace",
    }
}

/// The public id of the object `selectors` name at `level`.
fn selected_anchor(
    state: &State,
    slots: &ResolvedResourceSlots,
    level: BulkLevel,
) -> Option<String> {
    let indexes = &state.resource_indexes;
    match level {
        BulkLevel::Tab => {
            slots.tab.and_then(|tab| indexes.tab_ids.get(&tab)).map(|id| id.to_string())
        }
        BulkLevel::Pane => {
            slots.pane.and_then(|pane| indexes.pane_ids.get(&pane)).map(|id| id.to_string())
        }
        BulkLevel::Screen => {
            slots.screen.and_then(|screen| indexes.screen_ids.get(&screen)).map(|id| id.to_string())
        }
        BulkLevel::Workspace => slots
            .workspace
            .and_then(|workspace| indexes.workspace_ids.get(&workspace))
            .map(|id| id.to_string()),
    }
}

/// The objects `request` chooses relative to `anchor`, in container order,
/// that the call closes, and the `selection` ids that are already gone: never
/// the home workspace, nor a tab, pane or screen with no tab (it has nothing
/// to close and stays); a workspace with no tab closes.
fn choose(
    request: &BulkRequest,
    anchor: &str,
    items: Vec<Item>,
) -> anyhow::Result<(Vec<Item>, Vec<String>)> {
    let closes = |item: &Item| item.closable && (!item.tabs.is_empty() || item.workspace.is_some());
    let level = level_name(request.level);
    if request.selector == BulkSelector::Selection {
        let ids = request.ids.as_deref().unwrap_or_default();
        let wanted = ids.iter().map(String::as_str).collect::<std::collections::HashSet<_>>();
        let listed =
            items.iter().map(|item| item.id.as_str()).collect::<std::collections::HashSet<_>>();
        let mut gone = Vec::new();
        for id in ids {
            if !listed.contains(id.as_str()) && !gone.contains(id) {
                gone.push(id.clone());
            }
        }
        let chosen = items
            .into_iter()
            .filter(|item| wanted.contains(item.id.as_str()) && closes(item))
            .collect();
        return Ok((chosen, gone));
    }
    let Some(position) = items.iter().position(|item| item.id == anchor) else {
        return Err(crate::state::commit::state_not_found(level, anchor));
    };
    let container = items[position].container;
    let skip_pinned = !request.include_pinned;
    let chosen = items
        .into_iter()
        .enumerate()
        .filter(|(_, item)| item.container == container)
        .filter(|(index, item)| match request.selector {
            BulkSelector::This => *index == position,
            // A preset never takes Home's pinned column (`pinned-dock-v1`).
            _ if item.dock_pinned => false,
            BulkSelector::Others => *index != position && !(skip_pinned && item.pinned),
            BulkSelector::ToRight => *index > position && !(skip_pinned && item.pinned),
            BulkSelector::ToLeft => *index < position && !(skip_pinned && item.pinned),
            BulkSelector::All => !(skip_pinned && item.pinned),
            // Handled above: a selection names its objects.
            BulkSelector::Selection => false,
        })
        .map(|(_, item)| item)
        .filter(closes)
        .collect();
    Ok((chosen, Vec::new()))
}

impl Mux {
    /// Run one `layout.bulk` request as one commit and one closed group.
    /// A retry with the same key replays before the objects resolve.
    pub(crate) fn state_layout_bulk(
        &self,
        mutation: &WorkspaceMutation,
        selectors: &crate::ResourceSelectors,
        request: &BulkRequest,
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "layout.bulk";
        let fingerprint =
            json!({"operation": OPERATION, "selectors": selectors, "request": request});
        if let Some(replay) = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replay_resource_patch(mutation, OPERATION, &fingerprint)?
        {
            return Ok(replay.into());
        }
        let presentation = self.presentation_snapshot();
        let (chosen, gone, surfaces, tab_ids, revision) = self.with_state(|state| {
            let anchor = match (&request.anchor, request.selector) {
                (Some(anchor), _) => anchor.clone(),
                (None, BulkSelector::Selection) => String::new(),
                (None, _) => {
                    let target = match request.level {
                        BulkLevel::Tab => crate::ResourceTarget::Tab,
                        BulkLevel::Pane => crate::ResourceTarget::Pane,
                        BulkLevel::Screen => crate::ResourceTarget::Screen,
                        BulkLevel::Workspace => crate::ResourceTarget::Workspace,
                    };
                    let slots = self
                        .resolve_in_state(state, target, selectors)
                        .map_err(anyhow::Error::new)?;
                    selected_anchor(state, &slots, request.level)
                        .context("bad request: the selectors name no object at the level")?
                }
            };
            let (chosen, gone) =
                choose(request, &anchor, items(state, &presentation, request.level))?;
            let surfaces =
                chosen.iter().flat_map(|item| item.tabs.iter().copied()).collect::<Vec<_>>();
            let tab_ids = surfaces
                .iter()
                .filter_map(|surface| state.resource_indexes.tab_ids.get(surface))
                .map(|id| id.to_string())
                .collect::<Vec<_>>();
            anyhow::Ok((chosen, gone, surfaces, tab_ids, state.resource_revision))
        })?;
        anyhow::ensure!(
            surfaces.len() <= MAX_BULK_TABS,
            "bad request: layout.bulk closes at most {MAX_BULK_TABS} tabs"
        );
        let ids = |level: BulkLevel| {
            if request.level == level {
                chosen.iter().map(|item| item.id.clone()).collect::<Vec<_>>()
            } else {
                Vec::new()
            }
        };
        let bare = chosen
            .iter()
            .filter(|item| item.tabs.is_empty())
            .filter_map(|item| item.workspace)
            .collect::<Vec<_>>();
        let result = json!({
            "tab_ids": tab_ids,
            "pane_ids": ids(BulkLevel::Pane),
            "screen_ids": ids(BulkLevel::Screen),
            "workspace_ids": ids(BulkLevel::Workspace),
            "gone_ids": gone,
        });
        let nothing = |mut result: Value| {
            result.set("workspace_ids", json!([]));
            result.set("closed_ids", json!([]));
            Ok(StateCommit { revision, result, replayed: false, personal_revision: None })
        };
        if surfaces.is_empty() && bare.is_empty() {
            return nothing(result);
        }
        let outcome = match self.close_tabs_and_bare_for_bulk(
            surfaces,
            bare,
            request.end_terminals,
            OPERATION,
            match request.level {
                BulkLevel::Tab => crate::resource::ResourceOperation::TabClose,
                BulkLevel::Pane => crate::resource::ResourceOperation::PaneClose,
                BulkLevel::Screen => crate::resource::ResourceOperation::ScreenClose,
                BulkLevel::Workspace => crate::resource::ResourceOperation::WorkspaceClose,
            },
            &fingerprint,
            mutation,
            request.level == BulkLevel::Workspace,
            result.clone(),
        ) {
            Ok(outcome) => outcome,
            // Every chosen object left before the commit: they are gone, as asked.
            Err(error) if format!("{error:#}").contains("close target disappeared") => {
                return nothing(result);
            }
            Err(error) => return Err(error),
        };
        Ok(StateCommit {
            revision: outcome.resource_revision,
            result: outcome.result,
            replayed: outcome.replayed,
            personal_revision: None,
        })
    }
}
