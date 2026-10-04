//! `app-screens-v1` operations (plans/cmux-next/app-screens.md):
//! `workspace.ensure_app {app, kind}` and the `app` tab (raw `new-app-tab`,
//! v2 `tab.create_app`). The Home workspace and the companion workspace of
//! an app workspace are in app_home.rs.
//!
//! `ensure_app` makes one workspace of kind `app` per app, holding its one
//! screen with one `app` tab, in two commits: (1) the workspace with its app
//! tab (`workspace.create {initial: app}`, so no client sees it empty), (2)
//! the screen's kind row with the workspace's `app_workspaces` row
//! ([`Mux::commit_screen_app`]). The kind row is written last, so no step
//! before it is refused by the app rules. A stop between the commits leaves
//! an ordinary workspace with one app tab, and the next call makes a new
//! app workspace. An app workspace an older build left empty or without
//! its kind is still finished by the next call.

use std::sync::Mutex;

use serde_json::{Map, json};

use crate::Surface;
use crate::mux::*;
use crate::resource::BrowserPublicId;
use crate::state::app_screens_store::{
    APP_TAB_ENGINE, APP_TAB_URL, AppScreenKind, AppTabRecord, ScreenApp, app_tab_for_mutation,
    live_app_workspace, validate_app_id, validate_display_name, write_app_display_name,
    write_app_tab, write_app_workspace, write_screen_app,
};
use crate::state::prelude::*;
use crate::workspace_registry::FrontendBrowserRecord;

#[path = "app_home.rs"]
pub(crate) mod home;

/// One `ensure_app` or Home migration at a time in this process, so two
/// concurrent calls for one app never make two workspaces.
pub(crate) static ENSURING: Mutex<()> = Mutex::new(());

pub(crate) const APP_MUTATION_ORIGIN: &str = "cmux-tui-app";
const SCREEN_APP_OPERATION: &str = "screen.app.set";

/// What `workspace.ensure_app` returns.
pub(crate) struct EnsuredApp {
    pub(crate) workspace_id: String,
    pub(crate) screen_id: String,
    pub(crate) revision: u64,
    pub(crate) replayed: bool,
}

/// Where a new app tab goes: a pane (or the focused pane), or a workspace,
/// which gets its first screen and pane when it has none.
#[derive(Debug, Clone, Copy)]
pub(crate) enum AppTabTarget {
    Pane(Option<PaneId>),
    Workspace(WorkspaceId),
}

/// A created or replayed app tab.
pub(crate) struct AppTabOutcome {
    pub(crate) surface: Arc<Surface>,
    pub(crate) replayed: bool,
}

impl Mux {
    pub(crate) fn state_ensure_app(
        self: &Arc<Self>,
        app: &str,
        kind: AppScreenKind,
        display_name: Option<&str>,
    ) -> anyhow::Result<EnsuredApp> {
        validate_app_id(app)?;
        let _ensuring = ENSURING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let existing =
            self.read_registry_state(|connection| live_app_workspace(connection, app))?;
        if let Some((workspace_id, _)) = existing {
            let workspace = self.workspace_slot_of(&workspace_id)?;
            let screens = self.with_state(|state| {
                state.workspace_by_id(workspace).map_or(0, |item| item.screens.len())
            });
            match self.app_screen_of(workspace, app) {
                Some((screen, Some(stored))) => {
                    anyhow::ensure!(
                        stored.kind == kind,
                        "bad request: app {app} is open as kind {}",
                        stored.kind.as_str()
                    );
                    let screen_id = self.public_screen(screen)?;
                    let revision = self.with_state(|state| state.resource_revision);
                    return Ok(EnsuredApp { workspace_id, screen_id, revision, replayed: true });
                }
                // A creation a crash interrupted before its kind commit.
                Some((screen, None)) => {
                    let finished =
                        self.finish_app_screen(&workspace_id, screen, app, kind, display_name);
                    if let Ok(ensured) = finished {
                        return Ok(ensured);
                    }
                }
                None if screens == 0 => {
                    return self.fill_app_workspace(
                        &workspace_id,
                        workspace,
                        app,
                        kind,
                        display_name,
                    );
                }
                None => {}
            }
            // The workspace lost its shape between the commits of an
            // interrupted creation: it stays as an ordinary workspace with
            // every tab, and the app gets a new workspace (its
            // `app_workspaces` row moves there).
        }
        // One commit makes the workspace with its app tab (no client sees
        // it empty); the kind commit then writes its kind and app rows.
        let mutation = WorkspaceMutation::local(APP_MUTATION_ORIGIN);
        let record = AppTabRecord { app: app.to_string(), route: None };
        let (surface, _) = self.state_create_app_workspace(
            Some(app.to_string()),
            None,
            false,
            record,
            None,
            &mutation,
        )?;
        let screen = self.screen_of_surface(surface)?;
        let workspace_id = self
            .with_state(|state| {
                let workspace = state.resource_indexes.screen_workspace.get(&screen)?;
                state.resource_indexes.workspace_ids.get(workspace).map(ToString::to_string)
            })
            .context("the created app workspace disappeared")?;
        self.finish_app_screen(&workspace_id, screen, app, kind, display_name)
    }

