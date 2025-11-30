use std::collections::HashMap;
use std::sync::Arc;

use agent_client_protocol::{
    Agent, ClientSideConnection, ContentBlock, ModelId, Plan, PromptRequest, SessionId,
    SessionModelState, SessionNotification, SessionUpdate, SetSessionModelRequest, TextContent,
    ToolCall, ToolCallStatus, ToolCallUpdate, ToolKind,
};
use ratatui::widgets::{Block, Borders};
use tokio::sync::mpsc;
use tui_textarea::TextArea;

use crate::acp_client::connection::connect_to_provider;
use crate::acp_client::events::AppEvent;
use crate::acp_client::markdown::normalize_code_fences;
use crate::acp_client::provider::AcpProvider;
use crate::acp_client::workspace_sync::WorkspaceSyncStatus;
use crate::palette::{fuzzy_match_str, PaletteCommand as PaletteCommandTrait};

#[derive(Clone)]
pub(crate) enum ChatEntry {
    Message {
        role: String,
        text: String,
        normalized_markdown: Option<String>,
    },
    ToolCall {
        id: String,
        title: String,
        kind: ToolKind,
        status: ToolCallStatus,
    },
    Plan(Plan),
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConnectionState {
    Connecting,
    Connected,
    SwitchingProvider(AcpProvider),
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum UiMode {
    Chat,
    MainPalette,
    SwitchPalette,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum PaletteCommand {
    ToggleDebugMode,
    SwitchProviderModel,
}

impl PaletteCommand {
    pub(crate) fn all() -> &'static [PaletteCommand] {
        &[
            PaletteCommand::ToggleDebugMode,
            PaletteCommand::SwitchProviderModel,
        ]
    }

    pub(crate) fn get_label(&self) -> &'static str {
        match self {
            PaletteCommand::ToggleDebugMode => "Toggle Debug Mode",
            PaletteCommand::SwitchProviderModel => "Switch Provider / Model",
        }
    }

    pub(crate) fn get_description(&self) -> &'static str {
        match self {
            PaletteCommand::ToggleDebugMode => "Show/hide raw ACP protocol messages",
            PaletteCommand::SwitchProviderModel => "Change AI provider or model",
        }
    }

    pub(crate) fn matches(&self, query: &str) -> bool {
        // Use the shared fuzzy matching from the trait
        crate::palette::fuzzy_match(self, query).is_some()
    }
}

impl PaletteCommandTrait for PaletteCommand {
    fn label(&self) -> &str {
        self.get_label()
    }

    fn description(&self) -> Option<&str> {
        Some(self.get_description())
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) enum SwitchPaletteItem {
    Header(String),
    Provider(AcpProvider),
    Model {
        provider: AcpProvider,
        id: String,
        name: String,
    },
    Loading(AcpProvider),
}

impl SwitchPaletteItem {
    pub(crate) fn is_selectable(&self) -> bool {
        !matches!(
            self,
            SwitchPaletteItem::Header(_) | SwitchPaletteItem::Loading(_)
        )
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) enum WorkspaceSyncState {
    Idle,
    Syncing,
    Completed,
    Failed(String),
}

pub(crate) struct App<'a> {
    pub(crate) history: Vec<ChatEntry>,
    pub(crate) textarea: TextArea<'a>,
    pub(crate) client_connection: Option<Arc<ClientSideConnection>>,
    pub(crate) session_id: Option<SessionId>,
    pub(crate) scroll_offset_from_bottom: u16,
    pub(crate) current_provider: AcpProvider,
    pub(crate) ui_mode: UiMode,
    pub(crate) palette_selection: usize,
    pub(crate) palette_input: TextArea<'a>,
    pub(crate) connection_state: ConnectionState,
    pub(crate) debug_mode: bool,
    pub(crate) debug_messages: Vec<String>,
    pub(crate) event_tx: mpsc::UnboundedSender<AppEvent>,
    pub(crate) base_url: String,
    pub(crate) sandbox_id: String,
    pub(crate) model_state: Option<SessionModelState>,
    pub(crate) model_switching: bool,
    pub(crate) provider_models: HashMap<AcpProvider, Option<Vec<(String, String)>>>,
    pub(crate) providers_loading: Vec<AcpProvider>,
    pub(crate) pending_model_switch: Option<ModelId>,
    pub(crate) workspace_sync_state: WorkspaceSyncState,
}

impl<'a> App<'a> {
    pub(crate) fn new(
        provider: AcpProvider,
        event_tx: mpsc::UnboundedSender<AppEvent>,
        base_url: String,
        sandbox_id: String,
    ) -> Self {
        let mut textarea = TextArea::default();
        textarea.set_block(
            Block::default()
                .borders(Borders::TOP | Borders::BOTTOM)
                .border_style(ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray)),
        );
        textarea
            .set_placeholder_text("Type a message and press Enter to send. Ctrl+J for new line.");

