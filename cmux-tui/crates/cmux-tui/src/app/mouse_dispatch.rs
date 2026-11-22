//! Mouse event dispatch: the entry points that route a mouse event by kind
//! and button, with sequence-based admission.

use std::time::Instant;

use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};

use crate::app::pointer::{Drag, PtyMousePressResult, TerminalPointerAdmission};
use crate::app::{App, RenderAction};

impl App {
    #[cfg(test)]
    pub(super) fn handle_mouse(&mut self, mouse: MouseEvent) -> anyhow::Result<RenderAction> {
        self.handle_mouse_with_sequence(mouse, None, None, Instant::now())
    }

    #[cfg(test)]
    pub(super) fn handle_mouse_at(
        &mut self,
        mouse: MouseEvent,
        now: Instant,
    ) -> anyhow::Result<RenderAction> {
        self.handle_mouse_with_sequence(mouse, None, None, now)
    }

    pub(super) fn handle_mouse_with_sequence(
        &mut self,
        mouse: MouseEvent,
        replay_sequence: Option<u64>,
        terminal_admission: Option<TerminalPointerAdmission>,
        now: Instant,
    ) -> anyhow::Result<RenderAction> {
        // A live physical sample supersedes retained motion. Replayed input
        // only supersedes motion that was retained earlier in the same
        // sequence, preserving newer samples until their chronological turn.
        if replay_sequence.is_none_or(|sequence| {
            self.pending_pointer_motion.as_ref().is_none_or(|pending| pending.sequence <= sequence)
        }) {
            self.pending_pointer_motion = None;
        }
        if self.pairing_dialog.is_none() && self.shortcut_help.is_some() {
            return Ok(self.handle_shortcut_help_mouse(mouse));
        }
        if self.pairing_dialog.is_some() {
            if mouse.kind == MouseEventKind::Moved {
                let hover_region = |position: Option<(u16, u16)>| {
                    position.and_then(|(x, y)| {
                        self.pairing_dialog.as_ref().map(|dialog| {
                            (dialog.approve.contains(x, y), dialog.deny.contains(x, y))
                        })
                    })
                };
                let before = hover_region(self.hover);
                let after = hover_region(Some((mouse.column, mouse.row)));
                self.sync_pointer_shape(mouse.column, mouse.row);
                self.hover = Some((mouse.column, mouse.row));
                return Ok(if before != after { RenderAction::Draw } else { RenderAction::None });
            }
            if !matches!(mouse.kind, MouseEventKind::Down(MouseButton::Left)) {
                if let MouseEventKind::Up(button) = mouse.kind {
                    self.active_pointer_buttons.remove(&button);
                }
                return Ok(RenderAction::None);
            }
        }
        // This TUI tracks one active pointer button. Ignore additional presses
        // until its release so a second button cannot orphan the inner app's
        // pressed state.
        if let MouseEventKind::Down(button) = mouse.kind
            && let Some(Drag::PtyMouse { button: active, .. }) = &self.drag
        {
            if button != *active {
                self.ignored_pty_mouse_buttons.insert(button);
            }
            return Ok(RenderAction::None);
        }
        match mouse.kind {
            MouseEventKind::Down(button) => {
                self.active_pointer_buttons.insert(button);
            }
            MouseEventKind::Up(button) => {
                self.active_pointer_buttons.remove(&button);
            }
            _ => {}
        }
        match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => self.handle_left_down_with_admission(
                mouse.column,
                mouse.row,
                mouse.modifiers,
                terminal_admission,
                now,
            ),
            MouseEventKind::Drag(MouseButton::Left) => {
                if self.forward_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Left,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::None)
                } else {
                    self.handle_left_drag(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Up(MouseButton::Left) => {
                if self.finish_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Left,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::Draw)
                } else {
                    self.handle_left_up(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Down(MouseButton::Right) => {
                self.reset_selection_click_sequence();
                if self.prompt.is_some() {
                    self.shake_frames = 6;
                    return Ok(RenderAction::Draw);
                }
                if self.begin_pty_mouse_drag_with_admission(
                    mouse.column,
                    mouse.row,
                    MouseButton::Right,
                    mouse.modifiers,
                    terminal_admission,
                ) != PtyMousePressResult::NotOwned
                {
                    return Ok(RenderAction::Draw);
                }
                self.open_context_menu(mouse.column, mouse.row);
                Ok(RenderAction::Draw)
            }
            MouseEventKind::Drag(MouseButton::Right) => {
                if self.forward_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Right,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::None)
                } else {
                    self.handle_right_drag(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Up(MouseButton::Right) => {
                if self.finish_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Right,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::Draw)
                } else {
                    self.handle_right_up(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Down(MouseButton::Middle) => {
                self.reset_selection_click_sequence();
                Ok(
                    if self.begin_pty_mouse_drag_with_admission(
                        mouse.column,
                        mouse.row,
                        MouseButton::Middle,
                        mouse.modifiers,
                        terminal_admission,
                    ) != PtyMousePressResult::NotOwned
                    {
                        RenderAction::Draw
                    } else {
                        RenderAction::None
                    },
                )
            }
            MouseEventKind::Drag(MouseButton::Middle) => {
                self.forward_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Middle,
                    mouse.modifiers,
                );
                Ok(RenderAction::None)
            }
            MouseEventKind::Up(MouseButton::Middle) => Ok(
                if self.finish_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Middle,
                    mouse.modifiers,
                ) {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                },
            ),
            MouseEventKind::Moved => self.handle_hover_with_admission(
                mouse.column,
                mouse.row,
                mouse.modifiers,
                terminal_admission,
            ),
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                let down = matches!(mouse.kind, MouseEventKind::ScrollDown);
                self.handle_scroll_with_admission(
                    mouse.column,
                    mouse.row,
                    down,
                    mouse.modifiers,
                    terminal_admission,
                )
            }
            MouseEventKind::ScrollLeft | MouseEventKind::ScrollRight => self
                .handle_horizontal_scroll_with_admission(
                    mouse.column,
                    mouse.row,
                    matches!(mouse.kind, MouseEventKind::ScrollRight),
                    mouse.modifiers,
                    terminal_admission,
                ),
        }
    }
}
