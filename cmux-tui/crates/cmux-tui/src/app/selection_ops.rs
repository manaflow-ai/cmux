//! Selection on the App: click sequences, selection from points and ranges,
//! semantic selection updates, visible input state, status message
//! presentation and selection, and selection auto-scroll.

use std::time::Instant;

use cmux_tui_core::{PointerSnapshotProbe, Rect, SurfaceId, SurfaceKind};
use crossterm::event::KeyModifiers;
use ghostty_vt::{Screen, SelectionPoint, SelectionRange};

use crate::app::layout::Hit;
use crate::app::pointer::Drag;
use crate::app::selection::{
    RenderedStatusMessage, SELECTION_REPEAT_DISTANCE_SQUARED, SELECTION_REPEAT_INTERVAL, Selection,
    SelectionClickSequence, SelectionMode, SemanticSelectionCache, StatusMessageSelection,
    VisibleInputState,
};
use crate::app::{App, RenderAction};

impl App {
    /// Whether a selection should be painted for a surface. A word or line
    /// can legitimately contain one cell, so endpoint equality alone is not
    /// enough to decide whether the highlight is visible.
    pub(crate) fn selection_is_visible(&self, surface: SurfaceId) -> bool {
        self.selection.is_some_and(|selection| {
            selection.surface == surface
                && (selection.anchor != selection.head
                    || (self.selection_mode_surface == Some(surface)
                        && self.selection_mode != SelectionMode::Cell))
        })
    }

    pub(super) fn reset_selection_click_sequence(&mut self) {
        self.selection_click_sequence = None;
        self.semantic_selection_cache = None;
    }

    fn reset_selection_mode(&mut self) {
        self.selection_mode = SelectionMode::Cell;
        self.selection_mode_surface = None;
        self.semantic_selection_cache = None;
    }

    /// Clear a press that has no semantic range while retaining the surface
    /// needed to turn a later drag into a cell selection.
    pub(super) fn clear_selection_for_cell_gesture(&mut self, surface: SurfaceId) {
        self.replace_selection(None);
        self.selection_mode = SelectionMode::Cell;
        self.selection_mode_surface = Some(surface);
        if let Some(sequence) = self.selection_click_sequence.as_mut()
            && sequence.surface == surface
        {
            sequence.mode = SelectionMode::Cell;
        }
    }

    pub(super) fn invalidate_selection_repeat(&mut self, surface: SurfaceId) {
        if let Some(sequence) = self.selection_click_sequence.as_mut()
            && sequence.surface == surface
        {
            sequence.repeatable = false;
        }
    }

    fn selection_point(cell: (u16, u64)) -> Option<SelectionPoint> {
        Some(SelectionPoint { column: cell.0, row: u32::try_from(cell.1).ok()? })
    }

    pub(super) fn canonical_selection_cell(
        &self,
        surface: SurfaceId,
        cell: (u16, u64),
    ) -> (u16, u64) {
        let Some(point) = Self::selection_point(cell) else { return cell };
        self.session
            .surface(surface)
            .and_then(|handle| {
                handle.with_terminal(|terminal| terminal.normalize_selection_point_screen(point))
            })
            .flatten()
            .map(|point| (point.column, u64::from(point.row)))
            .unwrap_or(cell)
    }

    fn selection_from_range(surface: SurfaceId, range: SelectionRange) -> Selection {
        Selection {
            surface,
            anchor: (range.start.column, u64::from(range.start.row)),
            head: (range.end.column, u64::from(range.end.row)),
        }
    }

