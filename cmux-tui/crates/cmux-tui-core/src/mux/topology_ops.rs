//! The topology ops of the legacy control protocol and the in-process TUI
//! (moved out of mux.rs for P8 landing 3a): each names the actor it acts as,
//! and commits through the ordinary topology path.

use super::*;

impl Mux {
    pub(crate) fn create_terminal_result_in_workspace_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunCommandResult> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_workspace_selectors(workspace)
            .with_context(|| format!("unknown workspace {workspace}"))?;
        let operation = if argv.is_some() {
            ResourceOperation::WorkspaceRun
        } else {
            ResourceOperation::TabCreateTerminal
        };
        let mut fields = Map::new();
        if let Some(argv) = argv {
            fields
                .insert("argv".into(), Value::Array(argv.into_iter().map(Value::String).collect()));
        }
        Self::insert_optional_string(&mut fields, "cwd", cwd);
        Self::insert_optional_string(&mut fields, "name", name);
        Self::insert_cell_size(&mut fields, size);
        let commit =
            self.commit_ordinary_topology_operation_by(actor, operation, selectors, fields)?;
        self.emit_resource_topology_legacy_events(operation, &commit);
        let terminal_id = self.created_terminal_host_id(&commit.result)?;
        let surface = self.ordinary_created_surface(&commit).ok();
        drop(_creation_handoff);
        if let Some(surface) = surface.as_ref() {
            self.reap_if_dead(surface);
        }
        self.created_terminal_run_result(&terminal_id)
    }

    pub(super) fn create_terminal_surface_in_workspace(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<(Arc<Surface>, RunPlacement)> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_workspace_selectors(workspace)
            .with_context(|| format!("unknown workspace {workspace}"))?;
        let operation = if argv.is_some() {
            ResourceOperation::WorkspaceRun
        } else {
            ResourceOperation::TabCreateTerminal
        };
        let mut fields = Map::new();
        if let Some(argv) = argv {
            fields
                .insert("argv".into(), Value::Array(argv.into_iter().map(Value::String).collect()));
        }
        Self::insert_optional_string(&mut fields, "cwd", cwd);
        Self::insert_optional_string(&mut fields, "name", name);
        Self::insert_cell_size(&mut fields, size);
        let commit =
            self.commit_ordinary_topology_operation_by(actor, operation, selectors, fields)?;
        self.emit_resource_topology_legacy_events(operation, &commit);
        let surface = self.ordinary_created_surface(&commit)?;
        let placement = self
            .with_state(|state| run_placement_for_surface(state, surface.id))
            .context("created terminal has no placement")?;
        Ok((surface, placement))
    }

    pub(crate) fn new_browser_tab_with_fields_as(
        self: &Arc<Self>,
        actor: &Actor,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        extra_fields: Map<String, Value>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            if let Some(target) = target {
                drop(state);
                self.ordinary_pane_selectors(target)
                    .with_context(|| format!("unknown pane {target}"))?
            } else if let Some(workspace) = state.workspaces.get(state.active_workspace) {
                let workspace = workspace.id;
                drop(state);
                self.ordinary_workspace_selectors(workspace)
                    .with_context(|| format!("unknown workspace {workspace}"))?
            } else {
                Self::ordinary_resource_selectors()
            }
        };
        let mut fields = Map::from_iter([("url".into(), Value::String(url))]);
        fields.extend(extra_fields);
        if let Some((cols, rows)) = size {
            let (cell_width, cell_height) = self.cell_pixel_size();
            fields.insert("width_px".into(), Value::from(u64::from(cols) * u64::from(cell_width)));
            fields
                .insert("height_px".into(), Value::from(u64::from(rows) * u64::from(cell_height)));
        }
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::TabCreateBrowser,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::TabCreateBrowser, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// `new_pane_right` with a directory, extra environment, and an optional
    /// caller-chosen terminal id (`terminal-placement-env-v1`).
    pub fn new_pane_right_with_options_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        width: f32,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        if !width.is_finite()
            || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
        {
            return Err(ViewportWidthError::OutOfRange { width }.into());
        }
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let mut fields = Map::from_iter([
            ("direction".into(), Value::String("right".into())),
            ("viewport_width".into(), Value::from(width)),
        ]);
        Self::insert_cell_size(&mut fields, size);
        Self::insert_spawn_options(&mut fields, spawn);
        let commit = self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::PaneSplit,
                selectors,
                fields,
            )
            .map_err(|error| {
                // Caller input errors stay visible; spawn failures keep the
                // generic message.
                let message = error.to_string();
                if message.starts_with("bad request") || message.starts_with("terminal_id_exists") {
                    return error;
                }
                eprintln!("cmux-tui: viewport pane PTY creation failed: {error:#}");
                anyhow::anyhow!("pane creation failed")
            })?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSplit, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// `new_pane` with a directory, extra environment, and an optional
    /// caller-chosen terminal id (`terminal-placement-env-v1`).
    pub fn new_pane_with_options_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let mut fields = Map::new();
        Self::insert_cell_size(&mut fields, size);
        Self::insert_spawn_options(&mut fields, spawn);
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::PaneCreate,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneCreate, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// New screen with a name (set in the creating commit) and the spawn
    /// options (directory, env, terminal id, program) of its first terminal.
    pub(crate) fn new_screen_named_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        Ok(self.new_screen_created_as(actor, workspace, name, spawn, size)?.0)
    }

    /// `new_screen_named_as` that also returns the new screen. Both ids are
    /// resolved under the creation handoff, which an exit-close also takes,
    /// so a terminal that exits at once cannot close the screen first.
    pub(crate) fn new_screen_created_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<(Arc<Surface>, ScreenId)> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = match workspace {
            Some(workspace) => self
                .ordinary_workspace_selectors(workspace)
                .with_context(|| format!("unknown workspace {workspace}"))?,
            None => {
                let active = self.with_state(|state| {
                    state.workspaces.get(state.active_workspace).map(|workspace| workspace.id)
                });
                active
                    .and_then(|workspace| self.ordinary_workspace_selectors(workspace))
                    .unwrap_or_else(Self::ordinary_resource_selectors)
            }
        };
        let mut fields = Map::new();
        Self::insert_optional_string(&mut fields, "name", name);
        Self::insert_spawn_options(&mut fields, spawn);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::ScreenCreate,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::ScreenCreate, &commit);
        let surface = self.ordinary_created_surface(&commit)?;
        let screen = self
            .with_state(|state| {
                let pane = state.pane_of(surface.id)?;
                let (wi, si) = state.screen_of(pane)?;
                Some(state.workspaces[wi].screens[si].id)
            })
            .context("created screen disappeared")?;
        drop(_creation_handoff);
        #[cfg(test)]
        if let Some(hook) = self.screen_created_hook.lock().unwrap().take() {
            hook(surface.id);
        }
        Ok((surface, screen))
    }

    /// `new_tab` with a directory, extra environment, and an optional
    /// caller-chosen terminal id (`terminal-placement-env-v1`).
    pub fn new_tab_with_options_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            if let Some(target) = target {
                drop(state);
                self.ordinary_pane_selectors(target)
                    .with_context(|| format!("unknown pane {target}"))?
            } else if let Some(workspace) = state.workspaces.get(state.active_workspace) {
                let workspace = workspace.id;
                drop(state);
                self.ordinary_workspace_selectors(workspace)
                    .with_context(|| format!("unknown workspace {workspace}"))?
            } else {
                Self::ordinary_resource_selectors()
            }
        };
        let mut fields = Map::new();
        Self::insert_cell_size(&mut fields, size);
        Self::insert_spawn_options(&mut fields, spawn);
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::TabCreateTerminal,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::TabCreateTerminal, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Create a workspace with one screen holding one pane with one tab.
    /// Returns the tab's surface. `size` is the expected content size in
    /// cells, when the caller knows it (spawning at the final size avoids
    /// shell redraw artifacts).
    pub fn new_workspace_as(
        self: &Arc<Self>,
        actor: &Actor,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_workspace_with_spawn_as(
            actor,
            name,
            TerminalSpawnOptions::new(None, Vec::new()),
            size,
        )
    }

    /// `new_workspace_as` whose first terminal starts with `spawn`
    /// (directory, environment, reserved terminal id; Reopen Closed of a
    /// workspace).
    pub(crate) fn new_workspace_with_spawn_as(
        self: &Arc<Self>,
        actor: &Actor,
        name: Option<String>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let mut fields =
            Map::from_iter([("initial_content".into(), Value::String("terminal".into()))]);
        Self::insert_optional_string(&mut fields, "name", name);
        Self::insert_spawn_options(&mut fields, spawn);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::WorkspaceCreate,
            Self::ordinary_resource_selectors(),
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::WorkspaceCreate, &commit);
        self.ordinary_created_surface(&commit)
    }

    pub(crate) fn run_command_result_with_options_as(
        self: &Arc<Self>,
        actor: &Actor,
        argv: Vec<String>,
        options: RunCommandOptions,
    ) -> anyhow::Result<RunCommandResult> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let RunCommandOptions { pane, new_workspace, workspace_key, cwd, name, size } = options;
        if workspace_key.is_some() && !new_workspace {
            anyhow::bail!("workspace key requires a new workspace");
        }
        let (operation, selectors) = if new_workspace {
            (ResourceOperation::WorkspaceCreate, Self::ordinary_resource_selectors())
        } else {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            if let Some(target) = target {
                drop(state);
                (
                    ResourceOperation::PaneRun,
                    self.ordinary_pane_selectors(target)
                        .with_context(|| format!("unknown pane {target}"))?,
                )
            } else if let Some(workspace) = state.workspaces.get(state.active_workspace) {
                let workspace = workspace.id;
                drop(state);
                (
                    ResourceOperation::WorkspaceRun,
                    self.ordinary_workspace_selectors(workspace)
                        .with_context(|| format!("unknown workspace {workspace}"))?,
                )
            } else {
                (ResourceOperation::WorkspaceCreate, Self::ordinary_resource_selectors())
            }
        };
        let mut fields = Map::from_iter([(
            "argv".into(),
            Value::Array(argv.into_iter().map(Value::String).collect()),
        )]);
        if operation == ResourceOperation::WorkspaceCreate {
            fields.insert("initial_content".into(), Value::String("terminal".into()));
            Self::insert_optional_string(&mut fields, "name", name.clone());
            Self::insert_optional_string(&mut fields, "workspace_key", workspace_key);
            Self::insert_optional_string(&mut fields, "terminal_name", name);
        } else {
            Self::insert_optional_string(&mut fields, "name", name);
        }
        Self::insert_optional_string(&mut fields, "cwd", cwd);
        Self::insert_cell_size(&mut fields, size);
        let commit =
            self.commit_ordinary_topology_operation_by(actor, operation, selectors, fields)?;
        self.emit_resource_topology_legacy_events(operation, &commit);
        let terminal_id = self.created_terminal_host_id(&commit.result)?;
        let surface = self.ordinary_created_surface(&commit).ok();
        drop(_creation_handoff);
        if let Some(surface) = surface.as_ref() {
            self.reap_if_dead(surface);
        }
        self.created_terminal_run_result(&terminal_id)
    }

    /// `split` with a directory, extra environment, and an optional
    /// caller-chosen terminal id (`terminal-placement-env-v1`).
    pub fn split_with_options_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        dir: SplitDir,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let direction = match dir {
            SplitDir::Right => "right",
            SplitDir::Down => "down",
        };
        let mut fields = Map::from_iter([("direction".into(), Value::String(direction.into()))]);
        Self::insert_cell_size(&mut fields, size);
        Self::insert_spawn_options(&mut fields, spawn);
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::PaneSplit,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSplit, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Runs a command and optionally creates its workspace with a caller-owned
    /// stable key. The key is only meaningful when `new_workspace` is true.
    pub(crate) fn run_command_surface_with_options_as(
        self: &Arc<Self>,
        actor: &Actor,
        argv: Vec<String>,
        options: RunCommandOptions,
    ) -> anyhow::Result<RunPlacement> {
        self.run_command_result_with_options_as(actor, argv, options)?
            .placement
            .context("command exited before its surface could be returned")
    }

    pub(crate) fn new_screen_with_cwd_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: Option<WorkspaceId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_screen_named_as(
            actor,
            workspace,
            None,
            TerminalSpawnOptions::new(cwd, Vec::new()),
            size,
        )
    }

    /// `new_tab` with extra environment for the new terminal's child only.
    pub fn new_tab_with_env_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        cwd: Option<String>,
        env: Vec<(String, String)>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_with_options_as(actor, pane, TerminalSpawnOptions::new(cwd, env), size)
    }

    /// Create a terminal in a specific workspace without changing the mux's
    /// active workspace. An empty workspace gets its first screen and pane;
    /// otherwise the new surface becomes a tab in that workspace's active
    /// pane. The target is re-resolved under the attach lock so concurrent
    /// first-terminal requests cannot accidentally create another workspace.
    pub fn create_terminal_in_workspace_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.create_terminal_surface_in_workspace(actor, workspace, argv, cwd, name, size)
            .map(|(_, placement)| placement)
    }

    /// Create a browser tab in a pane (default: the active pane). When
    /// the session has no workspaces yet, a workspace is created around
    /// the browser tab.
    pub fn new_browser_tab_as(
        self: &Arc<Self>,
        actor: &Actor,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_with_fields_as(actor, url, pane, size, Map::new())
    }

    /// `split` with an optional directory and extra environment for the new
    /// terminal's child only.
    pub fn split_with_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        dir: SplitDir,
        cwd: Option<String>,
        env: Vec<(String, String)>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_with_options_as(actor, target, dir, TerminalSpawnOptions::new(cwd, env), size)
    }

    /// Add a terminal as a viewport-width column after the target's column.
    ///
    /// Updated frontends render the new column at `width` times their own
    /// viewport width. The ordinary split ratio remains valid fallback data
    /// for older clients.
    pub fn new_pane_right_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_pane_right_with_options_as(
            actor,
            target,
            width,
            TerminalSpawnOptions::default(),
            size,
        )
    }

    /// Create a pane and reapply Zellij's default pane distribution to the
    /// containing screen. The screen stores creation order independently of
    /// the mutable split tree, so swaps and directional splits cannot reorder
    /// terminals when automatic layout resumes.
    pub fn new_pane_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_pane_with_options_as(actor, target, TerminalSpawnOptions::default(), size)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn run_command_surface_as(
        self: &Arc<Self>,
        actor: &Actor,
        argv: Vec<String>,
        pane: Option<PaneId>,
        new_workspace: bool,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.run_command_surface_with_options_as(
            actor,
            argv,
            RunCommandOptions { pane, new_workspace, workspace_key: None, cwd, name, size },
        )
    }

    /// Create a screen in a workspace (default: the active one) with one
    /// pane/tab, and make it active. Returns the tab's surface.
    pub fn new_screen_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_screen_with_cwd_as(actor, workspace, None, size)
    }

    /// Create a tab in a pane (default: the active pane of the active
    /// screen). When the session has no workspaces yet (headless before
    /// any command), a workspace is created around the new tab.
    pub fn new_tab_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_with_env_as(actor, pane, cwd, Vec::new(), size)
    }

    /// Split the screen containing `target`, putting a new single-tab
    /// pane after it. Returns the new pane's surface. `size` is the
    /// expected content size of the new pane, when the caller knows it.
    pub fn split_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_with_as(actor, target, dir, None, Vec::new(), size)
    }

    /// A topology op of `actor` on the legacy and TUI paths (P8 landing 3a).
    pub(crate) fn commit_ordinary_topology_operation_by(
        self: &Arc<Self>,
        actor: &Actor,
        operation: ResourceOperation,
        selectors: crate::ResourceSelectors,
        fields: Map<String, Value>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
        self.commit_resource_topology_operation(operation, selectors, fields, None, &mutation)
    }
}
