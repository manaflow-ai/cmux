//! The one validator of `app-screens-v1` (plans/cmux-next/app-screens.md).
//! Every command shape maps to a place and a
//! [`cmux_layout_reducer::AppAction`], and the reducer's
//! [`cmux_layout_reducer::check_app_target`] decides; the reducer's own
//! `apply` uses the same table for layout ops. An app screen is the only
//! screen of its app workspace and holds only its app tab; it refuses every
//! change but closing it with its workspace. Callers:
//!
//! - the topology effect intent (raw `new-tab`, `split`, `new-pane`,
//!   `new-pane-right`, `new-row`, `new-screen`, `close-surface`, `close-pane`,
//!   `undo-layout` and the v2 `tab.create_*`, `pane.*`, `tab.close`,
//!   `screen.create`, `screen.layout.undo`, `workspace.layout.apply`):
//!   [`refuse_effect`];
//! - every staged layout op (raw `move-tab*`, v2 `tab.move`): [`refuse_op`];
//! - `pane.swap`, `column.update`, `set-column-dock`, `apply-layout`,
//!   `close-tabs` and `move-tab-to-workspace` call [`refuse`] directly.
//!
//! These run before a change, so a refusal changes nothing (A4); the check
//! in the commit (app_commit_rules.rs) is the authoritative one. A new tab
//! sent to an app workspace (not to a pane) is not refused: it goes to the
//! app workspace's companion workspace (app_home.rs).

use cmux_layout_reducer::{AppAction, AppRefusal, LayoutOpKind, LayoutState, Reject, ScreenKind};
use rusqlite::Connection;
use serde_json::{Map, Value};

use crate::model::State;
use crate::resource::{ContentPublicId, ResourceOperation};
use crate::resource_selector::ResolvedResourceSlots;
use crate::state::app_screens_store::{ScreenApp, read_app_tabs, read_screen_apps};
use crate::{PaneId, ScreenId, SurfaceId, WorkspaceId};

/// Where an action lands.
#[derive(Debug, Clone, Copy)]
pub(crate) enum AppPlace {
    Pane(PaneId),
    Tab(SurfaceId),
    Screen(ScreenId),
    /// Every screen of the workspace.
    Workspace(WorkspaceId),
}

/// The reducer kind of a screen.
pub(crate) fn reducer_kind(state: &State, screen: ScreenId) -> ScreenKind {
    if state.resource_indexes.screen_apps.contains_key(&screen) {
        ScreenKind::App
    } else {
        ScreenKind::Workspace
    }
}

fn pane_screen(state: &State, pane: PaneId) -> Option<ScreenId> {
    let (workspace, screen) = state.screen_of(pane)?;
    Some(state.workspaces[workspace].screens[screen].id)
}

fn rule(state: &State, refusal: AppRefusal, screen: ScreenId) -> anyhow::Error {
    let public = state.resource_indexes.screen_ids.get(&screen).map(ToString::to_string);
    crate::state::app_screens_store::AppRule::new(refusal, public.unwrap_or_default()).into()
}

/// [`cmux_layout_reducer::check_app_target`] at a known screen.
pub(crate) fn refuse_at(state: &State, screen: ScreenId, action: AppAction) -> anyhow::Result<()> {
    cmux_layout_reducer::check_app_target(reducer_kind(state, screen), action)
        .map_err(|refusal| rule(state, refusal, screen))
}

/// Refuse `action` at `place` when the rule table says so. Unknown places
/// pass: the command reports them itself.
pub(crate) fn refuse(state: &State, place: AppPlace, action: AppAction) -> anyhow::Result<()> {
    let screen = match place {
        AppPlace::Pane(pane) => pane_screen(state, pane),
        AppPlace::Tab(tab) => state.pane_of(tab).and_then(|pane| pane_screen(state, pane)),
        AppPlace::Screen(screen) => Some(screen),
        AppPlace::Workspace(workspace) => {
            let Some(workspace) = state.workspace_by_id(workspace) else { return Ok(()) };
            for screen in &workspace.screens {
                refuse_at(state, screen.id, action)?;
            }
            return Ok(());
        }
    };
    match screen {
        Some(screen) => refuse_at(state, screen, action),
        None => Ok(()),
    }
}