        let mut palette_input = TextArea::default();
        palette_input.set_placeholder_text("Type to search...");
        palette_input.set_cursor_line_style(ratatui::style::Style::default());

        Self {
            history: vec![],
            textarea,
            client_connection: None,
            session_id: None,
            scroll_offset_from_bottom: 0,
            current_provider: provider,
            ui_mode: UiMode::Chat,
            palette_selection: 0,
            palette_input,
            connection_state: ConnectionState::Connecting,
            debug_mode: false,
            debug_messages: vec![],
            event_tx,
            base_url,
            sandbox_id,
            model_state: None,
            model_switching: false,
            provider_models: HashMap::new(),
            providers_loading: vec![],
            pending_model_switch: None,
            workspace_sync_state: WorkspaceSyncState::Idle,
        }
    }

    pub(crate) fn add_debug_message(&mut self, direction: &str, msg: &str) {
        if self.debug_mode {
            let timestamp = chrono::Utc::now().format("%H:%M:%S%.3f");
            self.debug_messages
                .push(format!("[{}] {} {}", timestamp, direction, msg));
            if self.debug_messages.len() > 100 {
                self.debug_messages.remove(0);
            }
        }
    }

    pub(crate) fn open_main_palette(&mut self) {
        self.ui_mode = UiMode::MainPalette;
        self.palette_selection = 0;
        self.palette_input = TextArea::default();
        self.palette_input.set_placeholder_text("Type to search...");
        self.palette_input
            .set_cursor_line_style(ratatui::style::Style::default());
    }

    pub(crate) fn open_switch_palette(&mut self) {
        self.ui_mode = UiMode::SwitchPalette;
        self.palette_input = TextArea::default();
        self.palette_input
            .set_placeholder_text("Type to filter providers/models...");
        self.palette_input
            .set_cursor_line_style(ratatui::style::Style::default());

        let items = self.get_switch_palette_items();
        let selectable: Vec<_> = items
            .iter()
            .enumerate()
            .filter(|(_, item)| item.is_selectable())
            .collect();

        self.palette_selection = 0;
        if let Some(ref model_state) = self.model_state {
            let current_model_id = &model_state.current_model_id;
            if let Some(pos) = selectable.iter().position(|(_, item)| {
                matches!(item, SwitchPaletteItem::Model { id, .. } if id == &*current_model_id.0)
            }) {
                self.palette_selection = pos;
                return;
            }
        }

        if let Some(pos) = selectable.iter().position(|(_, item)| {
            matches!(item, SwitchPaletteItem::Provider(p) if *p == self.current_provider)
        }) {
            self.palette_selection = pos;
        }
    }

    pub(crate) fn get_switch_palette_items(&self) -> Vec<SwitchPaletteItem> {
        let search = self.palette_search();
        let mut items = Vec::new();

        for provider in AcpProvider::all() {
            let provider_matches =
                search.is_empty() || fuzzy_match_str(&search, provider.display_name());

            let models = self.get_models_for_provider(*provider);

            let matching_models: Vec<_> = models
                .iter()
                .filter(|(_, name)| search.is_empty() || fuzzy_match_str(&search, name))
                .collect();

            let is_loading = self.providers_loading.contains(provider);

            if provider_matches || !matching_models.is_empty() || (search.is_empty() && is_loading)
            {
                items.push(SwitchPaletteItem::Header(
                    provider.display_name().to_string(),
                ));
                items.push(SwitchPaletteItem::Provider(*provider));

                if is_loading && models.is_empty() {
                    items.push(SwitchPaletteItem::Loading(*provider));
                } else if !matching_models.is_empty() {
                    for (id, name) in matching_models {
                        items.push(SwitchPaletteItem::Model {
                            provider: *provider,
                            id: id.clone(),
                            name: name.clone(),
                        });
                    }
                }
            }
        }

        items
    }

