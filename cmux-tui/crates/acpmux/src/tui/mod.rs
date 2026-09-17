//! Terminal UI: a session sidebar, a live transcript, a prompt box, and
//! overlays for creating sessions, picking models and modes, confirming
//! destructive actions, answering permissions, and help.
//!
//! Keys (also shown with `?`)
//!   Enter        send prompt        Ctrl-s   send as steer (interrupt)
//!   Ctrl-t / n   new session        Ctrl-x   cancel turn
//!   Ctrl-n/p     next / prev        Tab      focus sidebar
//!   Ctrl-l       pick model         Ctrl-o   pick mode
//!   :            command mode       ?        help
//!   y / n / 1-9  answer permission  Ctrl-q   quit (agents keep running)

mod commands;
pub mod dialog;
pub mod editor;
mod keys;
mod mouse;
mod picker;
pub mod render;
pub mod scroll;
mod session_ops;
pub mod theme;

pub use mouse::{ButtonAction, PermChoice};
pub use picker::{PickRow, Picker};

use crate::client::Client;
use crate::rpc::{Message, method};
use crate::transcript::{Item, Transcript};
use anyhow::Result;
use crossterm::event::{Event, EventStream, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
use futures_util::StreamExt;
use ratatui::layout::Rect;
use editor::Editor;
use render::{SelectMode, Selection, draw, word_bounds};
use scroll::Viewport;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Instant;
use theme::Chrome;
use tokio::sync::mpsc;

/// Screen rects from the last frame, for mouse hit testing.
#[derive(Debug, Default, Clone, Copy)]
pub struct Areas {
    pub sidebar: Rect,
    /// The sidebar's right rule; dragging it resizes the sidebar.
    pub sidebar_rule: Rect,
    pub transcript: Rect,
    pub composer: Rect,
    pub status: Rect,
}

pub(super) const WHEEL_ROWS: isize = 3;
pub(super) const MULTI_CLICK_MS: u128 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Input,
    Sidebar,
    Command,
    /// The transcript pane: j/k scroll, Enter or Esc returns to the composer.
    Transcript,
}

/// A modal layer drawn over the main screen. Only one at a time.
pub enum Overlay {
    None,
    Help,
    /// Add a remote daemon over ssh: one text field.
    AddHost { text: Editor },
    /// Change the working directory: one text field. On a live session this
    /// forks into a new draft, since a running agent cannot move.
    Directory { text: Editor },
    NewSession(NewForm),
    Picker(Picker),
    Confirm { title: String, action: ConfirmAction },
}

#[derive(Debug, Clone)]
pub enum ConfirmAction {
    Kill { id: String, purge: bool },
}

pub struct NewForm {
    pub agents: Vec<String>,
    pub agent: usize,
    pub name: String,
    pub cwd: String,
    pub policy: usize,
    pub prompt: String,
    /// 0 agent, 1 name, 2 directory, 3 permissions, 4 first message
    pub field: usize,
}

/// A pending session: shown in the sidebar, created on first send.
#[derive(Debug, Clone)]
pub struct Draft {
    pub id: u64,
    /// Create on this peer daemon instead of the local one.
    pub peer: Option<String>,
    pub agent: String,
    pub cwd: String,
    pub policy: String,
    pub model: Option<String>,
    pub creating: bool,
    /// The message typed so far, kept when switching between drafts.
    pub text: Editor,
    /// Failures while creating this draft, shown in red under the summary.
    pub errors: Vec<String>,
}

pub const POLICIES: [&str; 4] = ["ask", "approve-reads", "approve-all", "deny-all"];

#[derive(Debug, Clone)]
pub enum PickTarget {
    /// Session id. A model row from another harness forks into a draft.
    Model(Option<String>),
    Mode(String),
    /// Permission policy for a live session (Some) or the current draft (None).
    Policy(Option<String>),
    /// session id, config id
    Config(String, String),
    Agent,
}

pub(super) enum AppMsg {
    DraftFailed,
    Models(Value),
    Sessions(Vec<Value>),
    Attached { id: String, detail: Value, events: Vec<Value> },
    Agents(Vec<String>, Option<String>),
    Status(Value),
    Info(String),
    Error(String),
    Created(String),
}

