//! The Home workspace as an app workspace, and the companion workspace of an
//! app workspace (plans/cmux-next/app-screens.md, app-only model).
//!
//! `workspace.ensure_home {app}` makes the home workspace the app workspace
//! of the Home app. A home workspace that already holds tabs loses none:
//! its screens move into its companion workspace, an ordinary workspace of
//! kind `app_tabs` placed directly after it (default name "<display_name>
//! Tabs", `extra.default_title` until a rename), and then the home gets its
//! app tab and kind. Steps, each
//! resumable: (1) the companion is created holding every home screen, in
//! one commit, so no client ever sees it empty (an existing companion takes
//! the screens instead), (2) the app tab, (3) the kind commit, which also
//! writes the home's `app_workspaces` row. Idempotent.
//!
//! A new tab sent to an app workspace (a workspace or screen target, not a
//! pane) goes to the same companion workspace, which is created when it is
//! missing ([`Mux::route_new_tab_to_companion`]). The companion is found by
//! its kind row, never by its name, so a rename by the user is final.

use std::sync::Mutex;

use serde_json::json;

use super::{APP_MUTATION_ORIGIN, AppTabTarget, ENSURING};
use crate::model::Workspace;
use crate::mux::tab_drag::retarget_terminal_workspace;
use crate::mux::*;
use crate::state::app_screens_store::{
    AppScreenKind, AppTabRecord, ScreenApp, app_display_name, live_companion, validate_app_id,
    write_companion,
};
use crate::state::prelude::*;
use crate::workspace_registry::{PersonalWorkspaceUpdate, RegistryWorkspace, WorkspaceRegistry};

/// One companion creation at a time, so two racing creations make one.
pub(crate) static COMPANIONS: Mutex<()> = Mutex::new(());

const COMPANION_OPERATION: &str = "workspace.companion.create";
const COMPANION_MOVE_OPERATION: &str = "workspace.companion.fill";

impl Mux {
    /// `workspace.ensure_home {app}`: the home workspace `home` becomes the
    /// app workspace of `app` (section header).
    pub(crate) fn state_migrate_home(
        self: &Arc<Self>,
        home: &str,
        app: &str,
        display_name: Option<&str>,
    ) -> anyhow::Result<()> {
        validate_app_id(app)?;
        if let Some(name) = display_name {
            crate::state::app_screens_store::validate_display_name(name)?;
        }
        let _ensuring = ENSURING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let workspace = self.workspace_slot_of(home)?;
        let screen_app = ScreenApp { kind: AppScreenKind::App, app: app.to_string() };
        let screens = self.with_state(|state| {
            let item = state.workspace_by_id(workspace)?;
            Some(
                item.screens
                    .iter()
                    .map(|screen| {
                        (screen.id, state.resource_indexes.screen_apps.get(&screen.id).cloned())
                    })
                    .collect::<Vec<_>>(),
            )
        });
        let screens = screens.context("the home workspace disappeared")?;
        if let Some(stored) = screens.iter().find_map(|(_, stored)| stored.clone()) {
            anyhow::ensure!(
                stored == screen_app,
                "bad request: the home workspace already shows app {}",
                stored.app
            );
            return Ok(());
        }
        // Resume after a stop between the app tab and the kind commit: a
        // lone screen that is exactly the Home app tab.
        if let [(screen, None)] = screens.as_slice()
            && self.is_app_shaped(*screen, app)
            && self.commit_screen_app(*screen, screen_app.clone(), display_name).is_ok()
        {
            return Ok(());
        }
        if !screens.is_empty() {
            let _companions = COMPANIONS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            match self.read_registry_state(|connection| live_companion(connection, app))? {
                Some(companion) => self.move_screens_to_companion(workspace, &companion)?,
                None => {
                    self.create_companion(app, display_name, home, Some(workspace))?;
                }
            }
        }
        let record = AppTabRecord { app: app.to_string(), route: None };
        let tab = self.new_app_tab(AppTabTarget::Workspace(workspace), record, None, None)?;
        let screen = self.screen_of_surface(tab.surface.id)?;
        self.commit_screen_app(screen, screen_app, display_name)?;
        Ok(())
    }

