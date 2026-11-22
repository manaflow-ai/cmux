//! Left-button drag and release: selection drags, tab and workspace drags,
//! scrollbar and pane resize drags, and the release that completes them.

use crate::app::frame_geometry::rail_drag_width;
use crate::app::layout::RailKind;
use crate::app::pointer::{Drag, ScrollbarDragState};
use crate::app::selection::{Selection, SelectionMode};
use crate::app::{App, BrowserMouseDispatch, RenderAction};
use crate::ui::{horizontal_drag_offset, viewport_drag_offset};

impl App {
    pub(super) fn handle_left_drag(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        if let Some(menu) = self.menu.as_mut()
            && menu.scrollbar_drag.is_some()
        {
            menu.drag_scrollbar(y);
            self.hover = Some((x, y));
            return Ok(RenderAction::Draw);
        }
        match &self.drag {
            Some(Drag::TabArm { surface, at }) => {
                let (surface, at) = (*surface, *at);
                if (x, y) != at {
                    self.hover = Some((x, y));
                    let target = self.tab_drop_target_at(x, y);
                    self.drag = Some(Drag::Tab { surface, target });
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::Tab { surface, .. }) => {
                let surface = *surface;
                self.hover = Some((x, y));
                let target = self.tab_drop_target_at(x, y);
                self.drag = Some(Drag::Tab { surface, target });
                Ok(RenderAction::Draw)
            }
            Some(Drag::WorkspaceArm { workspace, at }) => {
                let (workspace, at) = (*workspace, *at);
                if (x, y) != at {
                    let target = self.workspace_drop_target_at(x, y);
                    self.drag = Some(Drag::Workspace { workspace, target });
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::Workspace { workspace, .. }) => {
                let workspace = *workspace;
                let target = self.workspace_drop_target_at(x, y);
                self.drag = Some(Drag::Workspace { workspace, target });
                Ok(RenderAction::Draw)
            }
            Some(Drag::Select { content, source_x, .. }) => {
                let fallback = (*content, *source_x);
                let selection_surface = self
                    .selection_mode_surface
                    .or_else(|| self.selection.map(|selection| selection.surface));
                let (content, source_x) = selection_surface
                    .and_then(|surface| self.current_selection_geometry(surface))
                    .unwrap_or(fallback);
                let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
                let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
                let col = source_x.saturating_add(cx - content.x);
                let offset = selection_surface
                    .map(|surface| self.surface_scroll_offset(surface))
                    .unwrap_or(0);
                let raw_current = (col, offset + (cy - content.y) as u64);
                if let Some(surface) = selection_surface {
                    self.mark_selection_dragged(surface);
                }
                let mode = selection_surface
                    .filter(|surface| self.selection_mode_surface == Some(*surface))
                    .and_then(|surface| {
                        self.selection_click_sequence
                            .as_ref()
                            .filter(|sequence| sequence.surface == surface)
                            .map(|sequence| sequence.mode)
                    })
                    .unwrap_or(SelectionMode::Cell);
                let current = if mode == SelectionMode::Line {
                    raw_current
                } else {
                    selection_surface
                        .map(|surface| self.canonical_selection_cell(surface, raw_current))
                        .unwrap_or(raw_current)
                };
                if mode == SelectionMode::Cell {
                    let selection = self.selection.or_else(|| {
                        let surface = selection_surface?;
                        let anchor = self.selection_anchor_cell(surface)?;
                        let anchor = self.canonical_selection_cell(surface, anchor);
                        Some(Selection { surface, anchor, head: current })
                    });
                    if let Some(mut selection) = selection {
                        selection.head = current;
                        self.replace_selection(Some(selection));
                    }
                } else if let Some(surface) = selection_surface {
                    self.update_semantic_selection(surface, mode, current);
                }
                let auto_scroll = if y <= content.y {
                    Some(-1)
                } else if y >= content.y + content.height.saturating_sub(1) {
                    Some(1)
                } else {
                    None
                };
                self.drag = Some(Drag::Select { content, source_x, auto_scroll, col });
                Ok(RenderAction::Draw)
            }
            Some(Drag::StatusMessage { rect }) => {
                let rect = *rect;
                if rect.width == 0 {
                    self.drag = None;
                    self.status_selection = None;
                    return Ok(RenderAction::Draw);
                }
                let cell = x.clamp(rect.x, rect.x + rect.width - 1) - rect.x;
                if let Some(selection) = self.status_selection.as_mut() {
                    selection.head = cell;
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::Browser { surface, content, frame_seq, .. }) => {
                let (surface, frame_seq) = (*surface, *frame_seq);
                let content = self.current_browser_content(surface).unwrap_or(*content);
                let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
                let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
                self.drag = Some(Drag::Browser { surface, content, position: (cx, cy), frame_seq });
                let _ = self.send_browser_mouse(
                    surface,
                    content,
                    cx,
                    cy,
                    frame_seq,
                    BrowserMouseDispatch::new("mouseMoved", Some("left"), Some(1)),
                );
                Ok(RenderAction::Draw)
            }
            Some(Drag::PtyMouse { .. }) => Ok(RenderAction::None),
            Some(Drag::Scrollbar {
                surface,
                track,
                anchor_y,
                anchor_offset,
                position_y,
                scrollbar,
            }) => {
                let surface = *surface;
                let state = ScrollbarDragState {
                    track: *track,
                    anchor_y: *anchor_y,
                    anchor_offset: *anchor_offset,
                    position_y: *position_y,
                    scrollbar: *scrollbar,
                };
                let Some((rendered_track, rendered_scrollbar)) = self.rendered_scrollbar(surface)
                else {
                    self.drag = None;
                    return Ok(RenderAction::Draw);
                };
                if let Some(updated) =
                    self.drag_scrollbar(surface, state, (rendered_track, rendered_scrollbar), y)
                {
                    self.drag = Some(Drag::Scrollbar {
                        surface,
                        track: updated.track,
                        anchor_y: updated.anchor_y,
                        anchor_offset: updated.anchor_offset,
                        position_y: updated.position_y,
                        scrollbar: updated.scrollbar,
                    });
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::HorizontalScrollbar { track, anchor_x, anchor_offset }) => {
                let (track, anchor_x, anchor_offset) = (*track, *anchor_x, *anchor_offset);
                if let Some((content_width, viewport_width, _)) = self.horizontal_scrollbar_state()
                {
                    let target = horizontal_drag_offset(
                        content_width,
                        viewport_width,
                        track.width,
                        anchor_offset,
                        i128::from(x) - i128::from(anchor_x),
                    );
                    self.set_viewport_target(target, false);
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::WorkspaceScrollbar {
                track,
                total_rows,
                visible_rows,
                anchor_y,
                anchor_offset,
            }) => {
                let (track, total_rows, visible_rows, anchor_y, anchor_offset) =
                    (*track, *total_rows, *visible_rows, *anchor_y, *anchor_offset);
                self.workspace_rail_scroll = viewport_drag_offset(
                    total_rows,
                    visible_rows,
                    track.height,
                    anchor_offset,
                    y as i128 - anchor_y as i128,
                );
                Ok(RenderAction::Draw)
            }
            Some(Drag::RailResize(kind)) => {
                let kind = *kind;
                if let Some(width) = rail_drag_width(&self.config, &self.sidebar_layout, kind, x) {
                    match kind {
                        RailKind::Machine => self.machine_sidebar_width_override = Some(width),
                        RailKind::Workspace => {
                            self.sidebar_compact = false;
                            self.sidebar_width_override = Some(width);
                        }
                        RailKind::Tabs => self.tabs_sidebar_width_override = Some(width),
                        RailKind::Projection(index) => {
                            if let Some(id) =
                                self.config.sidebar.views.get(index).map(|view| view.id.clone())
                            {
                                self.projection_sidebar_width_overrides.insert(id, width);
                            }
                        }
                    }
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::ResizeSplit { horizontal, vertical }) => {
                let (horizontal, vertical) = (*horizontal, *vertical);
                if let Some(target) = horizontal {
                    self.resize_drag_target(target, x, y);
                }
                if let Some(target) = vertical {
                    self.resize_drag_target(target, x, y);
                }
                Ok(RenderAction::Draw)
            }
            None => Ok(RenderAction::None),
        }
    }

    pub(super) fn handle_left_up(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        if let Some(menu) = self.menu.as_mut()
            && menu.finish_scrollbar_drag()
        {
            self.hover = Some((x, y));
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::TabArm { surface, .. }) = self.drag {
            self.drag = None;
            if let Some((pane, index)) = self.tab_location(surface) {
                self.focus_pane_after_input(pane);
                if self.prepare_pty_input_before_mutation() {
                    self.select_tab_for_client(Some(pane), Some(index), None);
                }
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Tab { surface, .. }) = self.drag {
            self.drag = None;
            if let Some(workspace) = self.tab_workspace_drop_at(x, y) {
                self.move_tab_to_workspace(surface, workspace);
                return Ok(RenderAction::Draw);
            }
            if let Some((pane, index)) = self.tab_drop_target_at(x, y)
                && self.prepare_pty_input_before_mutation()
            {
                self.session.move_tab(surface, pane, index);
            }
            return Ok(RenderAction::Draw);
        }
        if matches!(self.drag, Some(Drag::WorkspaceArm { .. })) {
            self.drag = None;
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Workspace { workspace, .. }) = self.drag {
            self.drag = None;
            if let Some(insertion) = self.workspace_drop_target_at(x, y)
                && self.prepare_pty_input_before_mutation()
            {
                self.session.move_workspace(workspace, insertion);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Browser { surface, content, frame_seq, .. }) = self.drag {
            self.drag = None;
            let content = self.current_browser_content(surface).unwrap_or(content);
            let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
            let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
            let _ = self.send_browser_mouse(
                surface,
                content,
                cx,
                cy,
                frame_seq,
                BrowserMouseDispatch::new("mouseReleased", Some("left"), Some(1)),
            );
            return Ok(RenderAction::Draw);
        }
        if matches!(self.drag, Some(Drag::ResizeSplit { .. })) {
            self.drag = None;
            self.session.settle_split_ratio();
            return Ok(RenderAction::Draw);
        }
        if matches!(self.drag, Some(Drag::StatusMessage { .. })) {
            self.drag = None;
            match self.status_selection.as_ref() {
                Some(selection) if selection.anchor != selection.head => {
                    self.copy_status_message_selection();
                }
                _ => self.status_selection = None,
            }
            return Ok(RenderAction::Draw);
        }
        let was_select = matches!(self.drag, Some(Drag::Select { .. }));
        let semantic_select = was_select
            && self.selection_mode_surface.is_some()
            && self.selection_mode != SelectionMode::Cell;
        let selection_dragged = was_select
            && self.selection_click_sequence.as_ref().is_some_and(|sequence| sequence.dragged);
        let was_drag = self.drag.is_some();
        self.drag = None;
        if selection_dragged {
            // Keep the sequence through the gesture so word and line drags use
            // their semantic mode, then make the next press a plain click.
            self.reset_selection_click_sequence();
        }
        if !was_select {
            return Ok(if was_drag { RenderAction::Draw } else { RenderAction::None });
        }
        match self.selection {
            Some(sel) if sel.anchor != sel.head || semantic_select => {
                self.copy_selection(sel);
                Ok(RenderAction::Draw)
            }
            _ => {
                // A plain click: no selection to keep.
                self.replace_selection(None);
                Ok(RenderAction::Draw)
            }
        }
    }
}