    pub(super) fn selection_for_click(
        &self,
        surface: SurfaceId,
        cell: (u16, u64),
        mode: SelectionMode,
    ) -> Option<Selection> {
        if mode == SelectionMode::Cell {
            let cell = self.canonical_selection_cell(surface, cell);
            return Some(Selection { surface, anchor: cell, head: cell });
        }
        let point = Self::selection_point(cell)?;
        let handle = self.session.surface(surface)?;
        let range = handle
            .with_terminal(|terminal| {
                let point = if mode == SelectionMode::Word {
                    terminal.normalize_selection_point_screen(point)?
                } else {
                    point
                };
                match mode {
                    SelectionMode::Word => terminal.select_word_screen(point).ok().flatten(),
                    SelectionMode::Line => terminal
                        .select_line_screen(point)
                        .ok()
                        .flatten()
                        .or_else(|| terminal.select_line_screen_untrimmed(point).ok().flatten()),
                    SelectionMode::Cell => None,
                }
            })
            .flatten()?;
        Some(Self::selection_from_range(surface, range))
    }

    fn terminal_active_screen(&self, surface: SurfaceId) -> Option<Screen> {
        self.session
            .surface(surface)
            .and_then(|handle| handle.with_terminal(|terminal| terminal.active_screen()))
    }

    fn terminal_content_generation(&self, surface: SurfaceId) -> Option<u64> {
        let handle = self.session.surface(surface)?;
        match handle.try_pointer_snapshot()? {
            PointerSnapshotProbe::Ready(snapshot) => Some(snapshot.content_generation),
            PointerSnapshotProbe::Contended => None,
        }
    }

    fn selection_repeat_allowed(
        previous: &SelectionClickSequence,
        surface: SurfaceId,
        screen: Option<Screen>,
        position: (u16, u16),
        modifiers: KeyModifiers,
        now: Instant,
    ) -> bool {
        let host_selection_modifier =
            |modifiers| modifiers == KeyModifiers::NONE || modifiers == KeyModifiers::SHIFT;
        if !previous.repeatable
            || screen.is_none()
            || previous.surface != surface
            || previous.screen != screen
            || previous.modifiers != modifiers
            || !host_selection_modifier(modifiers)
        {
            return false;
        }
        let Some(elapsed) = now.checked_duration_since(previous.time) else { return false };
        if elapsed > SELECTION_REPEAT_INTERVAL {
            return false;
        }
        let dx = u32::from(previous.position.0.abs_diff(position.0));
        let dy = u32::from(previous.position.1.abs_diff(position.1));
        dx.saturating_mul(dx).saturating_add(dy.saturating_mul(dy))
            <= SELECTION_REPEAT_DISTANCE_SQUARED
    }

    pub(super) fn begin_selection_click(
        &mut self,
        surface: SurfaceId,
        cell: (u16, u64),
        position: (u16, u16),
        modifiers: KeyModifiers,
        now: Instant,
    ) -> SelectionMode {
        self.semantic_selection_cache = None;
        let previous = self.selection_click_sequence.take();
        let screen = self.terminal_active_screen(surface);
        let repeated = previous.as_ref().is_some_and(|previous| {
            Self::selection_repeat_allowed(previous, surface, screen, position, modifiers, now)
        });
        let (mut count, mut tracked_anchor) = if repeated {
            let previous = previous.expect("repeated selection click has prior state");
            (previous.count.saturating_add(1).min(3), previous.tracked_anchor)
        } else {
            (1, None)
        };

        if let Some(row) = u32::try_from(cell.1).ok()
            && let Some(handle) = self.session.surface(surface)
        {
            // A tracked anchor is also a screen-generation check. If it can
            // no longer be moved, the terminal recycled or removed its page;
            // do not turn that stale press into a double click.
            let anchor_moved = tracked_anchor.as_mut().is_some_and(|anchor| {
                handle
                    .with_terminal(|terminal| {
                        terminal.set_tracked_screen_point(anchor, cell.0, row).is_ok()
                    })
                    .unwrap_or(false)
            });
            if repeated && tracked_anchor.is_some() && !anchor_moved {
                count = 1;
                tracked_anchor = None;
            }
            if tracked_anchor.is_none() {
                tracked_anchor = handle
                    .with_terminal(|terminal| terminal.track_screen_point(cell.0, row).ok())
                    .flatten();
            }
        }
        let mode = match count {
            2 => SelectionMode::Word,
            3 => SelectionMode::Line,
            _ => SelectionMode::Cell,
        };
        self.selection_click_sequence = Some(SelectionClickSequence {
            surface,
            screen,
            position,
            modifiers,
            time: now,
            count,
            mode,
            anchor: cell,
            dragged: false,
            tracked_anchor,
            repeatable: true,
        });
        mode
    }

