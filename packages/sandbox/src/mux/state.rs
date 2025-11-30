use std::collections::VecDeque;
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use tokio::sync::mpsc;

use crate::models::{NotificationLevel, SandboxNetwork, SandboxStatus, SandboxSummary};
use crate::mux::commands::MuxCommand;
use crate::mux::events::MuxEvent;
use crate::mux::layout::{Direction, NavDirection, Pane, PaneId, SandboxId, WorkspaceManager};
use crate::mux::palette::CommandPalette;
use crate::mux::sidebar::Sidebar;
use crate::mux::terminal::{SharedTerminalManager, TerminalRenderView};
use uuid::Uuid;

/// Which area of the UI has focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusArea {
    Sidebar,
    MainArea,
    CommandPalette,
    Notifications,
}

#[derive(Debug, Clone)]
pub struct NotificationEntry {
    pub id: Uuid,
    pub message: String,
    pub level: NotificationLevel,
    pub sandbox_id: Option<String>,
    pub tab_id: Option<String>,
    pub pane_id: Option<String>,
    pub sent_at: DateTime<Utc>,
    pub read_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Default)]
pub struct NotificationsState {
    pub items: Vec<NotificationEntry>,
    pub selected_index: usize,
    pub is_open: bool,
}

impl NotificationsState {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            selected_index: 0,
            is_open: false,
        }
    }

    pub fn unread_count(&self) -> usize {
        self.items
            .iter()
            .filter(|item| item.read_at.is_none())
            .count()
    }

    pub fn add_notification(&mut self, entry: NotificationEntry) {
        let insert_at = self
            .items
            .iter()
            .position(|existing| existing.sent_at <= entry.sent_at)
            .unwrap_or(self.items.len());
        self.items.insert(insert_at, entry);
        self.selected_index = 0;
    }

    pub fn combined_order(&self) -> Vec<usize> {
        let mut unread: Vec<usize> = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(idx, item)| (item.read_at.is_none()).then_some(idx))
            .collect();
        let mut read: Vec<usize> = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(idx, item)| item.read_at.is_some().then_some(idx))
            .collect();
        // Items are already sorted by sent_at desc; preserve that order
        unread.sort_by_key(|idx| std::cmp::Reverse(self.items[*idx].sent_at));
        read.sort_by_key(|idx| std::cmp::Reverse(self.items[*idx].sent_at));
        unread.extend(read);
        unread
    }

    pub fn selected_item_index(&self) -> Option<usize> {
        let order = self.combined_order();
        if order.is_empty() {
            return None;
        }
        let clamped = self.selected_index.min(order.len().saturating_sub(1));
        order.get(clamped).copied()
    }

    pub fn selected_item(&self) -> Option<&NotificationEntry> {
        self.selected_item_index()
            .and_then(|idx| self.items.get(idx))
    }

    pub fn selected_item_mut(&mut self) -> Option<&mut NotificationEntry> {
        let order = self.combined_order();
        let idx = order.get(self.selected_index).copied()?;
        self.items.get_mut(idx)
    }

    pub fn select_next(&mut self) {
        let total = self.combined_order().len();
        if total == 0 {
            self.selected_index = 0;
            return;
        }
        self.selected_index = (self.selected_index + 1).min(total.saturating_sub(1));
    }

    pub fn select_previous(&mut self) {
        if self.selected_index == 0 {
            return;
        }
        self.selected_index -= 1;
    }

    pub fn mark_read(&mut self) {
        if let Some(item) = self.selected_item_mut() {
            if item.read_at.is_none() {
                item.read_at = Some(Utc::now());
            }
        }
    }

    pub fn mark_unread(&mut self) {
        if let Some(item) = self.selected_item_mut() {
            item.read_at = None;
        }
    }

    pub fn toggle_read(&mut self) {
        if let Some(item) = self.selected_item_mut() {
            if item.read_at.is_some() {
                item.read_at = None;
            } else {
                item.read_at = Some(Utc::now());
            }
        }
    }
}

