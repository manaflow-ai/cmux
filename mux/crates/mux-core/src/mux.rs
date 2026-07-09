//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::browser::{self, BrowserBootstrap, BrowserRuntime};
use crate::layout::{Rect, layout_screen};
use crate::model::{Node, Pane, Screen, State, Workspace};
use crate::surface::{DefaultColors, Surface, SurfaceOptions};
use crate::{PaneId, ScreenId, SplitDir, SurfaceId, WorkspaceId};

/// Events pushed to subscribed frontends.
#[derive(Debug, Clone)]
pub enum MuxEvent {
    /// New output arrived in a surface (coalesced; cleared when rendered).
    SurfaceOutput(SurfaceId),
    /// A surface's runtime changed size.
    SurfaceResized {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    },
    /// A surface's child exited. The mux has already reaped it from the
    /// tree (a tree-changed follows) by the time this arrives.
    SurfaceExited(SurfaceId),
    TitleChanged(SurfaceId),
    Bell(SurfaceId),
    Notification(NotificationEvent),
    Status(String),
    /// A frontend should reload its local mux configuration and redraw.
    ConfigReloadRequested,
    /// A frontend should set its host terminal window title. Empty clears it.
    WindowTitleRequested(String),
    /// A PTY surface viewport moved within its scrollback.
    ScrollChanged {
        surface: SurfaceId,
        offset: u64,
        at_bottom: bool,
    },
    /// The workspace/screen/pane/tab tree changed (from any frontend or
    /// the control socket).
    TreeChanged,
    /// A screen's pane geometry changed. Clients should re-fetch layout.
    LayoutChanged(ScreenId),
    /// Every workspace is gone.
    Empty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationLevel {
    Info,
    Warning,
    Error,
}

impl NotificationLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            NotificationLevel::Info => "info",
            NotificationLevel::Warning => "warning",
            NotificationLevel::Error => "error",
        }
    }
}

#[derive(Debug, Clone)]
pub struct NotificationEvent {
    pub notification: u64,
    pub title: String,
    pub body: String,
    pub level: NotificationLevel,
    pub surface: Option<SurfaceId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Blocked,
    Idle,
    Done,
    Unknown,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentState::Working => "working",
            AgentState::Blocked => "blocked",
            AgentState::Idle => "idle",
            AgentState::Done => "done",
            AgentState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone)]
