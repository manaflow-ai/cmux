//! Left-button press: what a left click does at each hit target (tabs,
//! rails, menus, prompts, scrollbars, pane borders, terminal and browser
//! content).

use std::time::Instant;

use cmux_tui_core::SurfaceKind;
use crossterm::event::{KeyModifiers, MouseButton};

use crate::app::layout::{FocusTarget, Hit, OmnibarHit, RailKind};
use crate::app::pointer::{Drag, PtyMousePressResult, TerminalPointerAdmission};
use crate::app::selection::SelectionMode;
use crate::app::{
    App, BrowserMouseDispatch, RenderAction, WorkspaceRailSelection, workspace_creation_selection,
};
use crate::browser_input::BrowserInputKind;
use crate::machine::MachineRailSelection;

impl App {
    #[cfg(test)]
    pub(super) fn handle_left_down(
        &mut self,
        x: u16,
        y: u16,
        modifiers: KeyModifiers,
    ) -> anyhow::Result<RenderAction> {
        self.handle_left_down_with_admission(x, y, modifiers, None, Instant::now())
    }

    pub(super) fn handle_left_down_with_admission(
        &mut self,
        x: u16,
        y: u16,
        modifiers: KeyModifiers,
        terminal_admission: Option<TerminalPointerAdmission>,
        now: Instant,
    ) -> anyhow::Result<RenderAction> {
        self.replace_selection(None);
        self.status_selection = None;
        self.finish_active_drag();

        // A repeat is valid only for presses that land directly in a PTY
        // content cell. Shift is the host-selection override when an inner
        // PTY application owns mouse input, so preserve it for repeats.
        let repeat_target = (modifiers == KeyModifiers::NONE || modifiers == KeyModifiers::SHIFT)
            && self.hit_at(x, y).is_none()
            && self.pane_area_at(x, y).is_some_and(|area| {
                self.surface_kind(area.surface) == Some(SurfaceKind::Pty)
                    && self.terminal_input_rect(area).is_some_and(|content| content.contains(x, y))
            });
        if !repeat_target {
            self.reset_selection_click_sequence();
        }

        if self.pairing_dialog.is_some() {
            return self.handle_pairing_click(x, y);
        }
        // An open rename dialog captures the click.
        if self.prompt.is_some() {
            return self.handle_prompt_click(x, y);
        }

        // An open menu captures the click: activate or dismiss. Clicks on
        // the border chrome keep it open without activating.
        if let Some(mut menu) = self.menu.take() {
            if menu.start_scrollbar_drag(x, y) {
                self.menu = Some(menu);
            } else if let Some((depth, item)) = menu.hit_at(x, y) {
                let action = menu.action_at(depth, item);
                menu.select_at(depth, item);
                if let Some(action) = action {
                    let resource_matches = menu
                        .captured_resource(action)
                        .is_none_or(|expected| self.menu_action_resource(action) == expected);
                    if resource_matches {
                        self.activate_menu(action)?;
                    }
                } else {
                    self.menu = Some(menu);
                }
            } else if menu.contains(x, y) {
                self.menu = Some(menu); // padding click: keep it open
            }
            return Ok(RenderAction::Draw);
        }

        if let Some((pane, hit)) = self.omnibar_hit_at(x, y) {
            self.focus_pane_after_input(pane);
            if let Some(state) = self.omnibar.as_mut() {
                if state.pane == pane {
                    if hit == OmnibarHit::Edit
                        && let Some(area) = self
                            .pane_areas
                            .iter()
                            .find(|area| area.pane == pane && area.surface == state.surface)
                        && let Some(rect) = area.omnibar
                    {
                        state.select_all = false;
                        state.input.set_cursor_from_visible_column(
                            x.saturating_sub(rect.x) as usize,
                            rect.width as usize,
                        );
                    }
                    return Ok(RenderAction::Draw);
                }
                self.omnibar = None;
            }
            match hit {
                OmnibarHit::Back => {
                    self.enqueue_browser_command_for_pane(pane, BrowserInputKind::Back);
                }
                OmnibarHit::Forward => {
                    self.enqueue_browser_command_for_pane(pane, BrowserInputKind::Forward);
                }
                OmnibarHit::Reload => {
                    self.enqueue_browser_command_for_pane(pane, BrowserInputKind::Reload);
                }
                OmnibarHit::Edit => self.focus_omnibar(pane),
            }
            return Ok(RenderAction::Draw);
        }

        if let Some(state) = &self.omnibar {
            let editing_rect = self
                .pane_areas
                .iter()
                .find(|area| area.pane == state.pane && area.surface == state.surface)
                .and_then(|area| area.omnibar);
            if !editing_rect.is_some_and(|rect| rect.contains(x, y)) {
                self.omnibar = None;
            }
        }

        if self.config.sidebar.plugin.is_some()
            && self.sidebar_plugin_rect().contains(x, y)
            && self.sidebar_visible
        {
            let requested = self.sync_sidebar_plugin(true);
            if self.sidebar_plugin_surface.is_some() {
                self.focus = FocusTarget::WorkspaceRail;
            } else {
                self.leave_workspace_sidebar();
            }
            self.sidebar_focus_pending = requested && self.sidebar_plugin_surface.is_none();
            return Ok(RenderAction::Draw);
        }
        // Any click outside the plugin rect returns keyboard focus to the
        // panes; otherwise typing would keep going to the plugin PTY after
        // the user clicked into a pane.
        self.leave_workspace_sidebar();
        self.sidebar_focus_pending = false;

        if let Some(hit) = self.hit_at(x, y) {
            match hit {
                Hit::Machine { index, key } => {
                    self.machine_rail_follow_selection = true;
                    if let Some(machine) = self.machine_ui.as_mut() {
                        machine.selection = index;
                        machine.rail_selection = MachineRailSelection::Machine;
                    }
                    self.focus = FocusTarget::Pane;
                    self.activate_machine(key);
                }
                Hit::NewVm => {
                    self.machine_rail_follow_selection = true;
                    if let Some(machine) = self.machine_ui.as_mut() {
                        machine.rail_selection = MachineRailSelection::NewVm;
                    }
                    self.open_machine_creation_menu(x, y);
                }
                Hit::ConnectMachine => {
                    self.machine_rail_follow_selection = true;
                    if let Some(machine) = self.machine_ui.as_mut() {
                        machine.rail_selection = MachineRailSelection::ConnectMachine;
                    }
                    self.open_machine_connection_menu(x, y);
                }
                Hit::Workspace { index, id } => {
                    self.workspace_rail_follow_selection = true;
                    self.focus = FocusTarget::Pane;
                    self.activate_workspace(index);
                    self.drag = Some(Drag::WorkspaceArm { workspace: id, at: (x, y) });
                }
                Hit::SidebarTab { surface, .. } => {
                    let targets = self.sidebar_tab_targets();
                    if let Some((index, target)) =
                        targets.iter().enumerate().find(|(_, target)| target.surface == surface)
                    {
                        self.tabs_rail_follow_selection = true;
                        self.tabs_rail_selection = index;
                        self.activate_sidebar_tab(target)?;
                        self.focus = FocusTarget::Pane;
                    }
                }
                Hit::ProjectionToggle { view, branch } => {
                    let state = self.projection_rail_state_mut(view);
                    if !state.collapsed.remove(&branch) {
                        state.collapsed.insert(branch);
                    }
                }
                Hit::ProjectionRow { view, row, target } => {
                    let state = self.projection_rail_state_mut(view);
                    state.selected = row;
                    state.selected_action = None;
                    state.follow_selection = true;
                    self.activate_projection_target(target)?;
                    self.focus = FocusTarget::Pane;
                }
                Hit::RailPad(kind) => {
                    self.focus_rail(kind);
                }
                Hit::SidebarAction { view, action } => {
                    let kind = self.rail_kind_for_view(view);
                    match kind {
                        RailKind::Workspace => {
                            self.workspace_rail_selection = WorkspaceRailSelection::Action(action);
                            self.workspace_rail_follow_selection = true;
                        }
                        RailKind::Projection(_) => {
                            let action_index = self
                                .sidebar_action_rows(view)
                                .iter()
                                .position(|candidate| candidate.target == action)
                                .unwrap_or_default();
                            let state = self.projection_rail_state_mut(view);
                            state.selected_action = Some(action_index);
                            state.follow_selection = true;
                        }
                        RailKind::Machine | RailKind::Tabs => {}
                    }
                    return self.invoke_sidebar_action(action);
                }
                Hit::RecoverableWorkspace { index } => {
                    self.workspace_rail_follow_selection = true;
                    self.sidebar_recoverable_workspace_selection = index;
                    self.workspace_rail_selection = WorkspaceRailSelection::Recoverable;
                    self.focus = FocusTarget::Pane;
                    let workspace_id = self
                        .machine_ui
                        .as_ref()
                        .and_then(|ui| ui.recoverable_workspaces().get(index).copied())
                        .map(|workspace| workspace.id.clone());
                    if let Some(workspace_id) = workspace_id {
                        self.request_restore_managed_workspace(&workspace_id);
                    }
                }
                Hit::CreateWorkspace { mode } => {
                    self.workspace_rail_follow_selection = true;
                    self.workspace_rail_selection = workspace_creation_selection(mode);
                    self.create_workspace(mode, None)?;
                }
                Hit::SidebarFile { index } => {
                    self.focus = FocusTarget::WorkspaceRail;
                    self.sidebar_files.select(index);
                }
                Hit::SidebarFilterInput => {
                    self.focus = FocusTarget::WorkspaceRail;
                    if let Some(area) =
                        self.workspace_sidebar_area(self.content_area.height.saturating_add(1))
                    {
                        let input_width = area.width.saturating_sub(2);
                        let column = x.saturating_sub(area.x + 1) as usize;
                        self.sidebar_files
                            .set_filter_cursor_from_visible_column(column, input_width as usize);
                    }
                }
                Hit::ScreenEntry { index, .. } => {
                    self.focus = FocusTarget::Pane;
                    if self.prepare_pty_input_before_mutation() {
                        self.select_screen_for_client(Some(index), None);
                    }
                }
                Hit::StatusMessage => {
                    self.begin_status_message_selection(x);
                }
                Hit::CopyStatusMessage => self.copy_status_message(),
                Hit::NewScreen => {
                    self.focus = FocusTarget::Pane;
                    if let Some(action) = self.config.status_bar.screens_plus.action {
                        let pane = self.active_pane();
                        self.run_action_for_pane(action, pane)?;
                    } else {
                        self.new_screen(None)?;
                    }
                }
                Hit::Tab { pane, index } => {
                    if let Some(surface) = self
                        .tree
                        .pane(pane)
                        .and_then(|pane| pane.tabs.get(index))
                        .map(|t| t.surface)
                    {
                        self.drag = Some(Drag::TabArm { surface, at: (x, y) });
                    }
                }
                Hit::NewTab { pane } => {
                    self.focus_pane_after_input(pane);
                    if let Some(action) = self.config.tabs.plus.action {
                        self.run_action_for_pane(action, Some(pane))?;
                    } else if self.prepare_pty_input_before_mutation() {
                        self.session
                            .new_tab(Some(pane), self.terminal_tab_size_hint(Some(pane)))?;
                    }
                }
                Hit::Clients { surface } => self.open_clients_menu(x, y, surface),
                Hit::Scrollbar { surface, track, scrollbar } => {
                    self.start_scrollbar_drag(surface, track, scrollbar, y);
                }
                Hit::HorizontalScrollbar { track } => {
                    self.start_horizontal_scrollbar_drag(track, x);
                }
                Hit::WorkspaceScrollbar { track, total_rows, visible_rows } => {
                    self.workspace_rail_follow_selection = false;
                    self.start_workspace_scrollbar_drag(track, total_rows, visible_rows, y);
                }
                Hit::RailResize(kind) => {
                    self.drag = Some(Drag::RailResize(kind));
                }
                Hit::PaneResize { horizontal, vertical } => {
                    let horizontal = horizontal
                        .and_then(|(pane, edge)| self.resolve_pane_resize_drag(pane, edge));
                    let vertical =
                        vertical.and_then(|(pane, edge)| self.resolve_pane_resize_drag(pane, edge));
                    if horizontal.is_some() || vertical.is_some() {
                        self.drag = Some(Drag::ResizeSplit { horizontal, vertical });
                    }
                }
                Hit::TabScroll { pane, delta } => self.scroll_tabs(pane, delta),
            }
            return Ok(RenderAction::Draw);
        }

        if let Some(area) = self.pane_area_at(x, y).copied() {
            self.focus = FocusTarget::Pane;
            if area.content.contains(x, y) {
                if self.surface_kind(area.surface) == Some(SurfaceKind::Browser) {
                    if self.active_pane() != Some(area.pane) {
                        self.focus_pane_after_input(area.pane);
                    }
                    if let Some(frame_seq) = self.processed_browser_pointer_authority(area.surface)
                        && self.send_browser_mouse(
                            area.surface,
                            area.content,
                            x,
                            y,
                            frame_seq,
                            BrowserMouseDispatch::new("mousePressed", Some("left"), Some(1)),
                        )
                    {
                        self.drag = Some(Drag::Browser {
                            surface: area.surface,
                            content: area.content,
                            position: (x, y),
                            frame_seq,
                        });
                    }
                } else if self.begin_pty_mouse_drag_with_admission(
                    x,
                    y,
                    MouseButton::Left,
                    modifiers,
                    terminal_admission,
                ) != PtyMousePressResult::NotOwned
                {
                    self.reset_selection_click_sequence();
                    return Ok(RenderAction::Draw);
                } else {
                    if self.active_pane() != Some(area.pane) {
                        self.focus_pane_after_input(area.pane);
                    }
                    let Some(content) = self.terminal_input_rect(&area) else {
                        self.reset_selection_click_sequence();
                        return Ok(RenderAction::Draw);
                    };
                    if !content.contains(x, y) {
                        self.reset_selection_click_sequence();
                        return Ok(RenderAction::Draw);
                    }
                    // Begin a text selection; it becomes visible once the
                    // mouse moves to a second cell.
                    let offset = self.surface_scroll_offset(area.surface);
                    let source_x = area.content_source_x();
                    let col = source_x.saturating_add(x - content.x);
                    let cell = (col, offset + (y - content.y) as u64);
                    let mode = self.begin_selection_click(
                        area.surface,
                        cell,
                        (x.saturating_sub(content.x), y.saturating_sub(content.y)),
                        modifiers,
                        now,
                    );
                    if mode == SelectionMode::Cell && modifiers == KeyModifiers::NONE {
                        // Ghostty's cell behavior returns no range on press.
                        // Keep only the tracked anchor until a drag moves it.
                        self.clear_selection_for_cell_gesture(area.surface);
                    } else {
                        self.selection_mode = mode;
                        self.selection_mode_surface = Some(area.surface);
                        if let Some(selection) = self.selection_for_click(area.surface, cell, mode)
                        {
                            self.replace_selection(Some(selection));
                        } else {
                            // A semantic lookup can legitimately return no
                            // value for an empty cell. Do not leave an older
                            // selection or semantic drag mode active.
                            self.clear_selection_for_cell_gesture(area.surface);
                            self.invalidate_selection_repeat(area.surface);
                        }
                    }
                    self.drag = Some(Drag::Select { content, source_x, auto_scroll: None, col });
                }
            } else if self.active_pane() != Some(area.pane) {
                self.focus_pane_after_input(area.pane);
            }
            return Ok(RenderAction::Draw);
        }
        Ok(RenderAction::None)
    }
}