/// The main application state for the multiplexer.
pub struct MuxApp<'a> {
    // Core state - WorkspaceManager holds all sandbox workspaces
    pub workspace_manager: WorkspaceManager,
    pub sidebar: Sidebar,
    pub command_palette: CommandPalette<'a>,
    pub focus: FocusArea,

    // Zoom state
    pub zoomed_pane: Option<crate::mux::layout::PaneId>,

    // Help overlay
    pub show_help: bool,
    // Notifications overlay/state
    pub notifications: NotificationsState,
    // Pending tab IDs for sandboxes being created (kept in request order)
    pub pending_creation_tab_ids: VecDeque<crate::mux::layout::TabId>,

    // Event channel
    pub event_tx: mpsc::UnboundedSender<MuxEvent>,

    // Base URL for API calls
    pub base_url: String,

    // Workspace path used for new sandboxes
    pub workspace_path: PathBuf,

    // Status message to display
    pub status_message: Option<(String, std::time::Instant)>,

    // Tab rename state
    pub renaming_tab: bool,
    pub rename_input: Option<tui_textarea::TextArea<'a>>,

    // Terminal manager for handling sandbox connections
    pub terminal_manager: Option<SharedTerminalManager>,

    // Sandbox we need to connect to once available
    pub pending_connect: Option<String>,

    // Locally created placeholder sandboxes awaiting server confirmation
    pub pending_placeholder_sandboxes: VecDeque<SandboxId>,

    // Flag to indicate we need to create a sandbox on startup
    pub needs_initial_sandbox: bool,

    // Last rendered terminal views per pane for damage-aware drawing
    pub last_terminal_views:
        std::collections::HashMap<PaneId, crate::mux::terminal::TerminalRenderView>,

    /// Cursor blink state for the active terminal pane (set during render)
    pub cursor_blink: bool,
}

impl<'a> MuxApp<'a> {
    pub fn new(
        base_url: String,
        event_tx: mpsc::UnboundedSender<MuxEvent>,
        workspace_path: PathBuf,
    ) -> Self {
        Self {
            workspace_manager: WorkspaceManager::new(),
            sidebar: Sidebar::new(),
            command_palette: CommandPalette::new(),
            focus: FocusArea::MainArea,
            zoomed_pane: None,
            show_help: false,
            notifications: NotificationsState::new(),
            pending_creation_tab_ids: VecDeque::new(),
            event_tx,
            base_url,
            workspace_path,
            status_message: None,
            renaming_tab: false,
            rename_input: None,
            terminal_manager: None,
            pending_connect: None,
            pending_placeholder_sandboxes: VecDeque::new(),
            needs_initial_sandbox: false,
            last_terminal_views: std::collections::HashMap::new(),
            cursor_blink: true,
        }
    }

    /// Get the currently selected sandbox ID.
    pub fn selected_sandbox_id(&self) -> Option<SandboxId> {
        self.workspace_manager.active_sandbox_id
    }

    /// Get the currently selected sandbox ID as a string.
    pub fn selected_sandbox_id_string(&self) -> Option<String> {
        self.workspace_manager
            .active_sandbox_id
            .map(|id| id.to_string())
    }

    /// Select a sandbox by its ID string and switch to its workspace.
    pub fn select_sandbox(&mut self, sandbox_id_str: &str) -> bool {
        if let Ok(sandbox_id) = sandbox_id_str.parse::<SandboxId>() {
            if self.workspace_manager.has_sandbox(sandbox_id) {
                self.workspace_manager.select_sandbox(sandbox_id);
                return true;
            }
        }
        false
    }

    /// Add a new sandbox and create its workspace.
    pub fn add_sandbox(&mut self, sandbox_id_str: &str, name: &str) {
        if let Ok(sandbox_id) = sandbox_id_str.parse::<SandboxId>() {
            self.workspace_manager.add_sandbox(sandbox_id, name);
        }
    }

    /// Set the terminal manager
    pub fn set_terminal_manager(&mut self, manager: SharedTerminalManager) {
        self.terminal_manager = Some(manager);
    }

    /// Get a render-ready snapshot of the terminal for a pane.
    pub fn get_terminal_view(&self, pane_id: PaneId, height: usize) -> Option<TerminalRenderView> {
        let manager = self.terminal_manager.as_ref()?;
        // We need to use try_lock for non-async context
        let mut guard = manager.try_lock().ok()?;
        let buffer = guard.get_buffer_mut(pane_id)?;
        Some(buffer.render_view(height))
    }

