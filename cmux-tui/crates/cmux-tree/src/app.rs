use std::collections::HashSet;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::layout::Rect;
use serde_json::{Value, json};

use crate::codex::{ConnectionState, NetworkEvent, NetworkHub};
use crate::config::{Config, ConfigStore, MachineConfig};
use crate::discovery::{DiscoveredServer, DiscoveredTransport, LocalDiscovery, endpoint_key};
use crate::localization::{Catalog, Locale};
use crate::model::{
    Conversation, ThreadSummary, ThreadTreeRow, Turn, flatten_thread_tree, item_type,
};
use crate::trajectory::{ExpansionState, TrajectoryView};

const STATUS_TTL: Duration = Duration::from_secs(6);
const LIST_ROW_STRIDE: usize = 3;
const MAX_RETAINED_ITEM_FIELD_CHARS: usize = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Machines,
    Conversations,
    Trajectory,
}

impl Focus {
    fn next(self) -> Self {
        match self {
            Self::Machines => Self::Conversations,
            Self::Conversations => Self::Trajectory,
            Self::Trajectory => Self::Machines,
        }
    }

    fn previous(self) -> Self {
        match self {
            Self::Machines => Self::Trajectory,
            Self::Conversations => Self::Machines,
            Self::Trajectory => Self::Conversations,
        }
    }
}

#[derive(Debug, Clone)]
pub struct MachineView {
    pub config: MachineConfig,
    pub connection: ConnectionState,
    pub threads: Vec<ThreadSummary>,
    pub rows: Vec<ThreadTreeRow>,
    pub selected_thread_id: Option<String>,
    pub conversation: Option<Conversation>,
    pub error: Option<String>,
}

impl MachineView {
    fn new(config: MachineConfig) -> Self {
        Self {
            config,
            connection: ConnectionState::Connecting,
            threads: Vec::new(),
            rows: Vec::new(),
            selected_thread_id: None,
            conversation: None,
            error: None,
        }
    }

    pub fn selected_row(&self) -> Option<usize> {
        let selected = self.selected_thread_id.as_deref()?;
        self.rows.iter().position(|row| row.thread.id == selected)
    }

