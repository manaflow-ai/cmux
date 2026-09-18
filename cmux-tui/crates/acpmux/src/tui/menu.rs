//! Right-click context menus. A menu is a small popup at the pointer with
//! one action per row; the rows are built from what was clicked (a sidebar
//! session, a host chip, a transcript row, the composer). Keys: j/k or
//! arrows move, Enter runs, Esc closes; the mouse hovers and clicks.

use super::*;
use ratatui::buffer::Buffer;
use ratatui::style::Modifier;
use unicode_width::UnicodeWidthStr;

/// What a menu row does when picked.
#[derive(Debug, Clone)]
pub enum MenuAction {
    Run(Action),
    /// Session id + operation.
    Session(String, SessionOp),
    Draft(u64, DraftOp),
    /// Host chip: None = local.
    Host(Option<String>, HostOp),
    Transcript(TranscriptOp),
    Composer(ComposerOp),
}

#[derive(Debug, Clone, Copy)]
pub enum SessionOp {
    Open,
    Rename,
    Fork,
    Stop,
    Delete,
    Export,
    CopyId,
    NewHere,
    Web,
}

#[derive(Debug, Clone, Copy)]
pub enum DraftOp {
    Discard,
    Model,
    Directory,
    Effort,
    Policy,
}

#[derive(Debug, Clone, Copy)]
pub enum HostOp {
    Filter,
    ShowAll,
    NewSession,
    Remove,
    Add,
}

#[derive(Debug, Clone)]
pub enum TranscriptOp {
    CopySelection,
    CopyRow(usize),
    CopyItem(usize),
    Toggle(Toggle),
    ExpandAll,
    CollapseAll,
    OpenLink(String),
}

#[derive(Debug, Clone, Copy)]
pub enum ComposerOp {
    CopyAll,
    Clear,
    Undo,
    Send,
    Steer,
}

#[derive(Debug, Clone)]
pub struct MenuItem {
    pub label: String,
    pub action: MenuAction,
}

#[derive(Debug, Clone)]
pub struct Menu {
    pub title: String,
    pub items: Vec<MenuItem>,
    /// Pointer position the menu opened at.
    pub at: (u16, u16),
    pub cursor: usize,
    /// Rects drawn last frame: (rect, item index).
    pub rects: Vec<(Rect, usize)>,
    pub rect: Rect,
}

impl Menu {
    pub fn new(title: impl Into<String>, at: (u16, u16), items: Vec<MenuItem>) -> Self {
        Self { title: title.into(), items, at, cursor: 0, rects: Vec::new(), rect: Rect::default() }
    }
    pub fn item_at(&self, x: u16, y: u16) -> Option<usize> {
        self.rects.iter().find(|(r, _)| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height).map(|(_, i)| *i)
    }
}

fn item(label: impl Into<String>, action: MenuAction) -> MenuItem {
    MenuItem { label: label.into(), action }
}

