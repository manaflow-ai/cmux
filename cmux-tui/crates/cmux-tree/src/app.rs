use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::layout::Rect;
use serde_json::Value;

use crate::codex::{ConnectionState, NetworkEvent, NetworkHub};
use crate::config::{Config, ConfigStore, MachineConfig};
use crate::localization::{Catalog, Locale};
use crate::model::{Conversation, ThreadSummary, ThreadTreeRow, flatten_thread_tree};
use crate::trajectory::{ExpansionState, TrajectoryView};

const STATUS_TTL: Duration = Duration::from_secs(6);
const LIST_ROW_STRIDE: usize = 3;

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
        let changed = !events.is_empty();
        for event in events {
            self.handle_network_event(event);
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
                    machine.conversation = Some(conversation);
                    machine.error = None;
                    if is_selected_machine {
                        self.clamp_trajectory_cursor();
                    }
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
        if method.starts_with("thread/")
            || (affects_selected
                && (method.starts_with("item/")
                    || method.starts_with("turn/")
                    || method == "error"))
        {
            self.network.refresh(machine_id);
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
        if !(url.starts_with("ws://") || url.starts_with("wss://")) {
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

    fn refresh_selected(&self) {
        if let Some(machine) = self.selected_machine() {
            self.network.refresh(&machine.config.id);
        }
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
}