pub struct App {
    pub(super) client: Arc<Client>,
    pub(super) tx: mpsc::UnboundedSender<AppMsg>,
    pub sessions: Vec<Value>,
    pub selected: usize,
    pub transcripts: HashMap<String, Transcript>,
    pub(super) details: HashMap<String, Value>,
    pub(super) attached: HashSet<String>,
    pub input: Editor,
    pub command: String,
    /// Not-yet-created sessions shown as the top sidebar rows, newest first.
    /// Each is created on its first Enter, with that message.
    pub drafts: Vec<Draft>,
    pub(super) next_draft_id: u64,
    pub focus: Focus,
    pub overlay: Overlay,
    /// The new-session form is parked here while its agent picker is open.
    pub(super) parked_form: Option<Overlay>,
    pub status: String,
    pub web_url: Option<String>,
    /// Peers as reported by the daemon: name, connected, session count.
    pub hosts: Vec<(String, bool, u64)>,
    /// Sidebar filter: None = every host, Some("local") or Some(peer name).
    pub host_filter: Option<String>,
    /// Clickable host chips drawn last frame.
    pub host_chips: Vec<(Rect, Option<String>)>,
    pub(super) agents: Vec<String>,
    pub(super) default_agent: Option<String>,
    pub show_thoughts: bool,
    pub(super) quit: bool,
    pub(super) pending_select: Option<String>,
    pub(super) initial_empty_checked: bool,
    pub tick: u64,
    pub chrome: Chrome,
    pub areas: Areas,
    /// Per-session transcript viewport.
    pub viewport: HashMap<String, Viewport>,
    /// Scroll state for whichever dialog is open.
    pub dialog: dialog::DialogState,
    /// Sidebar width override from a drag or Alt-arrows.
    pub sidebar_width: Option<u16>,
    /// Alt-s / `:sidebar` hides the sidebar, like cmux's toggle.
    pub sidebar_hidden: bool,
    /// Unread cues per session id, cmux-style: 1 info (turn ended),
    /// 2 warning (permission waiting), 3 error. Cleared when selected.
    pub attention: HashMap<String, u8>,
    /// (mouse x at press, width at press) while the rule is dragged.
    pub sidebar_drag: Option<(u16, u16)>,
    /// Discriminant of the overlay drawn last frame, to reset dialog scroll on change.
    pub last_overlay: u8,
    pub hover: Option<(u16, u16)>,
    pub selection: Option<Selection>,
    /// Plain text of the rows drawn last frame, for copy.
    pub rows_cache: Vec<String>,
    /// Sidebar rows drawn last frame: (rect, session index).
    pub sidebar_rows: Vec<(Rect, usize)>,
    pub sidebar_offset: usize,
    pub toast: Option<(String, Instant)>,
    pub(super) last_click: Option<(Instant, u16, u16, u8)>,
    pub(super) pointer_shape: bool,
    /// Clickable dialog buttons drawn last frame.
    pub buttons: Vec<(Rect, ButtonAction)>,
    /// Clickable permission option rows drawn last frame.
    pub perm_rows: Vec<(Rect, ButtonAction)>,
    /// The current dialog's rect; a click outside it closes the dialog.
    pub dialog_rect: Rect,
}

pub(super) const DEFAULT_STATUS: &str = "Enter send · Ctrl-t new · Ctrl-x cancel · Ctrl-l model · Ctrl-o mode · : cmd · ? help · Ctrl-q quit";

impl App {
    /// True when the sidebar selection is a draft row.
    pub fn on_draft(&self) -> bool {
        self.selected < self.drafts.len()
    }
    /// Show an error where the user is looking: red in the status bar, and
    /// as a red row in the current transcript (or under the draft summary).
    pub(super) fn report_error(&mut self, e: String) {
        self.status = format!("error: {e}");
        if let Some(d) = self.draft_mut() {
            d.errors.push(e);
        } else if let Some(id) = self.selected_id() {
            self.transcripts.entry(id).or_default().items.push(crate::transcript::Item::Error { text: e });
        }
    }