    pub(super) fn selection_anchor_cell(&self, surface: SurfaceId) -> Option<(u16, u64)> {
        let sequence = self.selection_click_sequence.as_ref()?;
        if sequence.surface != surface {
            return None;
        }
        let handle = self.session.surface(surface)?;
        handle
            .with_terminal(|terminal| {
                if let Some(anchor) = sequence.tracked_anchor.as_ref() {
                    terminal
                        .tracked_screen_point(anchor)
                        .map(|(column, row)| (column, u64::from(row)))
                } else {
                    Some(sequence.anchor)
                }
            })
            .flatten()
    }

    pub(super) fn mark_selection_dragged(&mut self, surface: SurfaceId) {
        if let Some(sequence) = self.selection_click_sequence.as_mut()
            && sequence.surface == surface
        {
            sequence.dragged = true;
        }
    }

    /// Clear an invalid semantic drag result without ending the gesture. The
    /// mode and tracked anchor stay available so a later pointer sample can
    /// recover, while release cannot copy an older range.
    fn clear_selection_for_semantic_gesture(&mut self, surface: SurfaceId, mode: SelectionMode) {
        if self.selection.is_some() {
            self.selection_generation = self.selection_generation.wrapping_add(1);
            self.selection = None;
        }
        self.selection_mode = mode;
        self.selection_mode_surface = Some(surface);
        if let Some(sequence) = self.selection_click_sequence.as_mut()
            && sequence.surface == surface
        {
            sequence.mode = mode;
        }
    }

    pub(super) fn update_semantic_selection(
        &mut self,
        surface: SurfaceId,
        mode: SelectionMode,
        current: (u16, u64),
    ) {
        if mode == SelectionMode::Cell {
            return;
        }
        let Some(anchor) = self.selection_anchor_cell(surface) else {
            self.clear_selection_for_semantic_gesture(surface, mode);
            self.semantic_selection_cache = None;
            return;
        };
        let Some(anchor_point) = Self::selection_point(anchor) else {
            self.clear_selection_for_semantic_gesture(surface, mode);
            self.semantic_selection_cache = None;
            return;
        };
        let Some(current_point) = Self::selection_point(current) else {
            self.clear_selection_for_semantic_gesture(surface, mode);
            self.semantic_selection_cache = None;
            return;
        };
        let Some(handle) = self.session.surface(surface) else {
            self.clear_selection_for_semantic_gesture(surface, mode);
            self.semantic_selection_cache = None;
            return;
        };
        let Some((anchor_point, current_point)) = handle
            .with_terminal(|terminal| {
                if mode == SelectionMode::Word {
                    Some((
                        terminal.normalize_selection_point_screen(anchor_point)?,
                        terminal.normalize_selection_point_screen(current_point)?,
                    ))
                } else {
                    Some((anchor_point, current_point))
                }
            })
            .flatten()
        else {
            self.clear_selection_for_semantic_gesture(surface, mode);
            self.semantic_selection_cache = None;
            return;
        };
        let content_generation = self.terminal_content_generation(surface);
        if let Some(generation) = content_generation
            && let Some(cache) = self.semantic_selection_cache
            && cache.surface == surface
            && cache.mode == mode
            && cache.anchor == anchor_point
            && cache.current == current_point
            && cache.content_generation == generation
        {
            if let Some(range) = cache.range {
                self.replace_selection(Some(Self::selection_from_range(surface, range)));
            } else {
                self.clear_selection_for_semantic_gesture(surface, mode);
            }
            return;
        }
        let range = handle
            .with_terminal(|terminal| match mode {
                SelectionMode::Word => {
                    let first = terminal
                        .select_word_between_screen(anchor_point, current_point)
                        .ok()
                        .flatten()?;
                    let second = terminal
                        .select_word_between_screen(current_point, anchor_point)
                        .ok()
                        .flatten()?;
                    let current_before_anchor = (current.1, current.0) < (anchor.1, anchor.0);
                    Some(if current_before_anchor {
                        SelectionRange { start: second.start, end: first.end }
                    } else {
                        SelectionRange { start: first.start, end: second.end }
                    })
                }
                SelectionMode::Line => {
                    let select_line =
                        |point| {
                            terminal.select_line_screen(point).ok().flatten().or_else(|| {
                                terminal.select_line_screen_untrimmed(point).ok().flatten()
                            })
                        };
                    let first = select_line(anchor_point)?;
                    let second = select_line(current_point)?;
                    let current_before_anchor = (current.1, current.0) < (anchor.1, anchor.0);
                    Some(if current_before_anchor {
                        SelectionRange { start: second.start, end: first.end }
                    } else {
                        SelectionRange { start: first.start, end: second.end }
                    })
                }
                SelectionMode::Cell => None,
            })
            .flatten();
        if let Some(generation) = content_generation {
            self.semantic_selection_cache = Some(SemanticSelectionCache {
                surface,
                mode,
                anchor: anchor_point,
                current: current_point,
                content_generation: generation,
                range,
            });
        } else {
            self.semantic_selection_cache = None;
        }
        match range {
            Some(range) => self.replace_selection(Some(Self::selection_from_range(surface, range))),
            None => self.clear_selection_for_semantic_gesture(surface, mode),
        }
    }

