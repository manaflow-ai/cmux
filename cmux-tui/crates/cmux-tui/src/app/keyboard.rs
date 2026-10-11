//! Keyboard ingress on the App: resolving which target owns a key, and the
//! direct keyboard handlers.

use cmux_tui_core::{SurfaceId, SurfaceKind};
use crossterm::event::{KeyEvent, KeyEventKind};

use crate::app::host_input::{KeyboardIngress, TerminalInput};
use crate::app::layout::FocusTarget;
use crate::app::{
    App, RenderAction, action_for_binding, binding_matches, browser_only_action,
    modeless_action_for_binding,
};
use crate::config::{Action, SidebarView};
use crate::keys;

impl App {
    pub(super) fn resolve_keyboard_ingress(
        &mut self,
        mut input: keys::KeyboardInput,
    ) -> KeyboardIngress {
        input.resolve_macos_option_as_alt(self.config.keys.macos_option_as_alt);
        if input.is_composing() || input.is_modifier_only() || input.is_release() {
            return KeyboardIngress::Ignored;
        }
        if self.menu.is_none() && !self.status_message_hovered() {
            self.status_message = None;
        }
        if self.pairing_dialog.is_some()
            || self.shortcut_help.is_some()
            || self.prompt.is_some()
            || self.menu.is_some()
            || self.omnibar.is_some()
        {
            return KeyboardIngress::Routed(TerminalInput::Keyboard(input));
        }
        let (binding_key, binding_fallback) = input.shortcut_keys();
        if self.prefix_armed {
            self.prefix_armed = false;
            if input.suppresses_alt_shortcut() {
                self.focus = FocusTarget::Pane;
                return KeyboardIngress::Handled(RenderAction::Draw);
            }
            if binding_matches(&self.config.keys.prefix, &binding_key, binding_fallback.as_ref()) {
                return KeyboardIngress::Routed(TerminalInput::Keyboard(input));
            }
            let Some(action) =
                action_for_binding(&self.config.keys, &binding_key, binding_fallback.as_ref())
            else {
                self.focus = FocusTarget::Pane;
                return KeyboardIngress::Handled(RenderAction::Draw);
            };
            let was_sidebar_focused = self.workspace_sidebar_focused();
            let keep_machine_rail_focus =
                self.machine_sidebar_focused() && action == Action::ProviderMenu;
            if !(keep_machine_rail_focus || was_sidebar_focused && action == Action::SendPrefix) {
                self.focus = FocusTarget::Pane;
            }
            if was_sidebar_focused && action == Action::FocusSidebar {
                return KeyboardIngress::Handled(RenderAction::Draw);
            }
            if browser_only_action(action)
                && !self
                    .active_surface_handle()
                    .is_some_and(|surface| surface.kind() == SurfaceKind::Browser)
            {
                return KeyboardIngress::Routed(TerminalInput::Keyboard(input));
            }
            let prefix = self.config.keys.prefix;
            return KeyboardIngress::Routed(TerminalInput::FrontendAction {
                action,
                prefix: KeyEvent::new(prefix.code, prefix.mods),
            });
        }
        if !input.suppresses_alt_shortcut()
            && binding_matches(&self.config.keys.prefix, &binding_key, binding_fallback.as_ref())
        {
            self.prefix_armed = true;
            return KeyboardIngress::Handled(RenderAction::Draw);
        }
        if !input.suppresses_alt_shortcut()
            && let Some(action) = modeless_action_for_binding(
                &self.config.keys,
                &binding_key,
                binding_fallback.as_ref(),
            )
        {
            if action == Action::ClearHistory {
                return KeyboardIngress::Routed(TerminalInput::ClearHistoryKey(input));
            }
            let prefix = self.config.keys.prefix;
            return KeyboardIngress::Routed(TerminalInput::FrontendAction {
                action,
                prefix: KeyEvent::new(prefix.code, prefix.mods),
            });
        }
        KeyboardIngress::Routed(TerminalInput::Keyboard(input))
    }