pub struct LayoutLeafSpec {
    pub cwd: Option<String>,
    pub command: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub enum LayoutSpec {
    Leaf(LayoutLeafSpec),
    Split { dir: SplitDir, ratio: f32, a: Box<LayoutSpec>, b: Box<LayoutSpec> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoomMode {
    Toggle,
    On,
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    fn delta(self) -> (i32, i32) {
        match self {
            Direction::Left => (-1, 0),
            Direction::Right => (1, 0),
            Direction::Up => (0, -1),
            Direction::Down => (0, 1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentSource {
    Detected,
    Socket,
    Hook,
}

impl AgentSource {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentSource::Detected => "detected",
            AgentSource::Socket => "socket",
            AgentSource::Hook => "hook",
        }
    }
}

#[derive(Debug, Clone)]
pub struct AgentRecord {
    pub surface: SurfaceId,
    pub state: AgentState,
    pub source: AgentSource,
    pub session: Option<String>,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct SurfaceNotification {
    pub notification: u64,
    pub level: NotificationLevel,
    pub unread: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct RunPlacement {
    pub surface: SurfaceId,
    pub pane: PaneId,
    pub screen: ScreenId,
    pub workspace: WorkspaceId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppliedPane {
    pub pane: PaneId,
    pub surface: SurfaceId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedLayout {
    pub screen: ScreenId,
    pub panes: Vec<AppliedPane>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZoomState {
    pub pane: PaneId,
    pub zoomed: bool,
    pub zoomed_pane: Option<PaneId>,
}

/// The multiplexer. Shared by frontends and the control socket server.
pub struct Mux {
    state: Mutex<State>,
    subscribers: Mutex<Vec<Sender<MuxEvent>>>,
    next_id: AtomicU64,
    next_notification_id: AtomicU64,
    next_active_at: AtomicU64,
    surface_options: Mutex<SurfaceOptions>,
    browser_runtime: Mutex<Option<Arc<BrowserRuntime>>>,
    cell_pixels: Mutex<(u16, u16)>,
    default_colors: Mutex<DefaultColors>,
    agent_records: Mutex<HashMap<SurfaceId, AgentRecord>>,
    surface_notifications: Mutex<HashMap<SurfaceId, SurfaceNotification>>,
    #[cfg(test)]
    test_surface_runtime: bool,
    pub session: String,
}

impl Mux {
    pub fn new(session: impl Into<String>, surface_options: SurfaceOptions) -> Arc<Self> {
        Self::new_with_test_surface_runtime(session, surface_options, false)
    }

    fn new_with_test_surface_runtime(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> Arc<Self> {
        let session = session.into();
        let mut surface_options = surface_options;
        surface_options.browser_session_name = session.clone();
        Arc::new(Mux {
            state: Mutex::new(State {
                workspaces: Vec::new(),
                active_workspace: 0,
                panes: HashMap::new(),
                surfaces: HashMap::new(),
            }),
            subscribers: Mutex::new(Vec::new()),
            next_id: AtomicU64::new(1),
            next_notification_id: AtomicU64::new(1),
            next_active_at: AtomicU64::new(1),
            surface_options: Mutex::new(surface_options),
            browser_runtime: Mutex::new(None),
            cell_pixels: Mutex::new((8, 16)),
            default_colors: Mutex::new(DefaultColors::default()),
            agent_records: Mutex::new(HashMap::new()),
            surface_notifications: Mutex::new(HashMap::new()),
            #[cfg(test)]
            test_surface_runtime,
            session,
        })
    }

    #[cfg(test)]
    pub(crate) fn new_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(session, surface_options, true)
    }

    fn next_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    fn next_active_at(&self) -> u64 {
        self.next_active_at.fetch_add(1, Ordering::Relaxed)
    }

    fn next_notification_id(&self) -> u64 {
        self.next_notification_id.fetch_add(1, Ordering::Relaxed)
    }

    pub fn subscribe(&self) -> Receiver<MuxEvent> {
        let (tx, rx) = channel();
        self.subscribers.lock().unwrap().push(tx);
        rx
    }

    pub fn emit(&self, event: MuxEvent) {
        let mut subs = self.subscribers.lock().unwrap();
        subs.retain(|tx| tx.send(event.clone()).is_ok());
    }

    fn spawn_surface_with_command(
        self: &Arc<Self>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with(cwd, command, size)
    }

    fn spawn_surface_with(
        self: &Arc<Self>,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let id = self.next_id();
        let mut opts = self.surface_options.lock().unwrap().clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        if command.is_some() {
            opts.command = command;
        }
        // Spawn at the final size when the frontend knows it: starting at
        // the default 80x24 and resizing a frame later makes shells emit
        // artifacts (e.g. zsh's reverse-video %% partial-line marker).
        if let Some((cols, rows)) = size {
            opts.cols = cols.max(1);
            opts.rows = rows.max(1);
        }
        #[cfg(test)]
        let surface = if self.test_surface_runtime {
            Surface::spawn_for_test(id, opts, Arc::downgrade(self))?
        } else {
            Surface::spawn(id, opts, Arc::downgrade(self))?
        };
        #[cfg(not(test))]
        let surface = Surface::spawn(id, opts, Arc::downgrade(self))?;
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        Ok(surface)
    }

    fn spawn_surface(
        self: &Arc<Self>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with_command(cwd, size, None)
    }

    fn spawn_browser_surface(
        self: &Arc<Self>,
        url: String,
        size: Option<(u16, u16)>,
    ) -> Arc<Surface> {
        let id = self.next_id();
        let opts = self.surface_options.lock().unwrap().clone();
        let size = size.unwrap_or((opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let surface = browser::new_surface(id, url.clone(), size, cell_pixels, &opts);
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        self.start_browser_bootstrap(surface.clone(), BrowserBootstrap::Create { url }, None);
        surface
    }

    fn browser_runtime(&self) -> anyhow::Result<Arc<BrowserRuntime>> {
        let mut runtime = self.browser_runtime.lock().unwrap();
        if let Some(existing) = runtime.as_ref().filter(|existing| !existing.is_closed()) {
            return Ok(existing.clone());
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let created = BrowserRuntime::connect(&opts)?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    fn start_browser_bootstrap(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        runtime: Option<Arc<BrowserRuntime>>,
    ) {
        let mux = self.clone();
        let id = surface.id;
        let _ = std::thread::Builder::new().name(format!("browser-surface-{id}-bootstrap")).spawn(
            move || {
                let result = (|| -> anyhow::Result<()> {
                    let runtime = match runtime {
                        Some(runtime) => runtime,
                        None => mux.browser_runtime()?,
                    };
                    runtime.bootstrap_surface_sync(surface.clone(), bootstrap, Arc::downgrade(&mux))
                })();
                if let Err(err) = result {
                    if let Surface::Browser(browser) = surface.as_ref() {
                        browser.mark_failed(err.to_string());
                    }
                    mux.emit(MuxEvent::Status(format!("browser failed: {err}")));
                    mux.emit(MuxEvent::TitleChanged(id));
                    mux.emit(MuxEvent::SurfaceOutput(id));
                }
            },
        );
    }

    /// A fresh single-tab pane wrapping `surface`.
    fn make_pane(&self, surface: SurfaceId) -> (PaneId, Pane) {
        let id = self.next_id();
        (
            id,
            Pane {
                id,
                name: None,
                tabs: vec![surface],
                active_tab: 0,
                active_at: self.next_active_at(),
            },
        )
    }

    pub fn surface(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.get(&id).cloned()
    }

    /// Run `f` with the session state.
    ///
    /// The state lock is held for the duration of `f`; do not call back
    /// into `Mux` methods that take it (`surface()`, `close_pane()`, ...).
    pub fn with_state<R>(&self, f: impl FnOnce(&State) -> R) -> R {
        f(&self.state.lock().unwrap())
    }

    pub fn surface_count(&self) -> usize {
        self.state.lock().unwrap().surfaces.len()
    }

    pub fn surface_notification(&self, surface: SurfaceId) -> Option<SurfaceNotification> {
        self.surface_notifications.lock().unwrap().get(&surface).copied()
    }

    pub fn surface_notifications(&self) -> HashMap<SurfaceId, SurfaceNotification> {
        self.surface_notifications.lock().unwrap().clone()
    }

    pub fn clear_surface_notification(&self, surface: SurfaceId) -> bool {
        let cleared = self.surface_notifications.lock().unwrap().remove(&surface).is_some();
        if cleared {
            self.emit(MuxEvent::TreeChanged);
        }
        cleared
    }

    fn active_surface_in_state(state: &State) -> Option<SurfaceId> {
        let pane = state.active_pane()?;
        state.panes.get(&pane)?.active_surface()
    }

    pub fn active_surface(&self) -> Option<SurfaceId> {
        self.with_state(Self::active_surface_in_state)
    }

    fn clear_viewed_notification(&self, surface: Option<SurfaceId>) {
        if let Some(surface) = surface {
            let _ = self.surface_notifications.lock().unwrap().remove(&surface);
        }
    }

    pub fn post_notification(
        &self,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
    ) -> u64 {
        let id = self.next_notification_id();
        let mut unread_changed = false;
        if let Some(surface) = surface
            && self.active_surface() != Some(surface)
        {
            self.surface_notifications
                .lock()
                .unwrap()
                .insert(surface, SurfaceNotification { notification: id, level, unread: true });
            unread_changed = true;
        }
        self.emit(MuxEvent::Notification(NotificationEvent {
            notification: id,
            title,
            body,
            level,
            surface,
        }));
        if unread_changed {
            self.emit(MuxEvent::TreeChanged);
        }
        id
    }

    pub fn report_agent(
        &self,
        surface: SurfaceId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
    ) -> AgentRecord {
        let mut records = self.agent_records.lock().unwrap();
        if let Some(existing) = records.get(&surface)
            && existing.source == AgentSource::Hook
            && source == AgentSource::Socket
        {
            return existing.clone();
        }
        let record = AgentRecord { surface, state, source, session, updated_at_ms: now_ms() };
        records.insert(surface, record.clone());
        record
    }

    /// Drop the per-surface side tables (`agent_records`,
    /// `surface_notifications`) for a surface that has left the tree.
    /// `SurfaceId` is monotonic, so without this every closed tab would
    /// leak an entry forever and `list-agents` would keep reporting dead
    /// surfaces as live agents.
    fn purge_surface_side_tables(&self, surface: SurfaceId) {
        self.agent_records.lock().unwrap().remove(&surface);
        self.surface_notifications.lock().unwrap().remove(&surface);
    }

    pub fn list_agents(
        &self,
        surface: Option<SurfaceId>,
        state: Option<AgentState>,
    ) -> Vec<AgentRecord> {
        let mut records = self.agent_records.lock().unwrap().values().cloned().collect::<Vec<_>>();
        records.sort_by_key(|record| record.surface);
        records
            .into_iter()
            .filter(|record| surface.is_none_or(|surface| record.surface == surface))
            .filter(|record| state.is_none_or(|state| record.state == state))
            .collect()
    }

    pub fn shutdown(&self) {
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.kill();
        }
        if let Some(runtime) = self.browser_runtime.lock().unwrap().take() {
            runtime.shutdown();
        }
    }

    /// Update options used for future surface/browser launches.
    pub fn update_surface_options(&self, update: impl FnOnce(&mut SurfaceOptions)) {
        let mut options = self.surface_options.lock().unwrap();
        update(&mut options);
        options.browser_session_name = self.session.clone();
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) {
        let next = (width_px.max(1), height_px.max(1));
        {
            let mut cell = self.cell_pixels.lock().unwrap();
            if *cell == next {
                return;
            }
            *cell = next;
        }
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.set_cell_pixel_size(next.0, next.1);
        }
    }

    pub fn default_colors(&self) -> DefaultColors {
        *self.default_colors.lock().unwrap()
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        *self.default_colors.lock().unwrap() = colors;
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit(MuxEvent::SurfaceOutput(surface.id));
        }
    }

    /// Resize a surface and broadcast the final clamped size when it
    /// actually changes.
    pub fn resize_surface(&self, id: SurfaceId, cols: u16, rows: u16) -> anyhow::Result<bool> {
        let Some(surface) = self.surface(id) else {
            anyhow::bail!("unknown surface {id}");
        };
        if !surface.resize(cols, rows) {
            return Ok(false);
        }
        let (cols, rows) = surface.size();
        self.emit(MuxEvent::SurfaceResized { surface: id, cols, rows });
        Ok(true)
    }

    /// Create a workspace with one screen holding one pane with one tab.
    /// Returns the tab's surface. `size` is the expected content size in
    /// cells, when the caller knows it (spawning at the final size avoids
    /// shell redraw artifacts).
    pub fn new_workspace(
        self: &Arc<Self>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let surface = self.spawn_surface(None, size)?;
        let (pane_id, pane) = self.make_pane(surface.id);
        let screen_id = self.next_id();
        let ws_id = self.next_id();
        {
            let mut state = self.state.lock().unwrap();
            let name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.panes.insert(pane_id, pane);
            state.workspaces.push(Workspace {
                id: ws_id,
                name,
                screens: vec![Screen {
                    id: screen_id,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                }],
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
        }
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    pub fn run_command_surface(
        self: &Arc<Self>,
        argv: Vec<String>,
        pane: Option<PaneId>,
        new_workspace: bool,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        if new_workspace {
            let surface = self.spawn_surface_with_command(cwd, size, Some(argv))?;
            if let Some(name) = name.as_ref() {
                surface.set_name(Some(name.clone()));
            }
            let (pane_id, pane) = self.make_pane(surface.id);
            let screen_id = self.next_id();
            let ws_id = self.next_id();
            {
                let mut state = self.state.lock().unwrap();
                let workspace_name =
                    name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
                state.panes.insert(pane_id, pane);
                state.workspaces.push(Workspace {
                    id: ws_id,
                    name: workspace_name,
                    screens: vec![Screen {
                        id: screen_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
            }
            self.emit(MuxEvent::TreeChanged);
            self.reap_if_dead(&surface);
            return Ok(RunPlacement {
                surface: surface.id,
                pane: pane_id,
                screen: screen_id,
                workspace: ws_id,
            });
        }

        let target = {
            let state = self.state.lock().unwrap();
            match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            }
        };
        let Some(target) = target else {
            return self.run_command_surface(argv, None, true, cwd, name, size);
        };

        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let size = size.or_else(|| self.pane_size(target));
        let surface = self.spawn_surface_with_command(cwd, size, Some(argv))?;
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        let active_at = self.next_active_at();
        let placement = {
            let mut state = self.state.lock().unwrap();
            let Some((wi, si)) = state.screen_of(target) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("pane disappeared while creating tab");
            };
            let Some(pane) = state.panes.get_mut(&target) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("pane disappeared while creating tab");
            };
            pane.tabs.push(surface.id);
            pane.active_tab = pane.tabs.len() - 1;
            pane.active_at = active_at;
            RunPlacement {
                surface: surface.id,
                pane: target,
                screen: state.workspaces[wi].screens[si].id,
                workspace: state.workspaces[wi].id,
            }
        };
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(placement)
    }

    /// Create a screen in a workspace (default: the active one) with one
    /// pane/tab, and make it active. Returns the tab's surface.
    pub fn new_screen(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        // Validate the target before spawning a child.
        {
            let state = self.state.lock().unwrap();
            match workspace {
                Some(id) if !state.workspaces.iter().any(|w| w.id == id) => {
                    anyhow::bail!("unknown workspace {id}")
                }
                None if state.workspaces.is_empty() => {
                    drop(state);
                    return self.new_workspace(None, size);
                }
                _ => {}
            }
        }
        let surface = self.spawn_surface(None, size)?;
        let (pane_id, pane) = self.make_pane(surface.id);
        let screen_id = self.next_id();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let ws = match workspace {
                Some(id) => state.workspaces.iter_mut().find(|w| w.id == id),
                None => state.workspaces.get_mut(active),
            };
            match ws {
                Some(ws) => {
                    ws.screens.push(Screen {
                        id: screen_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    });
                    ws.active_screen = ws.screens.len() - 1;
                    state.panes.insert(pane_id, pane);
                    true
                }
                None => {
                    state.surfaces.remove(&surface.id);
                    false
                }
            }
        };
        if !attached {
            surface.kill();
            anyhow::bail!("workspace disappeared while creating screen");
        }
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Create a tab in a pane (default: the active pane of the active
    /// screen). When the session has no workspaces yet (headless before
    /// any command), a workspace is created around the new tab.
    pub fn new_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        // Resolve and validate the target before spawning a child.
        let target = {
            let state = self.state.lock().unwrap();
            match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            }
        };
        let Some(target) = target else {
            return self.new_workspace(None, size);
        };

        let cwd = cwd.or_else(|| self.pane_cwd(target));
        // A sibling tab renders at the size the pane already has.
        let size = size.or_else(|| self.pane_size(target));
        let surface = self.spawn_surface(cwd, size)?;
        let active_at = self.next_active_at();
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    true
                }
                None => {
                    // Pane disappeared between validation and attach.
                    state.surfaces.remove(&surface.id);
                    false
                }
            }
        };
        if !attached {
            surface.kill();
            anyhow::bail!("pane disappeared while creating tab");
        }
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Create a browser tab in a pane (default: the active pane). When
    /// the session has no workspaces yet, a workspace is created around
    /// the browser tab.
    pub fn new_browser_tab(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let target = {
            let state = self.state.lock().unwrap();
            match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            }
        };
        let Some(target) = target else {
            let surface = self.spawn_browser_surface(url, size);
            let (pane_id, pane) = self.make_pane(surface.id);
            let screen_id = self.next_id();
            let ws_id = self.next_id();
            {
                let mut state = self.state.lock().unwrap();
                let name = format!("{}", state.workspaces.len() + 1);
                state.panes.insert(pane_id, pane);
                state.workspaces.push(Workspace {
                    id: ws_id,
                    name,
                    screens: vec![Screen {
                        id: screen_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
            }
            self.emit(MuxEvent::TreeChanged);
            self.reap_if_dead(&surface);
            return Ok(surface);
        };

        let size = size.or_else(|| self.pane_size(target));
        let surface = self.spawn_browser_surface(url, size);
        let active_at = self.next_active_at();
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    true
                }
                None => {
                    state.surfaces.remove(&surface.id);
                    false
                }
            }
        };
        if !attached {
            surface.kill();
            anyhow::bail!("pane disappeared while creating browser tab");
        }
        self.emit(MuxEvent::TreeChanged);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    pub fn adopt_browser_target(
        self: &Arc<Self>,
        opener_surface: SurfaceId,
        target_id: String,
        url: String,
        runtime: Arc<BrowserRuntime>,
    ) -> bool {
        let (pane_id, size) = {
            let state = self.state.lock().unwrap();
            let Some(pane_id) = state.pane_of(opener_surface) else {
                return false;
            };
            let size = state.surfaces.get(&opener_surface).map(|surface| surface.size());
            (pane_id, size)
        };
        let id = self.next_id();
        let opts = self.surface_options.lock().unwrap().clone();
        let size = size.unwrap_or((opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let surface = browser::new_surface(id, url.clone(), size, cell_pixels, &opts);
        let active_at = self.next_active_at();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let Some(pane) = state.panes.get_mut(&pane_id) else {
                return false;
            };
            pane.tabs.push(surface.id);
            pane.active_tab = pane.tabs.len() - 1;
            pane.active_at = active_at;
            state.surfaces.insert(surface.id, surface.clone());
            true
        };
        if !attached {
            surface.kill();
            return false;
        }
        self.emit(MuxEvent::TreeChanged);
        self.start_browser_bootstrap(
            surface,
            BrowserBootstrap::ExistingTarget { target_id, url },
            Some(runtime),
        );
        true
    }

    /// Working directory of a pane's active surface, if reported.
    fn pane_cwd(&self, pane: PaneId) -> Option<String> {
        let surface = {
            let state = self.state.lock().unwrap();
            let active = state.panes.get(&pane)?.active_surface()?;
            state.surfaces.get(&active).cloned()
        };
        surface.and_then(|s| s.pwd())
    }

    /// Current cell size of a pane's active surface.
    fn pane_size(&self, pane: PaneId) -> Option<(u16, u16)> {
        let state = self.state.lock().unwrap();
        let active = state.panes.get(&pane)?.active_surface()?;
        state.surfaces.get(&active).map(|s| s.size())
    }

    /// Split the screen containing `target`, putting a new single-tab
    /// pane after it. Returns the new pane's surface. `size` is the
    /// expected content size of the new pane, when the caller knows it.
    pub fn split(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cwd = self.pane_cwd(target);
        // Halve the split axis as a fallback estimate; the frontend sends
        // the exact size on its next layout pass.
        let size = size.or_else(|| {
            self.pane_size(target).map(|(cols, rows)| match dir {
                SplitDir::Right => ((cols.saturating_sub(1) / 2).max(1), rows),
                SplitDir::Down => (cols, (rows.saturating_sub(1) / 2).max(1)),
            })
        });
        let surface = self.spawn_surface(cwd, size)?;
        let pane_id = self.next_id();
        let active_at = self.next_active_at();
        let mut done = false;
        let mut changed_screen = None;
        {
            let mut state = self.state.lock().unwrap();
            'outer: for ws in state.workspaces.iter_mut() {
                for screen in ws.screens.iter_mut() {
                    if screen.root.split_leaf(target, dir, pane_id) {
                        screen.active_pane = pane_id;
                        changed_screen = Some(screen.id);
                        done = true;
                        break 'outer;
                    }
                }
            }
            if done {
                state.panes.insert(
                    pane_id,
                    Pane {
                        id: pane_id,
                        name: None,
                        tabs: vec![surface.id],
                        active_tab: 0,
                        active_at,
                    },
                );
            } else {
                state.surfaces.remove(&surface.id);
            }
        }
        if !done {
            surface.kill();
            anyhow::bail!("pane {target} not found");
        }
        self.emit(MuxEvent::TreeChanged);
        if let Some(screen) = changed_screen {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    /// Close one tab. When it was the pane's last tab, the pane collapses
    /// out of its split tree (and emptied screens/workspaces are removed).
    pub fn close_surface(&self, target: SurfaceId) {
        let (removed, changed_screens, empty) = {
            let mut state = self.state.lock().unwrap();
            let changed_screen = surface_screen_id(&state, target);
            (
                remove_surface(&mut state, target),
                changed_screen.into_iter().collect::<Vec<_>>(),
                state.workspaces.is_empty(),
            )
        };
        if let Some(surface) = removed {
            self.purge_surface_side_tables(surface.id);
            surface.kill();
            self.emit(MuxEvent::TreeChanged);
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        if empty {
            self.emit(MuxEvent::Empty);
        }
    }

    /// Close every surface in `tabs` (helper for pane/screen/workspace
    /// close). Emits events outside the lock.
    fn close_surfaces(&self, tabs: Vec<SurfaceId>) {
        let (removed, changed_screens, empty) = {
            let mut state = self.state.lock().unwrap();
            let changed_screens = unique_screen_ids(
                tabs.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
            );
            let mut removed = Vec::new();
            for surface in tabs {
                if let Some(surface) = remove_surface(&mut state, surface) {
                    removed.push(surface);
                }
            }
            (removed, changed_screens, state.workspaces.is_empty())
        };
        if !removed.is_empty() {
            for surface in removed {
                self.purge_surface_side_tables(surface.id);
                surface.kill();
            }
            self.emit(MuxEvent::TreeChanged);
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        if empty {
            self.emit(MuxEvent::Empty);
        }
    }

    /// Close a pane and every tab in it.
    pub fn close_pane(&self, target: PaneId) {
        let tabs = {
            let state = self.state.lock().unwrap();
            match state.panes.get(&target) {
                Some(pane) => pane.tabs.clone(),
                None => return,
            }
        };
        self.close_surfaces(tabs);
    }

    /// Close a screen and every pane/tab in it.
    pub fn close_screen(&self, target: ScreenId) -> bool {
        let tabs = {
            let state = self.state.lock().unwrap();
            let Some(screen) =
                state.workspaces.iter().flat_map(|ws| ws.screens.iter()).find(|s| s.id == target)
            else {
                return false;
            };
            screen_tabs(&state, screen)
        };
        self.close_surfaces(tabs);
        true
    }

    /// Close a workspace and every screen/pane/tab in it.
    pub fn close_workspace(&self, target: WorkspaceId) -> bool {
        let tabs = {
            let state = self.state.lock().unwrap();
            let Some(ws) = state.workspaces.iter().find(|ws| ws.id == target) else {
                return false;
            };
            ws.screens.iter().flat_map(|screen| screen_tabs(&state, screen)).collect::<Vec<_>>()
        };
        self.close_surfaces(tabs);
        true
    }

    pub fn rename_workspace(&self, target: WorkspaceId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state.workspaces.iter_mut().find(|ws| ws.id == target) {
                Some(ws) => {
                    ws.name = name;
                    true
                }
                None => false,
            }
        };
        if renamed {
            self.emit(MuxEvent::TreeChanged);
        }
        renamed
    }

    /// Set a pane's user-visible name. An empty name clears it (the pane
    /// falls back to its active tab's title).
    pub fn rename_pane(&self, target: PaneId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.name = (!name.is_empty()).then_some(name);
                    true
                }
                None => false,
            }
        };
        if renamed {
            self.emit(MuxEvent::TreeChanged);
        }
        renamed
    }

    /// Set a tab's user-visible name. An empty name clears it (the tab
    /// falls back to its process title/number label).
    pub fn rename_surface(&self, target: SurfaceId, name: String) -> bool {
        let surface = self.state.lock().unwrap().surfaces.get(&target).cloned();
        let Some(surface) = surface else { return false };
        surface.set_name((!name.is_empty()).then_some(name));
        self.emit(MuxEvent::TreeChanged);
        true
    }

    /// Set a screen's user-visible name. An empty name clears it (the
    /// screen falls back to its number).
    pub fn rename_screen(&self, target: ScreenId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state
                .workspaces
                .iter_mut()
                .flat_map(|ws| ws.screens.iter_mut())
                .find(|s| s.id == target)
            {
                Some(screen) => {
                    screen.name = (!name.is_empty()).then_some(name);
                    true
                }
                None => false,
            }
        };
        if renamed {
            self.emit(MuxEvent::TreeChanged);
        }
        renamed
    }

    /// Reap a surface whose child exited before its tree insert completed.
    /// The exit handler sets the dead flag before calling `surface_exited`,
    /// whose `close_surface` finds nothing to remove in that window; the
    /// creator re-checks after the insert (a harmless no-op otherwise).
    fn reap_if_dead(&self, surface: &Arc<Surface>) {
        if surface.is_dead() {
            self.close_surface(surface.id);
        }
    }

    /// Called by a surface's reader thread when its child exits. The mux
    /// reaps the surface out of the tree itself, so frontends only need to
    /// drop their render state.
    pub fn surface_exited(&self, id: SurfaceId) {
        self.close_surface(id);
        self.emit(MuxEvent::SurfaceExited(id));
    }

    /// Make `pane` the active pane of its screen (and that screen and
    /// workspace active).
    pub fn focus_pane(&self, pane: PaneId) -> bool {
        let active_at = self.next_active_at();
        let (found, viewed) = {
            let mut state = self.state.lock().unwrap();
            match state.screen_of(pane) {
                Some((wi, si)) => {
                    state.active_workspace = wi;
                    let ws = &mut state.workspaces[wi];
                    ws.active_screen = si;
                    ws.screens[si].active_pane = pane;
                    stamp_pane(&mut state, pane, active_at);
                    (true, Self::active_surface_in_state(&state))
                }
                None => (false, None),
            }
        };
        if found {
            self.clear_viewed_notification(viewed);
            self.emit(MuxEvent::TreeChanged);
        }
        found
    }

    /// Set the deepest split ratio in `dir` on the path to `pane`.
    pub fn set_ratio(&self, pane: PaneId, dir: SplitDir, ratio: f32) -> bool {
        let ratio = clamp_split_ratio(ratio);
        let changed_screen = {
            let mut state = self.state.lock().unwrap();
            state.workspaces.iter_mut().flat_map(|ws| ws.screens.iter_mut()).find_map(|screen| {
                screen.root.set_deepest_ratio(pane, dir, ratio).then_some(screen.id)
            })
        };
        if let Some(screen) = changed_screen {
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(screen));
            true
        } else {
            false
        }
    }

    pub fn pane_neighbor(&self, pane: PaneId, dir: Direction) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some((wi, si)) = state.screen_of(pane) else {
                anyhow::bail!("unknown pane {pane}");
            };
            let screen = &state.workspaces[wi].screens[si];
            let (dx, dy) = dir.delta();
            let layout =
                layout_screen(&screen.root, Rect { x: 0, y: 0, width: 10_000, height: 10_000 });
            Ok(layout.neighbor(pane, dx, dy))
        })
    }

    pub fn focus_direction(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        dir: Direction,
    ) -> anyhow::Result<PaneId> {
        let target = self.with_state(|state| pane.or_else(|| state.active_pane()));
        let Some(target) = target else {
            anyhow::bail!("no active pane");
        };
        let Some(next) = self.pane_neighbor(target, dir)? else {
            anyhow::bail!("no neighbor");
        };
        if !self.focus_pane(next) {
            anyhow::bail!("unknown pane {next}");
        }
        Ok(next)
    }

    pub fn swap_panes(&self, pane: PaneId, target: PaneId) -> bool {
        let changed_screen = {
            let mut state = self.state.lock().unwrap();
            state
                .workspaces
                .iter_mut()
                .flat_map(|ws| ws.screens.iter_mut())
                .find_map(|screen| screen.root.swap_leaves(pane, target).then_some(screen.id))
        };
        if let Some(screen) = changed_screen {
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(screen));
            true
        } else {
            false
        }
    }

    pub fn zoom_pane(&self, pane: Option<PaneId>, mode: ZoomMode) -> anyhow::Result<ZoomState> {
        let changed = {
            let mut state = self.state.lock().unwrap();
            let target = match pane.or_else(|| state.active_pane()) {
                Some(pane) => pane,
                None => anyhow::bail!("no active pane"),
            };
            let Some((wi, si)) = state.screen_of(target) else {
                anyhow::bail!("unknown pane {target}");
            };
            let screen = &mut state.workspaces[wi].screens[si];
            let next = match mode {
                ZoomMode::Toggle if screen.zoomed_pane == Some(target) => None,
                ZoomMode::Toggle => Some(target),
                ZoomMode::On => Some(target),
                ZoomMode::Off => None,
            };
            let changed = screen.zoomed_pane != next;
            screen.zoomed_pane = next;
            (screen.id, target, next, changed)
        };
        if changed.3 {
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(changed.0));
        }
        Ok(ZoomState { pane: changed.1, zoomed: changed.2.is_some(), zoomed_pane: changed.2 })
    }

    pub fn apply_layout(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        layout: &LayoutSpec,
    ) -> anyhow::Result<AppliedLayout> {
        {
            let state = self.state.lock().unwrap();
            if let Some(id) = workspace
                && !state.workspaces.iter().any(|ws| ws.id == id)
            {
                anyhow::bail!("unknown workspace {id}");
            }
        }

        let mut created = Vec::new();
        let mut panes = Vec::new();
        let mut spawned = Vec::new();
        let root = match self.instantiate_layout(layout, &mut panes, &mut created, &mut spawned) {
            Ok(root) => root,
            Err(err) => {
                self.discard_spawned(spawned);
                return Err(err);
            }
        };
        let Some(active_pane) = created.first().map(|pane| pane.pane) else {
            self.discard_spawned(spawned);
            anyhow::bail!("layout must contain at least one leaf");
        };
        let screen_id = self.next_id();
        {
            let mut state = self.state.lock().unwrap();
            for (pane_id, pane) in panes {
                state.panes.insert(pane_id, pane);
            }
            let screen = Screen { id: screen_id, name, root, active_pane, zoomed_pane: None };
            match workspace {
                Some(id) => {
                    let ws = state
                        .workspaces
                        .iter_mut()
                        .find(|ws| ws.id == id)
                        .expect("workspace validated before spawning");
                    ws.screens.push(screen);
                }
                None if state.workspaces.is_empty() => {
                    let ws_id = self.next_id();
                    state.workspaces.push(Workspace {
                        id: ws_id,
                        name: "1".into(),
                        screens: vec![screen],
                        active_screen: 0,
                    });
                    state.active_workspace = 0;
                }
                None => {
                    let active = state.active_workspace;
                    let ws =
                        state.workspaces.get_mut(active).expect("active workspace index valid");
                    ws.screens.push(screen);
                }
            }
        }
        self.emit(MuxEvent::TreeChanged);
        self.emit(MuxEvent::LayoutChanged(screen_id));
        for surface in spawned {
            self.reap_if_dead(&surface);
        }
        Ok(AppliedLayout { screen: screen_id, panes: created })
    }

    fn instantiate_layout(
        self: &Arc<Self>,
        layout: &LayoutSpec,
        panes: &mut Vec<(PaneId, Pane)>,
        created: &mut Vec<AppliedPane>,
        spawned: &mut Vec<Arc<Surface>>,
    ) -> anyhow::Result<Node> {
        match layout {
            LayoutSpec::Leaf(spec) => {
                if spec.command.as_ref().is_some_and(|argv| argv.is_empty()) {
                    anyhow::bail!("leaf command must not be empty");
                }
                let surface =
                    self.spawn_surface_with(spec.cwd.clone(), spec.command.clone(), None)?;
                let (pane_id, pane) = self.make_pane(surface.id);
                created.push(AppliedPane { pane: pane_id, surface: surface.id });
                panes.push((pane_id, pane));
                spawned.push(surface);
                Ok(Node::Leaf(pane_id))
            }
            LayoutSpec::Split { dir, ratio, a, b } => Ok(Node::Split {
                dir: *dir,
                ratio: clamp_split_ratio(*ratio),
                a: Box::new(self.instantiate_layout(a, panes, created, spawned)?),
                b: Box::new(self.instantiate_layout(b, panes, created, spawned)?),
            }),
        }
    }

    fn discard_spawned(&self, spawned: Vec<Arc<Surface>>) {
        if spawned.is_empty() {
            return;
        }
        let ids = spawned.iter().map(|surface| surface.id).collect::<Vec<_>>();
        {
            let mut state = self.state.lock().unwrap();
            for id in &ids {
                state.surfaces.remove(id);
            }
        }
        for surface in spawned {
            surface.kill();
        }
    }

    /// Move an existing tab to `index` in `pane`. The surface is kept
    /// alive; if moving it empties the source pane, that pane collapses
    /// out of its split tree.
    pub fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) -> bool {
        let active_at = self.next_active_at();
        let moved = {
            let mut state = self.state.lock().unwrap();
            let moved = move_tab_in_state(&mut state, surface, pane, index);
            if moved {
                stamp_pane(&mut state, pane, active_at);
            }
            moved
        };
        if moved {
            self.emit(MuxEvent::TreeChanged);
        }
        moved
    }

    /// Reorder a workspace. The active workspace follows the moved entry.
    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) -> bool {
        let moved = {
            let mut state = self.state.lock().unwrap();
            let Some(old_idx) = state.workspaces.iter().position(|ws| ws.id == workspace) else {
                return false;
            };
            let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
            let new_idx = new_idx.min(state.workspaces.len().saturating_sub(1));
            if new_idx == old_idx {
                return false;
            }
            let active_id = state.workspaces.get(state.active_workspace).map(|ws| ws.id);
            let ws = state.workspaces.remove(old_idx);
            state.workspaces.insert(new_idx, ws);
            state.active_workspace = active_id
                .and_then(|id| state.workspaces.iter().position(|ws| ws.id == id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            true
        };
        if moved {
            self.emit(MuxEvent::TreeChanged);
        }
        moved
    }

    /// Select a tab within a pane (default: the active pane) by index or
    /// relative delta.
    pub fn select_tab(&self, pane: Option<PaneId>, index: Option<usize>, delta: Option<isize>) {
        let active_at = self.next_active_at();
        let viewed = {
            let mut state = self.state.lock().unwrap();
            let Some(target) = pane.or_else(|| state.active_pane()) else { return };
            let Some(pane) = state.panes.get_mut(&target) else { return };
            let len = pane.tabs.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    pane.active_tab = index;
                }
            } else if let Some(delta) = delta {
                pane.active_tab =
                    ((pane.active_tab as isize + delta).rem_euclid(len as isize)) as usize;
            }
            stamp_pane(&mut state, target, active_at);
            state.panes.get(&target).and_then(|pane| pane.active_surface())
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a screen in the active workspace by index or relative delta.
    pub fn select_screen(&self, index: Option<usize>, delta: Option<isize>) {
        let active_at = self.next_active_at();
        let viewed = {
            let mut state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let Some(ws) = state.workspaces.get_mut(active) else { return };
            let len = ws.screens.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    ws.active_screen = index;
                }
            } else if let Some(delta) = delta {
                ws.active_screen =
                    ((ws.active_screen as isize + delta).rem_euclid(len as isize)) as usize;
            }
            if let Some(pane) = ws.active_screen_ref().map(|screen| screen.active_pane) {
                stamp_pane(&mut state, pane, active_at);
            }
            Self::active_surface_in_state(&state)
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a workspace by index or relative delta.
    pub fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        let active_at = self.next_active_at();
        let viewed = {
            let mut state = self.state.lock().unwrap();
            let len = state.workspaces.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    state.active_workspace = index;
                }
            } else if let Some(delta) = delta {
                state.active_workspace =
                    ((state.active_workspace as isize + delta).rem_euclid(len as isize)) as usize;
            }
            if let Some(pane) = state
                .workspaces
                .get(state.active_workspace)
                .and_then(|ws| ws.active_screen_ref().map(|screen| screen.active_pane))
            {
                stamp_pane(&mut state, pane, active_at);
            }
            Self::active_surface_in_state(&state)
        };
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

impl Drop for Mux {
    fn drop(&mut self) {
        if let Ok(state) = self.state.get_mut() {
            for surface in state.surfaces.values() {
                surface.kill();
            }
        }
        if let Ok(runtime) = self.browser_runtime.get_mut()
            && let Some(runtime) = runtime.take()
        {
            runtime.shutdown();
        }
    }
}

/// Every surface in a screen (all panes, all tabs).
fn screen_tabs(state: &State, screen: &Screen) -> Vec<SurfaceId> {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    pane_ids
        .iter()
        .filter_map(|id| state.panes.get(id))
        .flat_map(|pane| pane.tabs.iter().copied())
        .collect()
}

fn stamp_pane(state: &mut State, pane: PaneId, active_at: u64) {
    if let Some(pane) = state.panes.get_mut(&pane) {
        pane.active_at = active_at;
    }
}

fn most_recent_pane(state: &State, panes: &[PaneId]) -> Option<PaneId> {
    panes
        .iter()
        .filter_map(|id| state.panes.get(id).map(|pane| (*id, pane.active_at)))
        .max_by_key(|(_, active_at)| *active_at)
        .map(|(id, _)| id)
}

fn clamp_split_ratio(ratio: f32) -> f32 {
    ratio.clamp(0.05, 0.95)
}

fn unique_screen_ids(ids: impl IntoIterator<Item = ScreenId>) -> Vec<ScreenId> {
    let mut unique = Vec::new();
    for id in ids {
        if !unique.contains(&id) {
            unique.push(id);
        }
    }
    unique
}

fn surface_screen_id(state: &State, surface: SurfaceId) -> Option<ScreenId> {
    let pane = state.pane_of(surface)?;
    let (wi, si) = state.screen_of(pane)?;
    Some(state.workspaces[wi].screens[si].id)
}

/// Remove one surface from the state: detach it from its
/// pane, and collapse emptied panes/screens/workspaces. Returns whether
/// anything was removed. Runs under the state lock.
fn remove_surface(state: &mut State, target: SurfaceId) -> Option<Arc<Surface>> {
    let removed = state.surfaces.remove(&target);
    let Some(pane_id) = state.pane_of(target) else {
        return removed;
    };
    let pane = state.panes.get_mut(&pane_id).expect("pane_of returned live id");
    let idx = pane.tabs.iter().position(|id| *id == target).expect("tab in pane");
    pane.tabs.remove(idx);
    if !pane.tabs.is_empty() {
        if pane.active_tab >= idx && pane.active_tab > 0 {
            pane.active_tab -= 1;
        }
        return removed;
    }

    // Last tab gone: the pane collapses out of its screen.
    state.panes.remove(&pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return removed;
    };
    let (was_active, root) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
        (was_active, root)
    };
    match root.remove_leaf(pane_id) {
        Some(root) => {
            let next_active = if was_active {
                let mut ids = Vec::new();
                root.pane_ids(&mut ids);
                most_recent_pane(state, &ids)
            } else {
                None
            };
            let screen = &mut state.workspaces[wi].screens[si];
            screen.root = root;
            if let Some(next) = next_active {
                screen.active_pane = next;
            }
            return removed;
        }
        None => {
            // Screen emptied: drop it from the workspace.
            let ws = &mut state.workspaces[wi];
            ws.screens.remove(si);
            ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
            if !ws.screens.is_empty() {
                return removed;
            }
        }
    }

    // Workspace emptied too: drop it, keeping the active selection stable.
    let active_id = state.workspaces.get(state.active_workspace).map(|w| w.id);
    state.workspaces.remove(wi);
    state.active_workspace = active_id
        .and_then(|id| state.workspaces.iter().position(|w| w.id == id))
        .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
    removed
}

fn collapse_empty_pane(state: &mut State, pane_id: PaneId) {
    state.panes.remove(&pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return;
    };
    let (was_active, root) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
        (was_active, root)
    };
    match root.remove_leaf(pane_id) {
        Some(root) => {
            let next_active = if was_active {
                let mut ids = Vec::new();
                root.pane_ids(&mut ids);
                most_recent_pane(state, &ids)
            } else {
                None
            };
            let screen = &mut state.workspaces[wi].screens[si];
            screen.root = root;
            if let Some(next) = next_active {
                screen.active_pane = next;
            }
        }
        None => {
            let ws = &mut state.workspaces[wi];
            ws.screens.remove(si);
            ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
            if !ws.screens.is_empty() {
                return;
            }
            let active_id = state.workspaces.get(state.active_workspace).map(|w| w.id);
            state.workspaces.remove(wi);
            state.active_workspace = active_id
                .and_then(|id| state.workspaces.iter().position(|w| w.id == id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
        }
    }
}

fn move_tab_in_state(
    state: &mut State,
    surface: SurfaceId,
    target_pane: PaneId,
    index: usize,
) -> bool {
    if !state.surfaces.contains_key(&surface) || !state.panes.contains_key(&target_pane) {
        return false;
    }
    let Some(source_pane) = state.pane_of(surface) else { return false };
    if source_pane == target_pane {
        let Some(pane) = state.panes.get_mut(&target_pane) else {
            return false;
        };
        let Some(old_idx) = pane.tabs.iter().position(|id| *id == surface) else {
            return false;
        };
        let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
        let new_idx = new_idx.min(pane.tabs.len().saturating_sub(1));
        if new_idx == old_idx {
            return false;
        }
        let tab = pane.tabs.remove(old_idx);
        pane.tabs.insert(new_idx, tab);
        pane.active_tab = new_idx;
        return true;
    }

    {
        let Some(source) = state.panes.get_mut(&source_pane) else {
            return false;
        };
        let Some(old_idx) = source.tabs.iter().position(|id| *id == surface) else {
            return false;
        };
        source.tabs.remove(old_idx);
        if !source.tabs.is_empty() && source.active_tab >= old_idx && source.active_tab > 0 {
            source.active_tab -= 1;
        }
    }

    if state.panes.get(&source_pane).is_some_and(|pane| pane.tabs.is_empty()) {
        collapse_empty_pane(state, source_pane);
    }

    let Some(target) = state.panes.get_mut(&target_pane) else {
        return false;
    };
    let new_idx = index.min(target.tabs.len());
    target.tabs.insert(new_idx, surface);
    target.active_tab = new_idx;
    if let Some((wi, si)) = state.screen_of(target_pane) {
        state.active_workspace = wi;
        let ws = &mut state.workspaces[wi];
        ws.active_screen = si;
        ws.screens[si].active_pane = target_pane;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
    }

    #[test]
    fn agent_reports_apply_hook_authority() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let socket = mux.report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("socket-session".to_string()),
        );
        assert_eq!(socket.state, AgentState::Working);
        assert_eq!(socket.source, AgentSource::Socket);

        let hook = mux.report_agent(
            surface.id,
            AgentState::Blocked,
            AgentSource::Hook,
            Some("hook-session".to_string()),
        );
        assert_eq!(hook.state, AgentState::Blocked);
        assert_eq!(hook.source, AgentSource::Hook);

        let ignored_socket = mux.report_agent(
            surface.id,
            AgentState::Done,
            AgentSource::Socket,
            Some("late-socket".to_string()),
        );
        assert_eq!(ignored_socket.state, AgentState::Blocked);
        assert_eq!(ignored_socket.source, AgentSource::Hook);

        let filtered = mux.list_agents(Some(surface.id), Some(AgentState::Blocked));
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].session.as_deref(), Some("hook-session"));
        assert!(mux.list_agents(Some(surface.id), Some(AgentState::Done)).is_empty());
    }

    #[test]
    fn closing_a_surface_purges_agent_and_notification_side_tables() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        // A second tab keeps the workspace alive after `first` closes, so we
        // exercise the per-surface purge rather than a full teardown.
        let second = mux.new_tab(Some(pane), None, None).unwrap();

        mux.report_agent(
            first.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("conf".to_string()),
        );
        mux.post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        );
        assert_eq!(mux.list_agents(Some(first.id), None).len(), 1);
        assert!(mux.surface_notification(first.id).is_some());

