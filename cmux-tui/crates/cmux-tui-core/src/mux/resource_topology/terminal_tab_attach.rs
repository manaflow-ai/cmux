//! The attach of a new terminal tab to its pane: the spawn, the slot in the pane's strip and
//! the `tab-added` delta, in one state lock. The slot is the strip index that the creation
//! names (`tab_slot`), else the `place` of its request (`tab_place`), else the end. The tab
//! takes the active tab of the pane, but not from the tab of a create request that arrived
//! after its own: a terminal launches while later requests make their tabs.

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
        mut spot: tab_strip::tab_place::Spot,
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
        let mut joins = None;
        let attached = {
            let mut state = self.state.lock().unwrap();
            if let Err(error) = ensure_pane_takes_tabs(operation, &state, target) {
                refused = Some(error);
            }
            // The strip index of the creation (`tab_slot`: Reopen Closed puts
            // a tab back in place) wins over the `place` of its request.
            let landing = match spot.index {
                None if refused.is_none() => {
                    spot.placed.land(&state, &notifications.presentation, target, surface.id, true)
                }
                _ => None,
            };
            let active = refused.is_none()
                && match &landing {
                    Some(landing) => landing.active,
                    None => spot.placed.takes_active(&state, target),
                };
            let pane = if refused.is_some() { None } else { state.panes.get_mut(&target) };
            let delta = match pane {
                Some(pane) => {
                    let end = pane.tabs.len();
                    let index = match landing {
                        Some(landing) => {
                            joins = landing.joins;
                            landing.index.min(end)
                        }
                        None => tab_strip::tab_slot::slot(spot.index, end),
                    };
                    pane.tabs.insert(index, surface.id);
                    if active {
                        pane.active_tab = index;
                        pane.active_at = active_at;
                    } else if end > 0 && pane.active_tab >= index {
                        // The tab of a later request is active: it stays
                        // active one slot to the right, and the pane keeps
                        // its place in the focus order. A pane that had no
                        // tab has no active tab to move: its index stays 0.
                        pane.active_tab = pane.active_tab.saturating_add(1);
                    }
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
                        transaction: spot.placed.transaction.take(),
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
        self.join_new_tab(surface.id, joins);
        self.reap_if_dead(&surface);
        Ok(created)
    }
}
