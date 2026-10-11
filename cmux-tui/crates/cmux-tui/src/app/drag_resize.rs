//! Scrollbar and drag queries plus surface resize enqueueing: horizontal
//! viewport scrolling, scrollbar drag start, tab and workspace drag views, and
//! surface resize and size reclaim.

use cmux_tui_core::{Rect, SurfaceId, SurfaceKind, WorkspaceId};

use crate::app::App;
use crate::app::pointer::{Drag, TabDragView};
use crate::app::surface_sync::{SurfaceResizeClaim, record_surface_resize_dispatch_result};
use crate::browser_input::{BrowserInputEvent, BrowserInputKind};
use crate::session::SurfaceHandle;
use crate::ui::{horizontal_offset_at, horizontal_thumb_geometry};

impl App {
    pub fn dragging_scrollbar(&self) -> Option<SurfaceId> {
        match self.drag {
            Some(Drag::Scrollbar { surface, .. }) => Some(surface),
            _ => None,
        }
    }

    pub(crate) fn horizontal_scrollbar_state(&self) -> Option<(u64, u16, u64)> {
        let viewport_width = self.content_area.width;
        if viewport_width == 0 || self.viewport_virtual_width <= u64::from(viewport_width) {
            return None;
        }
        Some((self.viewport_virtual_width, viewport_width, self.viewport_offset))
    }

    pub(super) fn scroll_horizontal_viewport(&mut self, delta: i16, animate: bool) -> bool {
        let Some(screen) = self.active_screen_id() else { return false };
        let Some((content_width, viewport_width, _)) = self.horizontal_scrollbar_state() else {
            return false;
        };
        let maximum = content_width.saturating_sub(u64::from(viewport_width));
        let current = self
            .viewport_states
            .get(&screen)
            .map_or(self.viewport_offset, |motion| motion.target.round() as u64);
        self.set_viewport_target(
            current.saturating_add_signed(i64::from(delta)).min(maximum),
            animate,
        )
    }

    /// Start a horizontal scrollbar drag. Grabbing the thumb freezes it at
    /// its rendered offset; clicking the track jumps first and anchors there.
    pub(super) fn start_horizontal_scrollbar_drag(&mut self, track: Rect, x: u16) {
        let Some((content_width, viewport_width, offset)) = self.horizontal_scrollbar_state()
        else {
            return;
        };
        if track.width == 0 {
            return;
        }
        let relative = x.saturating_sub(track.x).min(track.width - 1);
        let (thumb_x, thumb_width) =
            horizontal_thumb_geometry(content_width, viewport_width, offset, track.width);
        let on_thumb = relative >= thumb_x && relative < thumb_x.saturating_add(thumb_width);
        let anchor_offset = if on_thumb {
            self.set_viewport_target(offset, false);
            offset
        } else {
            let Some(target) =
                horizontal_offset_at(content_width, viewport_width, track.width, relative)
            else {
                return;
            };
            self.set_viewport_target(target, true);
            target
        };
        self.drag = Some(Drag::HorizontalScrollbar { track, anchor_x: x, anchor_offset });
    }

    pub fn dragging_workspace_scrollbar(&self) -> bool {
        matches!(self.drag, Some(Drag::WorkspaceScrollbar { .. }))
    }

    pub(super) fn enqueue_surface_resize(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        cols: u16,
        rows: u16,
        reassert: bool,
        claim: Option<SurfaceResizeClaim>,
    ) -> bool {
        if surface.kind() == SurfaceKind::Browser {
            let Some(claim) = claim else { return false };
            let ownership = self.session.surface_resize_ownership.clone();
            self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::Resize {
                    cols,
                    rows,
                    reassert,
                    _claim: Some(Box::new(claim)),
                    on_result: Some(Box::new(move |accepted| {
                        record_surface_resize_dispatch_result(
                            &ownership,
                            surface_id,
                            (cols, rows),
                            accepted,
                        );
                    })),
                },
            })
        } else {
            let Some(claim) = claim else { return false };
            self.session.resize_surface(surface_id, surface, cols, rows, reassert, claim)
        }
    }

    pub(super) fn enqueue_surface_size_reclaim(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        cols: u16,
        rows: u16,
        claim: Option<SurfaceResizeClaim>,
    ) -> bool {
        if surface.kind() == SurfaceKind::Browser {
            self.enqueue_surface_resize(surface_id, surface, cols, rows, true, claim)
        } else {
            let Some(claim) = claim else { return false };
            self.session.reclaim_surface_size(surface_id, surface, cols, rows, claim)
        }
    }

    pub fn tab_drag(&self) -> Option<TabDragView> {
        match self.drag {
            Some(Drag::Tab { surface, target }) => Some(TabDragView { surface, target }),
            _ => None,
        }
    }

    pub fn workspace_drag(&self) -> Option<(WorkspaceId, Option<usize>)> {
        match self.drag {
            Some(Drag::Workspace { workspace, target }) => Some((workspace, target)),
            _ => None,
        }
    }

    pub fn surface_scroll_offset(&self, surface: SurfaceId) -> u64 {
        self.session
            .surface(surface)
            .and_then(|surface| surface.scrollbar().map(|scrollbar| scrollbar.offset))
            .unwrap_or(0)
    }
}