    pub(super) fn replace_selection(&mut self, selection: Option<Selection>) {
        self.selection_generation = self.selection_generation.wrapping_add(1);
        self.selection = selection;
        if selection.is_none() {
            self.reset_selection_mode();
        }
    }

    pub(super) fn visible_input_state(&self, destination: Option<SurfaceId>) -> VisibleInputState {
        let pty_surface = destination
            .or_else(|| self.active_surface())
            .filter(|surface| self.tree.surface_kind(*surface) == SurfaceKind::Pty);
        VisibleInputState {
            pty_surface,
            selection: self.selection,
            scroll_offset: pty_surface.map_or(0, |surface| self.surface_scroll_offset(surface)),
        }
    }

    pub(super) fn painted_status_message_action(&self) -> RenderAction {
        if self
            .rendered_status_message
            .as_ref()
            .is_some_and(|rendered| self.status_message.as_deref() != Some(rendered.text.as_str()))
        {
            RenderAction::Draw
        } else {
            RenderAction::None
        }
    }

    pub(super) fn visible_input_action(&self, before: VisibleInputState) -> RenderAction {
        let status_action = self.painted_status_message_action();
        let action = if self.selection != before.selection
            || before
                .pty_surface
                .is_some_and(|surface| self.surface_scroll_offset(surface) != before.scroll_offset)
        {
            RenderAction::Draw
        } else {
            RenderAction::None
        };
        action.merge(status_action)
    }

    pub(crate) fn reset_rendered_status_message(&mut self) {
        // Per-frame render reset. `logged_status_message` deliberately
        // survives it: a message that stays visible across redraws is one
        // event, not one per frame. Dismissal (`hide_status_message`) clears
        // it, so a message that reappears later logs again.
        self.rendered_status_message = None;
    }

    pub(crate) fn present_status_message(&mut self, rect: Rect, text: String) {
        if self.status_selection.as_ref().is_some_and(|selection| selection.text != text) {
            self.status_selection = None;
            if matches!(self.drag, Some(Drag::StatusMessage { .. })) {
                self.drag = None;
            }
        }
        // Every visible status message passes through here; persist each new
        // one so warnings survive the session in the client log. Provider
        // notices ("VM created") share the status line but are not errors.
        if self.logged_status_message.as_deref() != Some(text.as_str()) {
            if self.status_notice_text.as_deref() == Some(text.as_str()) {
                crate::client_log::info("status", &text);
            } else {
                crate::client_log::error("status", &text);
            }
            self.logged_status_message = Some(text.clone());
        }
        self.rendered_status_message = Some(RenderedStatusMessage { rect, text });
    }

