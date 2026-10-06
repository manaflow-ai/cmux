//! The `screen.create` effect: a new screen holding one new terminal, with
//! the terminal's spawn fields (directory, argv, and through the terminal
//! reservation its environment and caller-chosen id).

use super::*;

impl Mux {
    pub(super) fn effect_add_screen(
        self: &Arc<Self>,
        intent: &Value,
        workspace: WorkspaceId,
        name: Option<String>,
        cwd: Option<String>,
        argv: Option<Vec<String>>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let workspace_key = self
            .with_state(|state| state.workspace_by_id(workspace).map(|item| item.key.clone()))
            .with_context(|| format!("workspace {workspace} disappeared"))?;
        let reservation = self.effect_terminal_reservation(
            intent,
            &workspace_key,
            argv.as_deref(),
            cwd.as_deref(),
            None,
            size,
            None,
        )?;
        let surface =
            self.spawn_surface_in_workspace_reserved(&workspace_key, cwd, size, argv, reservation)?;
        let (pane_id, pane) = match self.make_pane(surface.id) {
            Ok(value) => value,
            Err(error) => {
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "resource-terminal-screen-attach-failed",
                    "pane-identity-allocation-failed",
                )?;
                return Err(error);
            }
        };
        let screen_id = self.next_id();
        let public_id = match ScreenPublicId::random() {
            Ok(value) => value,
            Err(error) => {
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "resource-terminal-screen-attach-failed",
                    "screen-identity-allocation-failed",
                )?;
                return Err(anyhow::Error::new(error));
            }
        };
        let created = {
            let mut state = self.state.lock().unwrap();
            let Some(workspace_index) = state.workspace_index(workspace) else {
                drop(state);
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "resource-terminal-screen-attach-failed",
                    "workspace-disappeared-before-attach",
                )?;
                anyhow::bail!("workspace disappeared while creating screen");
            };
            state.insert_pane(pane);
            stamp_pane_focus(self, &mut state, pane_id);
            let workspace = &mut state.workspaces[workspace_index];
            workspace.screens.push(Screen {
                id: screen_id,
                public_id,
                name,
                root: Node::Leaf(pane_id),
                active_pane: pane_id,
                zoomed_pane: None,
                zellij_auto_layout: Some(vec![pane_id]),
                viewport_splits: Default::default(),
                viewport_base_width: None,
                layout_columns: Vec::new(),
                layout_revision: 0,
                layout_undo: Default::default(),
            });
            workspace.active_screen = workspace.screens.len() - 1;
            let path = self.created_resource_path_in_state(&state, surface.id)?;
            CreatedTerminalEffect { path }
        };
        self.reap_if_dead(&surface);
        Ok(created)
    }
}
