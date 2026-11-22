//! Terminal UI: a session sidebar, a live transcript, a prompt box, and
//! overlays for creating sessions, picking models and modes, confirming
//! destructive actions, answering permissions, and help.
//!
//! Keys (also shown with `?`)
//!   Enter        send prompt        Ctrl-s   send as steer (interrupt)
//!   Ctrl-t / n   new session        Ctrl-g   cancel turn
//!   Ctrl-n/p     next / prev        Tab      focus sidebar
//!   Ctrl-l       pick model         Ctrl-o   pick mode
//!   :            command mode       ?        help
//!   y / n / 1-9  answer permission  Ctrl-q   quit (agents keep running)
//!   (on a question, y opens the answer flow: digits pick, Enter confirms)

pub mod actions;
mod answering;
mod events;
mod run;
mod scheduler;
mod state;
mod terminal;
pub use run::run;
pub use state::*;
mod collapse;
pub mod dialog;
pub mod editor;
mod keys;
pub mod links;
pub mod menu;
mod mouse;
pub mod notify;
mod picker;
pub mod render;
pub use menu::{Menu, MenuAction};
pub(crate) mod directory;
mod keymap;
pub mod markdown;
pub mod scroll;
mod session_ops;
pub mod shimmer;
pub mod skills;
pub mod theme;

pub use actions::Action;
pub use answering::Answering;
pub use mouse::{ButtonAction, PermChoice};
pub use picker::{PickRow, Picker};