    pub fn draft(&self) -> Option<&Draft> {
        self.drafts.get(self.selected)
    }
    pub(super) fn draft_mut(&mut self) -> Option<&mut Draft> {
        let i = self.selected;
        self.drafts.get_mut(i)
    }
    /// Index into `sessions` for the current selection, or None on a draft.
    pub(super) fn session_index(&self) -> Option<usize> {
        self.selected.checked_sub(self.drafts.len())
    }
    pub(super) fn selected_session(&self) -> Option<&Value> {
        self.session_index().and_then(|i| self.sessions.get(i))
    }
    /// Number of sidebar rows: drafts plus sessions.
    pub(super) fn row_count(&self) -> usize {
        self.sessions.len() + self.drafts.len()
    }
    /// True when a session (or draft peer) belongs to the filtered host.
    pub fn host_matches(&self, peer: Option<&str>) -> bool {
        match self.host_filter.as_deref() {
            None => true,
            Some("local") => peer.is_none(),
            Some(h) => peer == Some(h),
        }
    }
    pub fn set_host_filter(&mut self, filter: Option<String>) {
        self.host_filter = filter;
        let visible: Vec<usize> = (0..self.row_count()).filter(|&i| self.row_visible(i)).collect();
        if !visible.contains(&self.selected) {
            if let Some(&i) = visible.first() {
                self.select(i);
            }
        }
    }
    pub fn row_visible(&self, i: usize) -> bool {
        if i < self.drafts.len() {
            self.host_matches(self.drafts[i].peer.as_deref())
        } else {
            self.sessions
                .get(i - self.drafts.len())
                .map(|s| self.host_matches(s.get("peer").and_then(Value::as_str)))
                .unwrap_or(false)
        }
    }
    /// The editor for the current row: a draft's own, or the shared one.
    pub fn editor(&self) -> &Editor {
        match self.draft() {
            Some(d) => &d.text,
            None => &self.input,
        }
    }
    pub fn editor_mut(&mut self) -> &mut Editor {
        if self.on_draft() {
            let i = self.selected;
            &mut self.drafts[i].text
        } else {
            &mut self.input
        }
    }
    pub(super) fn selected_id(&self) -> Option<String> {
        self.selected_session()
            .and_then(|s| s.get("sessionId").and_then(Value::as_str))
            .map(str::to_owned)
    }
    pub(super) fn selected_name(&self) -> String {
        if let Some(d) = self.draft() {
            return match &d.peer {
                Some(p) => format!("new session · {p}/{}", d.agent),
                None => format!("new session · {}", d.agent),
            };
        }
        self.selected_session()
            .and_then(|s| s.get("name").and_then(Value::as_str))
            .unwrap_or("-")
            .to_owned()
    }

    pub(super) fn select(&mut self, idx: usize) {
        if self.row_count() == 0 {
            return;
        }
        self.selected = idx.min(self.row_count() - 1);
        self.selection = None;
        if let Some(id) = self.selected_id() {
            self.attention.remove(&id);
            if !self.attached.contains(&id) {
                self.attach(&id);
            }
        }
    }