/// Raw `move-tab`, which reports a refused move as `moved: false`: the tab
/// leaves its pane and enters `pane`.
pub(crate) fn refuse_move_tab(state: &State, tab: SurfaceId, pane: PaneId) -> anyhow::Result<()> {
    if state.pane_of(tab) == Some(pane) {
        return Ok(());
    }
    refuse(state, AppPlace::Tab(tab), AppAction::MoveTabOut)?;
    refuse(state, AppPlace::Pane(pane), AppAction::AddTab)
}

/// `pane.swap` and raw `swap-pane`: both panes move.
pub(crate) fn refuse_swap(state: &State, first: PaneId, second: PaneId) -> anyhow::Result<()> {
    refuse(state, AppPlace::Pane(first), AppAction::Reorder)?;
    refuse(state, AppPlace::Pane(second), AppAction::Reorder)
}

/// Raw `apply-layout` into `workspace` (the active one when `None`).
pub(crate) fn refuse_apply_layout(
    state: &State,
    workspace: Option<WorkspaceId>,
) -> anyhow::Result<()> {
    match workspace {
        Some(workspace) => refuse(state, AppPlace::Workspace(workspace), AppAction::ApplyLayout),
        None => Ok(()),
    }
}

/// The topology effects: creations, splits, closes, layout replacement,
/// new screens and layout undo.
pub(crate) fn refuse_effect(
    state: &State,
    operation: ResourceOperation,
    resolved: &ResolvedResourceSlots,
    fields: &Map<String, Value>,
) -> anyhow::Result<()> {
    use ResourceOperation as Op;
    // `workspace.create {initial: app}` makes a new workspace.
    if fields.get("new_workspace") == Some(&Value::Bool(true)) {
        return Ok(());
    }
    let action = match operation {
        Op::TabCreateTerminal | Op::TabCreateBrowser | Op::PaneRun => AppAction::AddTab,
        Op::PaneCreate => AppAction::Split,
        Op::PaneSplit if fields.contains_key("viewport_width") => AppAction::AddColumn,
        Op::PaneSplit => AppAction::Split,
        Op::PaneClose => AppAction::ClosePane,
        Op::TabClose => AppAction::CloseTab,
        Op::WorkspaceLayoutApply | Op::ScreenLayoutUndo => AppAction::ApplyLayout,
        // An app workspace keeps exactly its one app screen.
        Op::ScreenCreate => AppAction::Split,
        _ => return Ok(()),
    };
    let place = match (operation, resolved.tab, resolved.pane, resolved.screen) {
        (Op::WorkspaceLayoutApply | Op::ScreenCreate, ..) => match resolved.workspace {
            Some(workspace) => AppPlace::Workspace(workspace),
            None => return Ok(()),
        },
        (_, Some(tab), ..) => AppPlace::Tab(tab),
        (_, None, Some(pane), _) => AppPlace::Pane(pane),
        (_, None, None, Some(screen)) => AppPlace::Screen(screen),
        (_, None, None, None) => match resolved.workspace {
            Some(workspace) => AppPlace::Workspace(workspace),
            None => return Ok(()),
        },
    };
    refuse(state, place, action)
}

/// Raw `new-tab` and `new-browser-tab` without a pane: the focused pane,
/// unless it is the app pane; then the creation goes to the focused
/// workspace, whose new tabs go to its companion workspace.
pub(crate) fn focused_ordinary_pane(state: &State) -> Option<PaneId> {
    let pane = state.active_pane()?;
    let screen = pane_screen(state, pane)?;
    (reducer_kind(state, screen) == ScreenKind::Workspace).then_some(pane)
}