    /// Whether `screen` is one pane holding only an app tab of `app`.
    fn is_app_shaped(&self, screen: ScreenId, app: &str) -> bool {
        let Some(surface) = self.app_surface_in(screen, app) else { return false };
        self.with_state(|state| {
            let Some(item) = state
                .workspaces
                .iter()
                .flat_map(|workspace| &workspace.screens)
                .find(|candidate| candidate.id == screen)
            else {
                return false;
            };
            let panes = item.root.pane_ids_vec();
            item.layout_columns.is_empty()
                && matches!(panes.as_slice(), [pane] if state.panes.get(pane)
                    .is_some_and(|pane| pane.tabs == [surface]))
        })
    }

    /// The daemon's default name of `app`'s companion: "<display name>
    /// Tabs" (`display_name`, else the one a client recorded for the app,
    /// else the app id).
    pub(crate) fn companion_default_name(
        &self,
        app: &str,
        display_name: Option<&str>,
    ) -> anyhow::Result<String> {
        let recorded = match display_name {
            Some(name) => Some(name.to_string()),
            None => self.read_registry_state(|connection| app_display_name(connection, app))?,
        };
        let name = format!("{} Tabs", recorded.as_deref().unwrap_or(app));
        Self::validate_workspace_name(&name)?;
        Ok(name)
    }

    /// One commit: a new ordinary workspace of kind `app_tabs` for `app`,
    /// placed directly after the app workspace `app_workspace` (public id),
    /// holding every screen of `screens_from` (moved, no tab lost) or none.
    /// Its default name is "<display name> Tabs" (`display_name`, else the
    /// one a client recorded for the app, else the app id). Returns its
    /// public id.
    fn create_companion(
        self: &Arc<Self>,
        app: &str,
        display_name: Option<&str>,
        app_workspace: &str,
        screens_from: Option<WorkspaceId>,
    ) -> anyhow::Result<String> {
        let name = self.companion_default_name(app, display_name)?;
        let public_id = WorkspacePublicId::random()?;
        let key = Self::new_workspace_key()?;
        let slot = self.next_id();
        let fingerprint = json!({"operation": COMPANION_OPERATION, "app": app, "key": key});
        let (created, app_owned, app_workspace_owned) =
            (public_id.to_string(), app.to_string(), app_workspace.to_string());
        let commit = self.commit_resource_mutation_plan(
            &WorkspaceMutation::local(APP_MUTATION_ORIGIN),
            COMPANION_OPERATION,
            &fingerprint,
            None,
            None,
            |state, registry| {
                anyhow::ensure!(
                    state.workspaces.len() < WORKSPACE_REGISTRY_LIMIT,
                    "workspace limit reached"
                );
                let mut projected = state.clone();
                let mut workspace = Workspace {
                    id: slot,
                    public_id: public_id.clone(),
                    key: key.clone(),
                    name: name.clone(),
                    screens: Vec::new(),
                    active_screen: 0,
                };
                let mut terminals = Vec::new();
                if let Some(from) = screens_from {
                    let from = projected.workspace_index(from).context("home disappeared")?;
                    terminals = screen_terminals(&projected, &projected.workspaces[from].screens);
                    workspace.screens = std::mem::take(&mut projected.workspaces[from].screens);
                    workspace.active_screen = projected.workspaces[from].active_screen;
                    projected.workspaces[from].active_screen = 0;
                }
                projected.push_workspace(workspace);
                Mux::rebuild_split_screen_index(&mut projected);
                let mut projection = self.resource_effect_projection_locked(
                    registry,
                    &mut projected,
                    json!({"workspace": public_id}),
                )?;
                for terminal in &terminals {
                    retarget_terminal_workspace(&mut projection.patch, terminal, &key);
                }
                let mut desired = self.registry_projection(state);
                desired.push(RegistryWorkspace {
                    id: slot,
                    public_id: public_id.clone(),
                    key: key.clone(),
                    name: name.clone(),
                    group_key: self.session.clone(),
                });
                let ledger = ResourceWorkspaceLedger {
                    event_kind: "workspace-added",
                    workspace_key: key.clone(),
                    workspaces: desired,
                    legacy_result: json!({"workspace": public_id, "name": name}),
                    presentation: None,
                };
                let (id, workspace_key, default_name) =
                    (created.clone(), key.clone(), name.clone());
                Ok(ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    move |state| *state = projected,
                )
                .with_workspace_ledger(ledger)
                .with_state_write(Box::new(
                    move |transaction, _result, changes| {
                        // The kind row and the placement, in the same commit and
                        // the same event batch as the workspace.
                        changes.extend(write_companion_mark(
                            transaction,
                            &app_owned,
                            &app_workspace_owned,
                            &id,
                            &workspace_key,
                            &default_name,
                        )?);
                        changes.extend(crate::state::values::fresh_upserts(
                            transaction,
                            std::slice::from_ref(&id),
                            &[],
                            &[],
                        )?);
                        Ok(())
                    },
                )))
            },
        )?;
        if !commit.replayed {
            self.reload_presentation(&self.workspace_registry.lock().unwrap())?;
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(created)
    }