    pub(super) fn attach(&mut self, id: &str) {
        self.attached.insert(id.to_owned());
        let client = self.client.clone();
        let tx = self.tx.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            match client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 3000})).await {
                Ok(v) => {
                    let events = v.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
                    let detail = v.get("session").cloned().unwrap_or(Value::Null);
                    let _ = tx.send(AppMsg::Attached { id, detail, events });
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::Error(format!("attach: {e}")));
                }
            }
        });
    }

    pub(super) fn refresh_sessions(&self) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            if let Ok(v) = client.request(method::MUX_SESSIONS, json!({})).await {
                let _ = tx.send(AppMsg::Sessions(v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default()));
            }
        });
    }

    pub(super) fn refresh_detail_later(&self, id: &str) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            if let Ok(v) = client.request(method::MUX_INFO, json!({"sessionId": id})).await {
                let _ = tx.send(AppMsg::Attached { id, detail: v, events: vec![] });
            }
        });
    }

    pub(super) fn request_bg(&self, m: &'static str, params: Value, ok_msg: Option<String>) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            match client.request(m, params).await {
                Ok(v) => {
                    if m == method::SESSION_NEW || m == method::SESSION_FORK || m == method::MUX_IMPORT {
                        if let Some(id) = v.get("sessionId").and_then(Value::as_str) {
                            let _ = tx.send(AppMsg::Created(id.to_owned()));
                        }
                    }
                    if let Some(msg) = ok_msg {
                        let _ = tx.send(AppMsg::Info(msg));
                    }
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::Error(e.to_string()));
                }
            }
        });
    }

    pub(super) fn send_prompt(&mut self, steer: bool) {
        if self.editor().text().trim().is_empty() {
            return;
        }
        if self.on_draft() {
            let text = self.editor_mut().take().trim().to_owned();
            self.create_from_draft(text);
            return;
        }
        let Some(id) = self.selected_id() else {
            self.status = "no session selected (Ctrl-t creates one)".into();
            return;
        };
        let text = self.input.take().trim().to_owned();
        if let Some(id) = self.selected_id() {
            self.viewport.entry(id).or_default().to_bottom();
        }
        if !steer {
            if let Some(t) = self.transcripts.get_mut(&id) {
                t.status = "running".into();
            }
        }
        let params = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"steer": steer}}});
        self.request_bg(method::SESSION_PROMPT, params, None);
    }

    pub(super) fn cancel(&mut self) {
        if let Some(id) = self.selected_id() {
            let client = self.client.clone();
            tokio::spawn(async move {
                let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
            });
            self.status = "cancel sent".into();
        }
    }

    pub(super) fn answer_permission(&mut self, choice: PermChoice) {
        let Some(id) = self.selected_id() else { return };
        let Some(t) = self.transcripts.get(&id) else { return };
        let Some(Item::Permission { id: pid, options, .. }) = t.pending_permission() else {
            self.status = "no pending permission".into();
            return;
        };
        let option_id = match choice {
            PermChoice::Index(i) => options.get(i).map(|o| o.0.clone()),
            PermChoice::Allow => options
                .iter()
                .find(|o| o.2 == "allow_once")
                .or_else(|| options.iter().find(|o| o.2.starts_with("allow")))
                .map(|o| o.0.clone()),
            PermChoice::Deny => options
                .iter()
                .find(|o| o.2 == "reject_once")
                .or_else(|| options.iter().find(|o| o.2.starts_with("reject")))
                .map(|o| o.0.clone()),
        };
        let Some(option_id) = option_id else {
            self.status = "that option does not exist".into();
            return;
        };
        let pid = pid.clone();
        self.request_bg(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": option_id}),
            None,
        );
    }

}

impl App {
    // --------------------------------------------------------- inbound

    pub(super) fn on_notification(&mut self, m: &str, p: Value) {
        let sid = p.get("sessionId").and_then(Value::as_str).map(str::to_owned);
        match m {
            method::SESSION_UPDATE => {
                if let Some(id) = sid {
                    self.transcripts.entry(id).or_default().apply_update(&p);
                }
            }
            method::MUX_EVENT => {
                if let Some(id) = sid {
                    let kind = p.get("kind").and_then(Value::as_str).unwrap_or("");
                    let level = match kind { "turn_error" => 3, "turn_end" => 1, _ => 0 };
                    if level > 0 && self.selected_id().as_deref() != Some(&id) {
                        let e = self.attention.entry(id.clone()).or_insert(0);
                        *e = (*e).max(level);
                    }
                    self.transcripts.entry(id).or_default().apply_event(&p);
                }
            }
            method::MUX_SESSION_CHANGED => {
                if let Some(s) = p.get("session") {
                    let id = s.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
                    if let Some(slot) = self.sessions.iter_mut().find(|x| x.get("sessionId").and_then(Value::as_str) == Some(&id)) {
                        *slot = s.clone();
                    } else {
                        self.sessions.push(s.clone());
                    }
                    self.sort_sessions();
                }
            }
            method::MUX_PERMISSION_PENDING => {
                let title = p.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
                let who = sid
                    .as_deref()
                    .and_then(|id| self.sessions.iter().find(|s| s.get("sessionId").and_then(Value::as_str) == Some(id)))
                    .and_then(|s| s.get("name").and_then(Value::as_str))
                    .unwrap_or("?");
                self.status = format!("permission needed in {who}: {title}  (y / n / 1-9)");
                if let Some(id) = sid.clone() {
                    if self.selected_id().as_deref() != Some(&id) {
                        let e = self.attention.entry(id).or_insert(0);
                        *e = (*e).max(2);
                    }
                }
            }
            "_acpmux/lagged" => self.status = "event stream lagged; reattach with Enter on the session".into(),
            _ => {}
        }
    }

