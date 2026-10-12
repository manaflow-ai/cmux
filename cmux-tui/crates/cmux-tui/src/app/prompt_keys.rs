//! Prompt and dialog input: sidebar file commands, committing and closing
//! prompts, prompt, pairing, shortcut help, omnibar and menu keys, and their
//! mouse clicks.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind};

use crate::app::overlays::{ConnectionDialogPhase, PairingDialog, Prompt, PromptTarget};
use crate::app::{
    App, RenderAction, clear_omnibar_selection, pairing_confirm, provider_action_error_message,
};
use crate::browser_input::BrowserInputKind;
use crate::machine::MachineRequest;
use crate::pty_input::{PtyInputBytes, PtyInputKind};
use crate::sidebar_files::{FileCommand, cd_command, file_url};
use crate::ui::input::InputEvent;
use crate::{keys, localization};

impl App {
    pub(super) fn run_file_command(&mut self, command: FileCommand) {
        if !self.session_available() {
            self.sidebar_files.set_message(localization::catalog().sidebar.no_active_session);
            return;
        }
        let result = match command {
            FileCommand::Reroot => {
                let cwd = self
                    .focused_surface_cwd()
                    .unwrap_or_else(|| self.sidebar_files.fallback_cwd().to_path_buf());
                self.sidebar_files.reroot(cwd);
                self.sidebar_followed_surface = self.tree.active_surface();
                return;
            }
            FileCommand::Cd(path) => {
                let Some(surface_id) = self.active_surface() else {
                    self.sidebar_files
                        .set_message(localization::catalog().sidebar.file_no_focused_pane);
                    return;
                };
                let Some(surface) = self.session.surface(surface_id) else {
                    self.sidebar_files
                        .set_message(localization::catalog().sidebar.file_surface_unavailable);
                    return;
                };
                let Some(bytes) = cd_command(&path.to_string_lossy()) else {
                    let message = localization::catalog().sidebar.file_path_has_control_characters;
                    self.sidebar_files.set_message(message);
                    return;
                };
                if self.write_pty_bytes(
                    surface_id,
                    surface,
                    PtyInputBytes::from_slice(bytes.as_bytes()),
                    PtyInputKind::Ordered,
                ) {
                    Ok(())
                } else {
                    Err(anyhow::anyhow!(localization::catalog().sidebar.file_input_not_queued))
                }
            }
            FileCommand::OpenEditor(path) => {
                let editor = std::env::var("EDITOR")
                    .ok()
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| "vi".to_string());
                let cwd = path
                    .parent()
                    .unwrap_or_else(|| std::path::Path::new("/"))
                    .to_string_lossy()
                    .into_owned();
                self.session.run_command(
                    vec![editor, path.to_string_lossy().into_owned()],
                    self.active_pane(),
                    Some(cwd),
                    self.terminal_tab_size_hint(self.active_pane()),
                )
            }
            FileCommand::OpenBrowser(path) => self.session.new_browser_tab(
                file_url(&path),
                self.active_pane(),
                self.browser_tab_size_hint(self.active_pane()),
            ),
        };
        match result {
            Ok(()) => self
                .sidebar_files
                .set_message(localization::catalog().sidebar.file_sent_to_focused_pane),
            Err(error) => self.sidebar_files.set_message(
                localization::catalog()
                    .sidebar
                    .file_command_failed
                    .replace("{error}", &error.to_string()),
            ),
        }
    }

    /// Commit the open rename dialog (Enter or the OK button).
    pub(super) fn commit_prompt(&mut self) {
        if let Some((route, input)) = self.prompt.as_ref().and_then(|prompt| {
            matches!(prompt.target, PromptTarget::ConnectMachine(_)).then(|| {
                let PromptTarget::ConnectMachine(route) = prompt.target else { unreachable!() };
                (route, prompt.input.as_str().to_string())
            })
        }) {
            self.begin_machine_connection(input, route);
            return;
        }
        let Some(prompt) = self.take_prompt() else { return };
        let input = prompt.input.as_str().to_string();
        if let PromptTarget::ClientMachine(key) = prompt.target {
            if !input.trim().is_empty() {
                self.request_rename_client_machine(key, input);
            }
            return;
        }
        if let PromptTarget::ManagedMachine(key) = prompt.target {
            if !input.is_empty() {
                self.request_rename_managed_machine(key, input);
            }
            return;
        }
        if let PromptTarget::ConfirmDeleteManagedMachine(key) = prompt.target {
            if input.trim() == "CONFIRM" {
                self.request_delete_managed_machine(key);
            } else {
                self.status_message =
                    Some(localization::catalog().sidebar.confirmation_mismatch.to_string());
                self.prompt = Some(prompt);
                self.shake_frames = 6;
            }
            return;
        }
        if let PromptTarget::ConfirmPurgeManagedMachine(key) = prompt.target {
            if input.trim() == "CONFIRM" {
                self.request_purge_managed_machine(key);
            } else {
                self.status_message =
                    Some(localization::catalog().sidebar.confirmation_mismatch.to_string());
                self.prompt = Some(prompt);
                self.shake_frames = 6;
            }
            return;
        }
        if let PromptTarget::ProviderAction(index) = prompt.target {
            let result = self.bound_provider_action(index, Some(&input));
            match result {
                Some(Ok((request, true))) => {
                    self.pending_provider_action = Some(request);
                    self.prompt = Some(Prompt::new(
                        localization::catalog().sidebar.confirm_destructive_action,
                        String::new(),
                        PromptTarget::ConfirmProviderAction,
                    ));
                }
                Some(Ok((request, false))) => {
                    if let Some(ui) = self.machine_ui.as_mut() {
                        ui.request = Some(request);
                    }
                }
                Some(Err(error)) => {
                    self.status_message = Some(provider_action_error_message(error).to_string());
                    self.prompt = Some(prompt);
                    self.shake_frames = 6;
                }
                None => {}
            }
            return;
        }
        if let PromptTarget::ConfirmProviderAction = prompt.target {
            if input.trim() == "CONFIRM" {
                if let (Some(request), Some(ui)) =
                    (self.pending_provider_action.take(), self.machine_ui.as_mut())
                {
                    ui.request = Some(request);
                }
            } else {
                self.status_message =
                    Some(localization::catalog().sidebar.confirmation_mismatch.to_string());
                self.prompt = Some(prompt);
                self.shake_frames = 6;
            }
            return;
        }
        if let PromptTarget::ManagedWorkspace(id) = prompt.target {
            if !input.is_empty() {
                self.request_rename_managed_workspace(id, input);
            }
            return;
        }
        if let PromptTarget::ConfirmPurgeManagedWorkspace(index) = prompt.target {
            if input.trim() == "CONFIRM" {
                let workspace_id = self
                    .machine_ui
                    .as_ref()
                    .and_then(|ui| ui.recoverable_workspaces().get(index).copied())
                    .map(|workspace| workspace.id.clone());
                if let Some(workspace_id) = workspace_id {
                    self.request_purge_managed_workspace(&workspace_id);
                }
            } else {
                self.status_message =
                    Some(localization::catalog().sidebar.confirmation_mismatch.to_string());
                self.prompt = Some(prompt);
                self.shake_frames = 6;
            }
            return;
        }
        if let PromptTarget::ConfirmLayoutUndo { pane, revision } = prompt.target {
            if input.trim() != "CONFIRM" {
                self.status_message =
                    Some(localization::catalog().sidebar.confirmation_mismatch.to_string());
                self.prompt = Some(prompt);
                self.shake_frames = 6;
                return;
            }
            if !self.prepare_pty_input_before_mutation() {
                self.prompt = Some(prompt);
                return;
            }
            if let Err(error) = self.session.undo_layout(pane, Some(revision), true) {
                self.status_message = Some(
                    localization::catalog()
                        .sidebar
                        .layout_undo_failed
                        .replace("{error}", &error.to_string()),
                );
            }
            return;
        }
        if !self.prepare_pty_input_before_mutation() {
            return;
        }
        match prompt.target {
            PromptTarget::Workspace(id) => {
                if !input.is_empty() {
                    self.request_rename_workspace(id, input);
                }
            }
            // Empty screen/tab names clear back to the default.
            PromptTarget::Screen(id) => self.session.rename_screen(id, input),
            PromptTarget::Surface(id) => self.session.rename_surface(id, input),
            PromptTarget::ConnectMachine(_)
            | PromptTarget::ClientMachine(_)
            | PromptTarget::ManagedMachine(_)
            | PromptTarget::ConfirmDeleteManagedMachine(_)
            | PromptTarget::ConfirmPurgeManagedMachine(_)
            | PromptTarget::ProviderAction(_)
            | PromptTarget::ConfirmProviderAction
            | PromptTarget::ManagedWorkspace(_)
            | PromptTarget::ConfirmPurgeManagedWorkspace(_)
            | PromptTarget::ConfirmLayoutUndo { .. } => {
                unreachable!("handled before session mutation")
            }
        }
    }

    fn take_prompt(&mut self) -> Option<Prompt> {
        self.shake_frames = 0;
        self.prompt.take()
    }

    pub(super) fn close_prompt(&mut self) {
        self.shake_frames = 0;
        self.prompt = None;
        if let Some(transaction) = self.connection_transaction.take() {
            if let Some(machine) = self.machine_ui.as_mut()
                && machine.request.as_ref().is_some_and(|request| {
                    matches!(
                        request,
                        MachineRequest::Connect { target, route }
                            if target == &transaction.target && route == &transaction.route
                    )
                })
            {
                machine.request = None;
            }
            if self.machine_action_connection_attempt == Some(transaction.attempt) {
                self.canceled_machine_connection_attempt = Some(transaction.attempt);
            }
        }
        self.pending_provider_action = None;
    }

    pub(super) fn handle_prompt_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        if let Some(phase) =
            self.connection_transaction.as_ref().map(|transaction| transaction.phase.clone())
        {
            match phase {
                ConnectionDialogPhase::Editing => {}
                ConnectionDialogPhase::Connecting | ConnectionDialogPhase::Starting => {
                    if key.code == KeyCode::Esc {
                        self.close_prompt();
                    }
                    return Ok(RenderAction::Draw);
                }
                ConnectionDialogPhase::Failed(_) => {
                    match key.code {
                        KeyCode::Enter => self.retry_machine_connection(),
                        KeyCode::Esc => self.close_prompt(),
                        KeyCode::Char('c' | 'C')
                            if key.modifiers.contains(KeyModifiers::CONTROL) =>
                        {
                            self.copy_connection_error();
                        }
                        _ => {}
                    }
                    return Ok(RenderAction::Draw);
                }
            }
        }
        let Some(prompt) = self.prompt.as_mut() else { return Ok(RenderAction::None) };
        match prompt.input.handle_key(&key) {
            InputEvent::Commit => self.commit_prompt(),
            InputEvent::Cancel => self.close_prompt(),
            InputEvent::Changed | InputEvent::None => {}
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn handle_prompt_text(&mut self, text: &str) -> anyhow::Result<RenderAction> {
        if self
            .connection_transaction
            .as_ref()
            .is_some_and(|transaction| !matches!(transaction.phase, ConnectionDialogPhase::Editing))
        {
            return Ok(RenderAction::Draw);
        }
        let Some(prompt) = self.prompt.as_mut() else { return Ok(RenderAction::None) };
        prompt.input.insert_str(text);
        Ok(RenderAction::Draw)
    }

    fn resolve_pairing(&mut self, approve: bool) {
        self.cancel_pointer_interaction();
        let Some(dialog) = self.pairing_dialog.take() else { return };
        if let Err(error) = self.session.respond_pairing(dialog.challenge.id, approve) {
            self.status_message = Some(
                localization::catalog()
                    .sidebar
                    .pairing_response_failed
                    .replace("{error}", &error.to_string()),
            );
        }
        self.pairing_dialog = self.pairing_queue.pop_front().map(PairingDialog::new);
    }

    pub(super) fn handle_pairing_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        if let Some(approve) = pairing_confirm::decision(&key, &self.session) {
            self.resolve_pairing(approve);
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn handle_shortcut_help_key(&mut self, key: KeyEvent) -> RenderAction {
        let Some(help) = self.shortcut_help.as_mut() else { return RenderAction::None };
        let total_rows = help.rows.len();
        let page = help.visible_rows.max(1) as isize;
        let previous_offset = help.scroll_offset;
        let mut close = false;
        match key.code {
            KeyCode::Esc => close = true,
            KeyCode::Char('?')
                if !key.modifiers.intersects(
                    KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                ) =>
            {
                close = true;
            }
            KeyCode::Up | KeyCode::Char('k') => help.scroll_by(-1, total_rows),
            KeyCode::Down | KeyCode::Char('j') => help.scroll_by(1, total_rows),
            KeyCode::PageUp => help.scroll_by(-page, total_rows),
            KeyCode::PageDown => help.scroll_by(page, total_rows),
            KeyCode::Home => help.scroll_offset = 0,
            KeyCode::End => help.scroll_offset = help.max_scroll(total_rows),
            _ => {}
        }
        if close {
            self.shortcut_help = None;
            RenderAction::Paint
        } else if help.scroll_offset != previous_offset {
            RenderAction::Paint
        } else {
            RenderAction::None
        }
    }

    pub(super) fn handle_shortcut_help_mouse(&mut self, mouse: MouseEvent) -> RenderAction {
        let Some(help) = self.shortcut_help.as_mut() else { return RenderAction::None };
        let total_rows = help.rows.len();
        let mut changed = false;
        let mut close = false;
        match mouse.kind {
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                let previous_offset = help.scroll_offset;
                let delta = if mouse.kind == MouseEventKind::ScrollUp { -1 } else { 1 };
                help.scroll_by(delta, total_rows);
                changed = help.scroll_offset != previous_offset;
            }
            MouseEventKind::Down(MouseButton::Left)
                if help.close_button.contains(mouse.column, mouse.row) =>
            {
                close = true;
            }
            MouseEventKind::Down(MouseButton::Left)
                if help.scrollbar_track.contains(mouse.column, mouse.row) =>
            {
                let previous_offset = help.scroll_offset;
                let was_dragging = help.scrollbar_dragging();
                help.start_scrollbar_drag(mouse.row, total_rows);
                changed = help.scroll_offset != previous_offset || !was_dragging;
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                let previous_offset = help.scroll_offset;
                help.drag_scrollbar(mouse.row, total_rows);
                changed = help.scroll_offset != previous_offset;
            }
            MouseEventKind::Up(MouseButton::Left) => {
                changed = help.scrollbar_dragging();
                help.scrollbar_drag = None;
            }
            MouseEventKind::Down(MouseButton::Left | MouseButton::Right)
                if !help.rect.contains(mouse.column, mouse.row) =>
            {
                close = true;
            }
            _ => {}
        }
        if close {
            self.shortcut_help = None;
            RenderAction::Paint
        } else if changed {
            RenderAction::Paint
        } else {
            RenderAction::None
        }
    }

    pub(super) fn handle_pairing_click(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        let Some(dialog) = self.pairing_dialog.as_ref() else { return Ok(RenderAction::None) };
        if dialog.approve.contains(x, y) {
            self.resolve_pairing(true);
        } else if dialog.deny.contains(x, y) || !dialog.rect.contains(x, y) {
            self.resolve_pairing(false);
        }
        Ok(RenderAction::Draw)
    }

    /// Clicks while the rename dialog is open: OK commits, Cancel (or a
    /// click outside the dialog) dismisses; clicks inside are swallowed.
    pub(super) fn handle_prompt_click(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        if let Some(phase) =
            self.connection_transaction.as_ref().map(|transaction| transaction.phase.clone())
        {
            let Some(prompt) = self.prompt.as_ref() else { return Ok(RenderAction::None) };
            match phase {
                ConnectionDialogPhase::Editing => {}
                ConnectionDialogPhase::Connecting | ConnectionDialogPhase::Starting => {
                    if prompt.cancel.contains(x, y) || !prompt.rect.contains(x, y) {
                        self.close_prompt();
                    }
                    return Ok(RenderAction::Draw);
                }
                ConnectionDialogPhase::Failed(_) => {
                    if prompt.ok.contains(x, y) {
                        self.retry_machine_connection();
                    } else if prompt.clear.contains(x, y) {
                        self.copy_connection_error();
                    } else if prompt.cancel.contains(x, y) || !prompt.rect.contains(x, y) {
                        self.close_prompt();
                    }
                    return Ok(RenderAction::Draw);
                }
            }
        }
        let Some(prompt) = self.prompt.as_mut() else { return Ok(RenderAction::None) };
        if prompt.ok.contains(x, y) {
            self.commit_prompt();
        } else if prompt.clear.contains(x, y) {
            prompt.input.clear();
        } else if prompt.input_rect.contains(x, y) {
            let column = x.saturating_sub(prompt.input_rect.x) as usize;
            prompt.input.set_cursor_from_visible_column(column, prompt.input_rect.width as usize);
        } else if prompt.cancel.contains(x, y) || !prompt.rect.contains(x, y) {
            self.close_prompt();
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn handle_omnibar_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(state) = self.omnibar.as_mut() else { return Ok(RenderAction::None) };
        let replace_selection = state.select_all
            && matches!(
                key.code,
                KeyCode::Backspace
                    | KeyCode::Delete
                    | KeyCode::Char(_)
                        if !key.modifiers.intersects(keys::SHORTCUT_MODIFIERS)
            );
        if replace_selection {
            state.input.clear();
            state.select_all = false;
        } else if matches!(
            key.code,
            KeyCode::Left
                | KeyCode::Right
                | KeyCode::Home
                | KeyCode::End
                | KeyCode::Backspace
                | KeyCode::Delete
        ) {
            state.select_all = false;
        }
        if matches!(key.code, KeyCode::Char('a') | KeyCode::Char('A'))
            && key.modifiers.contains(KeyModifiers::CONTROL)
        {
            state.select_all = true;
            state.input.cursor = state.input.buffer.len();
            return Ok(RenderAction::Draw);
        }
        match state.input.handle_key(&key) {
            InputEvent::Cancel => {
                self.omnibar = None;
            }
            InputEvent::Commit => {
                let Some(state) = self.omnibar.take() else { return Ok(RenderAction::Draw) };
                let input = state.input.as_str().trim();
                if input.is_empty() {
                    return Ok(RenderAction::Draw);
                }
                let url = cmux_tui_core::normalize_url(input);
                if !self.prepare_pty_input_before_mutation() {
                    return Ok(RenderAction::None);
                }
                self.enqueue_browser_command(state.surface, BrowserInputKind::Navigate(url));
            }
            InputEvent::Changed | InputEvent::None => {}
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn handle_omnibar_text(&mut self, text: &str) -> anyhow::Result<RenderAction> {
        let Some(state) = self.omnibar.as_mut() else { return Ok(RenderAction::None) };
        clear_omnibar_selection(state);
        state.input.insert_str(text);
        Ok(RenderAction::Draw)
    }

    pub(super) fn handle_menu_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(menu) = self.menu.as_mut() else { return Ok(RenderAction::None) };
        menu.finish_scrollbar_drag();
        match key.code {
            KeyCode::Esc => {
                if !menu.close_submenu() {
                    self.menu = None;
                }
                Ok(RenderAction::Draw)
            }
            KeyCode::Up => {
                menu.select_previous();
                Ok(RenderAction::Draw)
            }
            KeyCode::Down => {
                menu.select_next();
                Ok(RenderAction::Draw)
            }
            KeyCode::Home => {
                menu.select_first();
                Ok(RenderAction::Draw)
            }
            KeyCode::End => {
                menu.select_last();
                Ok(RenderAction::Draw)
            }
            KeyCode::Left if menu.search.is_some() => {
                menu.handle_search_key(&key);
                Ok(RenderAction::Draw)
            }
            KeyCode::Left => {
                menu.close_submenu();
                Ok(RenderAction::Draw)
            }
            KeyCode::Right if menu.search.is_some() => {
                menu.handle_search_key(&key);
                Ok(RenderAction::Draw)
            }
            KeyCode::Right => {
                menu.open_selected_submenu();
                Ok(RenderAction::Draw)
            }
            KeyCode::Enter => {
                if menu.open_selected_submenu() {
                    return Ok(RenderAction::Draw);
                }
                let Some(action) = menu.selected_action() else { return Ok(RenderAction::Draw) };
                let expected_resource = menu.captured_resource(action);
                self.menu = None;
                if expected_resource
                    .is_none_or(|expected| self.menu_action_resource(action) == expected)
                {
                    self.activate_menu(action)?;
                }
                Ok(RenderAction::Draw)
            }
            _ => {
                menu.handle_search_key(&key);
                Ok(RenderAction::Draw) // swallow while a menu is open
            }
        }
    }
}