    pub(crate) fn hide_status_message(&mut self) {
        self.rendered_status_message = None;
        self.logged_status_message = None;
        // The notice marker only describes the currently shown message; a
        // later status with the same text is a fresh event and must be
        // classified on its own.
        self.status_notice_text = None;
        self.status_selection = None;
        if matches!(self.drag, Some(Drag::StatusMessage { .. })) {
            self.drag = None;
        }
    }

    pub(crate) fn status_message_cell_selected(&self, text: &str, cell: u16) -> bool {
        self.status_selection.as_ref().is_some_and(|selection| selection.contains(text, cell))
    }

    pub(super) fn status_message_hovered(&self) -> bool {
        self.hover.is_some_and(|(x, y)| {
            self.rendered_status_message
                .as_ref()
                .is_some_and(|rendered| rendered.rect.contains(x, y))
                || self
                    .hits
                    .iter()
                    .any(|(rect, hit)| *hit == Hit::CopyStatusMessage && rect.contains(x, y))
        })
    }

    pub(super) fn begin_status_message_selection(&mut self, x: u16) -> bool {
        let Some(rendered) = self.rendered_status_message.clone() else { return false };
        if rendered.rect.width == 0 || !rendered.rect.contains(x, rendered.rect.y) {
            return false;
        }
        let cell = x.saturating_sub(rendered.rect.x).min(rendered.rect.width - 1);
        self.status_selection =
            Some(StatusMessageSelection { text: rendered.text, anchor: cell, head: cell });
        self.drag = Some(Drag::StatusMessage { rect: rendered.rect });
        true
    }

    pub(super) fn selection_auto_scroll_active(&self) -> bool {
        matches!(self.drag, Some(Drag::Select { auto_scroll: Some(_), .. }))
    }

    pub(super) fn auto_scroll_selection_tick(&mut self) -> bool {
        let Some(Drag::Select { content, source_x, auto_scroll: Some(dir), col }) = self.drag
        else {
            return false;
        };
        let Some(surface_id) =
            self.selection_mode_surface.or_else(|| self.selection.map(|sel| sel.surface))
        else {
            return false;
        };
        let Some(surface) = self.session.surface(surface_id) else { return false };
        let content =
            self.current_selection_geometry(surface_id).map_or(content, |(content, _)| content);
        let moved = surface.scroll_delta(dir as isize).unwrap_or(false);
        let edge_row = if dir < 0 { 0 } else { content.height.saturating_sub(1) };
        let offset = self.surface_scroll_offset(surface_id);
        let raw_edge_cell = (
            col.min(content.width.saturating_sub(1).saturating_add(source_x)),
            offset + edge_row as u64,
        );
        self.mark_selection_dragged(surface_id);
        let edge_cell = if self.selection_mode == SelectionMode::Line {
            raw_edge_cell
        } else {
            self.canonical_selection_cell(surface_id, raw_edge_cell)
        };
        if self.selection_mode != SelectionMode::Cell
            && self.selection_mode_surface == Some(surface_id)
        {
            self.update_semantic_selection(surface_id, self.selection_mode, edge_cell);
        } else {
            let selection = self.selection.or_else(|| {
                let anchor = self.selection_anchor_cell(surface_id)?;
                let anchor = self.canonical_selection_cell(surface_id, anchor);
                Some(Selection { surface: surface_id, anchor, head: edge_cell })
            });
            if let Some(mut selection) = selection {
                selection.head = edge_cell;
                self.replace_selection(Some(selection));
            }
        }
        moved
    }
}