    pub(crate) fn workspace_slot_of(&self, workspace_id: &str) -> anyhow::Result<WorkspaceId> {
        self.with_state(|state| {
            state
                .workspaces
                .iter()
                .find(|item| item.public_id.as_str() == workspace_id)
                .map(|item| item.id)
        })
        .context("the app workspace disappeared")
    }

    /// The app tab in the empty app workspace, then the kind commit.
    fn fill_app_workspace(
        self: &Arc<Self>,
        workspace_id: &str,
        workspace: WorkspaceId,
        app: &str,
        kind: AppScreenKind,
        display_name: Option<&str>,
    ) -> anyhow::Result<EnsuredApp> {
        let record = AppTabRecord { app: app.to_string(), route: None };
        let tab = self.new_app_tab(AppTabTarget::Workspace(workspace), record, None, None)?;
        let screen = self.screen_of_surface(tab.surface.id)?;
        self.finish_app_screen(workspace_id, screen, app, kind, display_name)
    }

    fn finish_app_screen(
        self: &Arc<Self>,
        workspace_id: &str,
        screen: ScreenId,
        app: &str,
        kind: AppScreenKind,
        display_name: Option<&str>,
    ) -> anyhow::Result<EnsuredApp> {
        let screen_app = ScreenApp { kind, app: app.to_string() };
        let commit = self.commit_screen_app(screen, screen_app, display_name)?;
        let screen_id = self.public_screen(screen)?;
        Ok(EnsuredApp {
            workspace_id: workspace_id.to_string(),
            screen_id,
            revision: commit.revision,
            replayed: false,
        })
    }