    fn get_models_for_provider(&self, provider: AcpProvider) -> Vec<(String, String)> {
        if let Some(Some(models)) = self.provider_models.get(&provider) {
            return models.clone();
        }

        if provider == self.current_provider {
            if let Some(ref model_state) = self.model_state {
                return model_state
                    .available_models
                    .iter()
                    .map(|m| (m.model_id.0.to_string(), m.name.clone()))
                    .collect();
            }
        }

        vec![]
    }

    pub(crate) fn current_model_name(&self) -> Option<&str> {
        self.model_state.as_ref().and_then(|s| {
            s.available_models
                .iter()
                .find(|m| m.model_id == s.current_model_id)
                .map(|m| m.name.as_str())
        })
    }

    pub(crate) fn close_palette(&mut self) {
        self.ui_mode = UiMode::Chat;
    }

    pub(crate) fn palette_search(&self) -> String {
        self.palette_input.lines().join("")
    }

    pub(crate) fn filtered_items_count(&self) -> usize {
        match self.ui_mode {
            UiMode::MainPalette => {
                let search = self.palette_search();
                PaletteCommand::all()
                    .iter()
                    .filter(|c| c.matches(&search))
                    .count()
            }
            UiMode::SwitchPalette => self
                .get_switch_palette_items()
                .iter()
                .filter(|item| item.is_selectable())
                .count(),
            UiMode::Chat => 0,
        }
    }

    pub(crate) fn palette_up(&mut self) {
        let len = self.filtered_items_count();
        if len > 0 {
            self.palette_selection = (self.palette_selection + len - 1) % len;
        }
    }

    pub(crate) fn palette_down(&mut self) {
        let len = self.filtered_items_count();
        if len > 0 {
            self.palette_selection = (self.palette_selection + 1) % len;
        }
    }

    pub(crate) fn palette_handle_input(&mut self, input: impl Into<tui_textarea::Input>) {
        let old_search = self.palette_search();
        self.palette_input.input(input);
        let new_search = self.palette_search();
        if old_search != new_search {
            self.palette_selection = 0;
        }
    }

    pub(crate) fn execute_main_palette_selection(&mut self) -> Option<PaletteCommand> {
        if self.ui_mode == UiMode::MainPalette {
            let search = self.palette_search();
            let filtered: Vec<_> = PaletteCommand::all()
                .iter()
                .filter(|c| c.matches(&search))
                .collect();
            if let Some(cmd) = filtered.get(self.palette_selection) {
                let cmd = **cmd;
                self.ui_mode = UiMode::Chat;
                return Some(cmd);
            }
        }
        self.ui_mode = UiMode::Chat;
        None
    }

    pub(crate) fn execute_switch_palette_selection(&mut self) {
        if self.ui_mode != UiMode::SwitchPalette {
            return;
        }

        let items = self.get_switch_palette_items();
        let selectable: Vec<_> = items
            .into_iter()
            .filter(|item| item.is_selectable())
            .collect();

        if let Some(selected) = selectable.get(self.palette_selection) {
            match selected {
                SwitchPaletteItem::Provider(provider) => {
                    let provider = *provider;
                    self.ui_mode = UiMode::Chat;
                    if provider != self.current_provider {
                        let old_provider = self.current_provider;
                        self.current_provider = provider;
                        self.connection_state = ConnectionState::SwitchingProvider(old_provider);
                        self.start_provider_switch(provider);
                        return;
                    }
                }
                SwitchPaletteItem::Model { provider, id, .. } => {
                    let model_id = ModelId::from(id.clone());
                    self.ui_mode = UiMode::Chat;

                    if *provider != self.current_provider {
                        let old_provider = self.current_provider;
                        self.current_provider = *provider;
                        self.connection_state = ConnectionState::SwitchingProvider(old_provider);
                        self.start_provider_switch_with_model(*provider, Some(model_id));
                        return;
                    }

                    if let Some(ref model_state) = self.model_state {
                        if model_id != model_state.current_model_id {
                            self.model_switching = true;
                            self.start_model_switch(model_id);
                            return;
                        }
                    }
                }
                SwitchPaletteItem::Header(_) | SwitchPaletteItem::Loading(_) => {}
            }
        }
        self.ui_mode = UiMode::Chat;
    }