    /// Get the active pane ID from the active workspace.
    pub fn active_pane_id(&self) -> Option<PaneId> {
        self.workspace_manager
            .active_tab()
            .and_then(|tab| tab.active_pane)
    }

    /// Get the active tab from the active workspace.
    pub fn active_tab(&self) -> Option<&crate::mux::layout::Tab> {
        self.workspace_manager.active_tab()
    }

    /// Get the active tab from the active workspace mutably.
    pub fn active_tab_mut(&mut self) -> Option<&mut crate::mux::layout::Tab> {
        self.workspace_manager.active_tab_mut()
    }

    /// Set a status message that will be displayed temporarily.
    pub fn set_status(&mut self, message: impl Into<String>) {
        self.status_message = Some((message.into(), std::time::Instant::now()));
    }

    /// Clear expired status messages.
    pub fn clear_expired_status(&mut self) {
        if let Some((_, time)) = &self.status_message {
            if time.elapsed() > std::time::Duration::from_secs(3) {
                self.status_message = None;
            }
        }
    }

    pub fn open_notifications(&mut self) {
        self.notifications.is_open = true;
        self.focus = FocusArea::Notifications;
    }

    pub fn close_notifications(&mut self) {
        self.notifications.is_open = false;
        if self.focus == FocusArea::Notifications {
            self.focus = FocusArea::MainArea;
        }
    }

    pub fn record_notification(
        &mut self,
        message: String,
        level: NotificationLevel,
        sandbox_id: Option<String>,
        tab_id: Option<String>,
        pane_id: Option<String>,
    ) {
        let entry = NotificationEntry {
            id: Uuid::new_v4(),
            message: message.clone(),
            level,
            sandbox_id,
            tab_id,
            pane_id,
            sent_at: Utc::now(),
            read_at: None,
        };
        self.notifications.add_notification(entry);
    }

    pub fn open_notification_target(&mut self, entry: &NotificationEntry) {
        let mut sandbox_selected = false;
        if let Some(sandbox_id_str) = &entry.sandbox_id {
            if let Ok(uuid) = Uuid::parse_str(sandbox_id_str) {
                let sandbox_id = SandboxId::from_uuid(uuid);
                if self.workspace_manager.has_sandbox(sandbox_id) {
                    self.workspace_manager.select_sandbox(sandbox_id);
                    self.sidebar.select_by_id(sandbox_id_str);
                    sandbox_selected = true;
                }
            }
        }

        let mut tab_selected = false;
        if let Some(tab_id_str) = &entry.tab_id {
            if let Ok(uuid) = Uuid::parse_str(tab_id_str) {
                let tab_id = crate::mux::layout::TabId::from_uuid(uuid);
                if sandbox_selected {
                    tab_selected = self
                        .workspace_manager
                        .select_tab_in_workspace_for_active(tab_id);
                } else if self.workspace_manager.select_tab_in_any_workspace(tab_id) {
                    if let Some(active_id) = self.workspace_manager.active_sandbox_id {
                        self.sidebar.select_by_id(&active_id.to_string());
                    }
                    sandbox_selected = true;
                    tab_selected = true;
                }
            }
        }

        if sandbox_selected || tab_selected {
            self.focus = FocusArea::MainArea;
        }

        self.set_status("Opened notification");
    }

