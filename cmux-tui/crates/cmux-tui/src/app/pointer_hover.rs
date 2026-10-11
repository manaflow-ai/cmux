//! Pointer hover and right button: clickable targets, the pointer shape, hover
//! handling with admission, and right-button drag and release.

use std::io::Write;

use cmux_tui_core::SurfaceKind;
use crossterm::event::KeyModifiers;
use ghostty_vt::MouseAction;

use crate::app::layout::{Hit, OmnibarHit};
use crate::app::pointer::TerminalPointerAdmission;
use crate::app::{App, BrowserMouseDispatch, RenderAction, browser_hover_forward_allowed};

impl App {
    /// Whether the cell is over something clickable (any hit, a menu row,
    /// or a dialog button): these render the hand pointer.
    fn is_clickable(&self, x: u16, y: u16) -> bool {
        if let Some(dialog) = &self.pairing_dialog {
            return dialog.approve.contains(x, y) || dialog.deny.contains(x, y);
        }
        if let Some(prompt) = &self.prompt {
            return prompt.ok.contains(x, y)
                || prompt.cancel.contains(x, y)
                || prompt.clear.contains(x, y)
                || prompt.input_rect.contains(x, y);
        }
        if let Some(menu) = &self.menu {
            // Everything inside the menu rect is menu territory: item rows
            // and scrollbar tracks are clickable; border cells never inherit
            // clickability from hits underneath.
            if menu.contains(x, y) {
                return menu.hit_at(x, y).is_some() || menu.scrollbar_at(x, y).is_some();
            }
        }
        if self.omnibar_hit_at(x, y).is_some() {
            return true;
        }
        self.hit_at(x, y).is_some()
    }

    /// Keep the terminal's mouse pointer shape in sync: a hand over
    /// clickable UI, the default elsewhere (OSC 22; terminals without
    /// support ignore it).
    pub(super) fn sync_pointer_shape(&mut self, x: u16, y: u16) {
        let want_pointer = self.is_clickable(x, y);
        if want_pointer == self.pointer_shape {
            return;
        }
        let shape = if want_pointer { "pointer" } else { "default" };
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock();
        if lock.recover_stream_locked().is_err() {
            return;
        }
        if self.ensure_graphics_writer_healthy().is_err() {
            return;
        }
        self.pointer_shape = want_pointer;
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]22;{shape}\x07");
        let _ = stdout.flush();
    }

    /// Mouse-move: sync the pointer shape, highlight the hovered menu
    /// item, and track the mouse position so tab-bar controls (+, ‹, ›)
    /// and the scrollbar render a hover state. Only redraws when the
    /// hovered element actually changes.
    pub(super) fn handle_hover_with_admission(
        &mut self,
        x: u16,
        y: u16,
        modifiers: KeyModifiers,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> anyhow::Result<RenderAction> {
        self.sync_pointer_shape(x, y);
        if let Some(menu) = self.menu.as_mut() {
            let before_scrollbar =
                self.hover.and_then(|(px, py)| menu.scrollbar_at(px, py).map(|(depth, _)| depth));
            let after_scrollbar = menu.scrollbar_at(x, y).map(|(depth, _)| depth);
            let selection_changed =
                menu.hit_at(x, y).is_some_and(|(depth, item)| menu.select_at(depth, item));
            self.hover = Some((x, y));
            return Ok(if selection_changed || before_scrollbar != after_scrollbar {
                RenderAction::Draw
            } else {
                RenderAction::None
            });
        }
        if self.menu.is_none() && self.prompt.is_none() && self.drag.is_none() {
            let _ = self.forward_pty_mouse_at_with_admission(
                (x, y),
                MouseAction::Motion,
                None,
                modifiers,
                false,
                terminal_admission,
            );
            let mut over_browser = false;
            if let Some(area) = self
                .pane_areas
                .iter()
                .find(|area| {
                    area.content.contains(x, y)
                        && self.surface_kind(area.surface) == Some(SurfaceKind::Browser)
                })
                .copied()
            {
                over_browser = true;
                let editing_same_pane =
                    self.omnibar.as_ref().is_some_and(|state| state.pane == area.pane);
                let status = self.session.surface(area.surface).and_then(|surface| {
                    (surface.kind() == SurfaceKind::Browser).then(|| surface.browser_status())
                });
                if browser_hover_forward_allowed(status.flatten(), editing_same_pane) {
                    let cell = (
                        area.content_source_x().saturating_add(x.saturating_sub(area.content.x)),
                        y.saturating_sub(area.content.y),
                    );
                    if let Some(frame_seq) = self.processed_browser_pointer_authority(area.surface)
                    {
                        let next = (area.surface, cell.0, cell.1, frame_seq);
                        if self.last_browser_hover != Some(next) {
                            let _ = self.send_browser_mouse(
                                area.surface,
                                area.content,
                                x,
                                y,
                                frame_seq,
                                BrowserMouseDispatch::new("mouseMoved", Some("none"), None),
                            );
                            self.last_browser_hover = Some(next);
                        }
                    }
                }
            }
            if !over_browser {
                self.last_browser_hover = None;
            }
        }
        let hoverable = |pos: Option<(u16, u16)>| {
            pos.and_then(|(px, py)| {
                self.hit_at(px, py)
                    .filter(|hit| {
                        matches!(
                            hit,
                            Hit::NewTab { .. }
                                | Hit::TabScroll { .. }
                                | Hit::Scrollbar { .. }
                                | Hit::HorizontalScrollbar { .. }
                                | Hit::WorkspaceScrollbar { .. }
                        )
                    })
                    .map(|hit| format!("{hit:?}"))
                    .or_else(|| {
                        self.omnibar_hit_at(px, py)
                            .filter(|(_, hit)| *hit != OmnibarHit::Edit)
                            .map(|(_, hit)| format!("{hit:?}"))
                    })
            })
        };
        let before = hoverable(self.hover);
        let after = hoverable(Some((x, y)));
        self.hover = Some((x, y));
        Ok(if before != after { RenderAction::Draw } else { RenderAction::None })
    }

    pub(super) fn handle_right_drag(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        self.hover = Some((x, y));
        let Some(menu) = self.menu.as_mut() else { return Ok(RenderAction::None) };
        if (x, y) != menu.right_press {
            menu.right_drag_moved = true;
        }
        if let Some((depth, item)) = menu.hit_at(x, y)
            && menu.select_at(depth, item)
        {
            return Ok(RenderAction::Draw);
        }
        Ok(RenderAction::None)
    }

    pub(super) fn handle_right_up(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        let Some(mut menu) = self.menu.take() else { return Ok(RenderAction::None) };
        let plain_open_click = !menu.right_drag_moved && (x, y) == menu.right_press;
        if plain_open_click {
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
        } else {
            self.menu = Some(menu);
        }
        Ok(RenderAction::Draw)
    }
}