impl App {
    /// Build and open the menu for whatever is under the pointer.
    pub(super) fn context_menu(&mut self, x: u16, y: u16) {
        let hit = |r: Rect| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
        // Host chips in the status bar.
        if let Some((_, key)) = self.host_chips.iter().find(|(r, _)| hit(*r)).cloned() {
            let is_local = key.as_deref() == Some("local");
            let name = if is_local { "this Mac".to_owned() } else { key.clone().unwrap_or_default() };
            let mut items = vec![
                item(format!("Show only {name}"), MenuAction::Host(key.clone(), HostOp::Filter)),
                item("Show every host", MenuAction::Host(None, HostOp::ShowAll)),
                item(format!("New session on {name}"), MenuAction::Host(key.clone(), HostOp::NewSession)),
            ];
            if !is_local {
                items.push(item(format!("Remove host {name}"), MenuAction::Host(key.clone(), HostOp::Remove)));
            }
            items.push(item("Add host…", MenuAction::Host(None, HostOp::Add)));
            self.overlay = Overlay::Menu(Menu::new(name, (x, y), items));
            return;
        }
        // Sidebar rows: drafts and sessions.
        if let Some((_, idx)) = self.sidebar_rows.iter().find(|(r, _)| hit(*r)).cloned() {
            self.select(idx);
            if idx < self.drafts.len() {
                let id = self.drafts[idx].id;
                self.overlay = Overlay::Menu(Menu::new(
                    "new session",
                    (x, y),
                    vec![
                        item("Harness and model…", MenuAction::Draft(id, DraftOp::Model)),
                        item("Directory…", MenuAction::Draft(id, DraftOp::Directory)),
                        item("Thinking effort…", MenuAction::Draft(id, DraftOp::Effort)),
                        item("Permissions…", MenuAction::Draft(id, DraftOp::Policy)),
                        item("Discard draft", MenuAction::Draft(id, DraftOp::Discard)),
                    ],
                ));
                return;
            }
            if let Some(id) = self.selected_id() {
                let name = self.selected_name();
                let stopped = self.selected_session().and_then(|s| s.get("status").and_then(Value::as_str)) == Some("closed");
                let mut items = vec![
                    item("Rename…", MenuAction::Session(id.clone(), SessionOp::Rename)),
                    item("Fork with history", MenuAction::Session(id.clone(), SessionOp::Fork)),
                    item("New session in this directory", MenuAction::Session(id.clone(), SessionOp::NewHere)),
                    item("Export bundle", MenuAction::Session(id.clone(), SessionOp::Export)),
                    item("Copy session id", MenuAction::Session(id.clone(), SessionOp::CopyId)),
                    item("Open in web dashboard", MenuAction::Session(id.clone(), SessionOp::Web)),
                ];
                if !stopped {
                    items.push(item("Stop agent (keeps history)", MenuAction::Session(id.clone(), SessionOp::Stop)));
                }
                items.push(item("Delete session…", MenuAction::Session(id.clone(), SessionOp::Delete)));
                self.overlay = Overlay::Menu(Menu::new(name, (x, y), items));
            }
            return;
        }
        // Sidebar background.
        if hit(self.areas.sidebar) {
            self.overlay = Overlay::Menu(Menu::new(
                "sessions",
                (x, y),
                vec![
                    item("New session", MenuAction::Run(Action::NewDraft)),
                    item("New session form…", MenuAction::Run(Action::NewForm)),
                    item("Add host…", MenuAction::Run(Action::AddHost)),
                    item("Hide sidebar", MenuAction::Run(Action::ToggleSidebar)),
                ],
            ));
            return;
        }
        // Composer.
        if hit(self.areas.composer) {
            let running = self.selected_session().and_then(|s| s.get("status").and_then(Value::as_str)) == Some("running");
            let mut items = vec![item("Copy text", MenuAction::Composer(ComposerOp::CopyAll)), item("Clear", MenuAction::Composer(ComposerOp::Clear)), item("Undo", MenuAction::Composer(ComposerOp::Undo))];
            if !self.editor().is_empty() {
                items.push(item("Send", MenuAction::Composer(ComposerOp::Send)));
                if running {
                    items.push(item(if self.selected_supports_steer() { "Steer the running turn" } else { "Queue after the running turn" }, MenuAction::Composer(ComposerOp::Steer)));
                }
            }
            items.push(item("Model…", MenuAction::Run(Action::Model)));
            items.push(item("Thinking effort…", MenuAction::Run(Action::Effort)));
            items.push(item("Permissions…", MenuAction::Run(Action::Policy)));
            self.overlay = Overlay::Menu(Menu::new("message", (x, y), items));
            return;
        }
        // Transcript rows.
        if let Some((row, col)) = self.transcript_cell_lenient(x, y) {
            let text = self.rows_cache.get(row).cloned().unwrap_or_default();
            let mut items = Vec::new();
            if let Some(link) = links::find(&text).into_iter().find(|l| col >= l.start && col < l.end) {
                items.push(item(format!("Open {}", render::truncate(&link.target, 40)), MenuAction::Transcript(TranscriptOp::OpenLink(link.target))));
            }
            if self.selection.as_ref().map(|s| s.anchor != s.head).unwrap_or(false) {
                items.push(item("Copy selection", MenuAction::Transcript(TranscriptOp::CopySelection)));
            }
            if let Some(&(item_idx, toggle)) = self.row_meta.get(row) {
                if let Some(t) = toggle {
                    let open = self.is_open(t);
                    let what = match t {
                        Toggle::Turn(_) => "the turn's work",
                        Toggle::Group(_) => "tool calls",
                        Toggle::Item(_) => "details",
                    };
                    items.push(item(format!("{} {what}", if open { "Collapse" } else { "Expand" }), MenuAction::Transcript(TranscriptOp::Toggle(t))));
                }
                if item_idx != usize::MAX {
                    items.push(item("Copy message", MenuAction::Transcript(TranscriptOp::CopyItem(item_idx))));
                }
            }
            items.push(item("Copy row", MenuAction::Transcript(TranscriptOp::CopyRow(row))));
            items.push(item("Expand everything", MenuAction::Transcript(TranscriptOp::ExpandAll)));
            items.push(item("Collapse everything", MenuAction::Transcript(TranscriptOp::CollapseAll)));
            items.push(item(if self.show_thoughts { "Hide thinking text" } else { "Show all thinking" }, MenuAction::Run(Action::ToggleThoughts)));
            items.push(item(if self.show_system { "Hide lifecycle events" } else { "Show lifecycle events" }, MenuAction::Run(Action::ToggleSystem)));
            self.overlay = Overlay::Menu(Menu::new("transcript", (x, y), items));
        }
    }