    pub(crate) fn start_provider_switch(&mut self, provider: AcpProvider) {
        self.start_provider_switch_with_model(provider, None);
    }

    pub(crate) fn start_provider_switch_with_model(
        &mut self,
        provider: AcpProvider,
        model: Option<ModelId>,
    ) {
        self.pending_model_switch = model;
        let tx = self.event_tx.clone();
        let base_url = self.base_url.clone();
        let sandbox_id = self.sandbox_id.clone();

        tokio::task::spawn_local(async move {
            match connect_to_provider(&base_url, &sandbox_id, provider, tx.clone()).await {
                Ok((connection, session_id, model_state)) => {
                    let _ = tx.send(AppEvent::ProviderSwitchComplete {
                        provider,
                        connection,
                        session_id,
                        model_state,
                    });
                }
                Err(e) => {
                    crate::acp_client::logging::log_debug(&format!(
                        "Provider switch failed: {}",
                        e
                    ));
                    let _ = tx.send(AppEvent::ProviderSwitchFailed {
                        provider,
                        error: e.to_string(),
                    });
                }
            }
        });
    }

    pub(crate) fn start_model_switch(&self, model_id: ModelId) {
        let tx = self.event_tx.clone();
        let conn = self.client_connection.clone();
        let session_id = self.session_id.clone();

        if let (Some(conn), Some(session_id)) = (conn, session_id) {
            let model_id_clone = model_id.clone();
            tokio::task::spawn_local(async move {
                let request = SetSessionModelRequest {
                    session_id,
                    model_id: model_id_clone.clone(),
                    meta: None,
                };

                match Agent::set_session_model(&*conn, request).await {
                    Ok(_) => {
                        let _ = tx.send(AppEvent::ModelSwitchComplete {
                            model_id: model_id_clone,
                        });
                    }
                    Err(e) => {
                        crate::acp_client::logging::log_debug(&format!(
                            "Model switch failed: {}",
                            e
                        ));
                        let _ = tx.send(AppEvent::ModelSwitchFailed {
                            error: e.to_string(),
                        });
                    }
                }
            });
        }
    }

    pub(crate) fn toggle_debug_mode(&mut self) {
        self.debug_mode = !self.debug_mode;
        if !self.debug_mode {
            self.debug_messages.clear();
        }
    }

    pub(crate) fn scroll_up(&mut self, lines: u16) {
        self.scroll_offset_from_bottom = self.scroll_offset_from_bottom.saturating_add(lines);
    }

    pub(crate) fn scroll_down(&mut self, lines: u16) {
        self.scroll_offset_from_bottom = self.scroll_offset_from_bottom.saturating_sub(lines);
    }

    pub(crate) fn scroll_to_top(&mut self) {
        self.scroll_offset_from_bottom = u16::MAX;
    }

    pub(crate) fn scroll_to_bottom(&mut self) {
        self.scroll_offset_from_bottom = 0;
    }

    pub(crate) fn update_workspace_sync_state(&mut self, status: WorkspaceSyncStatus) {
        let new_state = match status {
            WorkspaceSyncStatus::InProgress => WorkspaceSyncState::Syncing,
            WorkspaceSyncStatus::Completed => WorkspaceSyncState::Completed,
            WorkspaceSyncStatus::Failed(error) => WorkspaceSyncState::Failed(error),
        };

        if self.workspace_sync_state == new_state {
            return;
        }

        self.workspace_sync_state = new_state;
    }

