//! Terminal UI: a session sidebar, a live transcript, a prompt box, and
//! overlays for creating sessions, picking models and modes, confirming
//! destructive actions, answering permissions, and help.
//!
//! Keys (also shown with `?`)
//!   Enter        send prompt; steers a running turn when the agent steers
//!   Ctrl-s       queue the prompt for after the running turn
//!   Ctrl-t / n   new session        Ctrl-g   cancel turn
//!   Ctrl-n/p     next / prev        Tab      focus sidebar
//!   Ctrl-l       pick model         Ctrl-o   pick mode
//!   :            command mode       ?        help
//!   y / n / 1-9  answer permission  Ctrl-q   quit (agents keep running)
//!   (on a question, y opens the answer flow: digits pick, Enter confirms)

use cmux_json::JsonSet as _;

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
#[cfg(all(test, unix))]
mod answering_tests;
pub(crate) mod directory;
mod keymap;
pub mod markdown;
#[cfg(all(test, unix))]
mod recovery_tests;
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

/// Keep lag recovery responsive even if a session has an unusually large
/// event log. Each page is capped by the daemon's attach limit below.
pub(super) const MAX_RECOVERY_PAGES: u8 = 8;

impl Reread {
    async fn run(self, client: &Arc<Client>, tx: &mpsc::UnboundedSender<AppMsg>) {
        match self {
            Reread::Nothing => {}
            Reread::Detail(id) => {
                if let Ok(v) = client.request(method::MUX_INFO, json!({"sessionId": id})).await {
                    let _ = tx.send(AppMsg::Attached {
                        id,
                        detail: v,
                        events: vec![],
                        after_seq: None,
                        has_more: false,
                        last_seq: 0,
                    });
                }
            }
            Reread::Sessions => {
                if let Ok(v) = client.whole_list(method::MUX_SESSIONS, json!({})).await {
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
    /// Sessions with a lag recovery request in flight. A broadcast lag can
    /// notify us more than once; only one replay page per session is in flight.
    pub(super) recovery_in_flight: HashSet<String>,
    /// Number of pages already requested for each lagged session.
    pub(super) recovery_pages: HashMap<String, u8>,
    /// Number of records accepted from the current lag recovery.
    pub(super) recovery_replayed: HashMap<String, usize>,
    /// Cursor that started the current lag recovery, for the terminal status.
    pub(super) recovery_start: HashMap<String, u64>,
    /// Older transcript pages requested while the user scrolls to the top.
    pub(super) history_in_flight: HashSet<String>,
    pub(super) history_more: HashMap<String, bool>,
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
            // A paging transcript: an empty attach keeps this one, and it must still page.
            self.transcripts.entry(id).or_insert_with(Transcript::paging).push_local_error(e);
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
        self.selected_session().and_then(session_route_id)
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
        self.request_attach(id, None);
    }

    /// Replay records after the last sequence the TUI applied.  The daemon's
    /// page is forward-ordered for `afterSeq`, so Transcript's existing
    /// sequence deduplication can merge it into the live model.
    pub(super) fn recover_after_lag(&mut self, id: &str, after_seq: u64) -> bool {
        if !self.recovery_in_flight.insert(id.to_owned()) {
            return false;
        }
        self.recovery_pages.insert(id.to_owned(), 1);
        self.recovery_replayed.insert(id.to_owned(), 0);
        self.recovery_start.insert(id.to_owned(), after_seq);
        self.request_attach(id, Some(after_seq));
        true
    }

    fn request_attach(&mut self, id: &str, after_seq: Option<u64>) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            let mut params = json!({"sessionId": id, "limit": 3000});
            if let Some(after) = after_seq {
                params.set("afterSeq", json!(after));
            }
            match client.request(method::MUX_ATTACH, params).await {
                Ok(v) => {
                    let events =
                        v.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
                    let detail = v.get("session").cloned().unwrap_or(Value::Null);
                    let has_more = v.get("hasMore").and_then(Value::as_bool).unwrap_or(false);
                    let last_seq = v.get("lastSeq").and_then(Value::as_u64).unwrap_or(0);
                    let _ = tx.send(AppMsg::Attached {
                        id,
                        detail,
                        events,
                        after_seq,
                        has_more,
                        last_seq,
                    });
                }
                Err(e) => {
                    if let Some(after_seq) = after_seq {
                        let _ =
                            tx.send(AppMsg::RecoveryFailed { id, after_seq, error: e.to_string() });
                    } else {
                        let _ = tx.send(AppMsg::Error(format!("attach: {e}")));
                    }
                }
            }
        });
    }

    /// Asks for the page of records before the oldest one shown once the selected
    /// transcript is scrolled to its top, one page at a time, until the log has no more.
    pub(super) fn load_older_if_needed(&mut self) {
        let Some(id) = self.selected_id() else { return };
        let Some(v) = self.viewport.get(&id) else { return };
        if v.offset != 0
            || self.history_in_flight.contains(&id)
            || self.history_more.get(&id) == Some(&false)
        {
            return;
        }
        let Some(before) = self.transcripts.get(&id).and_then(Transcript::oldest_seq) else {
            return;
        };
        self.history_in_flight.insert(id.clone());
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            match client
                // A read of the log, not a second attach: the view is already subscribed.
                .request(
                    method::MUX_EVENTS,
                    json!({"sessionId": id, "limit": 3000, "beforeSeq": before}),
                )
                .await
            {
                Ok(v) => {
                    let events =
                        v.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
                    let has_more = v.get("hasMore").and_then(Value::as_bool).unwrap_or(false);
                    let _ = tx.send(AppMsg::Older { id, events, has_more });
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::OlderFailed { id, error: e.to_string() });
                }
            }
        });
        self.status = "loading earlier history…".into();
    }

    pub(super) fn refresh_sessions(&self) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            if let Ok(v) = client.whole_list(method::MUX_SESSIONS, json!({})).await {
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
                        && let Some(id) = session_route_id(&v)
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

    /// The selected session has a turn open: running, or waiting on a permission (the turn still
    /// takes a steer), by its list row or by its transcript, whichever is newer.
    pub(super) fn turn_open(&self) -> bool {
        self.selected_session()
            .and_then(|s| s.get("status"))
            .and_then(Value::as_str)
            .is_some_and(turn_open_status)
            || self
                .selected_id()
                .and_then(|id| self.transcripts.get(&id))
                .is_some_and(|t| turn_open_status(&t.status))
    }

    /// Enter steers a prompt into the running turn when the agent steers, as the app's composer does
    /// (Leo, 2026-11-05: "wt* like no these default enters became queues?"); Ctrl-s queues it. A
    /// slash command still waits for the turn, so it runs as its own turn, never as a steer.
    pub(super) fn enter_steers(&self) -> bool {
        self.turn_open()
            && !self.on_draft()
            && self.selected_supports_steer()
            && !self.editor().text().trim_start().starts_with('/')
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
            let queued = turn_open_status(&t.status) && !steer;
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
            t.push_optimistic(
                text.clone(),
                crate::transcript::Item::User { text: shown, steer, queued },
            );
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

fn session_route_id(session: &Value) -> Option<String> {
    crate::cli::resolve::routed_id(session).ok()
}

/// A session or transcript status with a turn still open: running, or waiting on a permission.
fn turn_open_status(status: &str) -> bool {
    matches!(status, "running" | "waiting")
}

#[cfg(test)]
mod session_route_tests;

#[cfg(all(test, unix))]
pub(super) mod interaction_tests;