use crate::client::Client;
use crate::rpc::{Message, method};
use crate::transcript::{Item, Transcript};
use anyhow::Result;
use crossterm::event::{
    Event, EventStream, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use editor::Editor;
use futures_util::StreamExt;
use ratatui::layout::Rect;
use render::{SelectMode, Selection, word_bounds};
use scroll::Viewport;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Instant;
use theme::Chrome;
use tokio::sync::mpsc;

/// What `App::request_then` re-reads once the request's reply arrived.
pub(super) enum Reread {
    Nothing,
    /// The session's detail (mode, model, config options).
    Detail(String),
    /// The session list (policy and other summary fields).
    Sessions,
    /// Daemon status (hosts and their connection state).
    Status,
}

impl Reread {
    async fn run(self, client: &Arc<Client>, tx: &mpsc::UnboundedSender<AppMsg>) {
        match self {
            Reread::Nothing => {}
            Reread::Detail(id) => {
                if let Ok(v) = client.request(method::MUX_INFO, json!({"sessionId": id})).await {
                    let _ = tx.send(AppMsg::Attached { id, detail: v, events: vec![] });
                }
            }
            Reread::Sessions => {
                if let Ok(v) = client.request(method::MUX_SESSIONS, json!({})).await {
                    let _ = tx.send(AppMsg::Sessions(
                        v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default(),
                    ));
                }
            }
            Reread::Status => {
                if let Ok(v) = client.request(method::MUX_STATUS, json!({})).await {
                    let _ = tx.send(AppMsg::Status(v));
                }
            }
        }
    }
}

/// Screen rects from the last frame, for mouse hit testing.
pub struct App {
    pub(super) client: Arc<Client>,
    pub(super) tx: mpsc::UnboundedSender<AppMsg>,
    pub sessions: Vec<Value>,
    pub selected: usize,
    pub transcripts: HashMap<String, Transcript>,
    pub(super) details: HashMap<String, Value>,
    pub(super) attached: HashSet<String>,
    pub input: Editor,
    pub input_images: Vec<PromptImage>,
    pub command: Editor,
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
    pub(super) harnesses: Vec<String>,
    pub(super) default_harness: Option<String>,
    pub(super) model_picker_current_only: bool,
    pub(super) skills: Vec<skills::Skill>,
    pub(super) palette_prefix: String,
    pub(super) palette_aliases: Vec<String>,
    pub(super) skill_prefix: String,
    pub(super) keymap: keymap::Keymap,
    pub(super) skill_paths: Vec<String>,
    pub show_thoughts: bool,
    /// Show lifecycle events (stopped, resumed, renamed, model set…).
    pub show_system: bool,
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
    /// A mouse button went down with the context menu open (or opened it):
    /// the item under the pointer runs on release, so press, drag, release
    /// picks like a native menu. A release over no item leaves the menu open.
    pub menu_pressed: bool,
    pub selection: Option<Selection>,
    /// Plain text of the rows drawn last frame, for copy.
    pub rows_cache: Vec<String>,
    pub(crate) transcript_cache: render::TranscriptCache,
    /// Per row: (item index, is a collapsible header). Parallel to `rows_cache`.
    pub row_meta: Vec<(usize, Option<Toggle>)>,
    pub transcript_hitboxes: Vec<(Rect, usize)>,
    /// (session, absolute row, screen row) keeps an accordion header fixed
    /// while its children are inserted or removed.
    pub transcript_anchor: Option<(String, usize, usize)>,
    /// Collapsibles flipped from their default, per session id.
    pub toggled: HashMap<String, std::collections::HashSet<Toggle>>,
    /// Composer mouse selection as (anchor, head) char offsets.
    pub composer_sel: Option<(usize, usize)>,
    /// Direction (-1/1) while a transcript drag sits past an edge; the tick scrolls.
    pub drag_autoscroll: Option<isize>,
    /// Most composer rows before it scrolls.
    pub composer_max_rows: u16,
    /// Hyperlink metadata for the terminal backend cell diff.
    pub link_cells: Vec<links::LinkCell>,
    /// Cursor position selected by the active editor.
    pub cursor_pos: Option<(u16, u16)>,
    /// Sidebar rows drawn last frame: (rect, session index).
    pub sidebar_rows: Vec<(Rect, usize)>,
    /// Project groups the user opened past their first rows ("Show more").
    pub expanded_groups: std::collections::HashSet<String>,
    /// Sidebar rows in the order drawn (absolute indexes), so stepping the
    /// selection follows the grouped list, not recency.
    pub sidebar_order: Vec<usize>,
    pub sidebar_nav: Vec<SidebarNav>,
    pub sidebar_nav_pos: usize,
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
    /// The open answer flow of a pending agent question (answering.rs).
    pub answering: Option<Answering>,
}

pub(super) const DEFAULT_STATUS: &str = "";

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
            self.transcripts
                .entry(id)
                .or_default()
                .items
                .push(crate::transcript::Item::Error { text: e });
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
    /// Move the selection by `delta` rows of the drawn sidebar order.
    pub(super) fn select_step(&mut self, delta: isize) {
        if self.sidebar_nav.is_empty() {
            let next = if delta > 0 { self.selected + 1 } else { self.selected.saturating_sub(1) };
            self.select(next);
            return;
        }
        let current = self
            .sidebar_nav
            .iter()
            .position(|item| matches!(item, SidebarNav::Session(i) if *i == self.selected))
            .unwrap_or(self.sidebar_nav_pos);
        let next =
            (current as isize + delta).clamp(0, self.sidebar_nav.len() as isize - 1) as usize;
        self.sidebar_nav_pos = next;
        match self.sidebar_nav[next].clone() {
            SidebarNav::Session(idx) => self.select(idx),
            SidebarNav::ShowMore(group) => {
                self.expanded_groups.insert(group);
                self.status = "expanded project sessions".into();
            }
        }
    }

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
        if !visible.contains(&self.selected)
            && let Some(&i) = visible.first()
        {
            self.select(i);
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

    pub fn prompt_images(&self) -> &[PromptImage] {
        self.draft().map(|d| d.images.as_slice()).unwrap_or(&self.input_images)
    }

    fn take_prompt_images(&mut self) -> Vec<PromptImage> {
        if self.on_draft() {
            std::mem::take(&mut self.drafts[self.selected].images)
        } else {
            std::mem::take(&mut self.input_images)
        }
    }

    fn prompt_blocks(text: &str, images: &[PromptImage]) -> Vec<Value> {
        let mut blocks = Vec::with_capacity(images.len() + usize::from(!text.is_empty()));
        if !text.is_empty() {
            blocks.push(json!({"type": "text", "text": text}));
        }
        blocks.extend(images.iter().map(|image| json!({"type": "image", "mimeType": image.mime_type, "data": image.data, "name": image.name})));
        blocks
    }

    pub(super) fn paste_images(&mut self, pasted: &str) -> bool {
        let mut found = Vec::new();
        let mut tokens = Vec::new();
        for line in pasted.lines() {
            let whole = line.trim().trim_matches(|c| matches!(c, '"' | '\'' | '`'));
            let whole_path = whole.strip_prefix("file://").unwrap_or(whole);
            if std::path::Path::new(whole_path).is_file() {
                tokens.push(whole.to_owned());
            } else {
                tokens.extend(line.split_whitespace().map(str::to_owned));
            }
        }
        for token in tokens {
            let token = token.trim_matches(|c| matches!(c, '"' | '\'' | '`'));
            let path = token.strip_prefix("file://").unwrap_or(token);
            let path = if path.starts_with("localhost/") { &path[9..] } else { path };
            let path = std::path::Path::new(path);
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
            let mime = match ext.as_str() {
                "png" => "image/png",
                "jpg" | "jpeg" => "image/jpeg",
                "gif" => "image/gif",
                "webp" => "image/webp",
                "bmp" => "image/bmp",
                "tif" | "tiff" => "image/tiff",
                "svg" => "image/svg+xml",
                _ => continue,
            };
            let Ok(meta) = std::fs::metadata(path) else { continue };
            if !meta.is_file() || meta.len() > 8 * 1024 * 1024 {
                continue;
            }
            let Ok(bytes) = std::fs::read(path) else { continue };
            use base64::Engine;
            found.push(PromptImage {
                name: path.file_name().and_then(|n| n.to_str()).unwrap_or("image").to_owned(),
                mime_type: mime.to_owned(),
                data: base64::engine::general_purpose::STANDARD.encode(bytes),
            });
        }
        if found.is_empty() {
            return false;
        }
        if self.on_draft() {
            self.drafts[self.selected].images.extend(found);
        } else {
            self.input_images.extend(found);
        }
        let count = self.prompt_images().len();
        self.status = format!("{count} image{} attached", if count == 1 { "" } else { "s" });
        true
    }
    pub(super) fn selected_id(&self) -> Option<String> {
        self.selected_session()
            .and_then(|s| s.get("sessionId").and_then(Value::as_str))
            .map(str::to_owned)
    }
    pub(super) fn selected_name(&self) -> String {
        if let Some(d) = self.draft() {
            return match &d.peer {
                Some(p) => format!("new session · {p}/{}", d.harness),
                None => format!("new session · {}", d.harness),
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
        self.transcript_anchor = None;
        if let Some(pos) = self
            .sidebar_nav
            .iter()
            .position(|item| matches!(item, SidebarNav::Session(i) if *i == self.selected))
        {
            self.sidebar_nav_pos = pos;
        }
        self.selection = None;
        if let Some(id) = self.selected_id() {
            self.attention.remove(&id);
            if !self.attached.contains(&id) {
                self.attach(&id);
            }
        }
    }

    /// Re-ask the daemon for harnesses and status (after a reconnect).
    pub(super) fn refresh_harnesses(&mut self) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            if let Ok(v) = client.request(method::MUX_HARNESSES, json!({})).await {
                let names: Vec<String> = v
                    .get("harnesses")
                    .and_then(Value::as_object)
                    .map(|o| o.keys().cloned().collect())
                    .unwrap_or_default();
                let _ = tx.send(AppMsg::Agents(
                    names,
                    v.get("defaultHarness").and_then(Value::as_str).map(str::to_owned),
                ));
            }
            if let Ok(v) = client.request(method::MUX_STATUS, json!({})).await {
                let _ = tx.send(AppMsg::Status(v));
            }
        });
    }

    pub(super) fn attach(&mut self, id: &str) {
        self.attached.insert(id.to_owned());
        let client = self.client.clone();
        let tx = self.tx.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            match client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 3000})).await
            {
                Ok(v) => {
                    let events =
                        v.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
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
                let _ = tx.send(AppMsg::Sessions(
                    v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default(),
                ));
            }
        });
    }

    pub(super) fn request_bg(&self, m: &'static str, params: Value, ok_msg: Option<String>) {
        // Shares `request_then`, which re-reads nothing here.
        self.request_then(m, params, ok_msg, Reread::Nothing);
    }

    /// `request_bg`, then re-read what the request changed once its reply
    /// arrived. The daemon applies a mode, model, config or policy change
    /// before it replies, so no timer is needed.
    pub(super) fn request_then(
        &self,
        m: &'static str,
        params: Value,
        ok_msg: Option<String>,
        reread: Reread,
    ) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let ok = Self::run_request(&client, &tx, m, params, ok_msg).await;
            if ok {
                reread.run(&client, &tx).await;
            }
        });
    }

    async fn run_request(
        client: &Arc<Client>,
        tx: &mpsc::UnboundedSender<AppMsg>,
        m: &'static str,
        params: Value,
        ok_msg: Option<String>,
    ) -> bool {
        {
            match client.request(m, params).await {
                Ok(v) => {
                    if (m == method::SESSION_NEW
                        || m == method::SESSION_FORK
                        || m == method::MUX_IMPORT)
                        && let Some(id) = v.get("sessionId").and_then(Value::as_str)
                    {
                        let _ = tx.send(AppMsg::Created(id.to_owned()));
                    }
                    if let Some(msg) = ok_msg {
                        let _ = tx.send(AppMsg::Info(msg));
                    }
                    true
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::Error(e.to_string()));
                    false
                }
            }
        }
    }

    pub(super) fn send_prompt(&mut self, steer: bool) {
        if self.editor().text().trim().is_empty() && self.prompt_images().is_empty() {
            return;
        }
        let raw = self.editor().text().trim().to_owned();
        if !steer && let Some(arg) = directory::cd_argument(&raw) {
            self.open_directory_dialog_at(arg.to_owned());
            return;
        }
        let text = if !self.remote_directory() && raw.contains(&self.skill_prefix) {
            self.skills = skills::Skill::discover(
                std::path::Path::new(&self.current_directory()),
                &self.skill_paths,
            );
            match skills::expand(&raw, &self.skills, &self.skill_prefix) {
                Ok(text) => text,
                Err(e) => {
                    self.report_error(format!("Skill: {e}"));
                    return;
                }
            }
        } else {
            raw
        };

        let images = self.take_prompt_images();
        if self.on_draft() {
            self.create_from_draft(text, images);
            return;
        }
        let Some(id) = self.selected_id() else {
            self.status = "no session selected (Ctrl-t creates one)".into();
            return;
        };
        self.input.take();
        if let Some(id) = self.selected_id() {
            self.viewport.entry(id).or_default().to_bottom();
        }
        // Show the message at once; the daemon's echo is matched, not added.
        if let Some(t) = self.transcripts.get_mut(&id) {
            let queued = t.status == "running" && !steer;
            let shown = if images.is_empty() {
                text.clone()
            } else if text.is_empty() {
                format!(
                    "[image: {}]",
                    images.iter().map(|i| i.name.as_str()).collect::<Vec<_>>().join(", ")
                )
            } else {
                format!(
                    "{text}\n[image: {}]",
                    images.iter().map(|i| i.name.as_str()).collect::<Vec<_>>().join(", ")
                )
            };
            t.items.push(crate::transcript::Item::User { text: shown, steer, queued });
            t.optimistic.push(text.clone());
            if !steer && !queued {
                t.status = "running".into();
            }
        }
        let params = json!({"sessionId": id, "prompt": Self::prompt_blocks(&text, &images), "_meta": {"acpmux": {"steer": steer}}});
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
        // A question is answered through its flow, never by a blank allow.
        if self.question_choice(&choice) {
            return;
        }
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

#[cfg(test)]
mod answering_tests;
#[cfg(test)]
mod interaction_tests {
    use super::*;
    pub(super) async fn app() -> (App, mpsc::UnboundedReceiver<Value>) {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        let socket = std::env::temp_dir().join(format!("acpmux-ui-{}.sock", uuid::Uuid::now_v7()));
        let _ = std::fs::remove_file(&socket);
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let (sent, requests) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = stream.into_split();
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let msg: Value = serde_json::from_str(&line).unwrap();
                let _ = sent.send(msg.clone());
                let result = if msg["method"] == "session/new" {
                    json!({"sessionId":"test-session"})
                } else {
                    json!({})
                };
                let reply =
                    json!({"jsonrpc":"2.0","id":msg["id"],"result":result}).to_string() + "\n";
                if writer.write_all(reply.as_bytes()).await.is_err() {
                    break;
                }
            }
        });
        let client = Client::connect(&socket).await.unwrap();
        let _ = std::fs::remove_file(socket);
        let (tx, _) = mpsc::unbounded_channel();
        let mut app = run::make_app(client, tx, vec![], crate::config::Config::default()).unwrap();
        app.default_harness = Some("codex".into());
        app.harnesses = vec!["codex".into(), "claude".into()];
        app.open_draft();
        (app, requests)
    }
    #[tokio::test]
    async fn refreshed_peer_harness_is_searchable_and_selectable() {
        let (mut app, _) = app().await;
        app.show_harness_picker(json!({"harnesses":[{"harness":"providers/deepseek"},{"harness":"providers/opencode-v2"}]}));
        if let Overlay::Picker(ref mut picker) = app.overlay {
            picker.filter.insert_str("deepseek harness");
            picker.refilter();
            assert_eq!(picker.visible.len(), 1);
            assert_eq!(picker.selected().unwrap().value, "providers/deepseek");
        } else {
            panic!("harness picker missing");
        }
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        let draft = app.draft().unwrap();
        assert_eq!(draft.peer.as_deref(), Some("providers"));
        assert_eq!(draft.harness, "deepseek");
    }

    #[tokio::test]
    async fn rendered_clicks_cd_and_chords_preserve_user_input() {
        let (mut app, mut requests) = app().await;
        let root = std::env::temp_dir().join(format!("acpmux-ui-dirs-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(root.join("My Project")).unwrap();
        app.draft_mut().unwrap().cwd = root.to_string_lossy().into_owned();
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(140, 40)).unwrap();
        terminal.draw(|f| render::draw(f, &mut app)).unwrap();
        let buttons = app.buttons.clone();
        let find = |a: ButtonAction| buttons.iter().find(|(_, b)| *b == a).unwrap().0;
        let harness = find(ButtonAction::DraftHarness);
        let model = find(ButtonAction::DraftModel);
        let policy = find(ButtonAction::DraftPolicy);
        assert!(harness.x + harness.width <= model.x && model.x + model.width <= policy.x);
        app.press(harness.x, harness.y, KeyModifiers::NONE);
        assert!(
            matches!(app.overlay, Overlay::Picker(ref p) if matches!(p.on_pick, PickTarget::DraftHarness))
        );
        app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        app.editor_mut().insert_str("cd 'My Project'");
        app.send_prompt(false);
        assert!(matches!(app.overlay, Overlay::Directory { .. }));
        terminal.draw(|f| render::draw(f, &mut app)).unwrap();
        assert!(!app.buttons.iter().any(|(_, b)| *b == ButtonAction::DraftHarness));
        app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        assert_eq!(app.editor().text(), "cd 'My Project'");
        app.send_prompt(false);
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert_eq!(
            app.current_directory(),
            std::fs::canonicalize(root.join("My Project")).unwrap().to_string_lossy()
        );
        assert!(app.editor().is_empty());
        app.editor_mut().insert_str("cd ..");
        app.send_prompt(false);
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert_eq!(
            app.current_directory(),
            std::fs::canonicalize(&root).unwrap().to_string_lossy()
        );
        app.on_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL));
        app.on_key(KeyEvent::new(KeyCode::Char('p'), KeyModifiers::NONE));
        assert!(matches!(app.overlay,Overlay::Picker(ref p) if p.title=="Commands"));
        app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        app.palette_prefix = ":".into();
        app.palette_aliases = vec![];
        app.on_key(KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE));
        assert_eq!(app.editor().text(), "/");
        app.editor_mut().clear();
        app.on_key(KeyEvent::new(KeyCode::Char(':'), KeyModifiers::NONE));
        assert!(matches!(app.overlay,Overlay::Picker(ref p) if p.title=="Commands"));
        app.on_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        let skill_dir = root.join(".agents/skills/acpmux-ui-test");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: UI test\ndescription: test only\n---\nCheck this test fixture.",
        )
        .unwrap();
        app.skill_prefix = "%".into();
        app.editor_mut().insert_str("Review with ");
        app.on_key(KeyEvent::new(KeyCode::Char('%'), KeyModifiers::NONE));
        assert!(
            matches!(app.overlay,Overlay::Picker(ref p) if p.rows.iter().any(|r|r.value=="acpmux-ui-test"))
        );
        app.overlay = Overlay::None;
        app.apply_pick(
            PickTarget::Skill { replace_prefix: true },
            "acpmux-ui-test".into(),
            String::new(),
        );
        assert_eq!(app.editor().text(), "Review with %acpmux-ui-test ");
        app.draft_mut().unwrap().model = Some("test-model".into());
        app.draft_mut().unwrap().effort = Some("high".into());
        app.send_prompt(false);
        let mut saw_new = false;
        loop {
            let msg = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
                .await
                .unwrap()
                .unwrap();
            if msg["method"] == "session/new" {
                assert_eq!(msg["params"]["_meta"]["acpmux"]["model"], "test-model");
                assert_eq!(msg["params"]["_meta"]["acpmux"]["effort"], "high");
                saw_new = true;
            }
            if msg["method"] == "session/prompt" {
                let text = msg["params"]["prompt"][0]["text"].as_str().unwrap();
                assert!(
                    saw_new
                        && text.contains("Check this test fixture.")
                        && text.contains("Base directory:")
                );
                break;
            }
        }
        app.drafts.clear();
        app.sessions = vec![json!({"sessionId":"test-session","harness":"fake","cwd":root})];
        app.selected = 0;
        let mut transcript = Transcript::default();
        transcript.available_commands = vec!["compact".into()];
        app.transcripts.insert("test-session".into(), transcript);
        app.open_palette();
        assert!(
            matches!(app.overlay,Overlay::Picker(ref p) if p.rows.iter().any(|r|r.value=="agent:/compact"))
        );
        app.overlay = Overlay::None;
        app.apply_pick(PickTarget::Action, "agent:/compact".into(), String::new());
        let msg = tokio::time::timeout(std::time::Duration::from_secs(5), requests.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(msg["method"], "session/prompt");
        assert_eq!(msg["params"]["prompt"][0]["text"], "/compact");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn dropped_image_becomes_an_acp_image_block() {
        let (mut app, _) = app().await;
        let path =
            std::env::temp_dir().join(format!("acpmux-ui-image-{}.png", uuid::Uuid::now_v7()));
        std::fs::write(&path, [137, 80, 78, 71]).unwrap();
        assert!(app.paste_images(&path.to_string_lossy()));
        assert_eq!(app.prompt_images().len(), 1);
        let blocks = App::prompt_blocks("look", app.prompt_images());
        assert_eq!(blocks[0]["type"], "text");
        assert_eq!(blocks[1]["type"], "image");
        assert_eq!(blocks[1]["mimeType"], "image/png");
        assert!(!blocks[1]["data"].as_str().unwrap().is_empty());
        std::fs::remove_file(path).unwrap();
    }
}