    /// The screen of `workspace` that is or will become `app`'s screen, and
    /// its stored kind: a screen with a kind row for `app`, else the first
    /// screen with an app tab of `app` (a creation a crash interrupted
    /// before its kind commit).
    fn app_screen_of(
        &self,
        workspace: WorkspaceId,
        app: &str,
    ) -> Option<(ScreenId, Option<ScreenApp>)> {
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
        })?;
        if let Some((screen, stored)) =
            screens.iter().find(|(_, stored)| stored.as_ref().is_some_and(|s| s.app == app))
        {
            return Some((*screen, stored.clone()));
        }
        screens
            .iter()
            .find(|(screen, _)| self.app_surface_in(*screen, app).is_some())
            .map(|(screen, _)| (*screen, None))
    }

    /// A tab of `screen` showing `app`.
    pub(crate) fn app_surface_in(&self, screen: ScreenId, app: &str) -> Option<SurfaceId> {
        let presentation = self.presentation_snapshot();
        self.with_state(|state| {
            let screen = state
                .workspaces
                .iter()
                .flat_map(|workspace| &workspace.screens)
                .find(|candidate| candidate.id == screen)?;
            screen.root.pane_ids_vec().into_iter().find_map(|pane| {
                state.panes.get(&pane)?.tabs.iter().copied().find(|tab| {
                    match state.resource_indexes.content_ids.get(tab) {
                        Some(ContentPublicId::Browser(browser)) => presentation
                            .apps
                            .tabs
                            .get(browser.as_str())
                            .is_some_and(|record| record.app == app),
                        _ => false,
                    }
                })
            })
        })
    }

    pub(crate) fn screen_of_surface(&self, surface: SurfaceId) -> anyhow::Result<ScreenId> {
        self.with_state(|state| {
            let pane = state.pane_of(surface)?;
            let (workspace, screen) = state.screen_of(pane)?;
            Some(state.workspaces[workspace].screens[screen].id)
        })
        .context("the app tab has no screen")
    }

    fn public_screen(&self, screen: ScreenId) -> anyhow::Result<String> {
        self.with_state(|state| {
            state.resource_indexes.screen_ids.get(&screen).map(ToString::to_string)
        })
        .context("the app screen has no public id")
    }

    /// One commit: `screen` becomes `screen_app` (its kind row, its index
    /// entry and its workspace's `app_workspaces` row, and the app's English
    /// `display_name` when given: the default name of its companion), with a
    /// fresh screen upsert in the same batch. The screen must already be one
    /// pane holding only the app tab.
    pub(crate) fn commit_screen_app(
        self: &Arc<Self>,
        screen: ScreenId,
        screen_app: ScreenApp,
        display_name: Option<&str>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        if let Some(name) = display_name {
            validate_display_name(name)?;
        }
        let display_name = display_name.map(str::to_string);
        let public = self.public_screen(screen)?;
        // The fences every topology effect holds from its app-rule check to
        // its commit: a kind commit never lands between the two.
        let _fences = self.app_screen_fences();
        let fingerprint = json!({
            "operation": SCREEN_APP_OPERATION,
            "screen": public,
            "kind": screen_app.kind.as_str(),
            "app": screen_app.app,
        });
        let app_surface = self.app_surface_in(screen, &screen_app.app);
        let commit = self.commit_resource_mutation_plan(
            &WorkspaceMutation::local(APP_MUTATION_ORIGIN),
            SCREEN_APP_OPERATION,
            &fingerprint,
            None,
            None,
            |state, registry| {
                let (wi, si) = state
                    .workspaces
                    .iter()
                    .enumerate()
                    .find_map(|(wi, workspace)| {
                        let si = workspace.screens.iter().position(|item| item.id == screen)?;
                        Some((wi, si))
                    })
                    .context("the app screen disappeared")?;
                let mut projected = state.clone();
                let workspace_id = projected.workspaces[wi].public_id.to_string();
                let target = &mut projected.workspaces[wi].screens[si];
                let panes = target.root.pane_ids_vec();
                let shaped = target.layout_columns.is_empty()
                    && matches!(panes.as_slice(), [pane] if app_surface.is_some_and(|surface| {
                        state.panes.get(pane).is_some_and(|pane| pane.tabs == [surface])
                    }));
                if !shaped {
                    // A1 does not hold (a racing effect changed the screen).
                    return Err(crate::state::app_rules::shape_rule(state, screen));
                }
                // No undo entry from before the kind may restore another shape.
                target.invalidate_layout_undo();
                projected.resource_indexes.screen_apps.insert(screen, screen_app.clone());
                let projection = self.resource_effect_projection_locked(
                    registry,
                    &mut projected,
                    json!({"screen": public}),
                )?;
                let (row, id, display) = (screen_app.clone(), public.clone(), display_name.clone());
                let app = screen_app.app.clone();
                Ok(ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    move |state| *state = projected,
                )
                .with_state_write(Box::new(
                    move |transaction, _result, changes| {
                        write_screen_app(transaction, &id, &row)?;
                        // The screen's workspace is its app's workspace (the
                        // Home workspace gets its row here).
                        write_app_workspace(transaction, &workspace_id, &app)?;
                        if let Some(display) = &display {
                            write_app_display_name(transaction, &app, display)?;
                        }
                        // The kind commit itself is checked on the rows it
                        // commits (the patch check ran before the row).
                        crate::state::app_commit_rules::check_screen(transaction, &id)?;
                        changes.extend(crate::state::values::fresh_upserts(
                            transaction,
                            &[],
                            std::slice::from_ref(&id),
                            &[],
                        )?);
                        Ok(())
                    },
                )))
            },
        )?;
        if !commit.replayed {
            // The raw tree reads the workspace's app row from presentation.
            self.reload_presentation(&self.workspace_registry.lock().unwrap())?;
            self.emit_screen_changed_for_transaction(&[screen], None);
            self.emit(MuxEvent::LayoutChanged(screen));
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(commit)
    }

    pub(crate) fn new_app_tab(
        self: &Arc<Self>,
        target: AppTabTarget,
        record: AppTabRecord,
        mutation: Option<&WorkspaceMutation>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<AppTabOutcome> {
        record.validate()?;
        let key = mutation.map(|mutation| (mutation.origin.as_str(), mutation.id.as_str()));
        let browser_id = match self.app_tab_browser(&record, key)? {
            AppTabBrowser::Placed(surface) => return Ok(AppTabOutcome { surface, replayed: true }),
            AppTabBrowser::Recorded(browser_id) => browser_id,
        };
        let fields = Map::from_iter([(
            "frontend_browser_id".to_string(),
            Value::String(browser_id.as_str().to_string()),
        )]);
        let created = match target {
            AppTabTarget::Pane(pane) => {
                self.new_browser_tab_with_fields(APP_TAB_URL.to_string(), pane, size, fields)
            }
            AppTabTarget::Workspace(workspace) => self.new_app_tab_in(workspace, fields),
        };
        match created {
            Ok(surface) => {
                self.publish_journal_event();
                Ok(AppTabOutcome { surface, replayed: false })
            }
            Err(error) => {
                // A keyed creation keeps its record, so a retry resumes it.
                if key.is_none() {
                    let mut registry = self.workspace_registry.lock().unwrap();
                    if registry.delete_frontend_browser(browser_id.as_str()).is_ok() {
                        let _ = self.reload_presentation(&registry);
                    }
                }
                Err(error)
            }
        }
    }

    /// The browser id of a new app tab: the recorded one of a keyed retry
    /// (or its live tab), else a new frontend row and app row in one commit.
    fn app_tab_browser(
        &self,
        record: &AppTabRecord,
        key: Option<(&str, &str)>,
    ) -> anyhow::Result<AppTabBrowser> {
        let recorded = match key {
            Some((origin, id)) => {
                self.read_registry_state(|connection| app_tab_for_mutation(connection, origin, id))?
            }
            None => None,
        };
        if let Some((browser_id, stored)) = recorded {
            anyhow::ensure!(
                stored == *record,
                "idempotency.conflict: the key named another app tab"
            );
            let placed = self.with_state(|state| {
                let content =
                    ContentPublicId::Browser(BrowserPublicId::parse(browser_id.clone()).ok()?);
                let surface = state.single_placement_of_content(&content)?;
                state.surfaces.get(&surface).cloned()
            });
            return Ok(match placed {
                Some(surface) => AppTabBrowser::Placed(surface),
                None => AppTabBrowser::Recorded(BrowserPublicId::parse(browser_id)?),
            });
        }
        let browser_id = BrowserPublicId::random()?;
        let frontend = FrontendBrowserRecord {
            engine: APP_TAB_ENGINE.to_string(),
            url: APP_TAB_URL.to_string(),
            title: None,
            favicon_url: None,
            profile_id: None,
            owner: None,
        };
        let id = browser_id.as_str().to_string();
        let write = |tx: &rusqlite::Transaction<'_>| write_app_tab(tx, &id, record, key);
        let mut registry = self.workspace_registry.lock().unwrap();
        registry.put_frontend_browser(browser_id.as_str(), &frontend, Some(&write))?;
        self.reload_presentation(&registry)?;
        Ok(AppTabBrowser::Recorded(browser_id))
    }

    /// An app tab in `workspace`'s active pane, or in a new first pane of an
    /// empty workspace.
    fn new_app_tab_in(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        mut fields: Map<String, Value>,
    ) -> anyhow::Result<Arc<Surface>> {
        let selectors = self
            .ordinary_workspace_selectors(workspace)
            .with_context(|| format!("unknown workspace {workspace}"))?;
        fields.insert("url".into(), Value::String(APP_TAB_URL.to_string()));
        let operation = crate::resource::ResourceOperation::TabCreateBrowser;
        let commit = self.commit_ordinary_topology_operation(operation, selectors, fields)?;
        self.emit_resource_topology_legacy_events(operation, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// v2 `tab.create_app`: the `tab.create_browser` creation path (with its
    /// `expected_revision`) and the app record committed first under the
    /// request's idempotency key.
    pub(crate) fn state_create_app_tab(
        self: &Arc<Self>,
        selectors: crate::ResourceSelectors,
        record: AppTabRecord,
        mut fields: Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<(SurfaceId, bool)> {
        record.validate()?;
        let key = Some((mutation.origin.as_str(), mutation.id.as_str()));
        let browser_id = match self.app_tab_browser(&record, key)? {
            AppTabBrowser::Placed(surface) => return Ok((surface.id, true)),
            AppTabBrowser::Recorded(browser_id) => browser_id,
        };
        fields.remove("app");
        fields.remove("route");
        fields.insert("url".into(), Value::String(APP_TAB_URL.to_string()));
        fields.insert("frontend_browser_id".into(), Value::String(browser_id.as_str().into()));
        let operation = crate::resource::ResourceOperation::TabCreateBrowser;
        let commit = self.resource_topology_operation(
            operation,
            selectors,
            fields,
            expected_revision,
            mutation,
        )?;
        if !commit.replayed {
            self.publish_journal_event();
        }
        Ok((self.resource_surface_for_created_path(&commit.result)?, commit.replayed))
    }
}

impl Mux {
    /// `workspace.create {initial_content: "app", initial: {app, route?}}`
    /// and raw `create-workspace {initial}`: a new ordinary workspace whose
    /// only tab is an app tab, in one commit (the session-target
    /// `tab.create_browser` path, which makes the workspace with its tab),
    /// so no client sees it empty. A retry with the same key returns the
    /// same tab.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn state_create_app_workspace(
        self: &Arc<Self>,
        name: Option<String>,
        key: Option<String>,
        ephemeral: bool,
        record: AppTabRecord,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<(SurfaceId, bool)> {
        let mut fields = Map::from_iter([("new_workspace".to_string(), Value::Bool(true))]);
        if let Some(name) = name {
            Self::validate_workspace_name(&name)?;
            fields.insert("workspace_name".into(), Value::String(name));
        }
        if let Some(key) = key {
            anyhow::ensure!(
                crate::workspace_registry::is_canonical_workspace_key(&key),
                "bad request: workspace key must be a lowercase UUID"
            );
            fields.insert("workspace_key".into(), Value::String(key));
        }
        if ephemeral {
            fields.insert("workspace_ephemeral".into(), Value::Bool(true));
        }
        let selectors = Self::ordinary_resource_selectors();
        self.state_create_app_tab(selectors, record, fields, expected_revision, mutation)
    }
}

enum AppTabBrowser {
    /// A keyed retry whose tab exists.
    Placed(Arc<Surface>),
    /// The browser id to create the tab under.
    Recorded(BrowserPublicId),
}