    /// Move every screen of `workspace` into the workspace `companion`
    /// (public id) in one commit; no tab is lost.
    fn move_screens_to_companion(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        companion: &str,
    ) -> anyhow::Result<()> {
        let target = self.workspace_slot_of(companion)?;
        let fingerprint = json!({"operation": COMPANION_MOVE_OPERATION, "workspace": companion});
        let commit = self.commit_resource_mutation_plan(
            &WorkspaceMutation::local(APP_MUTATION_ORIGIN),
            COMPANION_MOVE_OPERATION,
            &fingerprint,
            None,
            None,
            |state, registry| {
                let mut projected = state.clone();
                let from = projected.workspace_index(workspace).context("home disappeared")?;
                let to = projected.workspace_index(target).context("companion disappeared")?;
                let screens = std::mem::take(&mut projected.workspaces[from].screens);
                let active = projected.workspaces[from].active_screen;
                projected.workspaces[from].active_screen = 0;
                let terminals = screen_terminals(&projected, &screens);
                let destination = &mut projected.workspaces[to];
                if destination.screens.is_empty() {
                    destination.active_screen = active;
                }
                destination.screens.extend(screens);
                let key = destination.key.clone();
                Mux::rebuild_split_screen_index(&mut projected);
                let mut projection = self.resource_effect_projection_locked(
                    registry,
                    &mut projected,
                    json!({"workspace": companion}),
                )?;
                for terminal in &terminals {
                    retarget_terminal_workspace(&mut projection.patch, terminal, &key);
                }
                Ok(ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    move |state| *state = projected,
                ))
            },
        )?;
        if !commit.replayed {
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(())
    }
}

/// The terminals of `screens`, retargeted when the screens change workspace.
fn screen_terminals(
    state: &State,
    screens: &[crate::model::Screen],
) -> Vec<crate::resource::TerminalPublicId> {
    screens
        .iter()
        .flat_map(|screen| screen.root.pane_ids_vec())
        .filter_map(|pane| state.panes.get(&pane))
        .flat_map(|pane| pane.tabs.iter())
        .filter_map(|tab| state.surfaces.get(tab))
        .filter_map(|surface| surface.terminal_public_id().cloned())
        .collect()
}

/// The companion's rows, in the commit that creates it: its kind row
/// (`workspace_kind` `app_tabs` row) and its personal placement directly after the app
/// workspace, in the app workspace's group. Returns the placement changes
/// for the commit's `session.events` batch.
pub(crate) fn write_companion_mark(
    transaction: &rusqlite::Transaction<'_>,
    app: &str,
    app_workspace: &str,
    workspace_id: &str,
    workspace_key: &str,
    default_name: &str,
) -> anyhow::Result<Vec<Value>> {
    write_companion(transaction, app, workspace_id, default_name)?;
    let app_key: Option<String> = rusqlite::OptionalExtension::optional(transaction.query_row(
        "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
        [app_workspace],
        |row| row.get(0),
    ))?;
    let Some(app_key) = app_key else { return Ok(Vec::new()) };
    let local = crate::state::values::local_registry_id(transaction)?;
    let rows = crate::workspace_registry::personal_store::read_workspaces(transaction)?;
    let Some(app_row) =
        rows.iter().position(|row| row.session_id == local && row.workspace_key == app_key)
    else {
        return Ok(Vec::new());
    };
    let group = rows[app_row].group.clone();
    WorkspaceRegistry::set_personal_workspace_in(
        transaction,
        &local,
        workspace_key,
        PersonalWorkspaceUpdate {
            index: Some(app_row + 1),
            group: Some(group),
            ..Default::default()
        },
    )?;
    let mut changes = Vec::new();
    for placement in crate::state::personal_state_store::placement_snapshots(transaction)? {
        let id = crate::state::personal_state_store::placement_id(
            placement["workspace"]["session_id"].as_str().unwrap_or_default(),
            placement["workspace"]["workspace_ref"].as_str().unwrap_or_default(),
        );
        changes.push(crate::state::store::state_upsert("workspace_placement", &id, placement));
    }
    Ok(changes)
}