    pub fn selected_thread(&self) -> Option<&ThreadSummary> {
        let selected = self.selected_thread_id.as_deref()?;
        self.threads.iter().find(|thread| thread.id == selected)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HitKind {
    Column(Focus),
    Machine(usize),
    Conversation(usize),
    Accordion(usize),
    AddMachine,
    DialogField(usize),
    DialogSave,
    DialogCancel,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub area: Rect,
    pub kind: HitKind,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ColumnAreas {
    pub machines: Rect,
    pub conversations: Rect,
    pub trajectory: Rect,
}

#[derive(Debug, Clone)]
pub struct MachineDraft {
    pub values: [String; 3],
    pub cursors: [usize; 3],
    pub field: usize,
    pub error: Option<String>,
}

impl MachineDraft {
    fn new() -> Self {
        let url = "ws://127.0.0.1:4500".to_string();
        Self {
            values: [String::new(), url.clone(), String::new()],
            cursors: [0, url.chars().count(), 0],
            field: 0,
            error: None,
        }
    }
}

pub struct App {
    pub catalog: Catalog,
    pub focus: Focus,
    pub machines: Vec<MachineView>,
    pub selected_machine: usize,
    pub machine_scroll: usize,
    pub conversation_scroll: usize,
    pub trajectory_scroll: usize,
    pub trajectory_cursor: usize,
    pub expansion: ExpansionState,
    pub trajectory_view: TrajectoryView,
    pub hits: Vec<Hit>,
    pub columns: ColumnAreas,
    pub machine_viewport_height: usize,
    pub conversation_viewport_height: usize,
    pub trajectory_viewport_height: usize,
    pub draft: Option<MachineDraft>,
    pub status_message: Option<(String, Instant)>,
    pub config_store: ConfigStore,
    pub config: Config,
    network: NetworkHub,
    discovery: LocalDiscovery,
}

impl App {
    pub fn load(config_store: ConfigStore) -> Result<Self> {
        let config = config_store.load()?;
        Ok(Self::from_config(config_store, config, true))
    }

    fn from_config(config_store: ConfigStore, config: Config, connect: bool) -> Self {
        let catalog = Catalog::new(Locale::detect());
        let machines = config.machines.iter().cloned().map(MachineView::new).collect::<Vec<_>>();
        let mut network = NetworkHub::new();
        if connect {
            for machine in &config.machines {
                network.add_machine(machine.clone());
            }
        }
        Self {
            catalog,
            focus: Focus::Machines,
            machines,
            selected_machine: 0,
            machine_scroll: 0,
            conversation_scroll: 0,
            trajectory_scroll: 0,
            trajectory_cursor: 0,
            expansion: ExpansionState::default(),
            trajectory_view: TrajectoryView::default(),
            hits: Vec::new(),
            columns: ColumnAreas::default(),
            machine_viewport_height: 0,
            conversation_viewport_height: 0,
            trajectory_viewport_height: 0,
            draft: None,
            status_message: None,
            config_store,
            config,
            network,
            discovery: LocalDiscovery::new(connect),
        }
    }

    pub fn selected_machine(&self) -> Option<&MachineView> {
        self.machines.get(self.selected_machine)
    }

    pub fn selected_machine_mut(&mut self) -> Option<&mut MachineView> {
        self.machines.get_mut(self.selected_machine)
    }

    pub fn process_network_events(&mut self) -> bool {
        let events = self.network.drain().collect::<Vec<_>>();
        let mut changed = !events.is_empty();
        for event in events {
            self.handle_network_event(event);
        }
        if let Some(servers) = self.discovery.poll() {
            changed |= self.add_discovered_servers(servers);
        }
        if self.status_message.as_ref().is_some_and(|(_, at)| at.elapsed() > STATUS_TTL) {
            self.status_message = None;
            return true;
        }
        changed
    }

    fn handle_network_event(&mut self, event: NetworkEvent) {
        match event {
            NetworkEvent::Connection { machine_id, state } => {
                let error = match &state {
                    ConnectionState::Disconnected(details) => {
                        Some(self.catalog.app_server_error(details))
                    }
                    ConnectionState::Connecting | ConnectionState::Connected => None,
                };
                if let Some(machine) = self.machine_by_id_mut(&machine_id) {
                    if matches!(state, ConnectionState::Disconnected(_))
                        && let Some(conversation) = machine.conversation.as_mut()
                    {
                        for turn in &mut conversation.turns {
                            reset_loading_items(turn);
                        }
                    }
                    machine.connection = state;
                    machine.error = error;
                }
            }
            NetworkEvent::Threads { machine_id, threads } => {
                let mut changed_selection = None;
                let is_selected_machine =
                    self.selected_machine().is_some_and(|machine| machine.config.id == machine_id);
                if let Some(machine) = self.machine_by_id_mut(&machine_id) {
                    let previous = machine.selected_thread_id.clone();
                    machine.rows = flatten_thread_tree(threads.clone());
                    machine.threads = threads;
                    if machine
                        .selected_thread_id
                        .as_ref()
                        .is_none_or(|id| !machine.rows.iter().any(|row| &row.thread.id == id))
                    {
                        machine.selected_thread_id =
                            machine.rows.first().map(|row| row.thread.id.clone());
                    }
                    if machine.selected_thread_id != previous {
                        machine.conversation = None;
                        changed_selection = Some(machine.selected_thread_id.clone());
                    }
                }
                if is_selected_machine && let Some(thread_id) = changed_selection {
                    self.network.select_thread(&machine_id, thread_id);
                    self.reset_trajectory_navigation();
                }
            }
            NetworkEvent::Conversation { machine_id, thread_id, mut conversation } => {
                let is_selected_machine =
                    self.selected_machine().is_some_and(|machine| machine.config.id == machine_id);
                if let Some(machine) = self.machine_by_id_mut(&machine_id)
                    && machine.selected_thread_id.as_deref() == Some(&thread_id)
                {
                    if conversation.status.is_null()
                        && let Some(thread) =
                            machine.threads.iter().find(|thread| thread.id == thread_id)
                    {
                        conversation.status = thread.status.clone();
                    }
                    bound_conversation_items(&mut conversation);
                    machine.conversation = Some(merge_conversation_snapshot(
                        machine.conversation.take(),
                        conversation,
                    ));
                    machine.error = None;
                    if is_selected_machine {
                        self.clamp_trajectory_cursor();
                    }
                }
            }
            NetworkEvent::TurnItems { machine_id, thread_id, turn_id, items, truncated } => {
                let is_selected_machine =
                    self.selected_machine().is_some_and(|machine| machine.config.id == machine_id);
                if let Some(machine) = self.machine_by_id_mut(&machine_id)
                    && machine.selected_thread_id.as_deref() == Some(&thread_id)
                    && let Some(conversation) = machine.conversation.as_mut()
                    && let Some(turn) =
                        conversation.turns.iter_mut().find(|turn| turn.id == turn_id)
                {
                    hydrate_turn_items(turn, items, truncated);
                    machine.error = None;
                    if is_selected_machine {
                        self.clamp_trajectory_cursor();
                    }
                }
            }
            NetworkEvent::TurnItemsFailed { machine_id, thread_id, turn_id } => {
                if let Some(machine) = self.machine_by_id_mut(&machine_id)
                    && machine.selected_thread_id.as_deref() == Some(&thread_id)
                    && let Some(conversation) = machine.conversation.as_mut()
                    && let Some(turn) =
                        conversation.turns.iter_mut().find(|turn| turn.id == turn_id)
                {
                    reset_loading_items(turn);
                }
            }
            NetworkEvent::Notification { machine_id, method, params } => {
                self.handle_notification(&machine_id, &method, params);
            }
            NetworkEvent::Error { machine_id, message } => {
                let message = self.catalog.app_server_error(&message);
                if let Some(machine) = self.machine_by_id_mut(&machine_id) {
                    machine.error = Some(message.clone());
                }
                self.set_status(message);
            }
        }
    }

    fn handle_notification(&mut self, machine_id: &str, method: &str, params: Value) {
        if method == "thread/status/changed"
            && let Some(thread_id) = params.get("threadId").and_then(Value::as_str)
            && let Some(status) = params.get("status")
        {
            if let Some(machine) = self.machine_by_id_mut(machine_id) {
                if let Some(thread) =
                    machine.threads.iter_mut().find(|thread| thread.id == thread_id)
                {
                    let was_active = thread.is_active();
                    thread.status = status.clone();
                    let is_active = thread.is_active();
                    let now = now_unix();
                    if is_active && !was_active {
                        thread.recency_at = Some(thread.recency_at.unwrap_or(0).max(now));
                    } else if !is_active {
                        thread.updated_at = thread.updated_at.max(now);
                    }
                }
                if machine.selected_thread_id.as_deref() == Some(thread_id)
                    && let Some(conversation) = machine.conversation.as_mut()
                {
                    conversation.status = status.clone();
                }
                machine.rows = flatten_thread_tree(machine.threads.clone());
            }
            return;
        }

        let thread_id = params.get("threadId").and_then(Value::as_str);
        let affects_selected = thread_id.is_some_and(|thread_id| {
            self.machine_by_id(machine_id).and_then(|machine| machine.selected_thread_id.as_deref())
                == Some(thread_id)
        });
        let applied_incrementally = affects_selected
            && self
                .machine_by_id_mut(machine_id)
                .and_then(|machine| machine.conversation.as_mut())
                .is_some_and(|conversation| {
                    apply_conversation_notification(conversation, method, &params)
                });
        if method.starts_with("thread/") {
            self.network.refresh(machine_id);
        } else if affects_selected
            && !applied_incrementally
            && (method.starts_with("item/") || method.starts_with("turn/") || method == "error")
        {
            self.network.refresh_trajectory(machine_id);
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> bool {
        if matches!(key.kind, KeyEventKind::Release) {
            return true;
        }
        if self.draft.is_some() {
            self.handle_draft_key(key);
            return true;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            return false;
        }
        match key.code {
            KeyCode::Char('q') => return false,
            KeyCode::Char('a') => self.draft = Some(MachineDraft::new()),
            KeyCode::Tab => self.focus = self.focus.next(),
            KeyCode::BackTab => self.focus = self.focus.previous(),
            KeyCode::Left | KeyCode::Char('h') => self.focus = self.focus.previous(),
            KeyCode::Right | KeyCode::Char('l') => self.focus = self.focus.next(),
            KeyCode::Char('r') => self.refresh_selected(),
            KeyCode::Down | KeyCode::Char('j') => self.move_selection(1),
            KeyCode::Up | KeyCode::Char('k') => self.move_selection(-1),
            KeyCode::Enter | KeyCode::Char(' ') if self.focus == Focus::Trajectory => {
                self.toggle_selected_accordion();
            }
            KeyCode::Enter if self.focus == Focus::Machines => {
                if !self.machines.is_empty() {
                    self.focus = Focus::Conversations;
                }
            }
            KeyCode::Enter if self.focus == Focus::Conversations => {
                if self.selected_machine().is_some_and(|machine| !machine.rows.is_empty()) {
                    self.focus = Focus::Trajectory;
                }
            }
            KeyCode::PageDown => self.page_scroll(1),
            KeyCode::PageUp => self.page_scroll(-1),
            KeyCode::Home | KeyCode::Char('g') => self.scroll_to_edge(false),
            KeyCode::End | KeyCode::Char('G') => self.scroll_to_edge(true),
            _ => {}
        }
        true
    }

    pub fn handle_mouse(&mut self, mouse: MouseEvent) {
        if self.draft.is_some() {
            if mouse.kind == MouseEventKind::Down(MouseButton::Left)
                && let Some(hit) = self.hit_at(mouse.column, mouse.row).cloned()
            {
                match hit.kind {
                    HitKind::DialogField(index) => {
                        if let Some(draft) = self.draft.as_mut() {
                            draft.field = index.min(2);
                        }
                    }
                    HitKind::DialogSave => self.save_draft(),
                    HitKind::DialogCancel => self.draft = None,
                    _ => {}
                }
            }
            return;
        }
        match mouse.kind {
            MouseEventKind::ScrollUp => self.mouse_scroll(mouse.column, -3),
            MouseEventKind::ScrollDown => self.mouse_scroll(mouse.column, 3),
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(hit) = self.hit_at(mouse.column, mouse.row).cloned() {
                    match hit.kind {
                        HitKind::Column(focus) => self.focus = focus,
                        HitKind::Machine(index) => {
                            self.focus = Focus::Machines;
                            self.select_machine(index);
                        }
                        HitKind::Conversation(index) => {
                            self.focus = Focus::Conversations;
                            self.select_conversation(index);
                        }
                        HitKind::Accordion(index) => {
                            self.focus = Focus::Trajectory;
                            self.trajectory_cursor = index;
                            self.toggle_selected_accordion();
                        }
                        HitKind::AddMachine => self.draft = Some(MachineDraft::new()),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    fn handle_draft_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => self.draft = None,
            KeyCode::Tab => {
                if let Some(draft) = self.draft.as_mut() {
                    draft.field = (draft.field + 1) % 3;
                }
            }
            KeyCode::BackTab => {
                if let Some(draft) = self.draft.as_mut() {
                    draft.field = (draft.field + 2) % 3;
                }
            }
            KeyCode::Enter => {
                if self.draft.as_ref().is_some_and(|draft| draft.field < 2) {
                    if let Some(draft) = self.draft.as_mut() {
                        draft.field += 1;
                    }
                } else {
                    self.save_draft();
                }
            }
            KeyCode::Backspace => {
                if let Some(draft) = self.draft.as_mut() {
                    remove_before_cursor(
                        &mut draft.values[draft.field],
                        &mut draft.cursors[draft.field],
                    );
                }
            }
            KeyCode::Delete => {
                if let Some(draft) = self.draft.as_mut() {
                    remove_at_cursor(
                        &mut draft.values[draft.field],
                        &mut draft.cursors[draft.field],
                    );
                }
            }
            KeyCode::Left => {
                if let Some(draft) = self.draft.as_mut() {
                    draft.cursors[draft.field] = draft.cursors[draft.field].saturating_sub(1);
                }
            }
            KeyCode::Right => {
                if let Some(draft) = self.draft.as_mut() {
                    let length = draft.values[draft.field].chars().count();
                    draft.cursors[draft.field] = (draft.cursors[draft.field] + 1).min(length);
                }
            }
            KeyCode::Home => {
                if let Some(draft) = self.draft.as_mut() {
                    draft.cursors[draft.field] = 0;
                }
            }
            KeyCode::End => {
                if let Some(draft) = self.draft.as_mut() {
                    draft.cursors[draft.field] = draft.values[draft.field].chars().count();
                }
            }
            KeyCode::Char(character)
                if !key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                if let Some(draft) = self.draft.as_mut() {
                    insert_at_cursor(
                        &mut draft.values[draft.field],
                        &mut draft.cursors[draft.field],
                        character,
                    );
                    draft.error = None;
                }
            }
            _ => {}
        }
    }

    fn save_draft(&mut self) {
        let Some(draft) = self.draft.as_ref() else { return };
        let name = draft.values[0].trim().to_string();
        let url = draft.values[1].trim().trim_end_matches('/').to_string();
        if name.is_empty() {
            if let Some(draft) = self.draft.as_mut() {
                draft.error = Some(self.catalog.invalid_name().to_string());
                draft.field = 0;
            }
            return;
        }
        if !(url.starts_with("ws://") || url.starts_with("wss://") || url.starts_with("unix://")) {
            if let Some(draft) = self.draft.as_mut() {
                draft.error = Some(self.catalog.invalid_url().to_string());
                draft.field = 1;
            }
            return;
        }
        let token_file =
            (!draft.values[2].trim().is_empty()).then(|| PathBuf::from(draft.values[2].trim()));
        let machine = MachineConfig::new(name, url, token_file);
        let mut config = self.config.clone();
        config.machines.push(machine.clone());
        if let Err(error) = self.config_store.save(&config) {
            if let Some(draft) = self.draft.as_mut() {
                draft.error = Some(self.catalog.config_error(&format!("{error:#}")));
            }
            return;
        }
        if let Some(previous) = self.selected_machine() {
            self.network.select_thread(&previous.config.id, None);
        }
        self.config = config;
        self.machines.push(MachineView::new(machine.clone()));
        self.network.add_machine(machine);
        self.selected_machine = self.machines.len() - 1;
        self.draft = None;
        self.reset_trajectory_navigation();
        self.set_status(self.catalog.config_saved().to_string());
    }

    fn move_selection(&mut self, delta: isize) {
        match self.focus {
            Focus::Machines => {
                if self.machines.is_empty() {
                    return;
                }
                let next = shifted_index(self.selected_machine, self.machines.len(), delta);
                self.select_machine(next);
            }
            Focus::Conversations => {
                let Some(machine) = self.selected_machine() else { return };
                if machine.rows.is_empty() {
                    return;
                }
                let current = machine.selected_row().unwrap_or(0);
                let next = shifted_index(current, machine.rows.len(), delta);
                self.select_conversation(next);
            }
            Focus::Trajectory => {
                if self.trajectory_view.accordions.is_empty() {
                    self.scroll_trajectory(delta);
                    return;
                }
                self.trajectory_cursor = shifted_index(
                    self.trajectory_cursor,
                    self.trajectory_view.accordions.len(),
                    delta,
                );
                self.reveal_trajectory_cursor();
            }
        }
    }

    fn select_machine(&mut self, index: usize) {
        if index >= self.machines.len() || index == self.selected_machine {
            return;
        }
        if let Some(previous) = self.selected_machine() {
            self.network.select_thread(&previous.config.id, None);
        }
        self.selected_machine = index;
        self.conversation_scroll = 0;
        self.reset_trajectory_navigation();
        if let Some(machine) = self.selected_machine() {
            self.network.select_thread(&machine.config.id, machine.selected_thread_id.clone());
            self.network.refresh(&machine.config.id);
        }
    }

    fn select_conversation(&mut self, index: usize) {
        let Some(machine) = self.selected_machine() else { return };
        let Some(row) = machine.rows.get(index) else { return };
        let thread_id = row.thread.id.clone();
        let machine_id = machine.config.id.clone();
        if machine.selected_thread_id.as_deref() == Some(&thread_id) {
            return;
        }
        if let Some(machine) = self.selected_machine_mut() {
            machine.selected_thread_id = Some(thread_id.clone());
            machine.conversation = None;
        }
        self.reset_trajectory_navigation();
        self.network.select_thread(&machine_id, Some(thread_id));
    }

    fn toggle_selected_accordion(&mut self) {
        let Some(accordion) = self.trajectory_view.accordions.get(self.trajectory_cursor).cloned()
        else {
            return;
        };
        self.expansion.toggle(&accordion.key, accordion.default_expanded);
        let is_expanded = self.expansion.is_expanded(&accordion.key, accordion.default_expanded);
        if is_expanded
            && let Some(turn_id) =
                accordion.key.strip_prefix("turn:").and_then(|key| key.strip_suffix(":work"))
        {
            self.load_turn_items(turn_id);
        }
    }

    fn load_turn_items(&mut self, turn_id: &str) {
        let request = {
            let Some(machine) = self.selected_machine_mut() else { return };
            let Some(thread_id) = machine.selected_thread_id.clone() else { return };
            let Some(conversation) = machine.conversation.as_mut() else { return };
            let Some(turn) = conversation.turns.iter_mut().find(|turn| turn.id == turn_id) else {
                return;
            };
            if !turn.needs_item_hydration() {
                return;
            }
            turn.items_view = "loading".to_string();
            (machine.config.id.clone(), thread_id)
        };
        let (machine_id, thread_id) = request;
        self.network.load_turn_items(&machine_id, thread_id, turn_id.to_string());
    }

    fn page_scroll(&mut self, direction: isize) {
        match self.focus {
            Focus::Machines => {
                let amount = self.machine_viewport_height.saturating_sub(1).max(1);
                self.machine_scroll =
                    shifted_offset(self.machine_scroll, direction * amount as isize);
            }
            Focus::Conversations => {
                let amount = self.conversation_viewport_height.saturating_sub(1).max(1);
                self.conversation_scroll =
                    shifted_offset(self.conversation_scroll, direction * amount as isize);
            }
            Focus::Trajectory => {
                let amount = self.trajectory_viewport_height.saturating_sub(1).max(1);
                self.trajectory_scroll =
                    shifted_offset(self.trajectory_scroll, direction * amount as isize);
            }
        }
        self.clamp_scrolls();
    }

    fn scroll_to_edge(&mut self, end: bool) {
        match self.focus {
            Focus::Machines => {
                self.machine_scroll = if end { usize::MAX } else { 0 };
            }
            Focus::Conversations => {
                self.conversation_scroll = if end { usize::MAX } else { 0 };
            }
            Focus::Trajectory => {
                self.trajectory_scroll = if end { usize::MAX } else { 0 };
                if !self.trajectory_view.accordions.is_empty() {
                    self.trajectory_cursor =
                        if end { self.trajectory_view.accordions.len() - 1 } else { 0 };
                }
            }
        }
        self.clamp_scrolls();
    }

    fn mouse_scroll(&mut self, column: u16, delta: isize) {
        if self.columns.machines.x <= column
            && column < self.columns.machines.x + self.columns.machines.width
        {
            self.focus = Focus::Machines;
            self.machine_scroll = shifted_offset(self.machine_scroll, delta);
        } else if self.columns.conversations.x <= column
            && column < self.columns.conversations.x + self.columns.conversations.width
        {
            self.focus = Focus::Conversations;
            self.conversation_scroll = shifted_offset(self.conversation_scroll, delta);
        } else if self.columns.trajectory.x <= column
            && column < self.columns.trajectory.x + self.columns.trajectory.width
        {
            self.focus = Focus::Trajectory;
            self.trajectory_scroll = shifted_offset(self.trajectory_scroll, delta);
        }
        self.clamp_scrolls();
    }

    fn scroll_trajectory(&mut self, delta: isize) {
        self.trajectory_scroll = shifted_offset(self.trajectory_scroll, delta);
        self.clamp_scrolls();
    }

    pub fn clamp_scrolls(&mut self) {
        let machine_total = self.machines.len() * LIST_ROW_STRIDE;
        self.machine_scroll =
            self.machine_scroll.min(machine_total.saturating_sub(self.machine_viewport_height));
        let conversation_total =
            self.selected_machine().map_or(0, |machine| machine.rows.len() * LIST_ROW_STRIDE);
        self.conversation_scroll = self
            .conversation_scroll
            .min(conversation_total.saturating_sub(self.conversation_viewport_height));
        self.trajectory_scroll = self
            .trajectory_scroll
            .min(self.trajectory_view.lines.len().saturating_sub(self.trajectory_viewport_height));
    }

    pub fn reveal_machine_selection(&mut self) {
        reveal_fixed_row(
            &mut self.machine_scroll,
            self.selected_machine,
            self.machine_viewport_height,
        );
    }

    pub fn reveal_conversation_selection(&mut self) {
        let selected = self.selected_machine().and_then(MachineView::selected_row).unwrap_or(0);
        reveal_fixed_row(
            &mut self.conversation_scroll,
            selected,
            self.conversation_viewport_height,
        );
    }

    pub fn reveal_trajectory_cursor(&mut self) {
        let Some(accordion) = self.trajectory_view.accordions.get(self.trajectory_cursor) else {
            return;
        };
        reveal_line(
            &mut self.trajectory_scroll,
            accordion.line_index,
            self.trajectory_viewport_height,
        );
    }

    fn refresh_selected(&mut self) {
        if let Some(machine) = self.selected_machine() {
            self.network.refresh(&machine.config.id);
        }
        self.discovery.request_scan();
    }

    fn add_discovered_servers(&mut self, servers: Vec<DiscoveredServer>) -> bool {
        let mut known = self
            .machines
            .iter()
            .map(|machine| endpoint_key(&machine.config.url))
            .collect::<HashSet<_>>();
        let mut added = 0;
        for server in servers {
            if !known.insert(endpoint_key(&server.url)) {
                continue;
            }
            let name = match server.transport {
                DiscoveredTransport::WebSocket { port } => self.catalog.local_codex(port),
                DiscoveredTransport::UnixSocket => self.catalog.local_codex_daemon().to_string(),
            };
            let machine =
                MachineConfig { id: server.machine_id(), name, url: server.url, token_file: None };
            self.network.add_machine(machine.clone());
            self.machines.push(MachineView::new(machine));
            added += 1;
        }
        if added > 0 {
            self.set_status(self.catalog.discovered_local_servers(added));
        }
        added > 0
    }

    fn reset_trajectory_navigation(&mut self) {
        self.trajectory_scroll = 0;
        self.trajectory_cursor = 0;
        self.expansion.clear();
        self.trajectory_view = TrajectoryView::default();
    }

    fn clamp_trajectory_cursor(&mut self) {
        self.trajectory_cursor =
            self.trajectory_cursor.min(self.trajectory_view.accordions.len().saturating_sub(1));
    }

    fn hit_at(&self, x: u16, y: u16) -> Option<&Hit> {
        self.hits.iter().rev().find(|hit| {
            x >= hit.area.x
                && x < hit.area.x.saturating_add(hit.area.width)
                && y >= hit.area.y
                && y < hit.area.y.saturating_add(hit.area.height)
        })
    }

    fn machine_by_id(&self, id: &str) -> Option<&MachineView> {
        self.machines.iter().find(|machine| machine.config.id == id)
    }

    fn machine_by_id_mut(&mut self, id: &str) -> Option<&mut MachineView> {
        self.machines.iter_mut().find(|machine| machine.config.id == id)
    }

    fn set_status(&mut self, message: String) {
        self.status_message = Some((message, Instant::now()));
    }

    #[cfg(test)]
    pub fn fixture(config: Config) -> Self {
        Self::from_config(
            ConfigStore::new(PathBuf::from("/tmp/cmux-tree-test-config.json")),
            config,
            false,
        )
    }
}

fn merge_conversation_snapshot(
    existing: Option<Conversation>,
    mut snapshot: Conversation,
) -> Conversation {
    let Some(existing) = existing else { return snapshot };
    for turn in &mut snapshot.turns {
        let Some(previous) = existing.turns.iter().find(|previous| previous.id == turn.id) else {
            continue;
        };
        if turn.needs_item_hydration() && previous.has_item_detail() {
            let mut items = previous.items.clone();
            merge_summary_messages(&mut items, std::mem::take(&mut turn.items));
            turn.items = items;
            turn.items_view = previous.items_view.clone();
            turn.items_truncated = previous.items_truncated;
        }
    }
    snapshot
}

fn hydrate_turn_items(turn: &mut Turn, mut items: Vec<Value>, truncated: bool) {
    for item in &mut items {
        bound_json_strings(item);
    }
    let summary_messages = turn
        .items
        .iter()
        .filter(|item| matches!(item_type(item), "userMessage" | "agentMessage"))
        .cloned()
        .collect::<Vec<_>>();
    merge_summary_messages(&mut items, summary_messages);
    turn.items = items;
    turn.items_view = "full".to_string();
    turn.items_truncated = truncated;
}

fn reset_loading_items(turn: &mut Turn) {
    if !turn.is_loading_items() {
        return;
    }
    turn.items_view = if turn.internal_items().next().is_some() {
        "partial".to_string()
    } else {
        "summary".to_string()
    };
}

fn merge_summary_messages(items: &mut Vec<Value>, summaries: Vec<Value>) {
    for summary in summaries {
        let summary_id = json_item_id(&summary);
        if let Some(index) = summary_id.and_then(|id| {
            items
                .iter()
                .position(|item| json_item_id(item).is_some_and(|candidate| candidate == id))
        }) {
            items[index] = summary;
            continue;
        }
        match item_type(&summary) {
            "userMessage" => items.insert(0, summary),
            "agentMessage" => items.push(summary),
            _ => {}
        }
    }
}

fn json_item_id(item: &Value) -> Option<&str> {
    item.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())
}

fn bound_conversation_items(conversation: &mut Conversation) {
    for turn in &mut conversation.turns {
        for item in &mut turn.items {
            bound_json_strings(item);
        }
    }
}

fn bound_json_strings(value: &mut Value) {
    match value {
        Value::String(text) => {
            *text = bounded_text(text, MAX_RETAINED_ITEM_FIELD_CHARS);
        }
        Value::Array(values) => {
            for value in values {
                bound_json_strings(value);
            }
        }
        Value::Object(values) => {
            for value in values.values_mut() {
                bound_json_strings(value);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn bounded_text(value: &str, max_chars: usize) -> String {
    if value.len() <= max_chars || value.chars().count() <= max_chars {
        return value.to_string();
    }
    let side = max_chars.saturating_sub(3) / 2;
    let head = value.chars().take(side).collect::<String>();
    let tail = value.chars().rev().take(side).collect::<String>().chars().rev().collect::<String>();
    format!("{head}\n…\n{tail}")
}

fn apply_conversation_notification(
    conversation: &mut Conversation,
    method: &str,
    params: &Value,
) -> bool {
    match method {
        "turn/started" | "turn/completed" => {
            let Some(turn_value) = params.get("turn").cloned() else { return false };
            let Ok(mut incoming) = serde_json::from_value::<Turn>(turn_value) else { return false };
            for item in &mut incoming.items {
                bound_json_strings(item);
            }
            if let Some(existing) =
                conversation.turns.iter_mut().find(|turn| turn.id == incoming.id)
            {
                if incoming.needs_item_hydration() && existing.has_item_detail() {
                    let mut items = existing.items.clone();
                    merge_summary_messages(&mut items, std::mem::take(&mut incoming.items));
                    incoming.items = items;
                    incoming.items_view = existing.items_view.clone();
                    incoming.items_truncated = existing.items_truncated;
                }
                *existing = incoming;
            } else {
                conversation.turns.push(incoming);
            }
            true
        }
        "item/started" | "item/completed" => {
            let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
                return false;
            };
            let Some(mut item) = params.get("item").cloned() else { return false };
            bound_json_strings(&mut item);
            let turn = ensure_turn(conversation, turn_id);
            if turn.needs_item_hydration() {
                turn.items_view = "partial".to_string();
                turn.items_truncated = true;
            }
            upsert_item(turn, item);
            true
        }
        "item/agentMessage/delta" => {
            append_item_delta(conversation, params, "agentMessage", "text", None)
        }
        "item/plan/delta" => append_item_delta(conversation, params, "plan", "text", None),
        "item/commandExecution/outputDelta" => {
            append_item_delta(conversation, params, "commandExecution", "aggregatedOutput", None)
        }
        "item/reasoning/summaryTextDelta" => append_item_delta(
            conversation,
            params,
            "reasoning",
            "summary",
            params.get("summaryIndex").and_then(Value::as_u64).map(|value| value as usize),
        ),
        "item/reasoning/textDelta" => append_item_delta(
            conversation,
            params,
            "reasoning",
            "content",
            params.get("contentIndex").and_then(Value::as_u64).map(|value| value as usize),
        ),
        "item/reasoning/summaryPartAdded" => {
            let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
                return false;
            };
            let Some(item_id) = params.get("itemId").and_then(Value::as_str) else {
                return false;
            };
            let Some(index) =
                params.get("summaryIndex").and_then(Value::as_u64).map(|value| value as usize)
            else {
                return false;
            };
            let turn = ensure_turn(conversation, turn_id);
            let item = ensure_item(turn, item_id, "reasoning");
            ensure_string_array_slot(item, "summary", index);
            true
        }
        "item/fileChange/patchUpdated" => {
            let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
                return false;
            };
            let Some(item_id) = params.get("itemId").and_then(Value::as_str) else {
                return false;
            };
            let Some(mut changes) = params.get("changes").cloned() else { return false };
            bound_json_strings(&mut changes);
            let turn = ensure_turn(conversation, turn_id);
            let item = ensure_item(turn, item_id, "fileChange");
            item["changes"] = changes;
            true
        }
        "error" => {
            let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
                return false;
            };
            let Some(mut error) = params.get("error").cloned() else { return false };
            bound_json_strings(&mut error);
            ensure_turn(conversation, turn_id).error = Some(error);
            true
        }
        _ => false,
    }
}

fn ensure_turn<'a>(conversation: &'a mut Conversation, turn_id: &str) -> &'a mut Turn {
    if let Some(index) = conversation.turns.iter().position(|turn| turn.id == turn_id) {
        return &mut conversation.turns[index];
    }
    conversation.turns.push(Turn {
        id: turn_id.to_string(),
        status: "inProgress".to_string(),
        items_view: "live".to_string(),
        ..Turn::default()
    });
    conversation.turns.last_mut().expect("turn was just appended")
}

fn upsert_item(turn: &mut Turn, item: Value) {
    if let Some(id) = json_item_id(&item)
        && let Some(index) =
            turn.items.iter().position(|candidate| json_item_id(candidate) == Some(id))
    {
        turn.items[index] = item;
        return;
    }
    turn.items.push(item);
}

fn ensure_item<'a>(turn: &'a mut Turn, item_id: &str, kind: &str) -> &'a mut Value {
    if let Some(index) =
        turn.items.iter().position(|candidate| json_item_id(candidate) == Some(item_id))
    {
        return &mut turn.items[index];
    }
    turn.items.push(json!({
        "id": item_id,
        "type": kind,
        "status": "inProgress"
    }));
    turn.items.last_mut().expect("item was just appended")
}

fn append_item_delta(
    conversation: &mut Conversation,
    params: &Value,
    kind: &str,
    field: &str,
    index: Option<usize>,
) -> bool {
    let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else { return false };
    let Some(item_id) = params.get("itemId").and_then(Value::as_str) else { return false };
    let Some(delta) = params.get("delta").and_then(Value::as_str) else { return false };
    let turn = ensure_turn(conversation, turn_id);
    let item = ensure_item(turn, item_id, kind);
    if let Some(index) = index {
        ensure_string_array_slot(item, field, index);
        let Some(value) = item
            .get_mut(field)
            .and_then(Value::as_array_mut)
            .and_then(|values| values.get_mut(index))
        else {
            return false;
        };
        append_bounded_string(value, delta);
    } else {
        if item.get(field).and_then(Value::as_str).is_none() {
            item[field] = Value::String(String::new());
        }
        let Some(value) = item.get_mut(field) else { return false };
        append_bounded_string(value, delta);
    }
    true
}

fn ensure_string_array_slot(item: &mut Value, field: &str, index: usize) {
    if item.get(field).and_then(Value::as_array).is_none() {
        item[field] = Value::Array(Vec::new());
    }
    let Some(values) = item.get_mut(field).and_then(Value::as_array_mut) else { return };
    while values.len() <= index {
        values.push(Value::String(String::new()));
    }
}

fn append_bounded_string(value: &mut Value, delta: &str) {
    let text = value.as_str().unwrap_or_default();
    let mut updated = String::with_capacity(text.len().saturating_add(delta.len()));
    updated.push_str(text);
    updated.push_str(delta);
    *value = Value::String(bounded_text(&updated, MAX_RETAINED_ITEM_FIELD_CHARS));
}

fn reveal_fixed_row(offset: &mut usize, index: usize, viewport: usize) {
    let start = index * LIST_ROW_STRIDE;
    let end = start + 2;
    if start < *offset {
        *offset = start;
    } else if end >= offset.saturating_add(viewport) {
        *offset = end.saturating_add(1).saturating_sub(viewport);
    }
}

fn reveal_line(offset: &mut usize, line: usize, viewport: usize) {
    if line < *offset {
        *offset = line;
    } else if line >= offset.saturating_add(viewport) {
        *offset = line.saturating_add(1).saturating_sub(viewport);
    }
}

fn shifted_index(current: usize, length: usize, delta: isize) -> usize {
    if length == 0 {
        return 0;
    }
    current.saturating_add_signed(delta).min(length - 1)
}

fn shifted_offset(current: usize, delta: isize) -> usize {
    current.saturating_add_signed(delta)
}

fn insert_at_cursor(value: &mut String, cursor: &mut usize, character: char) {
    let byte = byte_index(value, *cursor);
    value.insert(byte, character);
    *cursor += 1;
}

fn remove_before_cursor(value: &mut String, cursor: &mut usize) {
    if *cursor == 0 {
        return;
    }
    let start = byte_index(value, *cursor - 1);
    let end = byte_index(value, *cursor);
    value.replace_range(start..end, "");
    *cursor -= 1;
}

fn remove_at_cursor(value: &mut String, cursor: &mut usize) {
    if *cursor >= value.chars().count() {
        return;
    }
    let start = byte_index(value, *cursor);
    let end = byte_index(value, *cursor + 1);
    value.replace_range(start..end, "");
}

fn byte_index(value: &str, character_index: usize) -> usize {
    value.char_indices().nth(character_index).map_or(value.len(), |(index, _)| index)
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .try_into()
        .unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unicode_draft_edits_use_character_positions() {
        let mut value = "東京".to_string();
        let mut cursor = 1;
        insert_at_cursor(&mut value, &mut cursor, 'A');
        assert_eq!((value.as_str(), cursor), ("東A京", 2));
        remove_before_cursor(&mut value, &mut cursor);
        assert_eq!((value.as_str(), cursor), ("東京", 1));
        remove_at_cursor(&mut value, &mut cursor);
        assert_eq!((value.as_str(), cursor), ("東", 1));
    }

    #[test]
    fn reveal_keeps_two_line_entry_inside_viewport() {
        let mut offset = 0;
        reveal_fixed_row(&mut offset, 4, 6);
        assert_eq!(offset, 9);
    }

    #[test]
    fn summary_refresh_preserves_incremental_tool_items() {
        let existing = Conversation {
            id: "thread".into(),
            turns: vec![Turn {
                id: "turn".into(),
                items: vec![
                    json!({"type": "userMessage", "id": "user", "content": []}),
                    json!({"type": "commandExecution", "id": "tool", "command": "cargo test"}),
                ],
                items_view: "live".into(),
                status: "inProgress".into(),
                ..Turn::default()
            }],
            ..Conversation::default()
        };
        let snapshot = Conversation {
            id: "thread".into(),
            turns: vec![Turn {
                id: "turn".into(),
                items: vec![
                    json!({"type": "userMessage", "id": "user", "content": []}),
                    json!({"type": "agentMessage", "id": "agent", "text": "Done"}),
                ],
                items_view: "summary".into(),
                status: "completed".into(),
                ..Turn::default()
            }],
            ..Conversation::default()
        };

        let merged = merge_conversation_snapshot(Some(existing), snapshot);

        assert_eq!(merged.turns[0].items_view, "live");
        assert!(merged.turns[0].items.iter().any(|item| json_item_id(item) == Some("tool")));
        assert!(merged.turns[0].items.iter().any(|item| json_item_id(item) == Some("agent")));
    }

    #[test]
    fn completed_item_notification_replaces_live_item_without_refresh() {
        let mut conversation = Conversation {
            id: "thread".into(),
            turns: vec![Turn {
                id: "turn".into(),
                items_view: "live".into(),
                status: "inProgress".into(),
                ..Turn::default()
            }],
            ..Conversation::default()
        };
        assert!(apply_conversation_notification(
            &mut conversation,
            "item/started",
            &json!({
                "threadId": "thread",
                "turnId": "turn",
                "item": {
                    "type": "commandExecution",
                    "id": "tool",
                    "command": "cargo test",
                    "status": "inProgress"
                }
            }),
        ));
        assert!(apply_conversation_notification(
            &mut conversation,
            "item/commandExecution/outputDelta",
            &json!({
                "threadId": "thread",
                "turnId": "turn",
                "itemId": "tool",
                "delta": "ok"
            }),
        ));

        assert_eq!(conversation.turns[0].items[0]["aggregatedOutput"], "ok");
    }

    #[test]
    fn explicit_hydration_is_bounded_in_retained_state() {
        let mut turn = Turn {
            id: "turn".into(),
            items: vec![
                json!({"type": "userMessage", "id": "user", "content": []}),
                json!({"type": "agentMessage", "id": "agent", "text": "Done"}),
            ],
            items_view: "summary".into(),
            ..Turn::default()
        };
        hydrate_turn_items(
            &mut turn,
            vec![json!({
                "type": "commandExecution",
                "id": "tool",
                "aggregatedOutput": "x".repeat(MAX_RETAINED_ITEM_FIELD_CHARS * 2)
            })],
            true,
        );

        assert_eq!(turn.items_view, "full");
        assert!(turn.items_truncated);
        assert!(turn.items.iter().any(|item| json_item_id(item) == Some("user")));
        assert!(turn.items.iter().any(|item| json_item_id(item) == Some("agent")));
        let output = turn
            .items
            .iter()
            .find(|item| json_item_id(item) == Some("tool"))
            .and_then(|item| item.get("aggregatedOutput"))
            .and_then(Value::as_str)
            .unwrap();
        assert!(output.chars().count() <= MAX_RETAINED_ITEM_FIELD_CHARS);
    }
}