    /// Execute a command.
    pub fn execute_command(&mut self, cmd: MuxCommand) {
        match cmd {
            // Navigation
            MuxCommand::FocusLeft => {
                if self.focus == FocusArea::MainArea {
                    if let Some(tab) = self.active_tab_mut() {
                        tab.navigate(NavDirection::Left);
                    }
                }
            }
            MuxCommand::FocusRight => {
                if self.focus == FocusArea::MainArea {
                    if let Some(tab) = self.active_tab_mut() {
                        tab.navigate(NavDirection::Right);
                    }
                }
            }
            MuxCommand::FocusUp => {
                if self.focus == FocusArea::MainArea {
                    if let Some(tab) = self.active_tab_mut() {
                        tab.navigate(NavDirection::Up);
                    }
                } else if self.focus == FocusArea::Sidebar {
                    self.sidebar.select_previous();
                }
            }
            MuxCommand::FocusDown => {
                if self.focus == FocusArea::MainArea {
                    if let Some(tab) = self.active_tab_mut() {
                        tab.navigate(NavDirection::Down);
                    }
                } else if self.focus == FocusArea::Sidebar {
                    self.sidebar.select_next();
                }
            }
            MuxCommand::FocusSidebar => {
                if self.sidebar.visible {
                    self.focus = FocusArea::Sidebar;
                }
            }
            MuxCommand::FocusMainArea => {
                self.focus = FocusArea::MainArea;
            }
            MuxCommand::NextPane => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.next_pane();
                }
            }
            MuxCommand::PrevPane => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.prev_pane();
                }
            }
            MuxCommand::NextTab => self.workspace_manager.next_tab(),
            MuxCommand::PrevTab => self.workspace_manager.prev_tab(),
            MuxCommand::GoToTab1 => self.workspace_manager.go_to_tab(0),
            MuxCommand::GoToTab2 => self.workspace_manager.go_to_tab(1),
            MuxCommand::GoToTab3 => self.workspace_manager.go_to_tab(2),
            MuxCommand::GoToTab4 => self.workspace_manager.go_to_tab(3),
            MuxCommand::GoToTab5 => self.workspace_manager.go_to_tab(4),
            MuxCommand::GoToTab6 => self.workspace_manager.go_to_tab(5),
            MuxCommand::GoToTab7 => self.workspace_manager.go_to_tab(6),
            MuxCommand::GoToTab8 => self.workspace_manager.go_to_tab(7),
            MuxCommand::GoToTab9 => self.workspace_manager.go_to_tab(8),

            // Pane management - new tabs/splits belong to the active sandbox
            MuxCommand::SplitHorizontal => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.split(Direction::Horizontal, Pane::terminal(None, "Terminal"));
                    self.set_status("Split horizontally");
                    // Auto-connect the new pane to the sandbox terminal
                    let _ = self.event_tx.send(MuxEvent::ConnectActivePaneToSandbox);
                }
            }
            MuxCommand::SplitVertical => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.split(Direction::Vertical, Pane::terminal(None, "Terminal"));
                    self.set_status("Split vertically");
                    // Auto-connect the new pane to the sandbox terminal
                    let _ = self.event_tx.send(MuxEvent::ConnectActivePaneToSandbox);
                }
            }
            MuxCommand::ClosePane => {
                if let Some(tab) = self.active_tab_mut() {
                    if tab.close_active_pane() {
                        self.set_status("Pane closed");
                    }
                }
            }
            MuxCommand::ToggleZoom => {
                if let Some(tab) = self.active_tab() {
                    if self.zoomed_pane.is_some() {
                        self.zoomed_pane = None;
                        self.set_status("Zoom off");
                    } else if let Some(pane_id) = tab.active_pane {
                        self.zoomed_pane = Some(pane_id);
                        self.set_status("Zoom on");
                    }
                }
            }
            MuxCommand::SwapPaneLeft
            | MuxCommand::SwapPaneRight
            | MuxCommand::SwapPaneUp
            | MuxCommand::SwapPaneDown => {
                self.set_status("Pane swapping not yet implemented");
            }
            MuxCommand::ResizeLeft => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.resize(NavDirection::Left, 0.05);
                }
            }
            MuxCommand::ResizeRight => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.resize(NavDirection::Right, 0.05);
                }
            }
            MuxCommand::ResizeUp => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.resize(NavDirection::Up, 0.05);
                }
            }
            MuxCommand::ResizeDown => {
                if let Some(tab) = self.active_tab_mut() {
                    tab.resize(NavDirection::Down, 0.05);
                }
            }

            // Tab management - tabs belong to the active sandbox workspace
            MuxCommand::NewTab => {
                if self.workspace_manager.new_tab().is_some() {
                    self.set_status("New tab created");
                    // Auto-connect the new pane to the sandbox terminal
                    let _ = self.event_tx.send(MuxEvent::ConnectActivePaneToSandbox);
                } else {
                    self.set_status("No sandbox selected");
                }
            }
            MuxCommand::CloseTab => {
                if self.workspace_manager.close_active_tab() {
                    self.set_status("Tab closed");
                }
            }
            MuxCommand::RenameTab => {
                self.start_tab_rename();
            }
            MuxCommand::MoveTabLeft => {
                self.workspace_manager.move_tab_left();
            }
            MuxCommand::MoveTabRight => {
                self.workspace_manager.move_tab_right();
            }

            // Sidebar - Ctrl+S toggles focus between sidebar and main area
            MuxCommand::ToggleSidebar => {
                // Ensure sidebar is visible
                if !self.sidebar.visible {
                    self.sidebar.visible = true;
                }
                // Toggle focus
                if self.focus == FocusArea::Sidebar {
                    self.focus = FocusArea::MainArea;
                } else {
                    self.focus = FocusArea::Sidebar;
                }
            }
            MuxCommand::SelectSandbox => {
                if self.focus == FocusArea::Sidebar {
                    if let Some(sandbox) = self.sidebar.selected_sandbox() {
                        let sandbox_id_str = sandbox.id.to_string();
                        let sandbox_name = sandbox.name.clone();
                        // Select the sandbox and switch to its workspace
                        self.select_sandbox(&sandbox_id_str);
                        self.set_status(format!("Selected: {}", sandbox_name));
                        // Switch to main area after selection
                        self.focus = FocusArea::MainArea;
                    }
                }
            }
            MuxCommand::NextSandbox => {
                if let Some(sandbox_id) = self.workspace_manager.next_sandbox() {
                    // Also update sidebar selection to match
                    let sandbox_id_str = sandbox_id.to_string();
                    self.sidebar.select_by_id(&sandbox_id_str);
                    if let Some(ws) = self.workspace_manager.active_workspace() {
                        self.set_status(format!("Switched to: {}", ws.name));
                    }
                }
            }
            MuxCommand::PrevSandbox => {
                if let Some(sandbox_id) = self.workspace_manager.prev_sandbox() {
                    // Also update sidebar selection to match
                    let sandbox_id_str = sandbox_id.to_string();
                    self.sidebar.select_by_id(&sandbox_id_str);
                    if let Some(ws) = self.workspace_manager.active_workspace() {
                        self.set_status(format!("Switched to: {}", ws.name));
                    }
                }
            }

            // Sandbox management
            MuxCommand::NewSandbox => {
                self.set_status("Creating new sandbox...");
                let tab_id = self.workspace_manager.active_tab_id().unwrap_or_default();
                let _ = self.event_tx.send(MuxEvent::CreateSandboxWithWorkspace {
                    workspace_path: self.workspace_path.clone(),
                    tab_id: Some(tab_id.to_string()),
                });
                self.add_placeholder_sandbox("Creating sandbox", Some(tab_id));
            }
            MuxCommand::DeleteSandbox => {
                if let Some(sandbox) = self.sidebar.selected_sandbox() {
                    self.set_status(format!("Deleting sandbox: {}", sandbox.name));
                } else {
                    self.set_status("No sandbox selected");
                }
            }
            MuxCommand::RefreshSandboxes => {
                self.set_status("Refreshing sandboxes...");
            }

            // Session
            MuxCommand::NewSession => {
                self.set_status("Creating new session...");
            }
            MuxCommand::AttachSandbox => {
                if let Some(sandbox_id) = self.selected_sandbox_id_string() {
                    self.set_status(format!("Attaching to sandbox: {}", sandbox_id));
                } else if let Some(sandbox) = self.sidebar.selected_sandbox() {
                    let sandbox_id_str = sandbox.id.to_string();
                    let sandbox_name = sandbox.name.clone();
                    self.select_sandbox(&sandbox_id_str);
                    self.set_status(format!("Attaching to sandbox: {}", sandbox_name));
                } else {
                    self.set_status("No sandbox selected");
                }
            }
            MuxCommand::DetachSandbox => {
                self.set_status("Detaching from sandbox...");
                // Don't clear workspace_manager.active_sandbox_id - just show status
            }

            // UI
            MuxCommand::OpenCommandPalette => {
                self.command_palette.open();
                self.focus = FocusArea::CommandPalette;
            }
            MuxCommand::ToggleHelp => {
                self.show_help = !self.show_help;
            }
            MuxCommand::ShowNotifications => {
                if self.notifications.is_open {
                    self.close_notifications();
                } else {
                    self.open_notifications();
                }
            }
            MuxCommand::Quit => {
                // Handled by the runner
            }

            // Scrolling (handled in pane content)
            MuxCommand::ScrollUp
            | MuxCommand::ScrollDown
            | MuxCommand::ScrollPageUp
            | MuxCommand::ScrollPageDown
            | MuxCommand::ScrollToTop
            | MuxCommand::ScrollToBottom => {
                // TODO: Forward to active pane
            }
        }
    }

    /// Close the command palette.
    pub fn close_command_palette(&mut self) {
        self.command_palette.close();
        self.focus = FocusArea::MainArea;
    }

    /// Start tab rename mode.
    fn start_tab_rename(&mut self) {
        if let Some(tab) = self.active_tab() {
            let mut input = tui_textarea::TextArea::default();
            input.insert_str(&tab.name);
            self.rename_input = Some(input);
            self.renaming_tab = true;
        }
    }

    /// Finish tab rename.
    pub fn finish_tab_rename(&mut self, apply: bool) {
        if apply {
            if let Some(input) = &self.rename_input {
                let new_name = input.lines().join("");
                if !new_name.is_empty() {
                    self.workspace_manager.rename_active_tab(new_name);
                }
            }
        }
        self.rename_input = None;
        self.renaming_tab = false;
    }

    /// Handle an event.
    pub fn handle_event(&mut self, event: MuxEvent) {
        match event {
            MuxEvent::CreateSandboxWithWorkspace { .. } => {
                self.set_status("Creating sandbox...");
            }
            MuxEvent::SandboxesRefreshed(sandboxes) => {
                let had_active = self.selected_sandbox_id().is_some();
                // Update sidebar
                self.sidebar.set_sandboxes(sandboxes.clone());
                // Sync workspace manager with sandboxes
                for sandbox in &sandboxes {
                    let sandbox_id_str = sandbox.id.to_string();
                    self.add_sandbox(&sandbox_id_str, &sandbox.name);
                }
                // Re-append pending placeholders so they stay visible during creation
                for placeholder_id in self.pending_placeholder_sandboxes.iter().copied() {
                    if self
                        .sidebar
                        .sandboxes
                        .iter()
                        .any(|sandbox| sandbox.id == placeholder_id.0)
                    {
                        continue;
                    }
                    if let Some(summary) = self.placeholder_summary(placeholder_id) {
                        self.sidebar.sandboxes.push(summary);
                    }
                }
                // Ensure selection stays in sync with available sandboxes
                if let Some(active_id) = self.selected_sandbox_id_string() {
                    self.sidebar.select_by_id(&active_id);
                } else if let Some(first) = sandboxes.first() {
                    let id_str = first.id.to_string();
                    self.sidebar.select_by_id(&id_str);
                    self.pending_connect.get_or_insert(id_str);
                }

                if !had_active {
                    if let Some(active_id) = self.selected_sandbox_id_string() {
                        self.pending_connect.get_or_insert(active_id);
                    }
                }
            }
            MuxEvent::SandboxRefreshFailed(error) => {
                self.sidebar.set_error(error.clone());
                self.set_status(format!("Error: {}", error));
            }
            MuxEvent::SandboxCreated(sandbox) => {
                // Drop one placeholder entry to keep the list responsive
                if let Some(placeholder_id) = self.pending_placeholder_sandboxes.pop_front() {
                    self.remove_local_sandbox(placeholder_id);
                }
                // Add the new sandbox to workspace manager
                let sandbox_id_str = sandbox.id.to_string();
                // Keep sidebar in sync immediately without waiting for refresh
                self.sidebar
                    .sandboxes
                    .retain(|existing| existing.id != sandbox.id);
                self.sidebar.sandboxes.push(sandbox.clone());
                self.sidebar.select_by_id(&sandbox_id_str);
                self.add_sandbox(&sandbox_id_str, &sandbox.name);
                if let Some(tab_id) = self.pending_creation_tab_ids.pop_front() {
                    let _ = self.workspace_manager.set_active_tab_id_for_sandbox(
                        crate::mux::layout::SandboxId::from_uuid(sandbox.id),
                        tab_id,
                    );
                }
                self.workspace_manager
                    .select_sandbox(crate::mux::layout::SandboxId::from_uuid(sandbox.id));
                self.pending_connect = Some(sandbox_id_str.clone());
                self.set_status(format!("Created sandbox: {}", sandbox.name));
            }
            MuxEvent::SandboxTabMapped { sandbox_id, tab_id } => {
                if let (Ok(sandbox_uuid), Ok(tab_uuid)) =
                    (Uuid::parse_str(&sandbox_id), Uuid::parse_str(&tab_id))
                {
                    let sandbox_id = SandboxId::from_uuid(sandbox_uuid);
                    let tab_id = crate::mux::layout::TabId::from_uuid(tab_uuid);
                    let _ = self
                        .workspace_manager
                        .set_active_tab_id_for_sandbox(sandbox_id, tab_id);
                }
            }
            MuxEvent::SandboxDeleted(id) => {
                self.remove_sandbox_by_id_string(&id);
                self.focus = FocusArea::Sidebar;
                self.set_status(format!("Deleted sandbox: {}", id));
            }
            MuxEvent::SandboxConnectionChanged {
                sandbox_id,
                connected,
            } => {
                let state = if connected {
                    "connected"
                } else {
                    "disconnected"
                };
                self.set_status(format!("Sandbox {}: {}", sandbox_id, state));
            }
            MuxEvent::TerminalOutput { .. } => {
                // TODO: Forward to appropriate pane
            }
            MuxEvent::Error(msg) => {
                self.set_status(format!("Error: {}", msg));
            }
            MuxEvent::Notification {
                message,
                level,
                sandbox_id,
                tab_id,
                pane_id,
            } => {
                self.record_notification(message, level, sandbox_id, tab_id, pane_id);
            }
            MuxEvent::StatusMessage { message } => {
                self.set_status(message);
            }
            MuxEvent::ConnectToSandbox { sandbox_id } => {
                // Select the sandbox and update workspace
                self.select_sandbox(&sandbox_id);
                self.set_status(format!("Connecting to sandbox: {}", sandbox_id));
            }
            MuxEvent::ConnectActivePaneToSandbox => {
                // This is handled in the runner, just acknowledge here
            }
            MuxEvent::TerminalExited { .. } => {
                // Cleanup is handled in the runner where terminal state is available
            }
        }
    }

    /// Add a local placeholder sandbox for immediate UI feedback while creation runs.
    pub fn add_placeholder_sandbox(
        &mut self,
        name: impl Into<String>,
        tab_id: Option<crate::mux::layout::TabId>,
    ) {
        let sandbox_id = SandboxId::new();
        let name = name.into();
        let summary = SandboxSummary {
            id: sandbox_id.0,
            index: self.sidebar.sandboxes.len(),
            name: name.clone(),
            created_at: Utc::now(),
            workspace: "/workspace".to_string(),
            status: SandboxStatus::Unknown,
            network: SandboxNetwork {
                host_interface: "pending".to_string(),
                sandbox_interface: "pending".to_string(),
                host_ip: "0.0.0.0".to_string(),
                sandbox_ip: "0.0.0.0".to_string(),
                cidr: 24,
            },
        };

        self.sidebar.sandboxes.push(summary);
        let id_str = sandbox_id.to_string();
        self.sidebar.select_by_id(&id_str);
        self.workspace_manager.add_sandbox(sandbox_id, name.clone());
        if let Some(tab_id) = tab_id {
            let _ = self
                .workspace_manager
                .set_active_tab_id_for_sandbox(sandbox_id, tab_id);
        }
        self.workspace_manager.select_sandbox(sandbox_id);
        self.pending_placeholder_sandboxes.push_back(sandbox_id);
    }

    fn remove_local_sandbox(&mut self, sandbox_id: SandboxId) {
        self.remove_sandbox_by_id_string(&sandbox_id.to_string());
    }

    fn remove_sandbox_by_id_string(&mut self, id: &str) {
        let removed_index = self
            .sidebar
            .sandboxes
            .iter()
            .position(|sandbox| sandbox.id.to_string() == id);

        if let Ok(sandbox_id) = id.parse::<SandboxId>() {
            self.workspace_manager.remove_sandbox(sandbox_id);
        }

        self.sidebar
            .sandboxes
            .retain(|sandbox| sandbox.id.to_string() != id);

        if let Some(pending) = &self.pending_connect {
            if pending == id {
                self.pending_connect = None;
            }
        }

        if self.sidebar.sandboxes.is_empty() {
            self.sidebar.selected_index = 0;
            self.workspace_manager.active_sandbox_id = None;
        } else if let Some(idx) = removed_index {
            let next_index = if idx < self.sidebar.sandboxes.len() {
                idx
            } else {
                self.sidebar.sandboxes.len() - 1
            };

            self.sidebar.selected_index = next_index;

            let next_id = self.sidebar.sandboxes[next_index].id.to_string();
            let _ = self.select_sandbox(&next_id);
            self.sidebar.select_by_id(&next_id);
        }
    }

    fn placeholder_summary(&self, sandbox_id: SandboxId) -> Option<SandboxSummary> {
        let name = self
            .workspace_manager
            .get_workspace(sandbox_id)
            .map(|ws| ws.name.clone())
            .unwrap_or_else(|| "Creating sandbox".to_string());

        Some(SandboxSummary {
            id: sandbox_id.0,
            index: self.sidebar.sandboxes.len(),
            name,
            created_at: Utc::now(),
            workspace: "/workspace".to_string(),
            status: SandboxStatus::Unknown,
            network: SandboxNetwork {
                host_interface: "pending".to_string(),
                sandbox_interface: "pending".to_string(),
                host_ip: "0.0.0.0".to_string(),
                sandbox_ip: "0.0.0.0".to_string(),
                cidr: 24,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{NotificationLevel, SandboxNetwork, SandboxStatus, SandboxSummary};
    use chrono::Utc;
    use uuid::Uuid;

    #[test]
    fn sandbox_created_sets_pending_and_selection() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let mut app = MuxApp::new("http://localhost".to_string(), tx, PathBuf::from("."));
        let sandbox = sample_sandbox("demo");

        app.handle_event(MuxEvent::SandboxCreated(sandbox.clone()));

        assert_eq!(
            app.pending_connect,
            Some(sandbox.id.to_string()),
            "pending_connect should point at the new sandbox"
        );
        assert_eq!(
            app.selected_sandbox_id_string(),
            Some(sandbox.id.to_string())
        );
        assert_eq!(
            app.sidebar.selected_sandbox().map(|s| s.id),
            Some(sandbox.id)
        );
    }

    #[test]
    fn refresh_without_selection_queues_connect() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let mut app = MuxApp::new("http://localhost".to_string(), tx, PathBuf::from("."));
        let sandbox = sample_sandbox("demo");

        app.handle_event(MuxEvent::SandboxesRefreshed(vec![sandbox.clone()]));

        assert_eq!(app.pending_connect, Some(sandbox.id.to_string()));
        assert_eq!(
            app.sidebar.selected_sandbox().map(|s| s.id),
            Some(sandbox.id)
        );
        assert_eq!(
            app.selected_sandbox_id_string(),
            Some(sandbox.id.to_string())
        );
    }

    #[test]
    fn notifications_track_read_state() {
        let mut notifications = NotificationsState::new();
        let entry = NotificationEntry {
            id: Uuid::new_v4(),
            message: "hello".to_string(),
            level: NotificationLevel::Info,
            sandbox_id: None,
            tab_id: None,
            pane_id: None,
            sent_at: Utc::now(),
            read_at: None,
        };
        notifications.add_notification(entry);
        assert_eq!(notifications.unread_count(), 1);

        notifications.mark_read();
        assert_eq!(notifications.unread_count(), 0);
        assert!(notifications
            .selected_item()
            .and_then(|item| item.read_at)
            .is_some());

        notifications.mark_unread();
        assert_eq!(notifications.unread_count(), 1);
        assert!(notifications
            .selected_item()
            .and_then(|item| item.read_at)
            .is_none());
    }

    fn sample_sandbox(name: &str) -> SandboxSummary {
        SandboxSummary {
            id: Uuid::new_v4(),
            index: 0,
            name: name.to_string(),
            created_at: Utc::now(),
            workspace: "/workspace".to_string(),
            status: SandboxStatus::Running,
            network: SandboxNetwork {
                host_interface: "veth0".to_string(),
                sandbox_interface: "eth0".to_string(),
                host_ip: "10.0.0.1".to_string(),
                sandbox_ip: "10.0.0.2".to_string(),
                cidr: 24,
            },
        }
    }
}
