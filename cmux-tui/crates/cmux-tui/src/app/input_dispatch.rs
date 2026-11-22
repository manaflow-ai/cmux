//! Terminal input dispatch on the App: routing a classified terminal input to
//! its handler, and paste handling.

use std::time::Instant;

use cmux_tui_core::SurfaceId;
use crossterm::event::MouseEventKind;

use crate::app::host_input::TerminalInput;
use crate::app::pointer::TerminalPointerAdmission;
use crate::app::{App, RenderAction, clear_omnibar_selection};
use crate::config::SidebarView;

impl App {
    pub(super) fn dispatch_terminal_input(
        &mut self,
        input: TerminalInput,
        input_sequence: Option<u64>,
        terminal_pointer_admission: Option<TerminalPointerAdmission>,
        semantic_result: Option<u64>,
        action_destination: Option<SurfaceId>,
        action_fallback_destination: Option<SurfaceId>,
    ) -> anyhow::Result<RenderAction> {
        if !matches!(&input, TerminalInput::Mouse(_)) {
            self.reset_selection_click_sequence();
        }
        let semantic_result =
            if semantic_result.is_none() && self.input_creates_session_destination(&input) {
                self.clear_finished_semantic_destinations();
                let intent = self.allocate_semantic_destination_intent();
                self.latest_semantic_destination_intent = Some(intent);
                Some(intent)
            } else {
                semantic_result
            };
        match input {
            TerminalInput::Keyboard(key) => {
                let dismissed = !key.is_release() && self.dismiss_painted_durable_notice();
                let action = self.handle_direct_keyboard_to(key, action_destination)?;
                Ok(if dismissed { action.merge(RenderAction::Draw) } else { action })
            }
            TerminalInput::FrontendAction { action, prefix } => {
                let dismissed = self.dismiss_painted_durable_notice();
                let action = self.run_resolved_action_with_semantic_intent(
                    action,
                    prefix,
                    semantic_result,
                    action_destination,
                    action_fallback_destination,
                )?;
                Ok(if dismissed { action.merge(RenderAction::Draw) } else { action })
            }
            TerminalInput::ClearHistoryKey(input) => {
                let dismissed = self.dismiss_painted_durable_notice();
                let action = self.run_clear_history_shortcut_to(input, action_destination);
                Ok(if dismissed { action.merge(RenderAction::Draw) } else { action })
            }
            TerminalInput::Mouse(mouse) => {
                if matches!(mouse.kind, MouseEventKind::Down(_))
                    && self.durable_notice_banner_row() == Some(mouse.row)
                    && self.dismiss_painted_durable_notice()
                {
                    return Ok(RenderAction::Draw);
                }
                let dismissed = matches!(
                    mouse.kind,
                    MouseEventKind::Down(_)
                        | MouseEventKind::ScrollUp
                        | MouseEventKind::ScrollDown
                        | MouseEventKind::ScrollLeft
                        | MouseEventKind::ScrollRight
                ) && self.dismiss_painted_durable_notice();
                let action = self.handle_mouse_with_sequence(
                    mouse,
                    input_sequence,
                    terminal_pointer_admission,
                    Instant::now(),
                )?;
                Ok(if dismissed { action.merge(RenderAction::Draw) } else { action })
            }
            TerminalInput::Paste(text) => {
                let dismissed = self.dismiss_painted_durable_notice();
                let action = self.handle_paste_to(text, action_destination)?;
                Ok(if dismissed { action.merge(RenderAction::Draw) } else { action })
            }
            TerminalInput::FocusGained => {
                self.advance_pointer_focus_generation();
                self.reassert_scoped_host_terminal_state();
                self.reassert_visible_surface_sizes();
                Ok(RenderAction::Draw)
            }
            TerminalInput::FocusLost => {
                let action = if self.cancel_pointer_interaction() {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                };
                self.advance_pointer_focus_generation();
                Ok(action)
            }
            TerminalInput::Resize => {
                self.reassert_scoped_host_terminal_state();
                if self.graphics_supported {
                    self.graphics_host_scene_reset_pending = true;
                }
                self.refresh_cell_pixels();
                self.render_states.clear();
                self.sidebar_plugin_surface = None;
                Ok(RenderAction::Draw)
            }
        }
    }

    fn handle_paste_to(
        &mut self,
        text: String,
        destination: Option<SurfaceId>,
    ) -> anyhow::Result<RenderAction> {
        let action = self.handle_paste_to_inner(text, destination)?;
        Ok(action.merge(self.painted_status_message_action()))
    }

    fn handle_paste_to_inner(
        &mut self,
        text: String,
        destination: Option<SurfaceId>,
    ) -> anyhow::Result<RenderAction> {
        // A context menu acts on the resources visible when it opened. Keep a
        // status message alive while the menu owns input so status actions can
        // still validate and copy that exact message.
        if self.menu.is_none() && !self.status_message_hovered() {
            self.status_message = None;
        }
        if self.pairing_dialog.is_some() || self.shortcut_help.is_some() {
            Ok(RenderAction::Draw)
        } else if let Some(prompt) = self.prompt.as_mut() {
            prompt.input.insert_str(&text);
            Ok(RenderAction::Draw)
        } else if let Some(state) = self.omnibar.as_mut() {
            clear_omnibar_selection(state);
            state.input.insert_str(&text);
            Ok(RenderAction::Draw)
        } else if let Some(menu) = self.menu.as_mut() {
            menu.insert_search_text(&text);
            Ok(RenderAction::Draw)
        } else if self.machine_sidebar_focused() || self.tabs_sidebar_focused() {
            Ok(RenderAction::Draw)
        } else if self.workspace_sidebar_focused() {
            if self.config.sidebar.plugin.is_some() {
                self.paste_sidebar(&text);
                Ok(if self.status_message.is_some() {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                })
            } else {
                if self.sidebar_view == SidebarView::Files {
                    self.sidebar_files.insert_filter_text(&text);
                }
                Ok(RenderAction::Draw)
            }
        } else {
            if let Some(surface) = destination {
                self.paste_to_surface(&text, surface);
            } else {
                self.paste(&text);
            }
            Ok(if self.status_message.is_some() { RenderAction::Draw } else { RenderAction::None })
        }
    }
}