    pub(super) fn run_menu_action(&mut self, action: MenuAction) {
        match action {
            MenuAction::Run(a) => self.run_action(a, &[]),
            MenuAction::Session(id, op) => {
                if let Some(i) = self.sessions.iter().position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id)) {
                    self.select(i + self.drafts.len());
                }
                match op {
                    SessionOp::Open => self.focus = Focus::Input,
                    SessionOp::Rename => self.run_action(Action::Rename, &[]),
                    SessionOp::Fork => self.run_action(Action::Fork, &[]),
                    SessionOp::Stop => self.run_action(Action::Stop, &[]),
                    SessionOp::Delete => self.run_action(Action::Delete, &[]),
                    SessionOp::Export => self.run_action(Action::Export, &[]),
                    SessionOp::CopyId => self.copy_to_clipboard(&id),
                    SessionOp::Web => self.run_action(Action::Web, &[]),
                    SessionOp::NewHere => {
                        let cwd = self.selected_session().and_then(|s| s.get("cwd").and_then(Value::as_str)).unwrap_or("").to_owned();
                        self.apply_directory(cwd);
                    }
                }
            }
            MenuAction::Draft(id, op) => {
                if let Some(i) = self.drafts.iter().position(|d| d.id == id) {
                    self.select(i);
                }
                match op {
                    DraftOp::Discard => self.discard_draft(),
                    DraftOp::Model => self.run_action(Action::Model, &[]),
                    DraftOp::Directory => self.run_action(Action::Directory, &[]),
                    DraftOp::Effort => self.run_action(Action::Effort, &[]),
                    DraftOp::Policy => self.run_action(Action::Policy, &[]),
                }
            }
            MenuAction::Host(key, op) => match op {
                HostOp::Filter => self.set_host_filter(key),
                HostOp::ShowAll => self.set_host_filter(None),
                HostOp::NewSession => {
                    self.set_host_filter(key);
                    self.open_draft();
                }
                HostOp::Remove => {
                    if let Some(name) = key {
                        self.run_action(Action::RemoveHost, &[&name]);
                    }
                }
                HostOp::Add => self.run_action(Action::AddHost, &[]),
            },
            MenuAction::Transcript(op) => match op {
                TranscriptOp::CopySelection => {
                    if let Some(sel) = self.selection.clone() {
                        let text = sel.text(&self.rows_cache);
                        self.copy_to_clipboard(&text);
                    }
                }
                TranscriptOp::CopyRow(row) => {
                    let text = self.rows_cache.get(row).cloned().unwrap_or_default();
                    self.copy_to_clipboard(text.trim_start());
                }
                TranscriptOp::CopyItem(idx) => {
                    let text = self.selected_id().and_then(|id| self.transcripts.get(&id)).and_then(|t| t.items.get(idx)).map(crate::transcript::item_text).unwrap_or_default();
                    self.copy_to_clipboard(&text);
                }
                TranscriptOp::Toggle(t) => self.toggle(t),
                TranscriptOp::ExpandAll => self.set_all_open(true),
                TranscriptOp::CollapseAll => self.set_all_open(false),
                TranscriptOp::OpenLink(target) => {
                    let cwd = self.selected_session().and_then(|s| s.get("cwd").and_then(Value::as_str)).unwrap_or("").to_owned();
                    self.status = links::open(&target, &cwd);
                }
            },
            MenuAction::Composer(op) => match op {
                ComposerOp::CopyAll => {
                    let t = self.editor().text();
                    self.copy_to_clipboard(&t);
                }
                ComposerOp::Clear => self.editor_mut().clear(),
                ComposerOp::Undo => self.editor_mut().undo(),
                ComposerOp::Send => self.send_prompt(false),
                ComposerOp::Steer => self.send_prompt(true),
            },
        }
    }
}

/// Draw the menu at its pointer position, clamped to the screen.
pub fn draw(buf: &mut Buffer, area: Rect, c: &theme::Chrome, hover: Option<(u16, u16)>, m: &mut Menu) {
    let w = (m.items.iter().map(|i| i.label.width()).max().unwrap_or(8).max(m.title.width() + 2) as u16 + 4).min(area.width.saturating_sub(2));
    let h = (m.items.len() as u16 + 3).min(area.height.saturating_sub(1));
    let x = m.at.0.min(area.x + area.width - w);
    let y = if m.at.1 + h <= area.y + area.height { m.at.1 } else { m.at.1.saturating_sub(h) }.max(area.y);
    let r = Rect { x, y, width: w, height: h };
    m.rect = r;
    render::fill(buf, r, c.prompt());
    render::border(buf, r, c.prompt_border());
    buf.set_stringn(r.x + 2, r.y + 1, &m.title, (r.width - 4) as usize, c.prompt_title());
    m.rects.clear();
    for (i, it) in m.items.iter().enumerate().take(h.saturating_sub(3) as usize) {
        let ry = r.y + 2 + i as u16;
        let rect = Rect { x: r.x + 1, y: ry, width: r.width - 2, height: 1 };
        let hovered = hover.map(|(hx, hy)| hy == ry && hx >= rect.x && hx < rect.x + rect.width).unwrap_or(false);
        if hovered {
            m.cursor = i;
        }
        let selected = m.cursor == i;
        let style = if selected { c.prompt().bg(c.menu_selected_bg).fg(c.menu_selected_fg).add_modifier(Modifier::BOLD) } else { c.prompt() };
        if selected {
            for cx in rect.x..rect.x + rect.width {
                if let Some(cell) = buf.cell_mut((cx, ry)) {
                    cell.set_style(style);
                }
            }
        }
        buf.set_stringn(r.x + 2, ry, &it.label, (r.width - 4) as usize, style);
        m.rects.push((rect, i));
    }
}