    pub(super) fn sort_sessions(&mut self) {
        let selected_id = self.selected_id();
        self.sessions.sort_by(|a, b| {
            let ua = a.get("updatedAt").and_then(Value::as_u64).unwrap_or(0);
            let ub = b.get("updatedAt").and_then(Value::as_u64).unwrap_or(0);
            ub.cmp(&ua)
        });
        if let Some(id) = selected_id {
            if let Some(i) = self.sessions.iter().position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id)) {
                self.selected = i + self.drafts.len();
            }
        }
    }

    pub(super) fn on_msg(&mut self, msg: AppMsg) {
        match msg {
            AppMsg::Sessions(list) => {
                let had = !self.sessions.is_empty();
                self.sessions = list;
                self.sort_sessions();
                if !had && !self.sessions.is_empty() && self.drafts.is_empty() {
                    self.select(0);
                }
            }
            AppMsg::Attached { id, detail, events } => {
                if events.is_empty() && self.transcripts.contains_key(&id) {
                    if let Some(t) = self.transcripts.get_mut(&id) {
                        t.mode = detail.get("currentModeId").and_then(Value::as_str).map(str::to_owned).or(t.mode.clone());
                        t.model = detail.get("model").and_then(Value::as_str).map(str::to_owned).or(t.model.clone());
                    }
                    self.details.insert(id, detail);
                    return;
                }
                let mut t = Transcript::default();
                for e in &events {
                    t.apply_event(e);
                }
                t.status = detail.get("status").and_then(Value::as_str).unwrap_or("").to_owned();
                t.mode = detail.get("currentModeId").and_then(Value::as_str).map(str::to_owned);
                t.model = detail.get("model").and_then(Value::as_str).map(str::to_owned);
                self.details.insert(id.clone(), detail);
                self.transcripts.insert(id, t);
            }
            AppMsg::Agents(list, default) => {
                self.agents = list;
                self.default_agent = default;
            }
            AppMsg::Status(v) => {
                self.web_url = v.get("webUrl").and_then(Value::as_str).map(str::to_owned);
                self.hosts = v
                    .get("peers")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(|p| (
                                p.get("name").and_then(Value::as_str).unwrap_or("").to_owned(),
                                p.get("connected").and_then(Value::as_bool).unwrap_or(false),
                                p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                            ))
                            .collect()
                    })
                    .unwrap_or_default();
            }
            AppMsg::Models(v) => self.show_model_picker(v),
            AppMsg::DraftFailed => {
                for d in self.drafts.iter_mut() {
                    d.creating = false;
                }
            }
            AppMsg::Info(s) => self.status = s,
            AppMsg::Error(e) => self.report_error(e),
            AppMsg::Created(id) => {
                self.refresh_sessions();
                self.attach(&id);
                self.pending_select = Some(id);
                self.status = DEFAULT_STATUS.into();
            }
        }
    }
}