/// A layout op of a staged plan, on `model`, the projection of `state`.
pub(crate) fn refuse_op(
    state: &State,
    model: &LayoutState,
    kind: &LayoutOpKind,
) -> anyhow::Result<()> {
    match cmux_layout_reducer::check_app_op(model, kind) {
        Err(Reject::AppScreenFixed(screen)) => Err(rule(state, AppRefusal::ScreenFixed, screen)),
        _ => Ok(()),
    }
}

/// A1 broken by a staged layout change (an introduced
/// `Violation::AppScreenShape` of the reducer's check), so a tab-group or
/// screen move keeps the typed error.
pub(crate) fn shape_rule(state: &State, screen: ScreenId) -> anyhow::Error {
    rule(state, AppRefusal::ScreenFixed, screen)
}

/// The raw-only mapping of an app reject from the reducer, where the public
/// screen id is not at hand (the `model_result` check of a respawn drag).
pub(crate) fn reject_rule(reject: &Reject) -> Option<anyhow::Error> {
    match reject {
        Reject::AppScreenFixed(_) => Some(
            crate::state::app_screens_store::AppRule::new(AppRefusal::ScreenFixed, String::new())
                .into(),
        ),
        _ => None,
    }
}

/// Whether `screen` still has the shape of `app` (A1): one pane, no
/// columns, holding one `app` tab of the screen's app.
fn has_shape(
    state: &State,
    screen: &crate::model::Screen,
    app: &ScreenApp,
    app_tabs: &std::collections::HashMap<String, crate::state::app_screens_store::AppTabRecord>,
) -> bool {
    if !screen.layout_columns.is_empty() {
        return false;
    }
    let panes = screen.root.pane_ids_vec();
    let [pane] = panes.as_slice() else { return false };
    let Some(pane) = state.panes.get(pane) else { return false };
    let [tab] = pane.tabs.as_slice() else { return false };
    match state.resource_indexes.content_ids.get(tab) {
        Some(ContentPublicId::Browser(browser)) => {
            app_tabs.get(browser.as_str()).is_some_and(|record| record.app == app.app)
        }
        _ => false,
    }
}

impl crate::resource::PublicSlotIndexes {
    /// Rebuilt indexes keep the screen kinds of `old` whose screen is live.
    pub(crate) fn keep_screen_apps(mut self, old: &mut Self) -> Self {
        self.screen_apps = std::mem::take(&mut old.screen_apps);
        self.screen_apps.retain(|screen, _| self.screen_ids.contains_key(screen));
        self
    }
}

/// Overlay the stored screen kinds on the restored state. Rows whose screen
/// is gone, or which lost their shape in an older build, are deleted in one
/// transaction: the screen loads as an ordinary screen and keeps every tab.
pub(crate) fn load_screen_apps(state: &mut State, connection: &Connection) -> anyhow::Result<()> {
    let rows = read_screen_apps(connection)?;
    if rows.is_empty() {
        return Ok(());
    }
    let app_tabs = read_app_tabs(connection)?;
    let mut loaded = std::collections::HashMap::new();
    let mut stale = Vec::new();
    for (public, app) in rows {
        let screen = state
            .resource_indexes
            .screens
            .iter()
            .find(|(id, _)| id.as_str() == public)
            .map(|(_, screen)| *screen);
        let valid = screen.is_some_and(|screen| {
            state
                .workspaces
                .iter()
                .flat_map(|workspace| &workspace.screens)
                .find(|candidate| candidate.id == screen)
                .is_some_and(|candidate| has_shape(state, candidate, &app, &app_tabs))
        });
        match screen.filter(|_| valid) {
            Some(screen) => {
                loaded.insert(screen, app);
            }
            None => stale.push(public),
        }
    }
    if !stale.is_empty() {
        let transaction = connection.unchecked_transaction()?;
        for public in &stale {
            transaction
                .execute("DELETE FROM resource_screen_kinds WHERE screen_id = ?1", [public])?;
        }
        transaction.commit()?;
    }
    state.resource_indexes.screen_apps = loaded;
    Ok(())
}