        mux.close_surface(first.id);

        // The dead surface must not linger in either side table.
        assert!(mux.list_agents(Some(first.id), None).is_empty());
        assert!(mux.list_agents(None, None).is_empty());
        assert!(mux.surface_notification(first.id).is_none());
        assert!(mux.with_state(|state| state.surfaces.contains_key(&second.id)));
    }

    #[test]
    fn notification_sets_unread_and_clears_when_tab_is_viewed() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, None).unwrap();
        let notification = mux.post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        );

        let state = mux.surface_notification(first.id).unwrap();
        assert_eq!(state.notification, notification);
        assert_eq!(state.level, NotificationLevel::Warning);
        assert!(state.unread);

        mux.select_tab(Some(pane), Some(1), None);
        assert!(mux.surface_notification(first.id).is_some());
        mux.select_tab(Some(pane), Some(0), None);
        assert!(mux.surface_notification(first.id).is_none());
        assert!(mux.surface_notification(second.id).is_none());
    }

    #[test]
    fn notification_to_active_surface_does_not_set_unread() {
        let mux = test_mux();
        let events = mux.subscribe();
        let surface = mux.new_workspace(None, None).unwrap();
        assert_eq!(mux.active_surface(), Some(surface.id));

        let notification = mux.post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Info,
            Some(surface.id),
        );

        assert!(mux.surface_notification(surface.id).is_none());
        assert!(events.try_iter().any(|event| {
            matches!(
                event,
                MuxEvent::Notification(note)
                    if note.notification == notification && note.surface == Some(surface.id)
            )
        }));
    }

    fn seed_split_ratio_tree(mux: &Mux) -> (PaneId, PaneId, PaneId) {
        let (p1, p2, p3) = (1, 2, 3);
        *mux.state.lock().unwrap() = State {
            workspaces: vec![Workspace {
                id: 1,
                name: "1".into(),
                screens: vec![Screen {
                    id: 1,
                    name: None,
                    root: Node::Split {
                        dir: SplitDir::Right,
                        ratio: 0.5,
                        a: Box::new(Node::Split {
                            dir: SplitDir::Right,
                            ratio: 0.5,
                            a: Box::new(Node::Leaf(p1)),
                            b: Box::new(Node::Leaf(p3)),
                        }),
                        b: Box::new(Node::Leaf(p2)),
                    },
                    active_pane: p3,
                    zoomed_pane: None,
                }],
                active_screen: 0,
            }],
            active_workspace: 0,
            panes: HashMap::from([
                (p1, Pane { id: p1, name: None, tabs: vec![1], active_tab: 0, active_at: 1 }),
                (p2, Pane { id: p2, name: None, tabs: vec![2], active_tab: 0, active_at: 2 }),
                (p3, Pane { id: p3, name: None, tabs: vec![3], active_tab: 0, active_at: 3 }),
            ]),
            surfaces: HashMap::new(),
        };
        (p1, p2, p3)
    }

    fn leaf_spec() -> LayoutSpec {
        LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None })
    }

    fn split_spec(dir: SplitDir, ratio: f32, a: LayoutSpec, b: LayoutSpec) -> LayoutSpec {
        LayoutSpec::Split { dir, ratio, a: Box::new(a), b: Box::new(b) }
    }

    fn node_shape(node: &Node) -> String {
        match node {
            Node::Leaf(_) => "leaf".to_string(),
            Node::Split { dir, ratio, a, b } => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                format!("{dir}:{ratio:.2}({}, {})", node_shape(a), node_shape(b))
            }
        }
    }

    fn spec_shape(spec: &LayoutSpec) -> String {
        match spec {
            LayoutSpec::Leaf(_) => "leaf".to_string(),
            LayoutSpec::Split { dir, ratio, a, b } => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                format!(
                    "{dir}:{:.2}({}, {})",
                    clamp_split_ratio(*ratio),
                    spec_shape(a),
                    spec_shape(b)
                )
            }
        }
    }

    fn leaf_order(node: &Node) -> Vec<PaneId> {
        let mut ids = Vec::new();
        node.pane_ids(&mut ids);
        ids
    }

    fn screen_root(mux: &Mux, screen: ScreenId) -> Node {
        mux.with_state(|s| {
            s.workspaces
                .iter()
                .flat_map(|ws| ws.screens.iter())
                .find(|candidate| candidate.id == screen)
                .unwrap()
                .root
                .clone()
        })
    }

    #[test]
    fn apply_layout_round_trip_reproduces_tree_shape_and_ratios() {
        let mux = test_mux();
        let spec = split_spec(
            SplitDir::Right,
            0.33,
            leaf_spec(),
            split_spec(SplitDir::Down, 0.67, leaf_spec(), leaf_spec()),
        );
        let first = mux.apply_layout(None, Some("round-trip".into()), &spec).unwrap();
        let exported_shape = node_shape(&screen_root(&mux, first.screen));

        let round_trip_spec = mux.with_state(|s| {
            fn from_node(node: &Node) -> LayoutSpec {
                match node {
                    Node::Leaf(_) => leaf_spec(),
                    Node::Split { dir, ratio, a, b } => {
                        split_spec(*dir, *ratio, from_node(a), from_node(b))
                    }
                }
            }
            from_node(&s.workspaces[0].screens[0].root)
        });
        let second = mux.apply_layout(None, Some("round-trip-2".into()), &round_trip_spec).unwrap();
        let applied_shape = node_shape(&screen_root(&mux, second.screen));

        assert_eq!(exported_shape, spec_shape(&spec));
        assert_eq!(applied_shape, exported_shape);
        assert_eq!(first.panes.len(), 3);
        assert_eq!(second.panes.len(), 3);
    }

    #[test]
    fn pane_neighbor_returns_directional_adjacency() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(
                    SplitDir::Right,
                    0.5,
                    leaf_spec(),
                    split_spec(SplitDir::Down, 0.5, leaf_spec(), leaf_spec()),
                ),
            )
            .unwrap();
        let p1 = applied.panes[0].pane;
        let p2 = applied.panes[1].pane;
        let p3 = applied.panes[2].pane;

        assert_eq!(mux.pane_neighbor(p1, Direction::Right).unwrap(), Some(p2));
        assert_eq!(mux.pane_neighbor(p2, Direction::Down).unwrap(), Some(p3));
        assert_eq!(mux.pane_neighbor(p1, Direction::Left).unwrap(), None);
    }

    #[test]
    fn focus_direction_moves_active_pane() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(None, None, &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()))
            .unwrap();
        let p1 = applied.panes[0].pane;
        let p2 = applied.panes[1].pane;
        assert!(mux.focus_pane(p1));

        assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), p2);
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].active_pane, p2));
        assert!(mux.focus_direction(None, Direction::Right).is_err());
    }

    #[test]
    fn swap_pane_exchanges_leaf_positions_and_preserves_surfaces() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(None, None, &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()))
            .unwrap();
        let p1 = applied.panes[0].pane;
        let s1 = applied.panes[0].surface;
        let p2 = applied.panes[1].pane;
        let s2 = applied.panes[1].surface;
        assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p1, p2]);

        assert!(mux.swap_panes(p1, p2));
        assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p2, p1]);
        mux.with_state(|s| {
            assert_eq!(s.panes[&p1].tabs, vec![s1]);
            assert_eq!(s.panes[&p2].tabs, vec![s2]);
        });
    }

    #[test]
    fn zoom_pane_toggles_screen_zoom_state() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(None, None, &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()))
            .unwrap();
        let p2 = applied.panes[1].pane;

        let zoomed = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
        assert_eq!(zoomed.zoomed_pane, Some(p2));
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, Some(p2)));

        let restored = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
        assert_eq!(restored.zoomed_pane, None);
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, None));
    }

    #[test]
    fn process_info_metadata_is_recorded_for_spawned_surface() {
        let mux = test_mux();
        let cwd = std::env::temp_dir().to_string_lossy().into_owned();
        let applied = mux
            .apply_layout(
                None,
                None,
                &LayoutSpec::Leaf(LayoutLeafSpec {
                    cwd: Some(cwd.clone()),
                    command: Some(vec!["echo".into(), "ok".into()]),
                }),
            )
            .unwrap();
        let surface = mux.surface(applied.panes[0].surface).unwrap();

        assert_eq!(surface.process_id(), Some(surface.id as u32));
        assert_eq!(surface.spawn_command().as_deref(), Some("echo ok"));
        assert_eq!(surface.spawn_cwd().as_deref(), Some(cwd.as_str()));
    }

    #[test]
    fn split_and_close_collapses_tree() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p2, p3]);
        });

        mux.close_pane(p2);
        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p3]);
        });

        mux.close_pane(p1);
        mux.close_pane(p3);
        assert_eq!(mux.surface_count(), 0);
        mux.with_state(|s| assert!(s.workspaces.is_empty()));
    }

    #[test]
    fn structural_test_mux_can_create_many_surfaces_without_ptys() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((120, 40))).unwrap();
        let pane = mux.with_state(|s| s.pane_of(first.id).unwrap());

        for _ in 0..450 {
            mux.new_tab(Some(pane), None, None).unwrap();
        }

        assert_eq!(mux.surface_count(), 451);
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs.len(), 451);
            for surface in pane.tabs.iter().filter_map(|id| s.surfaces.get(id)) {
                assert_eq!(surface.kind(), crate::surface::SurfaceKind::Pty);
                assert_eq!(surface.size(), (120, 40));
                assert!(!surface.is_dead());
            }
        });
    }

    #[test]
    fn closing_active_pane_focuses_most_recent_remaining_pane() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        assert!(mux.focus_pane(p1));
        assert!(mux.focus_pane(p3));
        mux.close_pane(p3);

        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[0].active_pane, p1);
            assert!(s.panes.contains_key(&p2));
        });
    }

    #[test]
    fn tabs_within_pane() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();

        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id, s2.id]);
            assert_eq!(p.active_tab, 1);
        });

        // Closing the active tab activates the previous one; the pane stays.
        mux.close_surface(s2.id);
        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id]);
            assert_eq!(p.active_tab, 0);
            assert_eq!(s.workspaces.len(), 1);
        });

        // Closing the last tab collapses the pane, screen, and workspace.
        mux.close_surface(s1.id);
        mux.with_state(|s| assert!(s.workspaces.is_empty()));
    }

    #[test]
    fn move_tab_within_pane_clamps_and_tracks_active_tab() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();
        let s3 = mux.new_tab(Some(pane), None, None).unwrap();

        assert!(mux.move_tab(s3.id, pane, 0));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s3.id, s1.id, s2.id]);
            assert_eq!(pane.active_tab, 0);
        });

        assert!(mux.move_tab(s3.id, pane, 99));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
            assert_eq!(pane.active_tab, 2);
        });
    }

    #[test]
    fn move_tab_same_position_preserves_active_tab_and_emits_no_event() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();
        let s3 = mux.new_tab(Some(pane), None, None).unwrap();
        mux.select_tab(Some(pane), Some(0), None);
        let events = mux.subscribe();

        assert!(!mux.move_tab(s2.id, pane, 1));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
            assert_eq!(pane.active_tab, 0);
        });
        assert!(events.try_iter().all(|event| !matches!(event, MuxEvent::TreeChanged)));
    }

    #[test]
    fn move_tab_across_panes_collapses_empty_source_and_preserves_surface() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let original_count = mux.surface_count();

        assert!(mux.move_tab(s1.id, p2, 0));
        mux.with_state(|s| {
            assert!(!s.panes.contains_key(&p1));
            let target = &s.panes[&p2];
            assert_eq!(target.tabs, vec![s1.id, s2.id]);
            assert_eq!(target.active_tab, 0);
            assert!(s.surfaces.contains_key(&s1.id));
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p2]);
        });
        assert_eq!(mux.surface_count(), original_count);
    }

    #[test]
    fn set_ratio_updates_deepest_split_and_clamps() {
        let mux = test_mux();
        let (p1, p2, p3) = seed_split_ratio_tree(&mux);

        assert!(mux.set_ratio(p1, SplitDir::Right, 0.8));
        mux.with_state(|s| {
            let root = &s.workspaces[0].screens[0].root;
            let Node::Split { ratio: root_ratio, a, .. } = root else {
                panic!("root should be split");
            };
            assert_eq!(*root_ratio, 0.5);
            let Node::Split { ratio: inner_ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*inner_ratio, 0.8);
        });

        assert!(mux.set_ratio(p2, SplitDir::Right, -1.0));
        mux.with_state(|s| {
            let Node::Split { ratio, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            assert_eq!(*ratio, 0.05);
        });

        assert!(mux.set_ratio(p3, SplitDir::Right, 2.0));
        mux.with_state(|s| {
            let Node::Split { a, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            let Node::Split { ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*ratio, 0.95);
        });

        assert!(!mux.set_ratio(9999, SplitDir::Right, 0.4));
    }

    #[test]
    fn screens_within_workspace() {
        let mux = test_mux();
        mux.new_workspace(None, None).unwrap();
        let s2 = mux.new_screen(None, None).unwrap();

        let (screen1, screen2) = mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 2);
            assert_eq!(ws.active_screen, 1);
            (ws.screens[0].id, ws.screens[1].id)
        });

        // Select back to screen 1; screen 2 keeps running.
        mux.select_screen(Some(0), None);
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 0));

        // Renaming a screen sticks; clearing falls back.
        assert!(mux.rename_screen(screen2, "logs".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[1].name.as_deref(), Some("logs"));
        });

        // Focusing a pane in screen 2 activates that screen.
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        assert!(mux.focus_pane(p2));
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 1));

        // Closing screen 2 keeps the workspace with screen 1.
        assert!(mux.close_screen(screen2));
        mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 1);
            assert_eq!(ws.screens[0].id, screen1);
            assert_eq!(ws.active_screen, 0);
        });
    }

    #[test]
    fn workspaces_and_renames() {
        let mux = test_mux();
        let events = mux.subscribe();
        mux.new_workspace(None, None).unwrap();
        mux.new_workspace(Some("dev".into()), None).unwrap();

        let (ws0, ws1, pane1, surface1) = mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 2);
            assert_eq!(s.workspaces[1].name, "dev");
            assert_eq!(s.active_workspace, 1);
            let pane = s.workspaces[1].screens[0].active_pane;
            let surface = s.panes[&pane].tabs[0];
            (s.workspaces[0].id, s.workspaces[1].id, pane, surface)
        });

        assert!(mux.rename_workspace(ws0, "ops".into()));
        assert!(mux.rename_pane(pane1, "logs".into()));
        assert!(mux.rename_surface(surface1, "api".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].name, "ops");
            assert_eq!(s.panes[&pane1].name.as_deref(), Some("logs"));
            assert_eq!(s.surfaces[&surface1].name().as_deref(), Some("api"));
        });
        // Clearing the names falls back to the generated labels.
        assert!(mux.rename_pane(pane1, String::new()));
        assert!(mux.rename_surface(surface1, String::new()));
        mux.with_state(|s| {
            assert_eq!(s.panes[&pane1].name, None);
            assert_eq!(s.surfaces[&surface1].name(), None);
        });

        assert!(mux.close_workspace(ws1));
        mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 1);
            assert_eq!(s.workspaces[0].id, ws0);
            assert_eq!(s.active_workspace, 0);
        });
        assert!(events.try_iter().count() > 0);
    }

    #[test]
    fn move_workspace_reorders_and_tracks_active_workspace() {
        let mux = test_mux();
        mux.new_workspace(Some("one".into()), None).unwrap();
        mux.new_workspace(Some("two".into()), None).unwrap();
        mux.new_workspace(Some("three".into()), None).unwrap();
        let (ws1, ws2, ws3) =
            mux.with_state(|s| (s.workspaces[0].id, s.workspaces[1].id, s.workspaces[2].id));

        assert!(mux.move_workspace(ws3, 0));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws1, ws2]
            );
            assert_eq!(s.active_workspace, 0);
        });

        assert!(mux.move_workspace(ws1, 99));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws2, ws1]
            );
            assert_eq!(s.active_workspace, 0);
        });
    }
}
