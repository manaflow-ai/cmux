//! The edit ops (close, rename, select, focus, move, swap, zoom) of the legacy
//! control protocol and the in-process TUI (moved out of mux.rs for P8
//! landing 3a): each names the actor it acts as.

use super::*;

impl Mux {
    /// Close a pane and every tab in it.
    pub fn close_pane_as(self: &Arc<Self>, actor: &Actor, target: PaneId) -> anyhow::Result<bool> {
        let Some(selectors) = self.ordinary_pane_selectors(target) else { return Ok(false) };
        let commit = self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::PaneClose,
                selectors,
                Map::new(),
            )
            .with_context(|| format!("close pane {target}"))?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneClose, &commit);
        Ok(true)
    }

    /// Close a screen and every pane/tab in it.
    pub fn close_screen_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: ScreenId,
    ) -> anyhow::Result<bool> {
        let Some(selectors) = self.ordinary_screen_selectors(target) else { return Ok(false) };
        let commit = self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::ScreenClose,
                selectors,
                Map::new(),
            )
            .with_context(|| format!("close screen {target}"))?;
        self.emit_resource_topology_legacy_events(ResourceOperation::ScreenClose, &commit);
        Ok(true)
    }

    /// Close one tab. When it was the pane's last tab, the pane collapses
    /// out of its split tree; when it was the workspace's last tab, the
    /// workspace closes in the same commit (LAST-TAB-CLOSES-WORKSPACE).
    pub fn close_surface_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: SurfaceId,
    ) -> anyhow::Result<bool> {
        let Some(selectors) = self.ordinary_tab_selectors(target) else { return Ok(false) };
        let commit = self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::TabClose,
                selectors,
                Map::new(),
            )
            .with_context(|| format!("close surface {target}"))?;
        self.emit_resource_topology_legacy_events(ResourceOperation::TabClose, &commit);
        Ok(true)
    }

    pub fn focus_direction_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        dir: Direction,
    ) -> anyhow::Result<PaneId> {
        let target = self.with_state(|state| pane.or_else(|| state.active_pane()));
        let Some(target) = target else {
            anyhow::bail!("no active pane");
        };
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let direction = match dir {
            Direction::Left => "left",
            Direction::Right => "right",
            Direction::Up => "up",
            Direction::Down => "down",
        };
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::PaneFocusDirection,
            selectors,
            Map::from_iter([("direction".into(), Value::String(direction.into()))]),
        )?;
        let public_id = PanePublicId::parse(
            commit.result["pane"]
                .as_str()
                .context("pane focus result omitted its pane id")?
                .to_string(),
        )?;
        let next = self
            .with_state(|state| state.resource_indexes.panes.get(&public_id).copied())
            .context("focused pane disappeared")?;
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
        Ok(next)
    }

    /// Make `pane` the active pane of its screen (and that screen and
    /// workspace active).
    pub fn focus_pane_as(self: &Arc<Self>, actor: &Actor, pane: PaneId) -> bool {
        let layout_changed = self.with_state(|state| {
            let (workspace, screen) = state.screen_of(pane)?;
            let screen = &state.workspaces[workspace].screens[screen];
            (screen.active_pane != pane
                && (screen.root.contains_stack_pane(screen.active_pane)
                    || screen.root.contains_stack_pane(pane)))
            .then_some(screen.id)
        });
        let Some(selectors) = self.ordinary_pane_selectors(pane) else { return false };
        if self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::PaneFocus,
                selectors,
                Map::new(),
            )
            .is_err()
        {
            return false;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        if let Some(screen) = layout_changed {
            self.emit(MuxEvent::LayoutChanged(screen));
        } else {
            self.emit(MuxEvent::TreeChanged);
        };
        true
    }

    /// Move an existing tab to `index` in `pane`. The surface is kept
    /// alive; if moving it empties the source pane, that pane collapses
    /// out of its split tree.
    pub fn move_tab_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
    ) -> bool {
        if self.with_state(|state| {
            let Some(source) = state.pane_of(surface) else { return false };
            if source != pane {
                return false;
            }
            let Some(pane) = state.panes.get(&pane) else { return false };
            let Some(old_index) = pane.tabs.iter().position(|candidate| *candidate == surface)
            else {
                return false;
            };
            let final_index = if index > old_index { index.saturating_sub(1) } else { index }
                .min(pane.tabs.len().saturating_sub(1));
            final_index == old_index
        }) {
            return false;
        }
        let Some(selectors) = self.ordinary_tab_selectors(surface) else { return false };
        let Some((destination_workspace, destination_screen, destination_pane, changed_screen)) =
            self.with_state(|state| {
                let (workspace, screen) = state.screen_of(pane)?;
                let source_pane = state.pane_of(surface)?;
                let source_screen = (source_pane != pane
                    && state.panes.get(&source_pane)?.tabs.len() == 1)
                    .then(|| {
                        state.screen_of(source_pane).map(|(workspace, screen)| {
                            state.workspaces[workspace].screens[screen].id
                        })
                    })
                    .flatten();
                Some((
                    state.workspaces[workspace].public_id.to_string(),
                    state.workspaces[workspace].screens[screen].public_id.to_string(),
                    state.resource_indexes.pane_ids.get(&pane)?.to_string(),
                    source_screen,
                ))
            })
        else {
            return false;
        };
        let fields = Map::from_iter([
            ("destination_workspace".into(), Value::String(destination_workspace)),
            ("destination_screen".into(), Value::String(destination_screen)),
            ("destination_pane".into(), Value::String(destination_pane)),
            ("index".into(), Value::from(u64::try_from(index).unwrap_or(u64::MAX))),
        ]);
        let Ok(commit) = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::TabMove,
            selectors,
            fields,
        ) else {
            return false;
        };
        if let Some(surface) = self.surface(surface)
            && let Some(workspace_key) = self.workspace_key_for_pane(pane)
        {
            let _ = surface.persist_host_workspace(&workspace_key);
        }
        self.emit_resource_topology_legacy_events(ResourceOperation::TabMove, &commit);
        if let Some(screen) = changed_screen.filter(|source| {
            self.with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .any(|workspace| workspace.screens.iter().any(|screen| screen.id == *source))
            })
        }) {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        true
    }

    /// Set a pane's user-visible name. An empty name clears it (the pane
    /// falls back to its active tab's title).
    pub fn rename_pane_as(self: &Arc<Self>, actor: &Actor, target: PaneId, name: String) -> bool {
        let Some(selectors) = self.ordinary_pane_selectors(target) else { return false };
        if self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::PaneRename,
                selectors,
                Self::nullable_name_fields(name),
            )
            .is_err()
        {
            return false;
        }
        self.emit(MuxEvent::TreeChanged);
        true
    }

    /// Set a screen's user-visible name. An empty name clears it (the
    /// screen falls back to its number).
    pub fn rename_screen_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: ScreenId,
        name: String,
    ) -> bool {
        let Some(selectors) = self.ordinary_screen_selectors(target) else { return false };
        if self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::ScreenRename,
                selectors,
                Self::nullable_name_fields(name),
            )
            .is_err()
        {
            return false;
        }
        let notifications = self.tree_decorations();
        let renamed = {
            let state = self.state.lock().unwrap();
            let Some(wi) = state
                .workspaces
                .iter()
                .enumerate()
                .find_map(|(wi, workspace)| {
                    workspace
                        .screens
                        .iter()
                        .position(|screen| screen.id == target)
                        .map(|si| (wi, si))
                })
                .map(|(wi, _)| wi)
            else {
                return false;
            };
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::ScreenRenamed,
                target,
            )
            .expect("renamed screen is present in tree snapshot");
            TreeDelta {
                kind: TreeDeltaKind::ScreenRenamed,
                workspace: state.workspaces[wi].id,
                screen: Some(target),
                pane: None,
                surface: None,
                index: None,
                entity,
                workspace_revision: None,
                transaction: None,
            }
        };
        self.emit(MuxEvent::TreeDelta(renamed));
        true
    }

    /// Set a tab's user-visible name. An empty name clears it (the tab
    /// falls back to its process title/number label).
    pub fn rename_surface_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: SurfaceId,
        name: String,
    ) -> bool {
        let Some(selectors) = self.ordinary_tab_selectors(target) else { return false };
        if self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::TabRename,
                selectors,
                Self::nullable_name_fields(name),
            )
            .is_err()
        {
            return false;
        }
        // A kept tab (keep-layout) has no surface after a restart; its tree
        // entry still carries the renamed tab.
        let notifications = self.tree_decorations();
        let delta = {
            let state = self.state.lock().unwrap();
            (|| {
                let pane = state.pane_of(target)?;
                let (wi, si) = state.screen_of(pane)?;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabRenamed,
                    target,
                )?;
                Some(TreeDelta {
                    kind: TreeDeltaKind::TabRenamed,
                    workspace: state.workspaces[wi].id,
                    screen: Some(state.workspaces[wi].screens[si].id),
                    pane: Some(pane),
                    surface: Some(target),
                    index: None,
                    entity,
                    workspace_revision: None,
                    transaction: None,
                })
            })()
        };
        match delta {
            Some(delta) => self.emit(MuxEvent::TreeDelta(delta)),
            None => self.emit(MuxEvent::TreeChanged),
        }
        true
    }

    /// Select a screen in the active workspace by index or relative delta.
    pub fn select_screen_as(
        self: &Arc<Self>,
        actor: &Actor,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let screen = {
            let state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let Some(ws) = state.workspaces.get(active) else { return };
            let len = ws.screens.len();
            if len == 0 {
                return;
            }
            let selected = if let Some(index) = index.filter(|index| *index < len) {
                index
            } else if let Some(delta) = delta {
                ((ws.active_screen as isize + delta).rem_euclid(len as isize)) as usize
            } else {
                ws.active_screen
            };
            ws.screens[selected].id
        };
        let Some(selectors) = self.ordinary_screen_selectors(screen) else { return };
        if self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::ScreenFocus,
                selectors,
                Map::new(),
            )
            .is_err()
        {
            return;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a workspace by index or relative delta.
    pub fn select_workspace_as(
        self: &Arc<Self>,
        actor: &Actor,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let workspace = {
            let state = self.state.lock().unwrap();
            let len = state.workspaces.len();
            if len == 0 {
                return;
            }
            let selected = if let Some(index) = index.filter(|index| *index < len) {
                index
            } else if let Some(delta) = delta {
                ((state.active_workspace as isize + delta).rem_euclid(len as isize)) as usize
            } else {
                state.active_workspace
            };
            state.workspaces[selected].id
        };
        let Some(selectors) = self.ordinary_workspace_selectors(workspace) else { return };
        if self
            .commit_ordinary_topology_operation_by(
                actor,
                ResourceOperation::WorkspaceFocus,
                selectors,
                Map::new(),
            )
            .is_err()
        {
            return;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    pub fn swap_panes_as(self: &Arc<Self>, actor: &Actor, pane: PaneId, target: PaneId) -> bool {
        if pane == target {
            return false;
        }
        let Some(selectors) = self.ordinary_pane_selectors(pane) else { return false };
        let Some((other_workspace, other_screen, other_pane)) = self.with_state(|state| {
            let first = state.screen_of(pane)?;
            let second = state.screen_of(target)?;
            if first != second {
                return None;
            }
            Some((
                state.workspaces[second.0].public_id.to_string(),
                state.workspaces[second.0].screens[second.1].public_id.to_string(),
                state.resource_indexes.pane_ids.get(&target)?.to_string(),
            ))
        }) else {
            return false;
        };
        let fields = Map::from_iter([
            ("other_workspace".into(), Value::String(other_workspace)),
            ("other_screen".into(), Value::String(other_screen)),
            ("other_pane".into(), Value::String(other_pane)),
        ]);
        let Ok(commit) = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::PaneSwap,
            selectors,
            fields,
        ) else {
            return false;
        };
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSwap, &commit);
        true
    }

    pub fn zoom_pane_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        mode: ZoomMode,
    ) -> anyhow::Result<ZoomState> {
        let (target, next, changed) = self.with_state(|state| {
            let target = pane.or_else(|| state.active_pane()).context("no active pane")?;
            let (workspace, screen) =
                state.screen_of(target).with_context(|| format!("unknown pane {target}"))?;
            let current = state.workspaces[workspace].screens[screen].zoomed_pane;
            let next = match mode {
                ZoomMode::Toggle if current == Some(target) => None,
                ZoomMode::Toggle | ZoomMode::On => Some(target),
                ZoomMode::Off => None,
            };
            Ok::<_, anyhow::Error>((target, next, current != next))
        })?;
        if !changed {
            return Ok(ZoomState { pane: target, zoomed: next.is_some(), zoomed_pane: next });
        }
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let fields = match mode {
            ZoomMode::Toggle => Map::new(),
            ZoomMode::On => Map::from_iter([("enabled".into(), Value::Bool(true))]),
            ZoomMode::Off => Map::from_iter([("enabled".into(), Value::Bool(false))]),
        };
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::PaneZoom,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneZoom, &commit);
        let zoomed_pane = self.with_state(|state| {
            state
                .screen_of(target)
                .and_then(|(workspace, screen)| {
                    state.workspaces.get(workspace)?.screens.get(screen)
                })
                .and_then(|screen| screen.zoomed_pane)
        });
        Ok(ZoomState { pane: target, zoomed: zoomed_pane.is_some(), zoomed_pane })
    }
}
