//! Resource topology effect execution: effect intents, the executor, effect slots and created paths, and the per-effect create, rename, add-pane and layout-apply steps.

use super::client_ids::{
    requested_client_pane_id, requested_client_split_id, requested_client_tab_id,
    requested_reopen_tab_id,
};
use super::*;
use crate::state::app_workspaces::{APP_WORKSPACE_FIELD, APP_WORKSPACE_NAME_FIELD};
use cmux_json::JsonSet as _;

impl Mux {
    pub(super) fn resource_topology_effect_intent(
        &self,
        operation: ResourceOperation,
        selectors: &ResourceSelectors,
        fields: &Map<String, Value>,
        context: ResourceEffectIntentContext<'_>,
        state: &mut State,
        registry: &WorkspaceRegistry,
    ) -> anyhow::Result<Value> {
        validate_effect_fields(operation, fields)?;
        if operation == ResourceOperation::WorkspaceCreate
            && let Some(name) = fields.get("name").and_then(Value::as_str)
        {
            Self::validate_workspace_name(name)?;
        }
        if operation == ResourceOperation::WorkspaceCreate
            && let Some(key) = fields.get("workspace_key").and_then(Value::as_str)
        {
            anyhow::ensure!(
                state.workspaces.iter().all(|workspace| workspace.key != key),
                "workspace key already exists: {key}"
            );
        }
        if operation == ResourceOperation::TabCreateBrowser {
            let _ = effect_browser_cell_size(self, fields)?;
        }
        let target = effect_target(operation, selectors);
        let resolved = self
            .resolve_resource_path_in_state(state, registry, target, selectors)
            .map_err(anyhow::Error::new)?;
        let mut intent = json!({
            "path":resolved.path,
            "fields":fields,
        });
        let creates = creation_identity_kind(operation, fields);
        if creates == Some(CreatedIdentityKind::Terminal) {
            let terminal_id = match fields.get(RESERVED_TERMINAL_ID_FIELD) {
                Some(requested) => {
                    let requested =
                        requested.as_str().context("bad request: terminal_id must be a string")?;
                    validate_requested_terminal_id(requested)?;
                    anyhow::ensure!(
                        registry.terminal_record(requested)?.is_none(),
                        "terminal_id_exists: {requested}"
                    );
                    requested.to_string()
                }
                None => TerminalId::random()?.to_hex(),
            };
            let mutation = context.mutation.reservation();
            intent.set(
                "terminal_reservation",
                json!({
                    "terminal_id":terminal_id,
                    "mutation_id":mutation.id,
                    "mutation_origin":mutation.origin,
                    "mutation_actor":mutation.actor.wire(),
                }),
            );
            let tab_id = match requested_client_tab_id(fields, state, registry)? {
                Some(tab_id) => Some(tab_id),
                None => requested_reopen_tab_id(fields, state, registry)?,
            };
            if let Some(tab_id) = tab_id {
                intent.set_path(&["terminal_reservation", "tab_id"], json!(tab_id));
            }
        }
        // FC-1: a terminal tab or `pane.run` aimed at a pinned column that takes no tabs (Home's dock
        // before its `allow_tabs`, or one closed to tabs) opens in a new column right of the dock
        // instead of a `dock-column-pinned` refusal. Decided here, under the state lock, and stored
        // in the intent, so the operation, its fingerprint and a replay stay the caller's, and every
        // creator gets it: the JSON-lines `new-tab`, `tab.create_terminal`, the receipted
        // `create-surface-with-receipt` (the TUI, the SDKs), and `pane.run`.
        let beside_closed_dock =
            matches!(operation, ResourceOperation::TabCreateTerminal | ResourceOperation::PaneRun)
                .then(|| {
                    resolved.pane.and_then(|pane| terminal_column_beside_closed_dock(state, pane))
                })
                .flatten();
        if let Some(width) = beside_closed_dock {
            intent.set(BESIDE_CLOSED_DOCK_FIELD, json!({ "viewport_width": width }));
            intent.set("pane_reservation", json!({ "pane_id": PanePublicId::random()? }));
            intent.set("split_reservation", json!({ "split_id": SplitPublicId::random()? }));
        }
        if matches!(operation, ResourceOperation::PaneSplit | ResourceOperation::PaneCreate) {
            // The new pane's public id is fixed here, so a creation resumed
            // after a restart makes the same pane (`split-client-keys-v1`).
            let pane_id = match requested_client_pane_id(fields, state, registry)? {
                Some(pane_id) => pane_id,
                None => PanePublicId::random()?,
            };
            intent.set("pane_reservation", json!({ "pane_id": pane_id }));
        }
        if operation == ResourceOperation::PaneSplit {
            // The new split's public id is fixed here too: the caller's
            // (`split-client-split-id-v1`), so the layout names the split the
            // caller already shows, else a new one, so the first layout that
            // holds the split already names it.
            let split_id = match requested_client_split_id(fields, state, registry)? {
                Some(split_id) => split_id,
                None => SplitPublicId::random()?,
            };
            intent.set("split_reservation", json!({ "split_id": split_id }));
        }
        if topology_effect_may_create_workspace(operation) {
            let mutation = context.mutation.reservation();
            let workspace_key = fields
                .get("workspace_key")
                .and_then(Value::as_str)
                .map(str::to_string)
                .map(Ok)
                .unwrap_or_else(Self::new_workspace_key)?;
            intent.set(
                "workspace_reservation",
                json!({
                    "workspace_key":workspace_key,
                    "workspace_public_id":WorkspacePublicId::random()?,
                    "mutation_id":mutation.id,
                    "mutation_origin":mutation.origin,
                    "mutation_actor":mutation.actor.wire(),
                }),
            );
        }
        if creates == Some(CreatedIdentityKind::Browser) {
            // A frontend-rendered browser registers its content id before
            // the tab commits, so the creation must use that exact id.
            let browser_id = match fields.get("frontend_browser_id").and_then(Value::as_str) {
                Some(id) => Mux::unbound_frontend_browser_id(&registry.connection.get(), id)?,
                None => BrowserPublicId::random()?,
            };
            let tab_id = match requested_reopen_tab_id(fields, state, registry)? {
                Some(tab_id) => tab_id,
                None => TabPublicId::random()?,
            };
            intent.set(
                "browser_reservation",
                json!({
                    "tab_id":tab_id,
                    "browser_id":browser_id,
                }),
            );
        }
        if operation == ResourceOperation::WorkspaceLayoutApply {
            validate_layout_apply_intent(state, &resolved, &fields["layout"])?;
        }
        if operation == ResourceOperation::ScreenLayoutUndo {
            let screen = resolved.screen.context("screen selector has no live screen")?;
            let (workspace_index, screen_index) =
                find_screen(state, screen).context("resolved screen disappeared")?;
            let entry = state.workspaces[workspace_index].screens[screen_index]
                .layout_undo
                .back()
                .cloned()
                .ok_or(LayoutUndoError::Unavailable)?;
            let current_revision =
                state.workspaces[workspace_index].screens[screen_index].layout_revision;
            if entry.after_revision != current_revision {
                return Err(LayoutUndoError::Stale(
                    "layout changed since the last undoable action".to_string(),
                )
                .into());
            }
            if let Some(expected) = fields.get("expected_layout_revision").and_then(Value::as_u64)
                && expected != entry.after_revision
            {
                return Err(LayoutUndoError::Stale(format!(
                    "layout revision conflict: expected {expected}, current {}",
                    entry.after_revision
                ))
                .into());
            }
            let confirm_close =
                fields.get("confirm_close").and_then(Value::as_bool).unwrap_or(false);
            if !entry.created_panes.is_empty() && !confirm_close {
                let details = layout_undo_confirmation_details(
                    state,
                    registry,
                    workspace_index,
                    screen_index,
                )?;
                return Err(anyhow::Error::new(ResourceError::new(
                    "confirmation.required",
                    "layout undo would close panes",
                    details,
                    false,
                )));
            }
            if !entry.created_panes.is_empty() {
                let details = layout_undo_confirmation_details(
                    state,
                    registry,
                    workspace_index,
                    screen_index,
                )?;
                let confirmation_matches = context.expected_revision.is_some()
                    && fields
                        .get("confirmation_token")
                        .and_then(Value::as_str)
                        .is_some_and(|token| details["confirmation_token"].as_str() == Some(token));
                if !confirmation_matches {
                    return Err(anyhow::Error::new(ResourceError::new(
                        "confirmation.required",
                        "layout undo confirmation is missing or stale",
                        details,
                        false,
                    )));
                }
            }
            intent.set("layout_revision", json!(entry.after_revision));
        }
        Ok(intent)
    }