pub async fn run(client: Arc<Client>, initial: Option<String>) -> Result<()> {
    let mut notes = client
        .notifications()
        .await
        .ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
    let (tx, mut rx) = mpsc::unbounded_channel::<AppMsg>();
    let watch = client.request(method::MUX_WATCH, json!({"enabled": true})).await?;
    let mut app = App {
        client: client.clone(),
        tx: tx.clone(),
        sessions: watch.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default(),
        selected: 0,
        transcripts: HashMap::new(),
        details: HashMap::new(),
        attached: HashSet::new(),
        input: Editor::default(),
        command: String::new(),
        drafts: Vec::new(),
        next_draft_id: 1,
        focus: Focus::Input,
        overlay: Overlay::None,
        parked_form: None,
        status: DEFAULT_STATUS.into(),
        web_url: None,
        hosts: Vec::new(),
        host_filter: None,
        host_chips: Vec::new(),
        agents: Vec::new(),
        default_agent: None,
        show_thoughts: false,
        quit: false,
        pending_select: None,
        initial_empty_checked: false,
        tick: 0,
        chrome: Chrome::detect(),
        areas: Areas::default(),
        viewport: HashMap::new(),
        dialog: dialog::DialogState::default(),
        sidebar_width: None,
        sidebar_hidden: false,
        attention: HashMap::new(),
        sidebar_drag: None,
        last_overlay: 0,
        hover: None,
        selection: None,
        rows_cache: Vec::new(),
        sidebar_rows: Vec::new(),
        sidebar_offset: 0,
        toast: None,
        last_click: None,
        pointer_shape: false,
        buttons: Vec::new(),
        perm_rows: Vec::new(),
        dialog_rect: Rect::default(),
    };
    app.sort_sessions();
    {
        let c = client.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            if let Ok(v) = c.request(method::MUX_AGENTS, json!({})).await {
                let names: Vec<String> = v.get("agents").and_then(Value::as_object).map(|o| o.keys().cloned().collect()).unwrap_or_default();
                let _ = tx.send(AppMsg::Agents(names, v.get("defaultAgent").and_then(Value::as_str).map(str::to_owned)));
            }
            if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await {
                let _ = tx.send(AppMsg::Status(v));
            }
        });
    }
    if let Some(id) = initial {
        if let Some(i) = app.sessions.iter().position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id)) {
            app.select(i);
        }
    } else if !app.sessions.is_empty() {
        app.select(0);
    }

    let mut terminal = ratatui::init();
    let _ = crossterm::execute!(
        std::io::stdout(),
        crossterm::event::EnableMouseCapture,
        crossterm::event::EnableBracketedPaste,
        crossterm::event::EnableFocusChange,
        crossterm::event::PushKeyboardEnhancementFlags(crossterm::event::KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
    );
    let mut events = EventStream::new();
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(250));
    let result: Result<()> = loop {
        // First paint with no sessions: open the form so the empty screen is not a dead end.
        if !app.initial_empty_checked && !app.agents.is_empty() {
            app.initial_empty_checked = true;
            if app.sessions.is_empty() && matches!(app.overlay, Overlay::None) {
                app.open_new_session();
            }
        }
        if let Err(e) = terminal.draw(|f| draw(f, &mut app)) {
            break Err(e.into());
        }
        tokio::select! {
            ev = events.next() => {
                match ev {
                    Some(Ok(Event::Key(k))) if k.kind != crossterm::event::KeyEventKind::Release => app.on_key(k),
                    Some(Ok(Event::Mouse(m))) => app.on_mouse(m),
                    Some(Ok(Event::Paste(s))) => {
                        match &mut app.overlay {
                            Overlay::NewSession(f) => match f.field {
                                2 => f.cwd.push_str(s.trim()),
                                4 => f.prompt.push_str(&s),
                                1 => f.name.push_str(s.trim()),
                                _ => {}
                            },
                            _ => app.editor_mut().insert_str(&s),
                        }
                    }
                    Some(Err(e)) => break Err(e.into()),
                    None => break Ok(()),
                    _ => {}
                }
            }
            n = notes.recv() => {
                match n {
                    Some(Message::Notification { method: m, params }) => app.on_notification(&m, params.unwrap_or(Value::Null)),
                    Some(_) => {}
                    None => { app.status = "daemon connection closed".into(); break Ok(()); }
                }
            }
            m = rx.recv() => {
                if let Some(m) = m { app.on_msg(m); }
            }
            _ = tick.tick() => {
                app.tick = app.tick.wrapping_add(1);
                if app.tick % 16 == 0 {
                    let c = client.clone();
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await {
                            let _ = tx.send(AppMsg::Status(v));
                        }
                    });
                }
                if let Some((_, at)) = &app.toast {
                    if at.elapsed().as_millis() > 1800 {
                        app.toast = None;
                    }
                }
            }
        }
        if let Some(id) = app.pending_select.take() {
            if let Some(i) = app.sessions.iter().position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id)) {
                app.drafts.retain(|d| !d.creating);
                app.select(i + app.drafts.len());
                app.focus = Focus::Input;
            } else {
                app.pending_select = Some(id);
            }
        }
        if app.quit {
            break Ok(());
        }
    };
    app.set_pointer(false);
    let _ = crossterm::execute!(
        std::io::stdout(),
        crossterm::event::PopKeyboardEnhancementFlags,
        crossterm::event::DisableFocusChange,
        crossterm::event::DisableBracketedPaste,
        crossterm::event::DisableMouseCapture
    );
    ratatui::restore();
    if let Some(u) = &app.web_url {
        println!("acpmux: agents keep running. Web dashboard: {u}");
    }
    result
}