    #[cfg(test)]
    pub(super) fn handle_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        self.handle_keyboard(key.into())
    }

    #[cfg(test)]
    pub(super) fn handle_keyboard(
        &mut self,
        input: keys::KeyboardInput,
    ) -> anyhow::Result<RenderAction> {
        match self.resolve_keyboard_ingress(input) {
            KeyboardIngress::Routed(TerminalInput::Keyboard(input)) => {
                self.handle_direct_keyboard(input)
            }
            KeyboardIngress::Routed(TerminalInput::FrontendAction { action, prefix }) => {
                self.run_resolved_action(action, prefix)
            }
            KeyboardIngress::Routed(TerminalInput::ClearHistoryKey(input)) => {
                Ok(self.run_clear_history_shortcut(input))
            }
            KeyboardIngress::Routed(_) => unreachable!("keyboard ingress returned non-key input"),
            KeyboardIngress::Handled(action) => Ok(action),
            KeyboardIngress::Ignored => Ok(RenderAction::None),
        }
    }

    #[cfg(test)]
    fn handle_direct_keyboard(
        &mut self,
        input: keys::KeyboardInput,
    ) -> anyhow::Result<RenderAction> {
        self.handle_direct_keyboard_to(input, None)
    }

    pub(super) fn handle_direct_keyboard_to(
        &mut self,
        input: keys::KeyboardInput,
        destination: Option<SurfaceId>,
    ) -> anyhow::Result<RenderAction> {
        let visible_state = self.visible_input_state(destination);
        let action = self.handle_direct_keyboard_to_inner(input, destination)?;
        Ok(action.merge(self.visible_input_action(visible_state)))
    }

    fn handle_direct_keyboard_to_inner(
        &mut self,
        input: keys::KeyboardInput,
        destination: Option<SurfaceId>,
    ) -> anyhow::Result<RenderAction> {
        let key = input.ui_key();
        if key.kind == KeyEventKind::Release {
            return Ok(RenderAction::None);
        }
        // A context menu acts on the resources visible when it opened. Keep a
        // status message alive while the menu owns input so status actions can
        // still validate and copy that exact message.
        if self.menu.is_none() && !self.status_message_hovered() {
            self.status_message = None;
        }
        if self.pairing_dialog.is_some() {
            return self.handle_pairing_key(key);
        }
        if self.shortcut_help.is_some() {
            return Ok(self.handle_shortcut_help_key(key));
        }
        if self.prompt.is_some() {
            if let Some(text) = input.text_for_direct_input() {
                return self.handle_prompt_text(text);
            }
            return self.handle_prompt_key(key);
        }
        if self.menu.is_some() {
            if let Some(text) = input.text_for_direct_input()
                && self.menu.as_mut().is_some_and(|menu| menu.insert_search_text(text))
            {
                return Ok(RenderAction::Draw);
            }
            return self.handle_menu_key(key);
        }
        if self.omnibar.is_some() {
            if let Some(text) = input.text_for_direct_input() {
                return self.handle_omnibar_text(text);
            }
            return self.handle_omnibar_key(key);
        }
        if self.machine_sidebar_focused() {
            return Ok(self.handle_machine_sidebar_key(&key));
        }
        if self.tabs_sidebar_focused() {
            return self.handle_tabs_sidebar_key(&key);
        }
        if let FocusTarget::ProjectionRail(index) = self.focus {
            return self.handle_projection_sidebar_key(index, &key);
        }
        if self.workspace_sidebar_focused() {
            if self.config.sidebar.plugin.is_some() {
                self.forward_sidebar_key(input);
                return Ok(if self.status_message.is_some() {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                });
            } else {
                if self.sidebar_view == SidebarView::Files
                    && let Some(text) = input.text_for_direct_input()
                    && self.sidebar_files.insert_filter_text(text)
                {
                    return Ok(RenderAction::Draw);
                }
                return self.handle_builtin_sidebar_key(&key);
            }
        }
        // Typing replaces any selection highlight.
        self.replace_selection(None);
        if let Some(surface) = destination {
            self.forward_key_to_surface(input, surface);
        } else {
            self.forward_key(input);
        }
        Ok(if self.status_message.is_some() { RenderAction::Draw } else { RenderAction::None })
    }
}
