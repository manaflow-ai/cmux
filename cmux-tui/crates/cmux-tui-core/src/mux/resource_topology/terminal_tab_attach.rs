//! The attach of a new terminal tab to its pane: the spawn, the slot in the pane's strip and
//! the `tab-added` delta, in one state lock.

use super::*;

impl Mux {
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
        let notifications = self.tree_decorations_placing(&surface);
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
                        mutation: None,
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
}