    pub(crate) fn on_session_update(&mut self, notification: SessionNotification) {
        match notification.update {
            SessionUpdate::UserMessageChunk(chunk) => {
                if let ContentBlock::Text(text_content) = chunk.content {
                    self.append_message("User", &text_content.text);
                }
            }
            SessionUpdate::AgentMessageChunk(chunk) => {
                if let ContentBlock::Text(text_content) = chunk.content {
                    self.append_message("Agent", &text_content.text);
                }
            }
            SessionUpdate::AgentThoughtChunk(chunk) => {
                if let ContentBlock::Text(text_content) = chunk.content {
                    self.append_message("Thought", &text_content.text);
                }
            }
            SessionUpdate::ToolCall(tool_call) => {
                self.add_tool_call(tool_call);
            }
            SessionUpdate::ToolCallUpdate(update) => {
                self.update_tool_call(update);
            }
            SessionUpdate::Plan(plan) => {
                self.update_plan(plan);
            }
            SessionUpdate::AvailableCommandsUpdate(_) | SessionUpdate::CurrentModeUpdate(_) => {}
        }
    }

    fn append_message(&mut self, role: &str, text: &str) {
        if role == "Thought" && text.trim().is_empty() {
            return;
        }
        if let Some(ChatEntry::Message {
            role: last_role,
            text: last_text,
            normalized_markdown,
        }) = self.history.last_mut()
        {
            if last_role == role {
                last_text.push_str(text);
                if matches!(role, "Agent" | "Thought") {
                    *normalized_markdown = Some(normalize_code_fences(last_text));
                }
                return;
            }
        }
        let normalized_markdown = if matches!(role, "Agent" | "Thought") {
            Some(normalize_code_fences(text))
        } else {
            None
        };
        self.history.push(ChatEntry::Message {
            role: role.to_string(),
            text: text.to_string(),
            normalized_markdown,
        });
    }

    fn add_tool_call(&mut self, tool_call: ToolCall) {
        self.history.push(ChatEntry::ToolCall {
            id: tool_call.id.to_string(),
            title: tool_call.title,
            kind: tool_call.kind,
            status: tool_call.status,
        });
    }

    fn update_tool_call(&mut self, update: ToolCallUpdate) {
        let id_str = update.id.to_string();
        for entry in self.history.iter_mut().rev() {
            if let ChatEntry::ToolCall {
                id,
                title,
                kind,
                status,
            } = entry
            {
                if id == &id_str {
                    if let Some(new_title) = update.fields.title {
                        *title = new_title;
                    }
                    if let Some(new_kind) = update.fields.kind {
                        *kind = new_kind;
                    }
                    if let Some(new_status) = update.fields.status {
                        *status = new_status;
                    }
                    return;
                }
            }
        }
        if let Some(title) = update.fields.title {
            self.history.push(ChatEntry::ToolCall {
                id: id_str,
                title,
                kind: update.fields.kind.unwrap_or_default(),
                status: update.fields.status.unwrap_or_default(),
            });
        }
    }

    fn update_plan(&mut self, plan: Plan) {
        for entry in self.history.iter_mut().rev() {
            if matches!(entry, ChatEntry::Plan(_)) {
                *entry = ChatEntry::Plan(plan);
                return;
            }
        }
        self.history.push(ChatEntry::Plan(plan));
    }

    pub(crate) async fn send_message(&mut self) {
        let (conn, session_id, tx) =
            if let (Some(conn), Some(session_id)) = (&self.client_connection, &self.session_id) {
                (conn.clone(), session_id.clone(), self.event_tx.clone())
            } else {
                return;
            };

        let lines = self.textarea.lines();
        let text = lines.join("\n");
        if text.trim().is_empty() {
            return;
        }

        self.append_message("User", &text);

        self.textarea = TextArea::default();
        self.textarea.set_block(
            Block::default()
                .borders(Borders::TOP | Borders::BOTTOM)
                .border_style(ratatui::style::Style::default().fg(ratatui::style::Color::DarkGray)),
        );
        self.textarea
            .set_placeholder_text("Type a message and press Enter to send. Ctrl+J for new line.");

        let request = PromptRequest {
            session_id,
            prompt: vec![ContentBlock::Text(TextContent {
                text,
                annotations: None,
                meta: None,
            })],
            meta: None,
        };

        tokio::task::spawn_local(async move {
            if let Err(error) = Agent::prompt(&*conn, request).await {
                crate::acp_client::logging::log_debug(&format!("Prompt failed: {}", error));
                let _ = tx.send(AppEvent::RequestError {
                    error: error.to_string(),
                });
            }
        });
    }
}