    pub(super) fn execute_resource_topology_effect(
        self: &Arc<Self>,
        actor: &Actor,
        operation: ResourceOperation,
        intent: &Value,
    ) -> anyhow::Result<Value> {
        let fields =
            intent["fields"].as_object().context("stored topology intent has invalid fields")?;
        let path: ResolvedResourcePath = serde_json::from_value(intent["path"].clone())
            .context("stored topology intent has an invalid path")?;
        match operation {
            ResourceOperation::WorkspaceCreate => {
                let argv = if fields.contains_key("argv") || fields.contains_key("shell") {
                    Some(effect_command(fields)?)
                } else {
                    None
                };
                let options = TerminalEffectOptions {
                    argv,
                    cwd: optional_owned_string(fields, "cwd")?,
                    name: optional_owned_string(fields, "terminal_name")?,
                    created_screen_name: None,
                    size: effect_cell_size(fields)?,
                    // Internal owner jobs retain their terminal view.
                    // Generic workspace.create still rejects this field
                    // at catalog admission, preserving its public shape.
                    on_exit: effect_on_exit(fields)?,
                };
                let name = optional_owned_string(fields, "name")?;
                let create = || self.effect_create_workspace_terminal(intent, name, options);
                // The stored `placement` (#29875), so a creation run again
                // after a restart still goes where its request named.
                let placement = fields
                    .get("placement")
                    .and_then(Value::as_str)
                    .and_then(crate::user_settings::NewWorkspacePlacement::from_wire);
                match placement {
                    Some(placement) => placement.scoped(create),
                    None => create(),
                }
                .map(|created| created.path)
            }
            ResourceOperation::WorkspaceClose => {
                let target =
                    self.effect_slots(&path)?.workspace.context("workspace disappeared")?;
                anyhow::ensure!(
                    self.close_workspace_at_revision_for_resource_effect(actor, target)?.is_some(),
                    "workspace disappeared"
                );
                Ok(json!({}))
            }
            ResourceOperation::WorkspaceRun => {
                let target =
                    self.effect_slots(&path)?.workspace.context("workspace disappeared")?;
                self.effect_create_terminal_in_workspace(
                    intent,
                    target,
                    TerminalEffectOptions {
                        argv: Some(effect_command(fields)?),
                        cwd: optional_owned_string(fields, "cwd")?,
                        name: optional_owned_string(fields, "name")?,
                        created_screen_name: None,
                        size: effect_cell_size(fields)?,
                        on_exit: effect_on_exit(fields)?,
                    },
                )
                .map(|created| created.path)
            }
            ResourceOperation::WorkspaceLayoutApply => {
                self.execute_layout_apply(&path, &fields["layout"])?;
                let workspace =
                    path.workspace.as_ref().context("layout intent omitted workspace id")?;
                Ok(json!({"workspace":workspace}))
            }
            ResourceOperation::ScreenCreate => {
                let slots = self.effect_slots(&path)?;
                let name = optional_owned_string(fields, "name")?;
                let cwd = optional_owned_string(fields, "cwd")?;
                let argv = optional_effect_command(fields)?;
                match slots.workspace {
                    Some(workspace) => self.effect_add_screen(
                        intent,
                        workspace,
                        name,
                        cwd,
                        argv,
                        effect_cell_size(fields)?,
                    ),
                    None => self.effect_create_workspace_terminal(
                        intent,
                        None,
                        TerminalEffectOptions {
                            argv,
                            cwd,
                            name: None,
                            created_screen_name: name,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                }
                .map(|created| created.path)
            }
            ResourceOperation::ScreenClose => {
                let target = self.effect_slots(&path)?.screen.context("screen disappeared")?;
                anyhow::ensure!(
                    self.close_screen_for_resource_effect(target)?,
                    "screen disappeared"
                );
                Ok(json!({}))
            }
            ResourceOperation::ScreenLayoutUndo => {
                let slots = self.effect_slots(&path)?;
                let pane = slots.pane.context("undo screen has no active pane")?;
                let revision = intent["layout_revision"]
                    .as_u64()
                    .context("stored undo intent omitted its layout revision")?;
                let confirmation_token = fields.get("confirmation_token").and_then(Value::as_str);
                match self.undo_layout_with_confirmation_token_for_resource_effect(
                    pane,
                    Some(revision),
                    fields.get("confirm_close").and_then(Value::as_bool).unwrap_or(false),
                    confirmation_token,
                )? {
                    LayoutUndoResult::Undone { .. } => {
                        let screen =
                            path.screen.as_ref().context("undo intent omitted screen id")?;
                        Ok(json!({"screen":screen}))
                    }
                    LayoutUndoResult::ConfirmationRequired { .. } => {
                        anyhow::bail!("validated layout undo unexpectedly requires confirmation")
                    }
                }
            }
            ResourceOperation::PaneCreate => {
                let slots = self.effect_slots(&path)?;
                match slots.pane {
                    Some(target) => self.effect_add_pane(
                        intent,
                        target,
                        PaneAddOptions {
                            direction: None,
                            argv: optional_effect_command(fields)?,
                            cwd: optional_owned_string(fields, "cwd")?,
                            size: effect_cell_size(fields)?,
                            ratio: None,
                            viewport_width: None,
                            row_height: None,
                            focus: true,
                            name: None,
                            on_exit: None,
                        },
                    ),
                    None if slots.workspace.is_some() => self.effect_create_terminal_in_workspace(
                        intent,
                        slots.workspace.expect("checked"),
                        TerminalEffectOptions {
                            argv: optional_effect_command(fields)?,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: None,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                    None => self.effect_create_workspace_terminal(
                        intent,
                        None,
                        TerminalEffectOptions {
                            argv: optional_effect_command(fields)?,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: None,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                }
                .map(|created| created.path)
            }
            ResourceOperation::PaneSplit => {
                let target = self.effect_slots(&path)?.pane.context("pane disappeared")?;
                self.effect_add_pane(
                    intent,
                    target,
                    PaneAddOptions {
                        direction: Some(required_str(fields, "direction")?),
                        argv: optional_effect_command(fields)?,
                        cwd: optional_owned_string(fields, "cwd")?,
                        size: effect_cell_size(fields)?,
                        ratio: fields
                            .get("ratio")
                            .and_then(Value::as_f64)
                            .map(|value| value as f32),
                        viewport_width: fields
                            .get("viewport_width")
                            .and_then(Value::as_f64)
                            .map(|value| value as f32),
                        row_height: rows::row_height_field(fields)?,
                        // Absent only on the daemon's own and the user's
                        // splits: the resource router sends `focus: false`
                        // for a caller that did not ask.
                        focus: fields
                            .get(PANE_SPLIT_FOCUS_FIELD)
                            .and_then(Value::as_bool)
                            .unwrap_or(true),
                        name: None,
                        on_exit: None,
                    },
                )
                .map(|created| created.path)
            }
            ResourceOperation::PaneClose => {
                let target = self.effect_slots(&path)?.pane.context("pane disappeared")?;
                anyhow::ensure!(self.close_pane_for_resource_effect(target)?, "pane disappeared");
                Ok(json!({}))
            }
            ResourceOperation::PaneRun => {
                let target = self.effect_slots(&path)?.pane.context("pane disappeared")?;
                self.effect_add_terminal_tab(
                    intent,
                    target,
                    Some(effect_command(fields)?),
                    optional_owned_string(fields, "cwd")?,
                    optional_owned_string(fields, "name")?,
                    effect_cell_size(fields)?,
                    effect_on_exit(fields)?,
                    None,
                )
                .map(|created| created.path)
            }
            ResourceOperation::TabCreateTerminal => {
                let slots = self.effect_slots(&path)?;
                match slots.pane {
                    Some(pane) => self.effect_add_terminal_tab(
                        intent,
                        pane,
                        optional_effect_command(fields)?,
                        optional_owned_string(fields, "cwd")?,
                        optional_owned_string(fields, "name")?,
                        effect_cell_size(fields)?,
                        None,
                        tab_strip::tab_slot::effect_index(fields),
                    ),
                    None if slots.workspace.is_some() => self.effect_create_terminal_in_workspace(
                        intent,
                        slots.workspace.expect("checked"),
                        TerminalEffectOptions {
                            argv: optional_effect_command(fields)?,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: optional_owned_string(fields, "name")?,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                    None => self.effect_create_workspace_terminal(
                        intent,
                        None,
                        TerminalEffectOptions {
                            argv: optional_effect_command(fields)?,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: optional_owned_string(fields, "name")?,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                }
                .map(|created| created.path)
            }
            ResourceOperation::TabCreateBrowser => {
                let slots = self.effect_slots(&path)?;
                let size = effect_browser_cell_size(self, fields)?;
                let identity = self.effect_browser_reservation(intent)?;
                let surface = match slots.pane {
                    Some(pane) => self.new_browser_tab_for_effect(fields, pane, size, identity)?,
                    None if slots.workspace.is_some() => self.create_browser_surface_in_workspace(
                        slots.workspace.expect("checked"),
                        required_str(fields, "url")?.to_string(),
                        size,
                        Some(identity),
                        frontend_browser_transaction(fields),
                    )?,
                    None => {
                        let (workspace_key, workspace_public_id, workspace_mutation) =
                            self.effect_workspace_reservation(intent)?;
                        // `app-screens-v1`: the app workspace and its kind
                        // row are staged together with the app tab.
                        let mark = match fields.get(APP_WORKSPACE_FIELD).and_then(Value::as_str) {
                            Some(app) => {
                                crate::state::home_store::EmptyWorkspaceMark::App(app.to_string())
                            }
                            None => crate::state::home_store::EmptyWorkspaceMark::None,
                        };
                        let placement = self.create_empty_workspace_for_resource_effect(
                            optional_owned_string(fields, APP_WORKSPACE_NAME_FIELD)?,
                            Some(workspace_key),
                            workspace_public_id,
                            &workspace_mutation,
                            mark,
                        )?;
                        self.create_browser_surface_in_workspace(
                            placement.workspace,
                            required_str(fields, "url")?.to_string(),
                            size,
                            Some(identity),
                            frontend_browser_transaction(fields),
                        )?
                    }
                };
                if let Some(name) = optional_owned_string(fields, "name")? {
                    surface.set_name(Some(name));
                }
                self.created_resource_path(surface.id)
            }
            ResourceOperation::TabClose => {
                let target = self.effect_slots(&path)?.tab.context("tab disappeared")?;
                anyhow::ensure!(self.close_surface_for_resource_effect(target)?, "tab disappeared");
                Ok(json!({}))
            }
            _ => anyhow::bail!("operation is not an effectful topology operation"),
        }
    }

    pub(super) fn effect_slots(&self, path: &ResolvedResourcePath) -> anyhow::Result<EffectSlots> {
        self.with_state(|state| self.effect_slots_in_state(state, path))
    }

    pub(super) fn effect_slots_in_state(
        &self,
        state: &State,
        path: &ResolvedResourcePath,
    ) -> anyhow::Result<EffectSlots> {
        let workspace = path
            .workspace
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .workspaces
                    .get(id)
                    .copied()
                    .with_context(|| format!("workspace {id} disappeared"))
            })
            .transpose()?
            .or_else(|| state.workspaces.get(state.active_workspace).map(|workspace| workspace.id));
        let screen = path
            .screen
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .screens
                    .get(id)
                    .copied()
                    .with_context(|| format!("screen {id} disappeared"))
            })
            .transpose()?
            .or_else(|| {
                workspace.and_then(|workspace| {
                    state.workspace_by_id(workspace)?.active_screen_ref().map(|screen| screen.id)
                })
            });
        let pane = path
            .pane
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .panes
                    .get(id)
                    .copied()
                    .with_context(|| format!("pane {id} disappeared"))
            })
            .transpose()?
            .or_else(|| {
                screen.and_then(|screen| {
                    find_screen(state, screen).map(|(workspace, screen)| {
                        state.workspaces[workspace].screens[screen].active_pane
                    })
                })
            });
        let tab = path
            .tab
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .tabs
                    .get(id)
                    .copied()
                    .with_context(|| format!("tab {id} disappeared"))
            })
            .transpose()?;
        Ok(EffectSlots { workspace, screen, pane, tab, terminal: path.terminal.clone() })
    }

    pub(in crate::mux) fn created_resource_path(
        &self,
        surface: SurfaceId,
    ) -> anyhow::Result<Value> {
        self.with_state(|state| self.created_resource_path_in_state(state, surface))
    }

    pub(in crate::mux) fn created_resource_path_in_state(
        &self,
        state: &State,
        surface: SurfaceId,
    ) -> anyhow::Result<Value> {
        let pane = state.pane_of(surface).context("created surface has no pane")?;
        let (workspace_index, screen_index) =
            state.screen_of(pane).context("created pane has no screen")?;
        let workspace = &state.workspaces[workspace_index];
        let screen = &workspace.screens[screen_index];
        let pane_id = state
            .resource_indexes
            .pane_ids
            .get(&pane)
            .context("created pane has no public identity")?;
        let live = state.surfaces.get(&surface).context("created surface disappeared")?;
        let identity =
            live.resource_identity().context("created surface has no resource identity")?;
        Ok(match &identity.content_id {
            ContentPublicId::Terminal(id) => json!({
                "kind":"terminal",
                "workspace_id":workspace.public_id,
                "screen_id":screen.public_id,
                "pane_id":pane_id,
                "tab_id":identity.tab_id,
                "terminal_id":id,
            }),
            ContentPublicId::Browser(id) => json!({
                "kind":"browser",
                "workspace_id":workspace.public_id,
                "screen_id":screen.public_id,
                "pane_id":pane_id,
                "tab_id":identity.tab_id,
                "browser_id":id,
            }),
        })
    }

    pub(super) fn effect_browser_reservation(
        &self,
        intent: &Value,
    ) -> anyhow::Result<TabResourceIdentity> {
        let stored = intent["browser_reservation"]
            .as_object()
            .context("stored topology intent omitted its browser reservation")?;
        let tab_id = TabPublicId::parse(
            stored["tab_id"]
                .as_str()
                .context("stored browser reservation omitted its tab id")?
                .to_string(),
        )?;
        let browser_id = BrowserPublicId::parse(
            stored["browser_id"]
                .as_str()
                .context("stored browser reservation omitted its browser id")?
                .to_string(),
        )?;
        Ok(TabResourceIdentity::persisted_browser(tab_id, browser_id))
    }

    pub(super) fn effect_create_workspace_terminal(
        self: &Arc<Self>,
        intent: &Value,
        workspace_name: Option<String>,
        options: TerminalEffectOptions,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let (workspace_key, workspace_public_id, workspace_mutation) =
            self.effect_workspace_reservation(intent)?;
        // `workspace.create {ephemeral: true}` stages the flag with the
        // workspace row; the request's fields are part of its fingerprint.
        let ephemeral = intent["fields"]["ephemeral"].as_bool().unwrap_or(false);
        // `workspace.create` from a caller: the resource router sends
        // `focus: false` unless it asked. Other creations focus.
        let focus = intent["fields"][WORKSPACE_CREATE_FOCUS_FIELD].as_bool().unwrap_or(true);
        crate::debug_spans::mark("effect.workspace_reserved");
        let placement = self.create_empty_workspace_for_resource_effect_focus(
            workspace_name,
            Some(workspace_key),
            workspace_public_id,
            &workspace_mutation,
            crate::state::home_store::EmptyWorkspaceMark::ephemeral(ephemeral),
            focus,
        )?;
        crate::debug_spans::mark("effect.workspace_created");
        self.effect_create_terminal_in_workspace(intent, placement.workspace, options)
    }

    pub(super) fn effect_create_terminal_in_workspace(
        self: &Arc<Self>,
        intent: &Value,
        workspace: WorkspaceId,
        options: TerminalEffectOptions,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let TerminalEffectOptions { argv, cwd, name, created_screen_name, size, on_exit } = options;
        let workspace_key = self
            .with_state(|state| state.workspace_by_id(workspace).map(|item| item.key.clone()))
            .with_context(|| format!("workspace {workspace} disappeared"))?;
        let reservation = self.effect_terminal_reservation(
            intent,
            &workspace_key,
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
            on_exit,
        )?;
        let terminal_hex = reservation.terminal_id.to_hex();
        crate::debug_spans::mark("effect.terminal_reserved");
        // The reservation's env is the creation's own (`env` field), so a
        // create into a fresh workspace gets it like one into a pane.
        let result = self.create_terminal_in_workspace_with_mutation_env(
            workspace,
            argv,
            cwd,
            name,
            size,
            Some(&terminal_hex),
            None,
            None,
            &reservation.mutation,
            on_exit,
            reservation.env.clone(),
        )?;
        crate::debug_spans::mark("effect.terminal_created");
        let surface =
            result.created_surface.context("created terminal result omitted its local surface")?;
        if let Some(name) = created_screen_name {
            self.effect_rename_created_screen(surface, name)?;
        }
        let path =
            result.created_path.context("created terminal result omitted its public path")?;
        if let Some(surface) = self.surface(surface) {
            self.reap_if_dead(&surface);
        }
        Ok(CreatedTerminalEffect { path })
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn effect_add_terminal_tab(
        self: &Arc<Self>,
        intent: &Value,
        target: PaneId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        on_exit: Option<TerminalOnExit>,
        index: Option<usize>,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        // FC-1: the intent decided that the target is a pinned dock that takes no tabs: the
        // terminal opens in a new column right of it, keeping the focus where it was.
        if let Some(width) =
            intent[BESIDE_CLOSED_DOCK_FIELD]["viewport_width"].as_f64().map(|width| width as f32)
        {
            return self.effect_add_pane(
                intent,
                target,
                PaneAddOptions {
                    direction: Some("right"),
                    argv,
                    cwd,
                    size,
                    ratio: None,
                    viewport_width: Some(width),
                    row_height: None,
                    focus: false,
                    name,
                    on_exit,
                },
            );
        }
        // `pinned-dock-v1`: a pinned column that takes no tabs refuses
        // before anything spawns, and again when the tab attaches.
        let operation = ResourceOperation::TabCreateTerminal.wire_name();
        self.with_state(|state| ensure_pane_takes_tabs(operation, state, target))?;
        let workspace_key = self
            .workspace_key_for_pane(target)
            .with_context(|| format!("pane {target} has no workspace"))?;
        let cwd = self.new_terminal_cwd(cwd, Some(target), None);
        let reservation = self.effect_terminal_reservation(
            intent,
            &workspace_key,
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
            on_exit,
        )?;
        let surface =
            self.spawn_surface_in_workspace_reserved(&workspace_key, cwd, size, argv, reservation)?;
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        let active_at = self.next_active_at();
        let notifications = self.tree_decorations();
        let mut refused = None;
        let attached = {
            let mut state = self.state.lock().unwrap();
            if let Err(error) = ensure_pane_takes_tabs(operation, &state, target) {
                refused = Some(error);
            }
            let pane = if refused.is_some() { None } else { state.panes.get_mut(&target) };
            let delta = match pane {
                Some(pane) => {
                    // At its end, or at the strip index the creation names
                    // (`tab_slot`: Reopen Closed puts a tab back in place).
                    let index = tab_strip::tab_slot::slot(index, pane.tabs.len());
                    pane.tabs.insert(index, surface.id);
                    pane.active_tab = index;
                    pane.active_at = active_at;
                    fence_layout_undo_for_tab_membership(&mut state, &[target]);
                    state.register_placed_tab_identity(surface.id);
                    let (workspace_index, screen_index) =
                        state.screen_of(target).expect("live pane belongs to a screen");
                    let workspace = state.workspaces[workspace_index].id;
                    let screen = state.workspaces[workspace_index].screens[screen_index].id;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )
                    .expect("new terminal tab is present in tree snapshot");
                    Some(TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    })
                }
                None => None,
            };
            delta
                .map(|delta| {
                    self.created_resource_path_in_state(&state, surface.id)
                        .map(|path| (delta, CreatedTerminalEffect { path }))
                })
                .transpose()?
        };
        if let Some(error) = refused {
            self.fail_hosted_terminal_attachment(
                &surface,
                "resource-terminal-tab-attach-failed",
                "pinned-column-takes-no-tabs",
            )?;
            return Err(error);
        }
        let Some((delta, created)) = attached else {
            self.fail_hosted_terminal_attachment(
                &surface,
                "resource-terminal-tab-attach-failed",
                "pane-disappeared-before-attach",
            )?;
            anyhow::bail!("pane disappeared while creating tab");
        };
        self.emit_tree_delta(delta, true);
        self.reap_if_dead(&surface);
        Ok(created)
    }

    pub(super) fn effect_rename_created_screen(
        &self,
        surface: SurfaceId,
        name: String,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let pane = state.pane_of(surface).context("created screen surface has no pane")?;
        let (workspace, screen) = state.screen_of(pane).context("created pane has no screen")?;
        state.workspaces[workspace].screens[screen].name = Some(name);
        Ok(())
    }

    pub(super) fn effect_add_pane(
        self: &Arc<Self>,
        intent: &Value,
        target: PaneId,
        options: PaneAddOptions<'_>,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let PaneAddOptions {
            direction,
            argv,
            cwd,
            size,
            ratio,
            viewport_width,
            row_height,
            focus,
            name,
            on_exit,
        } = options;
        let split_direction = direction
            .map(|direction| {
                Ok(match direction {
                    "left" => (SplitDir::Right, true),
                    "right" => (SplitDir::Right, false),
                    "up" => (SplitDir::Down, true),
                    "down" => (SplitDir::Down, false),
                    _ => anyhow::bail!("invalid pane split direction {direction:?}"),
                })
            })
            .transpose()?;
        let operation = if direction.is_some() {
            ResourceOperation::PaneSplit
        } else {
            ResourceOperation::PaneCreate
        }
        .wire_name();
        // Split Down (`down`, not swapped above its target) may grow the agent chat dock below
        // its chat (#29848); every other new pane in the dock is refused.
        let splits_down = row_height.is_none() && split_direction == Some((SplitDir::Down, false));
        if viewport_width.is_none() {
            self.with_state(|state| {
                ensure_pane_column_not_agent_chat(operation, state, target, splits_down)
            })?;
        }
        let workspace_key = self
            .workspace_key_for_pane(target)
            .with_context(|| format!("pane {target} has no workspace"))?;
        let pane_public_id = match intent["pane_reservation"]["pane_id"].as_str() {
            Some(reserved) => PanePublicId::parse(reserved.to_string())
                .context("stored topology intent has an invalid pane id")?,
            // An intent stored before pane reservations existed.
            None => PanePublicId::random()?,
        };
        let spawned = self.effect_spawn_pane_surface(
            intent,
            target,
            &workspace_key,
            PaneTerminalSpawn { argv, cwd, size, name, on_exit },
        )?;
        let surface = spawned.surface().clone();
        #[cfg(test)]
        if viewport_width.is_some()
            && let Some(hook) = self.viewport_split_after_spawn.lock().unwrap().clone()
        {
            hook();
        }
        let split_public_id = match intent["split_reservation"]["split_id"].as_str() {
            Some(reserved) => Some(
                SplitPublicId::parse(reserved.to_string())
                    .context("stored topology intent has an invalid split id")?,
            ),
            // An intent stored before split reservations existed: the
            // projection names the split.
            None => None,
        };
        let pane_id = self.next_id();
        let split_id = split_direction.map(|_| self.next_id());
        let base_column_id =
            (viewport_width.is_some() || row_height.is_some()).then(|| self.next_id());
        let base_row_id = row_height.map(|_| self.next_id());
        let active_at = self.next_active_at();
        let notifications = self.tree_decorations();
        // A conversation tab's split (`conversation-tab-split-v1`): its one
        // `pane-added` carries the client transaction.
        let transaction = intent["fields"].as_object().and_then(frontend_browser_transaction);
        let attached = (|| -> anyhow::Result<(TreeDelta, ScreenId, CreatedTerminalEffect)> {
            let mut state = self.state.lock().unwrap();
            // A reserved pane id that became taken since preparation is
            // refused before the layout changes (release builds too).
            anyhow::ensure!(
                !state.resource_indexes.panes.contains_key(&pane_public_id),
                "pane_id_exists: {pane_public_id}"
            );
            if let Some(split_public_id) = &split_public_id {
                anyhow::ensure!(
                    !state.resource_indexes.splits.contains_key(split_public_id),
                    "split_id_exists: {split_public_id}"
                );
            }
            let Some((workspace, screen_index)) = state.screen_of(target) else {
                anyhow::bail!("pane disappeared before new pane attachment");
            };
            if viewport_width.is_none() {
                ensure_pane_column_not_agent_chat(operation, &state, target, splits_down)?;
            }
            let workspace_id = state.workspaces[workspace].id;
            let screen_id = state.workspaces[workspace].screens[screen_index].id;
            let screen = &mut state.workspaces[workspace].screens[screen_index];
            let before = screen.layout_snapshot();
            if let Some(height) = row_height {
                anyhow::ensure!(
                    screen.insert_layout_row_below(
                        target,
                        base_column_id.expect("new row reserved a base column id"),
                        base_row_id.expect("new row reserved a base row id"),
                        crate::model::LayoutRow::new(split_id.expect("row id"), height),
                        pane_id,
                    ),
                    "target pane disappeared from its layout"
                );
            } else if let Some(width) = viewport_width {
                let column = LayoutColumn::single(split_id.expect("column id"), width, pane_id);
                let base = base_column_id.expect("viewport column reserved a base id");
                // `direction: "left"` (`column-left-v1`) opens the column before the target's.
                let before = split_direction.is_some_and(|(_, before_target)| before_target);
                anyhow::ensure!(
                    screen.insert_layout_column_beside(target, base, column, before),
                    "target pane disappeared from its layout"
                );
            } else if let Some((dir, before_target)) = split_direction {
                let split = split_id.expect("split direction reserves an id");
                let in_viewport_column = screen.layout_columns_active();
                let root = if in_viewport_column {
                    let column = screen
                        .layout_column_for_pane_mut(target)
                        .context("target pane has no viewport column")?;
                    column.creation_order_auto_layout = None;
                    &mut column.root
                } else {
                    &mut screen.root
                };
                anyhow::ensure!(
                    root.split_leaf(target, split, dir, pane_id),
                    "target pane disappeared from its layout"
                );
                if before_target {
                    anyhow::ensure!(
                        root.swap_leaves(target, pane_id),
                        "new split leaves could not be ordered"
                    );
                }
                if let Some(new_ratio) = ratio {
                    let split_ratio = if before_target { new_ratio } else { 1.0 - new_ratio };
                    anyhow::ensure!(
                        root.set_split_ratio(split, split_ratio),
                        "new split ratio could not be applied"
                    );
                }
                if in_viewport_column {
                    screen.sync_layout_column_projection();
                } else {
                    screen.creation_order_auto_layout = None;
                }
            } else if screen.layout_columns_active() {
                let column = screen
                    .layout_column_for_pane_mut(target)
                    .context("target pane has no viewport column")?;
                column.edit_row_of(target, |root, auto_layout| {
                    append_to_auto_layout(root, auto_layout, pane_id, || self.next_id());
                });
                screen.sync_layout_column_projection();
            } else {
                append_to_auto_layout(
                    &mut screen.root,
                    &mut screen.creation_order_auto_layout,
                    pane_id,
                    || self.next_id(),
                );
            }
            if focus {
                screen.active_pane = pane_id;
            }
            screen.zoomed_pane = None;
            screen.record_layout_change(before, vec![pane_id], None);
            if let (Some(split), Some(public_id)) = (split_id, split_public_id) {
                state.resource_indexes.splits.insert(public_id.clone(), split);
                state.resource_indexes.split_ids.insert(split, public_id);
            }
            state.insert_pane(Pane {
                id: pane_id,
                public_id: pane_public_id,
                name: None,
                tabs: vec![surface.id],
                active_tab: 0,
                active_at,
                focused_at: 0,
            });
            state.register_placed_tab_identity(surface.id);
            if focus {
                stamp_pane_focus(self, &mut state, pane_id);
            }
            Self::rebuild_split_screen_index(&mut state);
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::PaneAdded,
                pane_id,
            )
            .expect("new pane is present in tree snapshot");
            let pane_index = state
                .workspaces
                .get(workspace)
                .and_then(|workspace| workspace.screens.get(screen_index))
                .context("the new pane's screen left state")?
                .root
                .pane_ids_vec()
                .iter()
                .position(|candidate| *candidate == pane_id)
                .expect("new pane is present in its screen layout");
            let path = self.created_resource_path_in_state(&state, surface.id)?;
            Ok((
                TreeDelta {
                    kind: TreeDeltaKind::PaneAdded,
                    workspace: workspace_id,
                    screen: Some(screen_id),
                    pane: Some(pane_id),
                    surface: None,
                    index: Some(pane_index),
                    entity,
                    workspace_revision: None,
                    transaction,
                },
                screen_id,
                CreatedTerminalEffect { path },
            ))
        })();
        let (delta, changed_screen, created) = match attached {
            Ok(attached) => attached,
            Err(error) => {
                self.fail_pane_surface_attachment(&spawned)?;
                return Err(error);
            }
        };
        self.emit_tree_delta(delta, false);
        self.emit_layout_changed(changed_screen, None);
        self.reap_if_dead(&surface);
        Ok(created)
    }

    pub(super) fn execute_layout_apply(
        &self,
        path: &ResolvedResourcePath,
        document: &Value,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let slots = self.effect_slots_in_state(&state, path)?;
        apply_resource_layout_document(self, &mut state, slots, document)
    }
}
