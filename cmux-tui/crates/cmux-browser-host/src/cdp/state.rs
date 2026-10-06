//! CDP driver state: tabs, sessions, frames' execution contexts, navigation
//! progress and dialogs. Updated only from CDP events and replies; driver
//! events are derived here so they follow the same order as the CDP stream.

use super::connection::CdpEvent;
use crate::protocol::DriverEvent;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};

/// Name of the isolated world that holds the page agent.
pub const AGENT_WORLD: &str = "cmux-agent";

/// Name of the isolated world only the host uses (focus checks, select-all,
/// capture masking). VM code can never target it: the host's gate refuses
/// `world: "host"` from the VM.
pub const HOST_WORLD: &str = "cmux-host";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum World {
    Page,
    Agent,
    Host,
}

impl World {
    pub fn parse(value: Option<&str>) -> Option<World> {
        match value {
            None | Some("agent") => Some(World::Agent),
            Some("page") => Some(World::Page),
            Some("host") => Some(World::Host),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct TabState {
    pub session_id: String,
    pub ready: bool,
    pub setup_error: Option<String>,
    /// The main frame's URL, also a pending one (`targetInfoChanged`).
    pub url: String,
    /// The main frame's committed URL (`frameNavigated`, same-document
    /// navigations): the document that script would run in.
    pub committed_url: String,
    /// Committed URL of every frame, by frame id.
    pub frame_urls: HashMap<String, String>,
    pub title: String,
    pub opener: Option<String>,
    pub main_frame: Option<String>,
    /// Script contexts per frame and world, with the flat session that owns them.
    pub contexts: HashMap<(String, World), (String, i64)>,
    /// Agent-world contexts known to hold the page agent: (session, context id).
    /// Chromium can report more than one isolated context with the agent
    /// world's name for one document, and not every one runs the agent script.
    pub agent_ready: HashSet<(String, i64)>,
    /// Requests in flight, for the Network events after their first.
    pub requests: HashMap<String, super::network::OpenRequest>,
    pub request_order: std::collections::VecDeque<String>,
    /// The newest responses' (URL, remote IP address), for net.fetch.
    pub responses: std::collections::VecDeque<(String, String)>,
    /// Out-of-process frames: frame id -> its own CDP session.
    pub frame_sessions: HashMap<String, String>,
    /// Closed shadow roots per CDP session (`closed_roots`).
    pub closed_roots: HashMap<String, super::closed_roots::SessionRoots>,
    /// Closed-root walks and DOM events of this tab (`tab.info closedRoots`).
    pub closed_root_stats: super::closed_roots::WalkStats,
    /// Loader of the main frame's current document.
    pub loader: Option<String>,
    /// Lifecycle events (`DOMContentLoaded`, `load`, `networkIdle`) seen for `loader`.
    pub lifecycle: HashSet<String>,
    /// Bumps on every main-frame navigation, document or same-document.
    pub nav_seq: u64,
    pub last_nav_same_document: bool,
    pub buttons: i64,
    /// Keys pressed and not released, oldest first: (key, code, location).
    /// Released when the last session leaves the tab.
    pub held_keys: Vec<(String, String, i64)>,
    pub mouse: (f64, f64),
    pub viewport: (f64, f64),
    pub device_scale_factor: f64,
    pub crashed: bool,
    pub open_dialogs: usize,
    /// Bumps when the main frame starts a download, so a navigation that
    /// turns into a download fails instead of waiting out its deadline.
    pub download_seq: u64,
    /// A fetch shell (a9 shell-tab conditions): the host's own tab. Never
    /// listed, no events, no page agent, no calls from the session.
    pub hidden: bool,
}

impl TabState {
    pub fn new(session_id: String, url: String, title: String, opener: Option<String>) -> Self {
        TabState {
            session_id,
            ready: false,
            setup_error: None,
            committed_url: url.clone(),
            url,
            frame_urls: HashMap::new(),
            title,
            opener,
            main_frame: None,
            contexts: HashMap::new(),
            agent_ready: HashSet::new(),
            requests: HashMap::new(),
            request_order: std::collections::VecDeque::new(),
            responses: std::collections::VecDeque::new(),
            frame_sessions: HashMap::new(),
            closed_roots: HashMap::new(),
            closed_root_stats: Default::default(),
            loader: None,
            lifecycle: HashSet::new(),
            nav_seq: 0,
            last_nav_same_document: false,
            buttons: 0,
            held_keys: Vec::new(),
            mouse: (0.0, 0.0),
            viewport: (1280.0, 800.0),
            device_scale_factor: 1.0,
            crashed: false,
            open_dialogs: 0,
            download_seq: 0,
            hidden: false,
        }
    }

    /// `commit`, `domcontentloaded` or `load` for the current document.
    pub fn load_state(&self) -> &'static str {
        if self.lifecycle.contains("load") {
            "load"
        } else if self.lifecycle.contains("DOMContentLoaded") {
            "domcontentloaded"
        } else {
            "commit"
        }
    }
}

/// Follow-up work an event asks for. It runs off the reader thread because it
/// makes CDP calls.
#[derive(Debug, Clone, PartialEq)]
pub enum FollowUp {
    /// A page target was attached: enable domains, install the agent world, resume it.
    SetUpPage { target_id: String, session_id: String },
    /// An out-of-process frame of a tab was attached: same setup on its session.
    SetUpFrame { target_id: String, session_id: String },
    /// A non-page target (worker) attached paused: let it run.
    Resume { session_id: String },
    /// A target that shows a browser page (`policy::is_browser_page`): let
    /// it run if paused and detach (through `parent` for a child session),
    /// so no agent call can reach it.
    Release { session_id: String, waiting: bool, parent: Option<String> },
    /// Closed-root change detection ended for a session (closed_roots.rs):
    /// stop its DOM events; the next read turns them on again.
    DisableDom { session_id: String },
}

#[derive(Debug, Default)]
pub struct Applied {
    pub events: Vec<DriverEvent>,
    pub follow_ups: Vec<FollowUp>,
}

#[derive(Debug, Default)]
pub struct State {
    pub tabs: HashMap<String, TabState>,
    pub sessions: HashMap<String, String>,
    /// Frame session -> the session it attached through (a nested
    /// cross-site frame attaches through its parent frame's session).
    pub parent_sessions: HashMap<String, String>,
    pub order: Vec<String>,
    pub active: Option<String>,
    /// Dialog id -> (tab, session that opened it).
    pub dialogs: HashMap<String, (String, String)>,
    pub next_dialog: u64,
    /// Marker URLs of fetch shells being created: the page target that
    /// attaches with one is hidden from its first event.
    pub shell_markers: HashSet<String>,
    /// Fetch shells by target id (also when the attach came after the
    /// create reply).
    pub shell_targets: HashSet<String>,
    /// Downloads by guid (headless Chromium, `save_downloads_in`).
    pub downloads: super::downloads::Downloads,
}

impl State {
    /// The tab a CDP session belongs to: its page session or one of its
    /// frame sessions.
    pub fn target_for_session(&self, session_id: &str) -> Option<&str> {
        self.sessions.get(session_id).map(String::as_str)
    }

    fn remove_tab(&mut self, target_id: &str, applied: &mut Applied) {
        self.shell_targets.remove(target_id);
        if let Some(tab) = self.tabs.remove(target_id) {
            self.sessions.remove(&tab.session_id);
            for session in tab.frame_sessions.values() {
                self.sessions.remove(session);
            }
            self.order.retain(|id| id != target_id);
            self.dialogs.retain(|_, (owner, _)| owner.as_str() != target_id);
            if self.active.as_deref() == Some(target_id) {
                self.active = None;
            }
            if !tab.hidden {
                applied.events.push(event("tab.closed", target_id, Map::new()));
            }
        }
    }

    /// True for a fetch shell's tab.
    pub fn is_hidden(&self, target_id: &str) -> bool {
        self.tabs.get(target_id).is_some_and(|tab| tab.hidden)
    }

    /// Applies one CDP event.
    pub fn apply(&mut self, cdp: &CdpEvent) -> Applied {
        let mut applied = Applied::default();
        let params = &cdp.params;
        match cdp.method.as_str() {
            "Target.attachedToTarget" => {
                self.attached(params, cdp.session_id.as_deref(), &mut applied);
            }
            "Target.detachedFromTarget" => {
                if let Some(session_id) = params.get("sessionId").and_then(Value::as_str)
                    && let Some(target_id) = self.sessions.get(session_id).cloned()
                {
                    let is_main =
                        self.tabs.get(&target_id).is_some_and(|tab| tab.session_id == session_id);
                    if is_main {
                        self.remove_tab(&target_id, &mut applied);
                    } else {
                        self.sessions.remove(session_id);
                        self.parent_sessions.remove(session_id);
                        if let Some(tab) = self.tabs.get_mut(&target_id) {
                            tab.frame_sessions.retain(|_, session| session.as_str() != session_id);
                            tab.closed_roots.remove(session_id);
                            tab.contexts.retain(|_, (session, _)| session.as_str() != session_id);
                        }
                    }
                }
            }
            "Target.targetDestroyed" => {
                if let Some(target_id) = params.get("targetId").and_then(Value::as_str) {
                    self.remove_tab(target_id, &mut applied);
                }
            }
            "Target.targetInfoChanged" => {
                let info = &params["targetInfo"];
                if let Some(target_id) = info.get("targetId").and_then(Value::as_str)
                    && let Some(tab) = self.tabs.get_mut(target_id)
                {
                    if let Some(title) = info.get("title").and_then(Value::as_str) {
                        tab.title = title.to_owned();
                    }
                    if let Some(url) = info.get("url").and_then(Value::as_str) {
                        tab.url = url.to_owned();
                    }
                }
            }
            "Browser.downloadWillBegin" | "Browser.downloadProgress" => {
                self.download_event(&cdp.method, params, &mut applied);
            }
            "Target.targetCrashed" => {
                if let Some(target_id) = params.get("targetId").and_then(Value::as_str) {
                    self.crashed(target_id, &mut applied);
                }
            }
            _ => {
                if let Some(session_id) = cdp.session_id.as_deref()
                    && let Some(target_id) = self.sessions.get(session_id).cloned()
                {
                    self.session_event(&target_id, session_id, &cdp.method, params, &mut applied);
                }
            }
        }
        // A fetch shell's events never reach the session.
        applied.events.retain(|event| {
            !event
                .payload
                .get("targetId")
                .and_then(Value::as_str)
                .is_some_and(|t| self.is_hidden(t))
        });
        applied
    }

    fn attached(&mut self, params: &Value, parent: Option<&str>, applied: &mut Applied) {
        let Some(session_id) = params.get("sessionId").and_then(Value::as_str) else {
            return;
        };
        let info = &params["targetInfo"];
        let kind = info.get("type").and_then(Value::as_str).unwrap_or("");
        let Some(target_id) = info.get("targetId").and_then(Value::as_str) else {
            return;
        };
        let waiting = params.get("waitingForDebugger").and_then(Value::as_bool) == Some(true);
        if info.get("url").and_then(Value::as_str).is_some_and(crate::policy::is_browser_page) {
            applied.follow_ups.push(FollowUp::Release {
                session_id: session_id.to_owned(),
                waiting,
                parent: parent.map(str::to_owned),
            });
            return;
        }
        let resume = |applied: &mut Applied| {
            if waiting {
                applied.follow_ups.push(FollowUp::Resume { session_id: session_id.to_owned() });
            }
        };
        // Prerenders and other page subtypes are not tabs.
        if info.get("subtype").and_then(Value::as_str).is_some_and(|s| !s.is_empty()) {
            resume(applied);
            return;
        }
        // An out-of-process iframe of a tab (its target id is its frame id).
        if kind == "iframe"
            && let Some(tab_id) = parent.and_then(|p| self.sessions.get(p)).cloned()
            && let Some(tab) = self.tabs.get_mut(&tab_id)
        {
            tab.frame_sessions.insert(target_id.to_owned(), session_id.to_owned());
            self.sessions.insert(session_id.to_owned(), tab_id.clone());
            if let Some(parent) = parent {
                self.parent_sessions.insert(session_id.to_owned(), parent.to_owned());
            }
            applied.follow_ups.push(FollowUp::SetUpFrame {
                target_id: tab_id,
                session_id: session_id.to_owned(),
            });
            return;
        }
        if kind != "page" || parent.is_some() || self.tabs.contains_key(target_id) {
            resume(applied);
            return;
        }
        let url = info.get("url").and_then(Value::as_str).unwrap_or("").to_owned();
        let title = info.get("title").and_then(Value::as_str).unwrap_or("").to_owned();
        let opener = info.get("openerId").and_then(Value::as_str).map(str::to_owned);
        let mut tab = TabState::new(session_id.to_owned(), url.clone(), title, opener.clone());
        tab.hidden = self.shell_markers.remove(&url) || self.shell_targets.contains(target_id);
        let hidden = tab.hidden;
        self.tabs.insert(target_id.to_owned(), tab);
        self.sessions.insert(session_id.to_owned(), target_id.to_owned());
        self.order.push(target_id.to_owned());
        if let Some(opener) = opener.filter(|_| !hidden) {
            let mut payload = Map::new();
            payload.insert("openerTargetId".into(), json!(opener));
            payload.insert("url".into(), json!(url));
            applied.events.push(event("tab.created", target_id, payload));
        }
        applied.follow_ups.push(FollowUp::SetUpPage {
            target_id: target_id.to_owned(),
            session_id: session_id.to_owned(),
        });
    }

    fn crashed(&mut self, target_id: &str, applied: &mut Applied) {
        if let Some(tab) = self.tabs.get_mut(target_id)
            && !tab.crashed
        {
            tab.crashed = true;
            applied.events.push(event("tab.crashed", target_id, Map::new()));
        }
    }

    fn session_event(
        &mut self,
        target_id: &str,
        session_id: &str,
        method: &str,
        params: &Value,
        applied: &mut Applied,
    ) {
        if method.starts_with("DOM.") {
            if let Some(tab) = self.tabs.get_mut(target_id) {
                tab.closed_root_stats.dom_events += 1;
                if let Some(roots) = tab.closed_roots.get_mut(session_id)
                    && roots.dom_changed(std::time::Instant::now())
                {
                    applied
                        .follow_ups
                        .push(FollowUp::DisableDom { session_id: session_id.to_owned() });
                }
            }
            return;
        }
        if method == "Inspector.targetCrashed" {
            self.crashed(target_id, applied);
            return;
        }
        if method == "Page.javascriptDialogOpening" {
            self.next_dialog += 1;
            let dialog_id = format!("d{}", self.next_dialog);
            self.dialogs.insert(dialog_id.clone(), (target_id.to_owned(), session_id.to_owned()));
            if let Some(tab) = self.tabs.get_mut(target_id) {
                tab.open_dialogs += 1;
            }
            let mut payload = Map::new();
            payload.insert("dialogId".into(), json!(dialog_id));
            payload.insert("type".into(), params.get("type").cloned().unwrap_or(json!("alert")));
            payload.insert("message".into(), params.get("message").cloned().unwrap_or(json!("")));
            payload.insert(
                "defaultValue".into(),
                params.get("defaultPrompt").cloned().unwrap_or(json!("")),
            );
            applied.events.push(event("dialog.opened", target_id, payload));
            return;
        }
        if method == "Page.javascriptDialogClosed" {
            self.dialogs.retain(|_, (tab, session)| {
                !(tab.as_str() == target_id && session.as_str() == session_id)
            });
            if let Some(tab) = self.tabs.get_mut(target_id) {
                tab.open_dialogs = tab.open_dialogs.saturating_sub(1);
            }
            return;
        }
        let Some(tab) = self.tabs.get_mut(target_id) else {
            return;
        };
        let is_main = tab.session_id == session_id;
        match method {
            "Page.frameNavigated" => {
                let frame = &params["frame"];
                let frame_id = frame.get("id").and_then(Value::as_str).unwrap_or("").to_owned();
                let url = frame_url(frame);
                tab.frame_urls.insert(frame_id.clone(), url.clone());
                if !is_main && crate::policy::is_browser_page(&url) {
                    // An out-of-process frame committed a browser page.
                    tab.frame_sessions.retain(|_, session| session.as_str() != session_id);
                    tab.contexts.retain(|_, (session, _)| session.as_str() != session_id);
                    let parent = self
                        .parent_sessions
                        .remove(session_id)
                        .unwrap_or_else(|| tab.session_id.clone());
                    self.sessions.remove(session_id);
                    applied.follow_ups.push(FollowUp::Release {
                        session_id: session_id.to_owned(),
                        waiting: false,
                        parent: Some(parent),
                    });
                    return;
                }
                if is_main && frame.get("parentId").and_then(Value::as_str).is_none() {
                    tab.crashed = false;
                    tab.main_frame = Some(frame_id.clone());
                    tab.url = url.clone();
                    tab.committed_url = url.clone();
                    // A new document: its frames start over.
                    tab.frame_urls.retain(|frame, _| *frame == frame_id);
                    tab.loader = frame.get("loaderId").and_then(Value::as_str).map(str::to_owned);
                    tab.lifecycle.clear();
                    tab.nav_seq += 1;
                    tab.last_nav_same_document = false;
                    // A back/forward cache restore brings back a loaded
                    // document; Chromium sends no lifecycle events for it.
                    if params.get("type").and_then(Value::as_str) == Some("BackForwardCacheRestore")
                    {
                        for name in ["DOMContentLoaded", "load", "networkIdle"] {
                            tab.lifecycle.insert(name.to_owned());
                        }
                    }
                }
                applied.events.push(navigated(target_id, &frame_id, &url, false));
            }
            "Page.navigatedWithinDocument" => {
                let frame_id =
                    params.get("frameId").and_then(Value::as_str).unwrap_or("").to_owned();
                let url = params.get("url").and_then(Value::as_str).unwrap_or("").to_owned();
                tab.frame_urls.insert(frame_id.clone(), url.clone());
                if tab.main_frame.as_deref() == Some(frame_id.as_str()) {
                    tab.url = url.clone();
                    tab.committed_url = url.clone();
                    tab.nav_seq += 1;
                    tab.last_nav_same_document = true;
                }
                applied.events.push(navigated(target_id, &frame_id, &url, true));
            }
            "Page.lifecycleEvent" => {
                let frame_id = params.get("frameId").and_then(Value::as_str);
                let loader = params.get("loaderId").and_then(Value::as_str);
                let name = params.get("name").and_then(Value::as_str).unwrap_or("");
                if frame_id.is_some()
                    && frame_id == tab.main_frame.as_deref()
                    && loader.is_some()
                    && loader == tab.loader.as_deref()
                    && tab.lifecycle.insert(name.to_owned())
                {
                    let state = match name {
                        "DOMContentLoaded" => Some("domcontentloaded"),
                        "load" => Some("load"),
                        "networkIdle" => Some("networkidle"),
                        _ => None,
                    };
                    if let Some(state) = state {
                        let mut payload = Map::new();
                        payload.insert("state".into(), json!(state));
                        applied.events.push(event("tab.loadState", target_id, payload));
                    }
                }
            }
            "Runtime.executionContextCreated" => {
                let context = &params["context"];
                let aux = &context["auxData"];
                let (Some(id), Some(frame_id)) = (
                    context.get("id").and_then(Value::as_i64),
                    aux.get("frameId").and_then(Value::as_str),
                ) else {
                    return;
                };
                let world = if aux.get("isDefault").and_then(Value::as_bool) == Some(true) {
                    Some(World::Page)
                } else if context.get("name").and_then(Value::as_str) == Some(AGENT_WORLD) {
                    Some(World::Agent)
                } else if context.get("name").and_then(Value::as_str) == Some(HOST_WORLD) {
                    Some(World::Host)
                } else {
                    None
                };
                if let Some(world) = world {
                    tab.contexts.insert((frame_id.to_owned(), world), (session_id.to_owned(), id));
                }
            }
            "Runtime.executionContextDestroyed" => {
                if let Some(id) = params.get("executionContextId").and_then(Value::as_i64) {
                    tab.contexts.retain(|_, (session, context)| {
                        !(session.as_str() == session_id && *context == id)
                    });
                }
            }
            "Runtime.executionContextsCleared" => {
                tab.contexts.retain(|_, (session, _)| session.as_str() != session_id);
                tab.agent_ready.retain(|(session, _)| session.as_str() != session_id);
            }
            "Page.downloadWillBegin"
                if params.get("frameId").and_then(Value::as_str) == tab.main_frame.as_deref() =>
            {
                tab.download_seq += 1;
            }
            network if network.starts_with("Network.") => {
                if let Some(event) = super::network::event(tab, target_id, network, params) {
                    applied.events.push(event);
                }
            }
            "Runtime.consoleAPICalled" => {
                let text = params
                    .get("args")
                    .and_then(Value::as_array)
                    .map(|args| args.iter().map(remote_object_text).collect::<Vec<_>>().join(" "))
                    .unwrap_or_default();
                let mut payload = Map::new();
                payload.insert("type".into(), params.get("type").cloned().unwrap_or(json!("log")));
                payload.insert("text".into(), json!(text));
                applied.events.push(event("console", target_id, payload));
            }
            "Runtime.exceptionThrown" => {
                let details = &params["exceptionDetails"];
                let stack = details["exception"]
                    .get("description")
                    .and_then(Value::as_str)
                    .or_else(|| details.get("text").and_then(Value::as_str))
                    .unwrap_or("")
                    .to_owned();
                let mut payload = Map::new();
                payload.insert("message".into(), json!(error_message(&stack)));
                payload.insert("stack".into(), json!(stack));
                applied.events.push(event("pageerror", target_id, payload));
            }
            _ => {}
        }
    }
}

fn event(name: &str, target_id: &str, mut payload: Map<String, Value>) -> DriverEvent {
    payload.insert("targetId".into(), json!(target_id));
    DriverEvent { name: name.to_owned(), payload: Value::Object(payload) }
}

fn navigated(target_id: &str, frame_id: &str, url: &str, same_document: bool) -> DriverEvent {
    let mut payload = Map::new();
    payload.insert("frameId".into(), json!(frame_id));
    payload.insert("url".into(), json!(url));
    payload.insert("sameDocument".into(), json!(same_document));
    event("tab.navigated", target_id, payload)
}

/// A frame's URL with its fragment (CDP reports the fragment separately).
pub fn frame_url(frame: &Value) -> String {
    let url = frame.get("url").and_then(Value::as_str).unwrap_or("");
    let fragment = frame.get("urlFragment").and_then(Value::as_str).unwrap_or("");
    format!("{url}{fragment}")
}

fn remote_object_text(object: &Value) -> String {
    match object.get("value") {
        Some(Value::String(text)) => text.clone(),
        Some(value) if !value.is_null() => value.to_string(),
        _ => object
            .get("description")
            .and_then(Value::as_str)
            .or_else(|| object.get("type").and_then(Value::as_str))
            .unwrap_or("")
            .to_owned(),
    }
}

/// `TypeError: x is not a function\n    at ...` -> `x is not a function`.
pub fn error_message(description: &str) -> String {
    let first = description.lines().next().unwrap_or("");
    match first.split_once(": ") {
        Some((name, rest)) if !name.is_empty() && !name.contains(' ') => rest.to_owned(),
        _ => first.to_owned(),
    }
}

#[cfg(test)]
#[path = "state_tests.rs"]
mod tests;
