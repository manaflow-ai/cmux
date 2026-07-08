//! TUI event loop and tmux-like command handling.
//!
//! Runs against a [`Session`], which is either the in-process mux or a
//! remote session attached over the control socket. All state mutations
//! go through the session; the app only owns presentation state (render
//! snapshots, prefix arming, the current layout, hit map, selection, and
//! menu/prompt overlays).

use std::collections::HashMap;
use std::io::Write;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use crossterm::event::{
    DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, EnableBracketedPaste,
    EnableFocusChange, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers,
    MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ghostty_vt::{KeyEncoder, RenderState, Screen};
use mux_core::{
    layout_screen, split_for_pane_edge, split_sides, BrowserSource, BrowserStatus, MuxEvent,
    PaneId, Rect, SplitDir, SplitEdge, SurfaceId, SurfaceKind, WorkspaceId,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal as RatatuiTerminal;

use crate::browser_input::{BrowserInputDispatcher, BrowserInputEvent, BrowserInputKind};
use crate::config::{Action, Config, ScrollbarPosition};
use crate::keys;
use crate::session::{Session, SurfaceHandle, TreeView};
use crate::ui::graphics::GraphicPlacement;
use crate::ui::graphics_writer::GraphicsWriter;
use crate::ui::input::{InputEvent, TextInput};
use crate::ui::thumb_geometry;

pub enum AppEvent {
    Mux(MuxEvent),
    Input(Event),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RenderAction {
    None,
    Graphics,
    Draw,
}

impl RenderAction {
    fn merge(self, other: Self) -> Self {
        match (self, other) {
            (RenderAction::Draw, _) | (_, RenderAction::Draw) => RenderAction::Draw,
            (RenderAction::Graphics, _) | (_, RenderAction::Graphics) => RenderAction::Graphics,
            (RenderAction::None, RenderAction::None) => RenderAction::None,
        }
    }
}

/// A clickable region of the current frame. The renderers rebuild the hit
/// map every draw, so hit-testing always matches what is on screen.
/// Left-click performs the action; right-click opens the matching context
/// menu where one exists (workspace rows, panes).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Hit {
    /// Sidebar workspace entry.
    Workspace {
        index: usize,
        id: WorkspaceId,
    },
    NewWorkspace,
    /// Status-bar screen entry.
    ScreenEntry {
        index: usize,
        id: mux_core::ScreenId,
    },
    NewScreen,
    /// Pane tab-bar entry.
    Tab {
        pane: PaneId,
        index: usize,
    },
    NewTab {
        pane: PaneId,
    },
    /// A pane's scrollbar column (click/drag jumps the viewport).
    Scrollbar {
        surface: SurfaceId,
        track: Rect,
    },
    /// Sidebar right border.
    SidebarResize,
    /// Pane border resize handle.
    PaneResize {
        horizontal: Option<(PaneId, PaneEdge)>,
        vertical: Option<(PaneId, PaneEdge)>,
    },
    /// Scroll a pane's tab bar left/right (overflow arrows, wheel).
    TabScroll {
        pane: PaneId,
        delta: isize,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneEdge {
    Left,
    Right,
    Top,
    Bottom,
}

/// One pane's screen real estate for the current frame. Every pane draws
/// a border box in its rect; the top border row doubles as the tab bar
/// and the scrollbar is either inside the box or on the right border.
/// `content` is the terminal area inside the box. Rects too small for a
/// box get `bar: None` and content = rect.
#[derive(Debug, Clone, Copy)]
pub struct PaneArea {
    pub pane: PaneId,
    pub surface: SurfaceId,
    pub rect: Rect,
    pub bar: Option<Rect>,
    pub omnibar: Option<Rect>,
    pub content: Rect,
    /// Scrollbar track (inside the box or on the right border).
    pub track: Option<Rect>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OmnibarHit {
    Back,
    Forward,
    Reload,
    Edit,
}

/// A context-menu entry: what activating it does (the label is derived).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    RenameWorkspace(WorkspaceId),
    CopyWorkspaceId(WorkspaceId),
    CloseWorkspace(WorkspaceId),
    RenameScreen(mux_core::ScreenId),
    CloseScreen(mux_core::ScreenId),
    BrowserBack(PaneId),
    BrowserForward(PaneId),
    BrowserReload(PaneId),
    BrowserEditUrl(PaneId),
    BrowserCopyUrl(PaneId),
    BrowserActivate(PaneId),
    RenameTab(PaneId),
    CopyTabId(PaneId),
    CopyPaneId(PaneId),
    NewTab(PaneId),
    NewBrowserTab(PaneId),
    SplitRight(PaneId),
    SplitDown(PaneId),
    CloseTab(PaneId),
    ClosePane(PaneId),
}

impl MenuAction {
    pub fn label(&self) -> &'static str {
        match self {
            MenuAction::RenameWorkspace(_) => "Rename workspace",
            MenuAction::CopyWorkspaceId(_) => "Copy workspace id",
            MenuAction::CloseWorkspace(_) => "Close workspace",
            MenuAction::RenameScreen(_) => "Rename screen",
            MenuAction::CloseScreen(_) => "Close screen",
            MenuAction::BrowserBack(_) => "Back",
            MenuAction::BrowserForward(_) => "Forward",
            MenuAction::BrowserReload(_) => "Reload",
            MenuAction::BrowserEditUrl(_) => "Edit URL",
            MenuAction::BrowserCopyUrl(_) => "Copy URL",
            MenuAction::BrowserActivate(_) => "Show in Chrome",
            MenuAction::RenameTab(_) => "Rename tab",
            MenuAction::CopyTabId(_) => "Copy tab id",
            MenuAction::CopyPaneId(_) => "Copy pane id",
            MenuAction::NewTab(_) => "New tab",
            MenuAction::NewBrowserTab(_) => "New browser tab",
            MenuAction::SplitRight(_) => "Split right",
            MenuAction::SplitDown(_) => "Split down",
            MenuAction::CloseTab(_) => "Close tab",
            MenuAction::ClosePane(_) => "Close pane",
        }
    }
}

/// Right-click context menu overlay. The rect includes the border chrome;
/// items get a one-cell padding column on each side inside that border
/// (no extra rows above/below), and the hover/selection highlight spans
/// the full inner row including those padding cells.
pub struct ContextMenu {
    pub items: Vec<MenuAction>,
    pub selected: usize,
    right_press: (u16, u16),
    right_drag_moved: bool,
    /// Where the menu is drawn (clamped to the screen by the renderer,
    /// which writes the final rect back for hit-testing).
    pub rect: Rect,
}

impl ContextMenu {
    /// Horizontal padding between the menu edge and the item labels.
    pub const PAD: u16 = 1;

    fn at(x: u16, y: u16, items: Vec<MenuAction>) -> Self {
        let label_w = items.iter().map(|i| i.label().len()).max().unwrap_or(0) as u16;
        // One space of inner padding either side of the label, plus the
        // one-cell padding column on each side, plus the border.
        let width = label_w + 2 + Self::PAD * 2 + 2;
        let height = items.len() as u16 + 2;
        ContextMenu {
            items,
            selected: 0,
            right_press: (x, y),
            right_drag_moved: false,
            rect: Rect { x: x.saturating_sub(1), y: y.saturating_sub(1), width, height },
        }
    }

    /// The item row at a screen cell. Border cells are dead chrome and
    /// never activate an item.
    pub fn item_at(&self, x: u16, y: u16) -> Option<usize> {
        if !self.rect.contains(x, y) {
            return None;
        }
        let right = self.rect.x + self.rect.width.saturating_sub(1);
        let bottom = self.rect.y + self.rect.height.saturating_sub(1);
        if x == self.rect.x || y == self.rect.y || x == right || y == bottom {
            return None;
        }
        let row = (y - self.rect.y - 1) as usize;
        (row < self.items.len()).then_some(row)
    }
}

/// What a committed rename prompt applies to.
#[derive(Debug, Clone, Copy)]
pub enum PromptTarget {
    Workspace(WorkspaceId),
    Screen(mux_core::ScreenId),
    Surface(SurfaceId),
}

/// Centered rename dialog: a text input with OK/Cancel buttons. The
/// renderer writes the final geometry back so mouse hit-testing (buttons,
/// dismiss-outside) matches what is drawn.
pub struct Prompt {
    pub label: &'static str,
    pub input: TextInput,
    pub target: PromptTarget,
    /// Dialog rect (set by the renderer each frame).
    pub rect: Rect,
    /// Input / button rects (set by the renderer each frame).
    pub input_rect: Rect,
    pub clear: Rect,
    pub ok: Rect,
    pub cancel: Rect,
}

#[derive(Debug, Clone)]
pub struct OmnibarState {
    pub pane: PaneId,
    pub surface: SurfaceId,
    pub input: TextInput,
    pub select_all: bool,
}

pub struct Toast {
    pub text: String,
    deadline: Instant,
}

#[derive(Debug, Clone, Copy)]
struct BrowserMouseDispatch {
    event_type: &'static str,
    button: Option<&'static str>,
    click_count: Option<u32>,
}

impl BrowserMouseDispatch {
    const fn new(
        event_type: &'static str,
        button: Option<&'static str>,
        click_count: Option<u32>,
    ) -> Self {
        Self { event_type, button, click_count }
    }
}

impl Prompt {
    fn new(label: &'static str, buffer: String, target: PromptTarget) -> Self {
        Prompt {
            label,
            input: TextInput::new(buffer),
            target,
            rect: Rect::default(),
            input_rect: Rect::default(),
            clear: Rect::default(),
            ok: Rect::default(),
            cancel: Rect::default(),
        }
    }
}

/// A text selection in one surface. Rows are absolute scrollback rows:
/// viewport row + scrollbar offset at capture time, so the selection
/// remains stable while the viewport scrolls.
#[derive(Debug, Clone, Copy)]
pub struct Selection {
    pub surface: SurfaceId,
    pub anchor: (u16, u64),
    pub head: (u16, u64),
}

impl Selection {
    /// Normalized (start, end) in row-major order, inclusive.
    pub fn range(&self) -> ((u16, u64), (u16, u64)) {
        let a = (self.anchor.1, self.anchor.0);
        let h = (self.head.1, self.head.0);
        if a <= h {
            (self.anchor, self.head)
        } else {
            (self.head, self.anchor)
        }
    }

    /// Whether a viewport cell is inside the (linear) selection at the
    /// current scrollbar offset.
    pub fn contains_viewport(&self, x: u16, y: u16, offset: u64) -> bool {
        let y = offset + y as u64;
        let ((sx, sy), (ex, ey)) = self.range();
        if y < sy || y > ey {
            return false;
        }
        if sy == ey {
            return x >= sx && x <= ex;
        }
        if y == sy {
            return x >= sx;
        }
        if y == ey {
            return x <= ex;
        }
        true
    }
}

#[derive(Debug, Clone, Copy)]
pub struct TabDragView {
    pub surface: SurfaceId,
    pub target: Option<(PaneId, usize)>,
}

/// Mouse drag in progress.
enum Drag {
    /// Left press on a tab chip; becomes `Tab` after moving cells.
    TabArm { surface: SurfaceId, at: (u16, u16) },
    /// Tab drag with the current drop target.
    Tab { surface: SurfaceId, target: Option<(PaneId, usize)> },
    /// Left press on a workspace entry; becomes `Workspace` after moving cells.
    WorkspaceArm { workspace: WorkspaceId, at: (u16, u16) },
    /// Workspace drag with the current insertion index.
    Workspace { workspace: WorkspaceId, target: Option<usize> },
    /// Text selection inside a pane's content rect.
    Select { content: Rect, auto_scroll: Option<i8>, col: u16 },
    /// Browser mouse drag inside a pane's content rect.
    Browser { surface: SurfaceId, content: Rect },
    /// Scrollbar thumb drag.
    Scrollbar { surface: SurfaceId, track: Rect, anchor_y: u16, anchor_offset: u64 },
    /// Sidebar width override drag.
    SidebarResize,
    /// Pane split resize drag.
    ResizeSplit { horizontal: Option<(PaneId, PaneEdge)>, vertical: Option<(PaneId, PaneEdge)> },
}

pub struct App {
    pub session: Session,
    pub config: Config,
    pub tree: TreeView,
    pub render_states: HashMap<SurfaceId, RenderState>,
    pub graphics_writer: Option<GraphicsWriter>,
    pub graphics_supported: bool,
    stdout_lock: Arc<Mutex<()>>,
    pub pane_areas: Vec<PaneArea>,
    pub prefix_armed: bool,
    pub session_label: String,
    pub sidebar_visible: bool,
    /// Width of the sidebar in the current frame (0 when hidden).
    pub sidebar_width: u16,
    sidebar_width_override: Option<u16>,
    /// Pane region of the current frame (screen minus sidebar/status).
    pub content_area: Rect,
    /// Clickable regions of the current frame, rebuilt by the renderers.
    pub hits: Vec<(Rect, Hit)>,
    /// Per-pane tab-bar scroll offset (first visible tab index), for
    /// panes whose tabs overflow the bar. Presentation state only.
    pub tab_scroll: HashMap<PaneId, usize>,
    /// Last mouse position; tab-bar controls (+, ‹, ›) under it render
    /// a hover highlight.
    pub hover: Option<(u16, u16)>,
    pub menu: Option<ContextMenu>,
    pub prompt: Option<Prompt>,
    pub omnibar: Option<OmnibarState>,
    pub toast: Option<Toast>,
    pub(crate) shake_frames: u8,
    pub selection: Option<Selection>,
    pub status_message: Option<String>,
    pub cell_pixels: (u16, u16),
    /// Whether the terminal pointer is currently the hand shape (over a
    /// clickable element); tracked to avoid re-emitting OSC 22.
    pointer_shape: bool,
    last_browser_hover: Option<(SurfaceId, u16, u16)>,
    /// Off-loop forwarder for browser input: CDP/socket round trips must
    /// never run on the event-loop thread (see `browser_input`).
    browser_input: BrowserInputDispatcher,
    drag: Option<Drag>,
    encoder: KeyEncoder,
    encode_buf: Vec<u8>,
    quit: bool,
}

/// Sidebar width for a terminal width: the configured width, hidden on
/// terminals too narrow to give panes room next to it.
fn sidebar_width_for(
    config: &Config,
    visible: bool,
    width: u16,
    override_width: Option<u16>,
) -> u16 {
    if !visible {
        return 0;
    }
    clamp_sidebar_width(config, width, override_width.unwrap_or(config.sidebar.width)).unwrap_or(0)
}

fn clamp_sidebar_width(config: &Config, terminal_width: u16, desired: u16) -> Option<u16> {
    let terminal_max = terminal_width.saturating_sub(40);
    let configured_max =
        if config.sidebar.max_width > 0 { config.sidebar.max_width } else { u16::MAX };
    let effective_max = terminal_max.min(configured_max);
    (effective_max >= 10).then_some(desired.clamp(10, effective_max))
}

fn sidebar_drag_width(config: &Config, content: Rect, sidebar_width: u16, x: u16) -> Option<u16> {
    let terminal_width = content.width.saturating_add(sidebar_width);
    clamp_sidebar_width(config, terminal_width, x.saturating_add(1))
}

fn content_size_for_rect(rect: Rect, scrollbar: ScrollbarPosition) -> Option<(u16, u16)> {
    let (_, _, content, _) = pane_parts_for_rect(rect, scrollbar, false);
    (content.width > 0 && content.height > 0).then_some((content.width, content.height))
}

fn cell_height_width_ratio(cell_pixels: (u16, u16)) -> u16 {
    let (width, height) = cell_pixels;
    if width == 0 || height == 0 {
        return 4;
    }
    ((height as f32 / width as f32).round() as u16).max(1)
}

fn zellij_smart_direction(content: Rect, ratio: u16) -> Option<SplitDir> {
    let rows = content.height as u32;
    let cols = content.width as u32;
    let ratio = ratio as u32;
    if rows.saturating_mul(ratio) > cols && rows > 20 {
        Some(SplitDir::Down)
    } else if cols > 60 {
        Some(SplitDir::Right)
    } else {
        None
    }
}

fn smart_split_target(
    areas: &[PaneArea],
    focused: Option<PaneId>,
    cell_pixels: (u16, u16),
) -> Option<(PaneId, SplitDir)> {
    let ratio = cell_height_width_ratio(cell_pixels);
    if let Some(area) = focused.and_then(|pane| areas.iter().find(|area| area.pane == pane)) {
        if let Some(dir) = zellij_smart_direction(area.content, ratio) {
            return Some((area.pane, dir));
        }
    }
    areas
        .iter()
        .filter_map(|area| {
            zellij_smart_direction(area.content, ratio).map(|dir| {
                let area_score = area.content.width as u32 * area.content.height as u32;
                (area_score, area.pane, dir)
            })
        })
        .max_by_key(|(area_score, _, _)| *area_score)
        .map(|(_, pane, dir)| (pane, dir))
}

fn browser_content_size_for_rect(rect: Rect, scrollbar: ScrollbarPosition) -> Option<(u16, u16)> {
    let (_, _, content, _) = pane_parts_for_rect(rect, scrollbar, true);
    (content.width > 0 && content.height > 0).then_some((content.width, content.height))
}

fn pane_parts_for_rect(
    rect: Rect,
    scrollbar: ScrollbarPosition,
    browser_omnibar: bool,
) -> (Option<Rect>, Option<Rect>, Rect, Option<Rect>) {
    let (bar, mut content, track) = if rect.width > 2 && rect.height > 2 {
        let reserved_cols = match scrollbar {
            ScrollbarPosition::Column => 3,
            ScrollbarPosition::Border => 2,
        };
        let right_border_x = rect.x + rect.width - 1;
        let track_x = match scrollbar {
            ScrollbarPosition::Column => right_border_x.saturating_sub(1),
            ScrollbarPosition::Border => right_border_x,
        };
        (
            Some(Rect { height: 1, ..rect }),
            Rect {
                x: rect.x + 1,
                y: rect.y + 1,
                width: rect.width.saturating_sub(reserved_cols).max(1),
                height: rect.height - 2,
            },
            Some(Rect { x: track_x, y: rect.y + 1, width: 1, height: rect.height - 2 }),
        )
    } else {
        (None, rect, None)
    };
    let omnibar = if browser_omnibar && content.height >= 2 {
        let row = Rect { height: 1, ..content };
        content.y = content.y.saturating_add(1);
        content.height = content.height.saturating_sub(1);
        Some(row)
    } else {
        None
    };
    (bar, omnibar, content, track)
}

pub fn run(session: Session, session_label: String) -> anyhow::Result<()> {
    let config = crate::config::load();
    // First workspace before the terminal switches modes, so a spawn
    // failure prints a normal error. Spawn at the size the first pane
    // will actually render at (a post-spawn resize makes shells like zsh
    // repaint their prompt, leaving a reverse-video % artifact). The
    // pane's border box eats one cell on every side.
    let initial_size = crossterm::terminal::size().ok().map(|(w, h)| {
        let sidebar = sidebar_width_for(&config, true, w, None);
        let pane = Rect {
            x: sidebar,
            y: 0,
            width: w.saturating_sub(sidebar),
            height: h.saturating_sub(1), // status bar
        };
        content_size_for_rect(pane, config.scrollbar.position).unwrap_or((1, 1))
    });
    session.ensure_initial(initial_size)?;
    let encoder = KeyEncoder::new()?;
    let stdout_lock = Arc::new(Mutex::new(()));

    let (tx, rx) = channel::<AppEvent>();

    // Session events → app channel.
    let session_events = session.events();
    std::thread::Builder::new().name("mux-events".into()).spawn({
        let tx = tx.clone();
        move || {
            while let Ok(event) = session_events.recv() {
                if tx.send(AppEvent::Mux(event)).is_err() {
                    break;
                }
            }
        }
    })?;

    // Crossterm input → app channel.
    enable_raw_mode()?;
    if let Err(e) = (|| -> anyhow::Result<()> {
        let _guard = stdout_lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        stdout.execute(EnterAlternateScreen)?;
        stdout.execute(EnableMouseCapture)?;
        stdout.execute(EnableFocusChange)?;
        stdout.execute(EnableBracketedPaste)?;
        Ok(())
    })() {
        let _ = restore_terminal(Some(&stdout_lock));
        return Err(e);
    }

    let cell_pixels = crate::ui::graphics::detect_cell_pixels(true);
    session.set_cell_pixel_size(cell_pixels.0, cell_pixels.1);
    let graphics_supported = crate::ui::graphics::probe_kitty_graphics();

    // Crossterm input → app channel. Start this after startup terminal
    // probes so DA / window-size responses are not consumed as key input.
    std::thread::Builder::new().name("input".into()).spawn({
        let tx = tx.clone();
        move || {
            while let Ok(event) = crossterm::event::read() {
                if tx.send(AppEvent::Input(event)).is_err() {
                    break;
                }
            }
        }
    })?;
    // Restore the host terminal even if we panic mid-frame.
    let default_hook = std::panic::take_hook();
    let restore_lock = stdout_lock.clone();
    std::panic::set_hook(Box::new(move |info| {
        let _ = restore_terminal(Some(&restore_lock));
        default_hook(info);
    }));

    let backend = CrosstermBackend::new(std::io::stdout());
    let mut terminal = match RatatuiTerminal::new(backend) {
        Ok(terminal) => terminal,
        Err(e) => {
            let _ = restore_terminal(Some(&stdout_lock));
            return Err(e.into());
        }
    };
    let graphics_writer =
        if graphics_supported { Some(GraphicsWriter::spawn(stdout_lock.clone())?) } else { None };

    let mut app = App {
        session,
        config,
        tree: TreeView::default(),
        render_states: HashMap::new(),
        graphics_writer,
        graphics_supported,
        stdout_lock: stdout_lock.clone(),
        pane_areas: Vec::new(),
        prefix_armed: false,
        session_label,
        sidebar_visible: true,
        sidebar_width: 0,
        sidebar_width_override: None,
        content_area: Rect::default(),
        hits: Vec::new(),
        tab_scroll: HashMap::new(),
        hover: None,
        menu: None,
        prompt: None,
        omnibar: None,
        toast: None,
        shake_frames: 0,
        selection: None,
        status_message: None,
        cell_pixels,
        pointer_shape: false,
        last_browser_hover: None,
        browser_input: BrowserInputDispatcher::spawn()?,
        drag: None,
        encoder,
        encode_buf: Vec::with_capacity(64),
        quit: false,
    };

    let result = app.event_loop(&mut terminal, rx);
    if let Some(writer) = app.graphics_writer.as_mut() {
        writer.shutdown(Duration::from_millis(200));
    }
    let _ = std::panic::take_hook();
    restore_terminal(Some(&stdout_lock))?;
    result
}

fn restore_terminal(stdout_lock: Option<&Arc<Mutex<()>>>) -> anyhow::Result<()> {
    let _guard = stdout_lock.map(|lock| lock.lock().unwrap());
    let mut stdout = std::io::stdout();
    // Reset the mouse pointer shape in case we left it as a hand.
    let _ = write!(stdout, "\x1b]22;default\x07");
    let _ = stdout.execute(DisableBracketedPaste);
    let _ = stdout.execute(DisableFocusChange);
    let _ = stdout.execute(DisableMouseCapture);
    let _ = stdout.execute(LeaveAlternateScreen);
    disable_raw_mode()?;
    Ok(())
}

impl App {
    fn event_loop(
        &mut self,
        terminal: &mut RatatuiTerminal<CrosstermBackend<std::io::Stdout>>,
        rx: Receiver<AppEvent>,
    ) -> anyhow::Result<()> {
        // Initial layout + draw.
        let size = terminal.size()?;
        self.sync_layout((size.width, size.height));
        self.draw_terminal(terminal)?;
        self.emit_graphics()?;

        while !self.quit && !crate::shutdown_requested() {
            // Block for the first event, then drain whatever queued so a
            // torrent of pty output coalesces into one frame.
            let timeout = if self.shake_frames > 0
                || self.selection_auto_scroll_active()
                || self.toast.is_some()
            {
                Duration::from_millis(30)
            } else {
                Duration::from_millis(250)
            };
            let mut action = RenderAction::None;
            let first = match rx.recv_timeout(timeout) {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => {
                    if self.shake_frames > 0 {
                        action = RenderAction::Draw;
                    }
                    if self.auto_scroll_selection_tick() {
                        action = action.merge(RenderAction::Draw);
                    }
                    if self.expire_toast() {
                        action = action.merge(RenderAction::Draw);
                    }
                    None
                }
                Err(RecvTimeoutError::Disconnected) => break,
            };
            if let Some(event) = first {
                action = action.merge(self.handle(event)?);
            }
            for _ in 0..256 {
                match rx.try_recv() {
                    Ok(event) => action = action.merge(self.handle(event)?),
                    Err(_) => break,
                }
            }
            if self.quit {
                break;
            }
            if self.expire_toast() {
                action = action.merge(RenderAction::Draw);
            }
            match action {
                RenderAction::Draw => {
                    let size = terminal.size()?;
                    self.sync_layout((size.width, size.height));
                    self.draw_terminal(terminal)?;
                    self.emit_graphics()?;
                }
                RenderAction::Graphics => {
                    self.emit_graphics()?;
                }
                RenderAction::None => {}
            }
        }
        Ok(())
    }

    fn draw_terminal(
        &mut self,
        terminal: &mut RatatuiTerminal<CrosstermBackend<std::io::Stdout>>,
    ) -> anyhow::Result<()> {
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock().unwrap();
        terminal.draw(|f| crate::ui::draw(self, f))?;
        Ok(())
    }

    fn frame_only_browser_update(&self, id: SurfaceId) -> bool {
        if !self.graphics_supported {
            return false;
        }
        let Some(area) = self.pane_areas.iter().find(|area| area.surface == id) else {
            return false;
        };
        let Some(surface) = self.session.surface(id) else {
            return false;
        };
        surface.kind() == SurfaceKind::Browser
            && surface.browser_frame().is_some()
            && area.content.width > 0
            && area.content.height > 0
    }

    fn mark_graphics_clean(&self, placements: &[GraphicPlacement]) {
        for placement in placements {
            if let Some(surface) = self.session.surface(placement.surface) {
                surface.take_dirty();
            }
        }
    }

    fn emit_graphics(&mut self) -> anyhow::Result<()> {
        if !self.graphics_supported {
            return Ok(());
        }
        let placements = self.graphic_placements();
        self.mark_graphics_clean(&placements);
        if let Some(writer) = &self.graphics_writer {
            writer.submit(placements);
        }
        Ok(())
    }

    fn graphic_placements(&self) -> Vec<GraphicPlacement> {
        let mut placements = Vec::new();
        for area in &self.pane_areas {
            let Some(surface) = self.session.surface(area.surface) else { continue };
            if surface.kind() != SurfaceKind::Browser {
                continue;
            }
            if self.browser_graphic_occluded(area.content) {
                continue;
            }
            let Some(frame) = surface.browser_frame() else { continue };
            placements.push(GraphicPlacement {
                surface: area.surface,
                rect: area.content,
                seq: frame.seq,
                data_b64: frame.data_b64,
            });
        }
        placements
    }

    fn browser_graphic_occluded(&self, rect: Rect) -> bool {
        self.menu.as_ref().is_some_and(|menu| rects_intersect(rect, menu.rect))
            || self.prompt.as_ref().is_some_and(|prompt| rects_intersect(rect, prompt.rect))
    }

    fn refresh_cell_pixels(&mut self, query_fallback: bool) {
        let next = crate::ui::graphics::detect_cell_pixels(query_fallback);
        if self.cell_pixels != next {
            self.cell_pixels = next;
            self.session.set_cell_pixel_size(next.0, next.1);
        }
    }

    /// Refresh the tree snapshot, recompute the active screen's layout
    /// (each pane's border box eats one cell on every side), and push
    /// content sizes to surfaces.
    fn sync_layout(&mut self, size: (u16, u16)) {
        let (width, height) = size;
        self.sidebar_width = sidebar_width_for(
            &self.config,
            self.sidebar_visible,
            width,
            self.sidebar_width_override,
        );
        let area = Rect {
            x: self.sidebar_width,
            y: 0,
            width: width.saturating_sub(self.sidebar_width),
            height: height.saturating_sub(1), // status bar
        };
        self.content_area = area;
        self.tree = self.session.tree();
        let layout = self
            .tree
            .active_screen()
            .map(|screen| layout_screen(&screen.layout, area))
            .unwrap_or_default();

        self.pane_areas.clear();
        let Some(screen) = self.tree.active_screen() else { return };
        for (pane_id, rect) in layout.panes {
            let Some(pane) = screen.pane(pane_id) else { continue };
            let Some(surface_id) = pane.active_surface() else { continue };
            let has_browser_omnibar =
                pane.tabs.get(pane.active_tab).is_some_and(|tab| tab.kind == SurfaceKind::Browser);
            let (bar, omnibar, content, track) =
                pane_parts_for_rect(rect, self.config.scrollbar.position, has_browser_omnibar);
            self.pane_areas.push(PaneArea {
                pane: pane_id,
                surface: surface_id,
                rect,
                bar,
                omnibar,
                content,
                track,
            });
            if content.width == 0 || content.height == 0 {
                continue;
            }
            // Size every tab in the pane, so switching tabs doesn't
            // trigger a resize flash. Passing the size means remote
            // mirrors attach at final geometry (replay is taken after the
            // server-side resize, so no post-attach reflow artifacts).
            let size = Some((content.width, content.height));
            for tab in &pane.tabs {
                if let Some(surface) = self.session.surface_sized(tab.surface, size) {
                    surface.resize(content.width, content.height);
                }
            }
        }
    }

    fn handle(&mut self, event: AppEvent) -> anyhow::Result<RenderAction> {
        match event {
            AppEvent::Mux(MuxEvent::Empty) => {
                self.quit = true;
                Ok(RenderAction::None)
            }
            AppEvent::Mux(MuxEvent::SurfaceExited(id)) => {
                self.render_states.remove(&id);
                self.session.forget_surface(id);
                if self.selection.is_some_and(|s| s.surface == id) {
                    self.selection = None;
                }
                if self.omnibar.as_ref().is_some_and(|state| state.surface == id) {
                    self.omnibar = None;
                }
                if self.last_browser_hover.is_some_and(|(surface, _, _)| surface == id) {
                    self.last_browser_hover = None;
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::Status(message)) => {
                self.status_message = Some(message);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SurfaceOutput(id)) => {
                if self.frame_only_browser_update(id) {
                    Ok(RenderAction::Graphics)
                } else {
                    Ok(RenderAction::Draw)
                }
            }
            AppEvent::Mux(_) => Ok(RenderAction::Draw),
            AppEvent::Input(Event::Key(key)) => {
                if key.kind != KeyEventKind::Release {
                    self.reassert_visible_surface_sizes();
                }
                self.handle_key(key)
            }
            AppEvent::Input(Event::Mouse(mouse)) => {
                self.reassert_visible_surface_sizes();
                self.handle_mouse(mouse)
            }
            AppEvent::Input(Event::Paste(text)) => {
                self.reassert_visible_surface_sizes();
                if let Some(prompt) = self.prompt.as_mut() {
                    prompt.input.insert_str(&text);
                    Ok(RenderAction::Draw)
                } else if let Some(state) = self.omnibar.as_mut() {
                    clear_omnibar_selection(state);
                    state.input.insert_str(&text);
                    Ok(RenderAction::Draw)
                } else {
                    self.paste(&text);
                    Ok(RenderAction::None)
                }
            }
            AppEvent::Input(Event::FocusGained) => {
                self.reassert_visible_surface_sizes();
                Ok(RenderAction::Draw)
            }
            AppEvent::Input(Event::Resize(_, _)) => {
                self.refresh_cell_pixels(false);
                self.render_states.clear();
                Ok(RenderAction::Draw)
            }
            AppEvent::Input(_) => Ok(RenderAction::None),
        }
    }

    fn active_pane(&self) -> Option<PaneId> {
        self.tree.active_screen().map(|screen| screen.active_pane)
    }

    fn active_surface(&self) -> Option<SurfaceId> {
        self.tree.active_surface()
    }

    fn active_surface_handle(&self) -> Option<SurfaceHandle> {
        self.active_surface().and_then(|id| self.session.surface(id))
    }

    fn active_surface_with_handle(&self) -> Option<(SurfaceId, SurfaceHandle)> {
        let id = self.active_surface()?;
        Some((id, self.session.surface(id)?))
    }

    fn active_screen_id(&self) -> Option<mux_core::ScreenId> {
        self.tree.active_screen().map(|screen| screen.id)
    }

    fn reassert_visible_surface_sizes(&self) {
        for area in &self.pane_areas {
            if area.content.width == 0 || area.content.height == 0 {
                continue;
            }
            if let Some(surface) = self
                .session
                .surface_sized(area.surface, Some((area.content.width, area.content.height)))
            {
                surface.reassert_size(area.content.width, area.content.height);
            }
        }
    }

    pub fn dragging_scrollbar(&self) -> Option<SurfaceId> {
        match self.drag {
            Some(Drag::Scrollbar { surface, .. }) => Some(surface),
            _ => None,
        }
    }

    pub fn tab_drag(&self) -> Option<TabDragView> {
        match self.drag {
            Some(Drag::Tab { surface, target }) => Some(TabDragView { surface, target }),
            _ => None,
        }
    }

    pub fn workspace_drag(&self) -> Option<(WorkspaceId, Option<usize>)> {
        match self.drag {
            Some(Drag::Workspace { workspace, target }) => Some((workspace, target)),
            _ => None,
        }
    }

    pub fn surface_scroll_offset(&self, surface: SurfaceId) -> u64 {
        self.session
            .surface(surface)
            .and_then(|surface| surface.with_terminal(|t| t.scrollbar().map(|sb| sb.offset)))
            .flatten()
            .unwrap_or(0)
    }

    fn selection_auto_scroll_active(&self) -> bool {
        matches!(self.drag, Some(Drag::Select { auto_scroll: Some(_), .. }))
    }

    fn auto_scroll_selection_tick(&mut self) -> bool {
        let Some(Drag::Select { content, auto_scroll: Some(dir), col }) = self.drag else {
            return false;
        };
        let Some(surface_id) = self.selection.map(|sel| sel.surface) else { return false };
        let Some(surface) = self.session.surface(surface_id) else { return false };
        let moved = surface
            .with_terminal(|t| {
                let before = t.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                t.scroll_delta(dir as isize);
                let after = t.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                before != after
            })
            .unwrap_or(false);
        let edge_row = if dir < 0 { 0 } else { content.height.saturating_sub(1) };
        let offset = self.surface_scroll_offset(surface_id);
        if let Some(sel) = self.selection.as_mut() {
            sel.head = (col.min(content.width.saturating_sub(1)), offset + edge_row as u64);
        }
        moved
    }

    /// Content size for a pane filling `rect`.
    fn size_of_rect(&self, rect: Rect) -> Option<(u16, u16)> {
        content_size_for_rect(rect, self.config.scrollbar.position)
    }

    /// Size hint for splitting `pane`: the second side of its rect.
    fn split_size_hint(&self, pane: PaneId, dir: SplitDir) -> Option<(u16, u16)> {
        let area = self.pane_areas.iter().find(|a| a.pane == pane)?;
        let (_, b) = split_sides(area.rect, dir, 0.5);
        self.size_of_rect(b)
    }

    fn split_pane(&mut self, pane: PaneId, dir: SplitDir) -> anyhow::Result<()> {
        let hint = self.split_size_hint(pane, dir);
        self.session.split(pane, dir, hint)
    }

    fn new_pane_smart(&mut self) -> anyhow::Result<()> {
        let Some((pane, dir)) =
            smart_split_target(&self.pane_areas, self.active_pane(), self.cell_pixels)
        else {
            return Ok(());
        };
        self.split_pane(pane, dir)
    }

    fn new_workspace(&mut self) -> anyhow::Result<()> {
        self.session.new_workspace(self.size_of_rect(self.content_area))
    }

    fn new_screen(&mut self) -> anyhow::Result<()> {
        self.session.new_screen(self.size_of_rect(self.content_area))
    }

    fn handle_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        if key.kind == KeyEventKind::Release {
            return Ok(RenderAction::None);
        }
        self.status_message = None;
        if self.prompt.is_some() {
            return self.handle_prompt_key(key);
        }
        if self.menu.is_some() {
            return self.handle_menu_key(key);
        }
        if self.omnibar.is_some() {
            return self.handle_omnibar_key(key);
        }
        if let Some(action) = self.config.keys.modeless_action_for(&key) {
            return self.run_action(action);
        }
        if self.prefix_armed {
            self.prefix_armed = false;
            return self.handle_prefixed(key);
        }
        if self.config.keys.prefix.matches(&key) {
            self.prefix_armed = true;
            return Ok(RenderAction::Draw);
        }
        // Typing replaces any selection highlight.
        self.selection = None;
        self.forward_key(&key);
        Ok(RenderAction::None)
    }

    /// Commit the open rename dialog (Enter or the OK button).
    fn commit_prompt(&mut self) {
        let Some(prompt) = self.take_prompt() else { return };
        let input = prompt.input.as_str().to_string();
        match prompt.target {
            PromptTarget::Workspace(id) => {
                if !input.is_empty() {
                    self.session.rename_workspace(id, input);
                }
            }
            // Empty screen/tab names clear back to the default.
            PromptTarget::Screen(id) => self.session.rename_screen(id, input),
            PromptTarget::Surface(id) => self.session.rename_surface(id, input),
        }
    }

    fn take_prompt(&mut self) -> Option<Prompt> {
        self.shake_frames = 0;
        self.prompt.take()
    }

    fn close_prompt(&mut self) {
        self.shake_frames = 0;
        self.prompt = None;
    }

    fn handle_prompt_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(prompt) = self.prompt.as_mut() else { return Ok(RenderAction::None) };
        match prompt.input.handle_key(&key) {
            InputEvent::Commit => self.commit_prompt(),
            InputEvent::Cancel => self.close_prompt(),
            InputEvent::Changed | InputEvent::None => {}
        }
        Ok(RenderAction::Draw)
    }

    /// Clicks while the rename dialog is open: OK commits, Cancel (or a
    /// click outside the dialog) dismisses; clicks inside are swallowed.
    fn handle_prompt_click(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        let Some(prompt) = self.prompt.as_mut() else { return Ok(RenderAction::None) };
        if prompt.ok.contains(x, y) {
            self.commit_prompt();
        } else if prompt.clear.contains(x, y) {
            prompt.input.clear();
        } else if prompt.input_rect.contains(x, y) {
            let column = x.saturating_sub(prompt.input_rect.x) as usize;
            prompt.input.set_cursor_from_visible_column(column, prompt.input_rect.width as usize);
        } else if prompt.cancel.contains(x, y) || !prompt.rect.contains(x, y) {
            self.close_prompt();
        }
        Ok(RenderAction::Draw)
    }

    fn handle_omnibar_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(state) = self.omnibar.as_mut() else { return Ok(RenderAction::None) };
        let replace_selection = state.select_all
            && matches!(
                key.code,
                KeyCode::Backspace
                    | KeyCode::Delete
                    | KeyCode::Char(_)
                        if !key.modifiers.intersects(
                            KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER
                        )
            );
        if replace_selection {
            state.input.clear();
            state.select_all = false;
        } else if matches!(
            key.code,
            KeyCode::Left
                | KeyCode::Right
                | KeyCode::Home
                | KeyCode::End
                | KeyCode::Backspace
                | KeyCode::Delete
        ) {
            state.select_all = false;
        }
        if matches!(key.code, KeyCode::Char('a') | KeyCode::Char('A'))
            && key.modifiers.contains(KeyModifiers::CONTROL)
        {
            state.select_all = true;
            state.input.cursor = state.input.buffer.len();
            return Ok(RenderAction::Draw);
        }
        match state.input.handle_key(&key) {
            InputEvent::Cancel => {
                self.omnibar = None;
            }
            InputEvent::Commit => {
                let Some(state) = self.omnibar.take() else { return Ok(RenderAction::Draw) };
                let input = state.input.as_str().trim();
                if input.is_empty() {
                    return Ok(RenderAction::Draw);
                }
                let url = mux_core::normalize_url(input);
                match self.session.surface(state.surface) {
                    Some(handle) => {
                        self.status_message =
                            handle.browser_navigate(&url).err().map(|e| e.to_string());
                    }
                    None => self.status_message = Some("unknown browser surface".to_string()),
                }
            }
            InputEvent::Changed | InputEvent::None => {}
        }
        Ok(RenderAction::Draw)
    }

    fn handle_menu_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(menu) = self.menu.as_mut() else { return Ok(RenderAction::None) };
        match key.code {
            KeyCode::Esc => {
                self.menu = None;
                Ok(RenderAction::Draw)
            }
            KeyCode::Up => {
                menu.selected = menu.selected.saturating_sub(1);
                Ok(RenderAction::Draw)
            }
            KeyCode::Down => {
                menu.selected = (menu.selected + 1).min(menu.items.len().saturating_sub(1));
                Ok(RenderAction::Draw)
            }
            KeyCode::Enter => {
                let action = menu.items[menu.selected];
                self.menu = None;
                self.activate_menu(action)?;
                Ok(RenderAction::Draw)
            }
            _ => Ok(RenderAction::Draw), // swallow while a menu is open
        }
    }

    fn handle_prefixed(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        // Prefix twice forwards the prefix chord literally.
        if self.config.keys.prefix.matches(&key) {
            self.forward_key(&key);
            return Ok(RenderAction::Draw);
        }
        // 1-9 select a tab by number (fixed: they mirror the tab labels).
        if let KeyCode::Char(c @ '1'..='9') = key.code {
            let pane = self.active_pane();
            self.session.select_tab(pane, Some(c as usize - '1' as usize), None);
            return Ok(RenderAction::Draw);
        }
        let Some(action) = self.config.keys.action_for(&key) else {
            return Ok(RenderAction::Draw); // unknown prefix command: swallow, redraw indicator
        };
        if browser_only_action(action)
            && !self
                .active_surface_handle()
                .is_some_and(|surface| surface.kind() == SurfaceKind::Browser)
        {
            self.forward_key(&key);
            return Ok(RenderAction::Draw);
        }
        self.run_action(action)
    }

    /// Execute one bound action. Shared by the (configurable) prefix keys
    /// and any future command surface.
    fn run_action(&mut self, action: Action) -> anyhow::Result<RenderAction> {
        let pane = self.active_pane();
        match action {
            Action::NewTab => {
                self.session.new_tab(pane, None)?;
            }
            Action::NewBrowserTab => self.create_browser_tab_for_edit(pane)?,
            Action::NewPaneSmart => self.new_pane_smart()?,
            Action::NextTab => self.session.select_tab(pane, None, Some(1)),
            Action::PrevTab => self.session.select_tab(pane, None, Some(-1)),
            Action::SplitRight => {
                if let Some(pane) = pane {
                    self.split_pane(pane, SplitDir::Right)?;
                }
            }
            Action::SplitDown => {
                if let Some(pane) = pane {
                    self.split_pane(pane, SplitDir::Down)?;
                }
            }
            Action::CloseTab => {
                // Close the active tab; the pane collapses with its last
                // tab, so this is also "close pane" for single-tab panes.
                if let Some(surface) = self.active_surface() {
                    self.render_states.remove(&surface);
                    self.session.close_surface(surface);
                }
            }
            Action::ClosePane => {
                if let Some(pane) = pane {
                    self.session.close_pane(pane);
                }
            }
            Action::RenameTab => self.open_rename_tab_prompt(pane),
            Action::RenameScreen => self.open_rename_screen_prompt(),
            Action::RenameWorkspace => self.open_rename_workspace_prompt(),
            Action::CloseScreen => {
                if let Some(screen) = self.active_screen_id() {
                    self.session.close_screen(screen);
                }
            }
            Action::PrevScreen => self.session.select_screen(None, Some(-1)),
            Action::NextScreen => self.session.select_screen(None, Some(1)),
            Action::NewScreen => self.new_screen()?,
            Action::NextWorkspace => self.session.select_workspace(None, Some(1)),
            Action::NewWorkspace => self.new_workspace()?,
            Action::ToggleSidebar => self.sidebar_visible = !self.sidebar_visible,
            Action::FocusLeft => self.move_focus(-1, 0),
            Action::FocusRight => self.move_focus(1, 0),
            Action::FocusUp => self.move_focus(0, -1),
            Action::FocusDown => self.move_focus(0, 1),
            Action::ResizeGrow => self.resize_focused_split(0.05),
            Action::ResizeShrink => self.resize_focused_split(-0.05),
            Action::ScrollUp => self.scroll_active(-10),
            Action::ScrollDown => self.scroll_active(10),
            Action::BrowserBack => {
                let result = self.browser_back();
                self.set_status_from_browser_result(result);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserForward => {
                let result = self.browser_forward();
                self.set_status_from_browser_result(result);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserReload => {
                let result = self.browser_reload();
                self.set_status_from_browser_result(result);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserEditUrl => {
                if let Some(pane) = pane {
                    self.focus_omnibar(pane);
                }
                return Ok(RenderAction::Draw);
            }
            Action::Detach => {
                // Local sessions end with the TUI; remote sessions keep
                // running server-side (detach).
                self.quit = true;
                return Ok(RenderAction::None);
            }
        }
        self.status_message = None;
        Ok(RenderAction::Draw)
    }

    fn set_status_from_browser_result(&mut self, result: anyhow::Result<()>) {
        self.status_message = result.err().map(|err| err.to_string());
    }

    fn open_rename_tab_prompt(&mut self, pane: Option<PaneId>) {
        let Some(pane) = pane else { return };
        let Some(tab) = self.tree.pane(pane).and_then(|p| p.tabs.get(p.active_tab)) else {
            return;
        };
        let buffer = tab.name.clone().unwrap_or_default();
        self.prompt = Some(Prompt::new("Rename tab", buffer, PromptTarget::Surface(tab.surface)));
    }

    fn open_rename_workspace_prompt(&mut self) {
        let Some(ws) = self.tree.active_workspace() else { return };
        self.prompt =
            Some(Prompt::new("Rename workspace", ws.name.clone(), PromptTarget::Workspace(ws.id)));
    }

    fn open_rename_screen_prompt(&mut self) {
        let Some(ws) = self.tree.active_workspace() else { return };
        let Some(screen) = ws.active_screen_ref() else { return };
        let buffer = screen.name.clone().unwrap_or_default();
        self.prompt = Some(Prompt::new("Rename screen", buffer, PromptTarget::Screen(screen.id)));
    }

    fn browser_tab_size_hint(&self, pane: Option<PaneId>) -> Option<(u16, u16)> {
        match pane {
            Some(pane) => self.pane_areas.iter().find(|area| area.pane == pane).and_then(|area| {
                browser_content_size_for_rect(area.rect, self.config.scrollbar.position)
            }),
            None => self
                .active_pane()
                .and_then(|pane| self.browser_tab_size_hint(Some(pane)))
                .or_else(|| {
                    browser_content_size_for_rect(self.content_area, self.config.scrollbar.position)
                }),
        }
    }

    fn create_browser_tab_for_edit(&mut self, pane: Option<PaneId>) -> anyhow::Result<()> {
        self.session.new_browser_tab(
            "about:blank".to_string(),
            pane,
            self.browser_tab_size_hint(pane),
        )?;
        self.tree = self.session.tree();
        let target_pane = pane.or_else(|| self.active_pane());
        if let Some(pane) = target_pane {
            self.focus_omnibar_with_buffer(pane, String::new(), false);
        }
        Ok(())
    }

    fn active_browser_handle(&self) -> anyhow::Result<SurfaceHandle> {
        let Some(surface) = self.active_surface_handle() else {
            anyhow::bail!("no active surface");
        };
        if surface.kind() != SurfaceKind::Browser {
            anyhow::bail!("active surface is not a browser");
        }
        Ok(surface)
    }

    fn browser_back(&mut self) -> anyhow::Result<()> {
        self.active_browser_handle()?.browser_back()
    }

    fn browser_forward(&mut self) -> anyhow::Result<()> {
        self.active_browser_handle()?.browser_forward()
    }

    fn browser_reload(&mut self) -> anyhow::Result<()> {
        self.active_browser_handle()?.browser_reload()
    }

    fn focus_omnibar(&mut self, pane: PaneId) {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        let Some(surface) = self.session.surface(surface_id) else { return };
        if surface.kind() != SurfaceKind::Browser {
            return;
        }
        let buffer = surface.browser_url().unwrap_or_default();
        self.focus_omnibar_with_buffer(pane, buffer, true);
    }

    fn focus_omnibar_with_buffer(&mut self, pane: PaneId, buffer: String, select_all: bool) {
        let Some(surface) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        if self.tree.surface_kind(surface) != SurfaceKind::Browser {
            return;
        }
        let Some(area) = self.pane_areas.iter().find(|area| area.pane == pane) else {
            return;
        };
        let has_omnibar = if area.surface == surface {
            area.omnibar.is_some()
        } else {
            let (_, omnibar, _, _) =
                pane_parts_for_rect(area.rect, self.config.scrollbar.position, true);
            omnibar.is_some()
        };
        if !has_omnibar {
            return;
        }
        self.omnibar =
            Some(OmnibarState { pane, surface, input: TextInput::new(buffer), select_all });
    }

    fn browser_handle_for_pane(&self, pane: PaneId) -> anyhow::Result<SurfaceHandle> {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            anyhow::bail!("pane has no active surface");
        };
        let Some(surface) = self.session.surface(surface_id) else {
            anyhow::bail!("unknown surface {surface_id}");
        };
        if surface.kind() != SurfaceKind::Browser {
            anyhow::bail!("active surface is not a browser");
        }
        Ok(surface)
    }

    fn browser_copy_url(&mut self, pane: PaneId) {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        let Some(url) = self.session.surface(surface_id).and_then(|surface| surface.browser_url())
        else {
            return;
        };
        self.copy_text_to_clipboard(&url);
        self.show_toast("Copied URL".to_string());
    }

    fn activate_menu(&mut self, action: MenuAction) -> anyhow::Result<()> {
        match action {
            MenuAction::RenameWorkspace(id) => {
                let buffer = self
                    .tree
                    .workspaces
                    .iter()
                    .find(|ws| ws.id == id)
                    .map(|ws| ws.name.clone())
                    .unwrap_or_default();
                self.prompt =
                    Some(Prompt::new("Rename workspace", buffer, PromptTarget::Workspace(id)));
            }
            MenuAction::CloseWorkspace(id) => self.session.close_workspace(id),
            MenuAction::CopyWorkspaceId(id) => {
                if let Some(short_id) =
                    self.tree.workspaces.iter().find(|ws| ws.id == id).map(|ws| ws.short_id.clone())
                {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::RenameScreen(id) => {
                let buffer = self
                    .tree
                    .workspaces
                    .iter()
                    .flat_map(|ws| ws.screens.iter())
                    .find(|s| s.id == id)
                    .and_then(|s| s.name.clone())
                    .unwrap_or_default();
                self.prompt = Some(Prompt::new("Rename screen", buffer, PromptTarget::Screen(id)));
            }
            MenuAction::CloseScreen(id) => self.session.close_screen(id),
            MenuAction::BrowserBack(id) => {
                let result =
                    self.browser_handle_for_pane(id).and_then(|handle| handle.browser_back());
                self.set_status_from_browser_result(result);
            }
            MenuAction::BrowserForward(id) => {
                let result =
                    self.browser_handle_for_pane(id).and_then(|handle| handle.browser_forward());
                self.set_status_from_browser_result(result);
            }
            MenuAction::BrowserReload(id) => {
                let result =
                    self.browser_handle_for_pane(id).and_then(|handle| handle.browser_reload());
                self.set_status_from_browser_result(result);
            }
            MenuAction::BrowserEditUrl(id) => self.focus_omnibar(id),
            MenuAction::BrowserCopyUrl(id) => self.browser_copy_url(id),
            MenuAction::BrowserActivate(id) => {
                let result =
                    self.browser_handle_for_pane(id).and_then(|handle| handle.browser_activate());
                self.set_status_from_browser_result(result);
            }
            MenuAction::RenameTab(id) => self.open_rename_tab_prompt(Some(id)),
            MenuAction::CopyTabId(id) => {
                if let Some(short_id) = self
                    .tree
                    .pane(id)
                    .and_then(|pane| pane.tabs.get(pane.active_tab))
                    .map(|tab| tab.short_id.clone())
                {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::CopyPaneId(id) => {
                if let Some(short_id) = self.tree.pane(id).map(|pane| pane.short_id.clone()) {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::NewTab(id) => self.session.new_tab(Some(id), None)?,
            MenuAction::NewBrowserTab(id) => self.create_browser_tab_for_edit(Some(id))?,
            MenuAction::SplitRight(id) => self.split_pane(id, SplitDir::Right)?,
            MenuAction::SplitDown(id) => self.split_pane(id, SplitDir::Down)?,
            MenuAction::CloseTab(id) => {
                if let Some(surface) = self.tree.pane(id).and_then(|p| p.active_surface()) {
                    self.render_states.remove(&surface);
                    self.session.close_surface(surface);
                }
            }
            MenuAction::ClosePane(id) => self.session.close_pane(id),
        }
        Ok(())
    }

    fn move_focus(&self, dx: i32, dy: i32) {
        let Some(active) = self.active_pane() else { return };
        // Re-derive the layout geometry from the frame's pane areas.
        let layout = mux_core::LayoutResult {
            panes: self.pane_areas.iter().map(|a| (a.pane, a.rect)).collect(),
        };
        if let Some(next) = layout.neighbor(active, dx, dy) {
            self.session.focus_pane(next);
        }
    }

    fn scroll_active(&mut self, delta: isize) {
        if let Some(surface) = self.active_surface_handle() {
            if surface.kind() == SurfaceKind::Browser {
                return;
            }
            let _ = surface.with_terminal(|t| t.scroll_delta(delta));
        }
    }

    fn forward_key(&mut self, key: &KeyEvent) {
        if self
            .active_surface_handle()
            .is_some_and(|surface| surface.kind() == SurfaceKind::Browser)
        {
            self.forward_browser_key(key);
            return;
        }
        let Some(input) = keys::key_input_from(key) else { return };
        let Some(surface) = self.active_surface_handle() else { return };
        self.encode_buf.clear();
        let Some(encoded) = surface.with_terminal(|term| {
            // New input snaps the viewport back to the live screen.
            term.scroll_to_bottom();
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        }) else {
            return;
        };
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            surface.write_bytes(&self.encode_buf);
        }
    }

    fn forward_browser_key(&mut self, key: &KeyEvent) {
        if matches!(key.code, KeyCode::Char('l') | KeyCode::Char('L'))
            && key.modifiers.contains(KeyModifiers::CONTROL)
        {
            if let Some(pane) = self.active_pane() {
                self.focus_omnibar(pane);
            }
            return;
        }
        let Some((surface_id, surface)) = self.active_surface_with_handle() else { return };
        if let KeyCode::Char(c) = key.code {
            if !key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER)
            {
                self.browser_input.enqueue(BrowserInputEvent {
                    surface_id,
                    surface,
                    kind: BrowserInputKind::InsertText(c.to_string()),
                });
                return;
            }
        }
        let Some((key_name, code, vk, text)) = browser_key_mapping(key.code) else { return };
        let modifiers = browser_modifiers(key.modifiers);
        let key_event =
            |event_type: &'static str, text: Option<&'static str>| BrowserInputKind::Key {
                event_type,
                key: key_name,
                code,
                windows_virtual_key_code: vk,
                modifiers,
                text,
            };
        self.browser_input.enqueue(BrowserInputEvent {
            surface_id,
            surface: surface.clone(),
            kind: key_event("keyDown", text),
        });
        if key.kind == KeyEventKind::Press {
            self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: key_event("keyUp", None),
            });
        }
    }

    fn paste(&mut self, text: &str) {
        let Some((surface_id, surface)) = self.active_surface_with_handle() else { return };
        if surface.kind() == SurfaceKind::Browser {
            self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::InsertText(text.to_string()),
            });
            return;
        }
        let Some(bracketed) = surface.with_terminal(|t| t.mode(2004, false)) else {
            return;
        };
        if bracketed {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            surface.write_bytes(&bytes);
        } else {
            surface.write_bytes(text.as_bytes());
        }
    }

    fn pane_area_at(&self, x: u16, y: u16) -> Option<&PaneArea> {
        self.pane_areas.iter().find(|a| a.rect.contains(x, y))
    }

    fn hit_at(&self, x: u16, y: u16) -> Option<Hit> {
        self.hits.iter().find(|(rect, _)| rect.contains(x, y)).map(|(_, hit)| *hit)
    }

    fn omnibar_hit_at(&self, x: u16, y: u16) -> Option<(PaneId, OmnibarHit)> {
        self.pane_areas.iter().find_map(|area| {
            let rect = area.omnibar?;
            if self.surface_kind(area.surface) != SurfaceKind::Browser {
                return None;
            }
            let editing = self
                .omnibar
                .as_ref()
                .is_some_and(|state| state.pane == area.pane && state.surface == area.surface);
            crate::ui::omnibar::hit(rect, x, y, editing).map(|hit| (area.pane, hit))
        })
    }

    fn tab_drop_target_at(&self, x: u16, y: u16) -> Option<(PaneId, usize)> {
        let area = self.pane_areas.iter().find(|area| {
            area.bar.is_some_and(|bar| bar.contains(x, y)) || area.content.contains(x, y)
        })?;
        let pane = self.tree.pane(area.pane)?;
        let len = pane.tabs.len();
        if !area.bar.is_some_and(|bar| bar.contains(x, y)) {
            return Some((area.pane, len));
        }
        let mut tab_hits = self
            .hits
            .iter()
            .filter_map(|(rect, hit)| match hit {
                Hit::Tab { pane, index } if *pane == area.pane => Some((*rect, *index)),
                _ => None,
            })
            .collect::<Vec<_>>();
        tab_hits.sort_by_key(|(rect, index)| (rect.x, *index));
        for (rect, index) in &tab_hits {
            let mid = rect.x + rect.width / 2;
            if x < mid {
                return Some((area.pane, (*index).min(len)));
            }
            if rect.contains(x, y) {
                return Some((area.pane, (index + 1).min(len)));
            }
        }
        Some((area.pane, len))
    }

    fn workspace_drop_target_at(&self, x: u16, y: u16) -> Option<usize> {
        if self.sidebar_width < 3 || x >= self.sidebar_width.saturating_sub(1) {
            return None;
        }
        let len = self.tree.workspaces.len();
        for index in 0..len {
            let start = 2 + index as u16 * 3;
            if y < start {
                return Some(index);
            }
            if y <= start + 1 {
                return Some(if y == start { index } else { index + 1 }.min(len));
            }
        }
        Some(len)
    }

    fn tab_location(&self, surface: SurfaceId) -> Option<(PaneId, usize)> {
        self.tree
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .find_map(|pane| {
                pane.tabs
                    .iter()
                    .position(|tab| tab.surface == surface)
                    .map(|index| (pane.id, index))
            })
    }

    fn workspace_index(&self, workspace: WorkspaceId) -> Option<usize> {
        self.tree.workspaces.iter().position(|ws| ws.id == workspace)
    }

    fn handle_mouse(&mut self, mouse: MouseEvent) -> anyhow::Result<RenderAction> {
        match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                self.handle_left_down(mouse.column, mouse.row)
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                self.handle_left_drag(mouse.column, mouse.row)
            }
            MouseEventKind::Up(MouseButton::Left) => self.handle_left_up(mouse.column, mouse.row),
            MouseEventKind::Down(MouseButton::Right) => {
                if self.prompt.is_some() {
                    self.shake_frames = 6;
                    return Ok(RenderAction::Draw);
                }
                self.open_context_menu(mouse.column, mouse.row);
                Ok(RenderAction::Draw)
            }
            MouseEventKind::Drag(MouseButton::Right) => {
                self.handle_right_drag(mouse.column, mouse.row)
            }
            MouseEventKind::Up(MouseButton::Right) => self.handle_right_up(mouse.column, mouse.row),
            MouseEventKind::Moved => self.handle_hover(mouse.column, mouse.row),
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                let down = matches!(mouse.kind, MouseEventKind::ScrollDown);
                self.handle_scroll(mouse.column, mouse.row, down)
            }
            _ => Ok(RenderAction::None),
        }
    }

    /// Whether the cell is over something clickable (any hit, a menu row,
    /// or a dialog button): these render the hand pointer.
    fn is_clickable(&self, x: u16, y: u16) -> bool {
        if let Some(prompt) = &self.prompt {
            return prompt.ok.contains(x, y)
                || prompt.cancel.contains(x, y)
                || prompt.clear.contains(x, y)
                || prompt.input_rect.contains(x, y);
        }
        if let Some(menu) = &self.menu {
            // Everything inside the menu rect is menu territory: only item
            // rows are clickable; border cells never inherit clickability
            // from hits underneath.
            if menu.rect.contains(x, y) {
                return menu.item_at(x, y).is_some();
            }
        }
        if self.omnibar_hit_at(x, y).is_some() {
            return true;
        }
        self.hit_at(x, y).is_some()
    }

    /// Keep the terminal's mouse pointer shape in sync: a hand over
    /// clickable UI, the default elsewhere (OSC 22; terminals without
    /// support ignore it).
    fn sync_pointer_shape(&mut self, x: u16, y: u16) {
        let want_pointer = self.is_clickable(x, y);
        if want_pointer == self.pointer_shape {
            return;
        }
        self.pointer_shape = want_pointer;
        let shape = if want_pointer { "pointer" } else { "default" };
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]22;{shape}\x07");
        let _ = stdout.flush();
    }

    /// Mouse-move: sync the pointer shape, highlight the hovered menu
    /// item, and track the mouse position so tab-bar controls (+, ‹, ›)
    /// and the scrollbar render a hover state. Only redraws when the
    /// hovered element actually changes.
    fn handle_hover(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        self.sync_pointer_shape(x, y);
        if let Some(menu) = self.menu.as_mut() {
            if let Some(item) = menu.item_at(x, y) {
                if item != menu.selected {
                    menu.selected = item;
                    return Ok(RenderAction::Draw);
                }
                return Ok(RenderAction::None);
            }
        }
        if self.menu.is_none() && self.prompt.is_none() && self.drag.is_none() {
            let mut over_browser = false;
            if let Some(area) = self
                .pane_areas
                .iter()
                .find(|area| {
                    area.content.contains(x, y)
                        && self.surface_kind(area.surface) == SurfaceKind::Browser
                })
                .copied()
            {
                over_browser = true;
                let editing_same_pane =
                    self.omnibar.as_ref().is_some_and(|state| state.pane == area.pane);
                let status = self.session.surface(area.surface).and_then(|surface| {
                    (surface.kind() == SurfaceKind::Browser).then(|| surface.browser_status())
                });
                if browser_hover_forward_allowed(status.flatten(), editing_same_pane) {
                    let cell = (x.saturating_sub(area.content.x), y.saturating_sub(area.content.y));
                    let next = (area.surface, cell.0, cell.1);
                    if self.last_browser_hover != Some(next) {
                        self.send_browser_mouse(
                            area.surface,
                            area.content,
                            x,
                            y,
                            BrowserMouseDispatch::new("mouseMoved", Some("none"), None),
                        );
                        self.last_browser_hover = Some(next);
                    }
                }
            }
            if !over_browser {
                self.last_browser_hover = None;
            }
        }
        let hoverable = |pos: Option<(u16, u16)>| {
            pos.and_then(|(px, py)| {
                self.hit_at(px, py)
                    .filter(|hit| {
                        matches!(
                            hit,
                            Hit::NewTab { .. } | Hit::TabScroll { .. } | Hit::Scrollbar { .. }
                        )
                    })
                    .map(|hit| format!("{hit:?}"))
                    .or_else(|| {
                        self.omnibar_hit_at(px, py)
                            .filter(|(_, hit)| *hit != OmnibarHit::Edit)
                            .map(|(_, hit)| format!("{hit:?}"))
                    })
            })
        };
        let before = hoverable(self.hover);
        let after = hoverable(Some((x, y)));
        self.hover = Some((x, y));
        Ok(if before != after { RenderAction::Draw } else { RenderAction::None })
    }

    fn handle_right_drag(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        self.hover = Some((x, y));
        let Some(menu) = self.menu.as_mut() else { return Ok(RenderAction::None) };
        if (x, y) != menu.right_press {
            menu.right_drag_moved = true;
        }
        if let Some(item) = menu.item_at(x, y) {
            if item != menu.selected {
                menu.selected = item;
                return Ok(RenderAction::Draw);
            }
        }
        Ok(RenderAction::None)
    }

    fn handle_right_up(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        let Some(menu) = self.menu.take() else { return Ok(RenderAction::None) };
        let plain_open_click = !menu.right_drag_moved && (x, y) == menu.right_press;
        if plain_open_click {
            self.menu = Some(menu);
        } else if let Some(item) = menu.item_at(x, y) {
            let action = menu.items[item];
            self.activate_menu(action)?;
        } else {
            self.menu = Some(menu);
        }
        Ok(RenderAction::Draw)
    }

    fn handle_left_down(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        self.selection = None;
        self.drag = None;

        // An open rename dialog captures the click.
        if self.prompt.is_some() {
            return self.handle_prompt_click(x, y);
        }

        // An open menu captures the click: activate or dismiss. Clicks on
        // the border chrome keep it open without activating.
        if let Some(menu) = self.menu.take() {
            if let Some(item) = menu.item_at(x, y) {
                self.activate_menu(menu.items[item])?;
            } else if menu.rect.contains(x, y) {
                self.menu = Some(menu); // padding click: keep it open
            }
            return Ok(RenderAction::Draw);
        }

        if let Some((pane, hit)) = self.omnibar_hit_at(x, y) {
            self.session.focus_pane(pane);
            if let Some(state) = &self.omnibar {
                if state.pane == pane {
                    return Ok(RenderAction::Draw);
                }
                self.omnibar = None;
            }
            match hit {
                OmnibarHit::Back => {
                    let result =
                        self.browser_handle_for_pane(pane).and_then(|handle| handle.browser_back());
                    self.set_status_from_browser_result(result);
                }
                OmnibarHit::Forward => {
                    let result = self
                        .browser_handle_for_pane(pane)
                        .and_then(|handle| handle.browser_forward());
                    self.set_status_from_browser_result(result);
                }
                OmnibarHit::Reload => {
                    let result = self
                        .browser_handle_for_pane(pane)
                        .and_then(|handle| handle.browser_reload());
                    self.set_status_from_browser_result(result);
                }
                OmnibarHit::Edit => self.focus_omnibar(pane),
            }
            return Ok(RenderAction::Draw);
        }

        if let Some(state) = &self.omnibar {
            let editing_rect = self
                .pane_areas
                .iter()
                .find(|area| area.pane == state.pane && area.surface == state.surface)
                .and_then(|area| area.omnibar);
            if !editing_rect.is_some_and(|rect| rect.contains(x, y)) {
                self.omnibar = None;
            }
        }

        if let Some(hit) = self.hit_at(x, y) {
            match hit {
                Hit::Workspace { id, .. } => {
                    self.drag = Some(Drag::WorkspaceArm { workspace: id, at: (x, y) });
                }
                Hit::NewWorkspace => self.new_workspace()?,
                Hit::ScreenEntry { index, .. } => {
                    self.session.select_screen(Some(index), None);
                }
                Hit::NewScreen => self.new_screen()?,
                Hit::Tab { pane, index } => {
                    if let Some(surface) = self
                        .tree
                        .pane(pane)
                        .and_then(|pane| pane.tabs.get(index))
                        .map(|t| t.surface)
                    {
                        self.drag = Some(Drag::TabArm { surface, at: (x, y) });
                    }
                }
                Hit::NewTab { pane } => {
                    self.session.focus_pane(pane);
                    self.session.new_tab(Some(pane), None)?;
                }
                Hit::Scrollbar { surface, track } => {
                    self.start_scrollbar_drag(surface, track, y);
                }
                Hit::SidebarResize => self.drag = Some(Drag::SidebarResize),
                Hit::PaneResize { horizontal, vertical } => {
                    self.drag = Some(Drag::ResizeSplit { horizontal, vertical });
                }
                Hit::TabScroll { pane, delta } => self.scroll_tabs(pane, delta),
            }
            return Ok(RenderAction::Draw);
        }

        if let Some(area) = self.pane_area_at(x, y).copied() {
            self.session.focus_pane(area.pane);
            if area.content.contains(x, y) {
                if self.surface_kind(area.surface) == SurfaceKind::Browser {
                    self.send_browser_mouse(
                        area.surface,
                        area.content,
                        x,
                        y,
                        BrowserMouseDispatch::new("mousePressed", Some("left"), Some(1)),
                    );
                    self.drag =
                        Some(Drag::Browser { surface: area.surface, content: area.content });
                } else {
                    // Begin a text selection; it becomes visible once the
                    // mouse moves to a second cell.
                    let offset = self.surface_scroll_offset(area.surface);
                    let cell = (x - area.content.x, offset + (y - area.content.y) as u64);
                    self.selection =
                        Some(Selection { surface: area.surface, anchor: cell, head: cell });
                    self.drag = Some(Drag::Select {
                        content: area.content,
                        auto_scroll: None,
                        col: x - area.content.x,
                    });
                }
            }
            return Ok(RenderAction::Draw);
        }
        Ok(RenderAction::None)
    }

    fn handle_left_drag(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        match &self.drag {
            Some(Drag::TabArm { surface, at }) => {
                let (surface, at) = (*surface, *at);
                if (x, y) != at {
                    let target = self.tab_drop_target_at(x, y);
                    self.drag = Some(Drag::Tab { surface, target });
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::Tab { surface, .. }) => {
                let surface = *surface;
                let target = self.tab_drop_target_at(x, y);
                self.drag = Some(Drag::Tab { surface, target });
                Ok(RenderAction::Draw)
            }
            Some(Drag::WorkspaceArm { workspace, at }) => {
                let (workspace, at) = (*workspace, *at);
                if (x, y) != at {
                    let target = self.workspace_drop_target_at(x, y);
                    self.drag = Some(Drag::Workspace { workspace, target });
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::Workspace { workspace, .. }) => {
                let workspace = *workspace;
                let target = self.workspace_drop_target_at(x, y);
                self.drag = Some(Drag::Workspace { workspace, target });
                Ok(RenderAction::Draw)
            }
            Some(Drag::Select { content, .. }) => {
                let content = *content;
                let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
                let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
                let offset =
                    self.selection.map(|sel| self.surface_scroll_offset(sel.surface)).unwrap_or(0);
                if let Some(sel) = self.selection.as_mut() {
                    sel.head = (cx - content.x, offset + (cy - content.y) as u64);
                }
                let auto_scroll = if y <= content.y {
                    Some(-1)
                } else if y >= content.y + content.height.saturating_sub(1) {
                    Some(1)
                } else {
                    None
                };
                self.drag = Some(Drag::Select { content, auto_scroll, col: cx - content.x });
                Ok(RenderAction::Draw)
            }
            Some(Drag::Browser { surface, content }) => {
                let (surface, content) = (*surface, *content);
                let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
                let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
                self.send_browser_mouse(
                    surface,
                    content,
                    cx,
                    cy,
                    BrowserMouseDispatch::new("mouseMoved", Some("left"), Some(1)),
                );
                Ok(RenderAction::Draw)
            }
            Some(Drag::Scrollbar { surface, track, anchor_y, anchor_offset }) => {
                let (surface, track, anchor_y, anchor_offset) =
                    (*surface, *track, *anchor_y, *anchor_offset);
                self.drag_scrollbar(surface, track, anchor_y, anchor_offset, y);
                Ok(RenderAction::Draw)
            }
            Some(Drag::SidebarResize) => {
                if let Some(width) =
                    sidebar_drag_width(&self.config, self.content_area, self.sidebar_width, x)
                {
                    self.sidebar_width_override = Some(width);
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::ResizeSplit { horizontal, vertical }) => {
                let (horizontal, vertical) = (*horizontal, *vertical);
                if let Some((pane, edge)) = horizontal {
                    self.resize_split(pane, edge, x, y);
                }
                if let Some((pane, edge)) = vertical {
                    self.resize_split(pane, edge, x, y);
                }
                Ok(RenderAction::Draw)
            }
            None => Ok(RenderAction::None),
        }
    }

    fn handle_left_up(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        if let Some(Drag::TabArm { surface, .. }) = self.drag {
            self.drag = None;
            if let Some((pane, index)) = self.tab_location(surface) {
                self.session.focus_pane(pane);
                self.session.select_tab(Some(pane), Some(index), None);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Tab { surface, .. }) = self.drag {
            self.drag = None;
            if let Some((pane, index)) = self.tab_drop_target_at(x, y) {
                self.session.move_tab(surface, pane, index);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::WorkspaceArm { workspace, .. }) = self.drag {
            self.drag = None;
            if let Some(index) = self.workspace_index(workspace) {
                self.session.select_workspace(Some(index), None);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Workspace { workspace, .. }) = self.drag {
            self.drag = None;
            if let Some(index) = self.workspace_drop_target_at(x, y) {
                self.session.move_workspace(workspace, index);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Browser { surface, content }) = self.drag {
            self.drag = None;
            let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
            let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
            self.send_browser_mouse(
                surface,
                content,
                cx,
                cy,
                BrowserMouseDispatch::new("mouseReleased", Some("left"), Some(1)),
            );
            return Ok(RenderAction::Draw);
        }
        let was_select = matches!(self.drag, Some(Drag::Select { .. }));
        let was_drag = self.drag.is_some();
        self.drag = None;
        if !was_select {
            return Ok(if was_drag { RenderAction::Draw } else { RenderAction::None });
        }
        match self.selection {
            Some(sel) if sel.anchor != sel.head => {
                self.copy_selection(sel);
                Ok(RenderAction::Draw)
            }
            _ => {
                // A plain click: no selection to keep.
                self.selection = None;
                Ok(RenderAction::Draw)
            }
        }
    }

    /// Copy the selected text to the host clipboard via OSC 52 (the host
    /// terminal owns the clipboard; this works over SSH too).
    fn copy_selection(&mut self, sel: Selection) {
        let Some(surface) = self.session.surface(sel.surface) else { return };
        let (start, end) = sel.range();
        let Some(text) = surface.with_terminal(|t| t.selection_text_absolute(start, end)).flatten()
        else {
            return;
        };
        if text.is_empty() {
            return;
        }
        if let SurfaceHandle::Local(local) = &surface {
            local.set_selection_text(Some(text.clone()));
        }
        self.copy_text_to_clipboard(&text);
        self.show_toast("Copied".to_string());
    }

    fn copy_text_to_clipboard(&self, text: &str) {
        let encoded = base64::engine::general_purpose::STANDARD.encode(text.as_bytes());
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]52;c;{encoded}\x07");
        let _ = stdout.flush();
    }

    fn copy_short_id(&mut self, short_id: String) {
        self.copy_text_to_clipboard(&short_id);
        self.show_toast(format!("Copied {short_id}"));
    }

    fn show_toast(&mut self, text: String) {
        self.toast = Some(Toast { text, deadline: Instant::now() + Duration::from_millis(1500) });
    }

    fn expire_toast(&mut self) -> bool {
        if self.toast.as_ref().is_some_and(|toast| Instant::now() >= toast.deadline) {
            self.toast = None;
            true
        } else {
            false
        }
    }

    /// Shift a pane's tab bar left/right. The renderer clamps to the
    /// valid range next frame.
    fn scroll_tabs(&mut self, pane: PaneId, delta: isize) {
        let entry = self.tab_scroll.entry(pane).or_insert(0);
        *entry = entry.saturating_add_signed(delta);
    }

    /// Start a scrollbar drag. Clicking the thumb only anchors; clicking
    /// outside it jumps first, then anchors at the clicked position.
    fn start_scrollbar_drag(&mut self, surface: SurfaceId, track: Rect, y: u16) {
        let Some(handle) = self.session.surface(surface) else { return };
        let mut anchor_offset = None;
        let _ = handle.with_terminal(|t| {
            let Some(sb) = t.scrollbar() else { return };
            let rel_y = y.saturating_sub(track.y).min(track.height.saturating_sub(1));
            let (thumb_y, thumb_len) = thumb_geometry(&sb, track.height);
            let on_thumb = rel_y >= thumb_y && rel_y < thumb_y + thumb_len;
            if !on_thumb {
                let denom = track.height.saturating_sub(1).max(1) as f64;
                let frac = (rel_y as f64 / denom).clamp(0.0, 1.0);
                let target = ((sb.total - sb.len) as f64 * frac).round() as i64;
                let delta = target - sb.offset as i64;
                if delta != 0 {
                    t.scroll_delta(delta as isize);
                }
            }
            anchor_offset = t.scrollbar().map(|after| after.offset);
        });
        if let Some(anchor_offset) = anchor_offset {
            self.drag = Some(Drag::Scrollbar { surface, track, anchor_y: y, anchor_offset });
        }
    }

    /// Map an anchored scrollbar drag delta to a viewport offset.
    fn drag_scrollbar(
        &mut self,
        surface: SurfaceId,
        track: Rect,
        anchor_y: u16,
        anchor_offset: u64,
        y: u16,
    ) {
        let Some(handle) = self.session.surface(surface) else { return };
        handle.with_terminal(|t| {
            let Some(sb) = t.scrollbar() else { return };
            let (_, thumb_len) = thumb_geometry(&sb, track.height);
            let range = sb.total.saturating_sub(sb.len);
            let travel = track.height.saturating_sub(thumb_len).max(1) as i128;
            let dy = y as i128 - anchor_y as i128;
            let delta = dy * range as i128 / travel;
            let target = (anchor_offset as i128 + delta).clamp(0, range as i128) as i64;
            let current = sb.offset as i64;
            let scroll_delta = target - current;
            if scroll_delta != 0 {
                t.scroll_delta(scroll_delta as isize);
            }
        });
    }

    fn resize_focused_split(&mut self, delta: f32) {
        let Some(pane) = self.active_pane() else { return };
        let Some(screen) = self.tree.active_screen() else { return };
        let Some(area) = self.pane_areas.iter().find(|area| area.pane == pane) else {
            return;
        };
        let candidates = [
            (SplitEdge::Right, PaneEdge::Right),
            (SplitEdge::Left, PaneEdge::Left),
            (SplitEdge::Bottom, PaneEdge::Bottom),
            (SplitEdge::Top, PaneEdge::Top),
        ];
        let Some((edge, target)) = candidates
            .into_iter()
            .filter_map(|(split_edge, pane_edge)| {
                split_for_pane_edge(&screen.layout, self.content_area, pane, split_edge)
                    .map(|target| (pane_edge, target))
            })
            .min_by_key(|(_, target)| target.area.width as u32 * target.area.height as u32)
        else {
            return;
        };
        let (current, dir, sign) = match edge {
            PaneEdge::Left => (
                (area.rect.x.saturating_sub(target.area.x)) as f32
                    / target.area.width.max(1) as f32,
                SplitDir::Right,
                -1.0,
            ),
            PaneEdge::Right => (
                (area.rect.x + area.rect.width).saturating_sub(target.area.x) as f32
                    / target.area.width.max(1) as f32,
                SplitDir::Right,
                1.0,
            ),
            PaneEdge::Top => (
                (area.rect.y.saturating_sub(target.area.y)) as f32
                    / target.area.height.max(1) as f32,
                SplitDir::Down,
                -1.0,
            ),
            PaneEdge::Bottom => (
                (area.rect.y + area.rect.height).saturating_sub(target.area.y) as f32
                    / target.area.height.max(1) as f32,
                SplitDir::Down,
                1.0,
            ),
        };
        self.session.set_ratio(target.set_pane, dir, (current + delta * sign).clamp(0.05, 0.95));
    }

    fn resize_split(&mut self, pane: PaneId, edge: PaneEdge, x: u16, y: u16) {
        let Some(screen) = self.tree.active_screen() else { return };
        let split_edge = match edge {
            PaneEdge::Left => SplitEdge::Left,
            PaneEdge::Right => SplitEdge::Right,
            PaneEdge::Top => SplitEdge::Top,
            PaneEdge::Bottom => SplitEdge::Bottom,
        };
        let Some(target) = split_for_pane_edge(&screen.layout, self.content_area, pane, split_edge)
        else {
            return;
        };
        let (coord, start, extent, dir) = match edge {
            PaneEdge::Left => (x, target.area.x, target.area.width, SplitDir::Right),
            PaneEdge::Right => {
                (x.saturating_add(1), target.area.x, target.area.width, SplitDir::Right)
            }
            PaneEdge::Top => (y, target.area.y, target.area.height, SplitDir::Down),
            PaneEdge::Bottom => {
                (y.saturating_add(1), target.area.y, target.area.height, SplitDir::Down)
            }
        };
        if extent == 0 {
            return;
        }
        let ratio = (coord.saturating_sub(start) as f32 / extent as f32).clamp(0.05, 0.95);
        self.session.set_ratio(target.set_pane, dir, ratio);
    }

    fn open_context_menu(&mut self, x: u16, y: u16) {
        self.menu = None;
        self.omnibar = None;
        match self.hit_at(x, y) {
            Some(Hit::Workspace { id, .. }) => {
                self.menu = Some(ContextMenu::at(
                    x,
                    y,
                    vec![
                        MenuAction::RenameWorkspace(id),
                        MenuAction::CopyWorkspaceId(id),
                        MenuAction::CloseWorkspace(id),
                    ],
                ));
                return;
            }
            Some(Hit::ScreenEntry { id, .. }) => {
                self.menu = Some(ContextMenu::at(
                    x,
                    y,
                    vec![MenuAction::RenameScreen(id), MenuAction::CloseScreen(id)],
                ));
                return;
            }
            _ => {}
        }
        if let Some(area) = self.pane_area_at(x, y) {
            let mut items = Vec::new();
            if self.surface_kind(area.surface) == SurfaceKind::Browser {
                items.extend([
                    MenuAction::BrowserBack(area.pane),
                    MenuAction::BrowserForward(area.pane),
                    MenuAction::BrowserReload(area.pane),
                    MenuAction::BrowserEditUrl(area.pane),
                    MenuAction::BrowserCopyUrl(area.pane),
                ]);
                if self.browser_source(area.surface) == Some(BrowserSource::External) {
                    items.push(MenuAction::BrowserActivate(area.pane));
                }
            }
            items.extend([
                MenuAction::RenameTab(area.pane),
                MenuAction::CopyTabId(area.pane),
                MenuAction::CopyPaneId(area.pane),
                MenuAction::NewTab(area.pane),
                MenuAction::NewBrowserTab(area.pane),
                MenuAction::SplitRight(area.pane),
                MenuAction::SplitDown(area.pane),
                MenuAction::CloseTab(area.pane),
                MenuAction::ClosePane(area.pane),
            ]);
            self.menu = Some(ContextMenu::at(x, y, items));
        }
    }

    fn handle_scroll(&mut self, x: u16, y: u16, down: bool) -> anyhow::Result<RenderAction> {
        let Some(area) = self.pane_area_at(x, y).copied() else { return Ok(RenderAction::None) };
        if self.active_pane() != Some(area.pane) {
            self.session.focus_pane(area.pane);
        }
        // Wheel over the tab bar scrolls the tabs, not the terminal.
        if area.bar.is_some_and(|bar| bar.contains(x, y)) {
            self.scroll_tabs(area.pane, if down { 1 } else { -1 });
            return Ok(RenderAction::Draw);
        }
        let (surface_id, _) = (area.surface, area.pane);
        let Some(surface) = self.session.surface(surface_id) else { return Ok(RenderAction::None) };
        if surface.kind() == SurfaceKind::Browser {
            if area.content.contains(x, y) {
                let (px, py) = self.browser_point(area.content, x, y);
                let delta = if down { 3.0 } else { -3.0 } * f64::from(self.cell_pixels.1);
                self.browser_input.enqueue(BrowserInputEvent {
                    surface_id,
                    surface,
                    kind: BrowserInputKind::Wheel { x: px, y: py, delta_y: delta },
                });
                return Ok(RenderAction::Draw);
            }
            return Ok(RenderAction::None);
        }
        let Some(sent_arrows) = surface.with_terminal(|term| {
            if term.active_screen() == Screen::Alternate && !term.mouse_tracking() {
                term.scroll_to_bottom();
                true
            } else {
                term.scroll_delta(if down { 3 } else { -3 });
                false
            }
        }) else {
            return Ok(RenderAction::None);
        };
        if sent_arrows {
            // Alt-screen apps without mouse support get arrow keys
            // (the usual alternate-scroll behavior).
            let seq: &[u8] = if down { b"\x1b[B\x1b[B\x1b[B" } else { b"\x1b[A\x1b[A\x1b[A" };
            surface.write_bytes(seq);
        }
        Ok(RenderAction::Draw)
    }

    fn surface_kind(&self, surface: SurfaceId) -> SurfaceKind {
        self.session.surface(surface).map(|surface| surface.kind()).unwrap_or(SurfaceKind::Pty)
    }

    fn browser_source(&self, surface: SurfaceId) -> Option<BrowserSource> {
        self.tree
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == surface)
            .and_then(|tab| tab.browser_source)
    }

    fn browser_point(&self, content: Rect, x: u16, y: u16) -> (f64, f64) {
        let col = x.saturating_sub(content.x) as f64 + 0.5;
        let row = y.saturating_sub(content.y) as f64 + 0.5;
        (col * f64::from(self.cell_pixels.0), row * f64::from(self.cell_pixels.1))
    }

    /// Queue a mouse event for the off-loop browser input worker; the
    /// event loop never waits on the CDP/socket round trip.
    fn send_browser_mouse(
        &self,
        surface_id: SurfaceId,
        content: Rect,
        x: u16,
        y: u16,
        dispatch: BrowserMouseDispatch,
    ) {
        let Some(surface) = self.session.surface(surface_id) else { return };
        let (px, py) = self.browser_point(content, x, y);
        self.browser_input.enqueue(BrowserInputEvent {
            surface_id,
            surface,
            kind: BrowserInputKind::Mouse {
                event_type: dispatch.event_type,
                x: px,
                y: py,
                button: dispatch.button,
                click_count: dispatch.click_count,
            },
        });
    }
}

fn browser_modifiers(modifiers: KeyModifiers) -> u32 {
    let mut out = 0;
    if modifiers.contains(KeyModifiers::ALT) {
        out |= 1;
    }
    if modifiers.contains(KeyModifiers::CONTROL) {
        out |= 2;
    }
    if modifiers.contains(KeyModifiers::SUPER) {
        out |= 4;
    }
    if modifiers.contains(KeyModifiers::SHIFT) {
        out |= 8;
    }
    out
}

fn browser_only_action(action: Action) -> bool {
    matches!(
        action,
        Action::BrowserBack
            | Action::BrowserForward
            | Action::BrowserReload
            | Action::BrowserEditUrl
    )
}

fn browser_hover_forward_allowed(status: Option<BrowserStatus>, editing_same_pane: bool) -> bool {
    !editing_same_pane && matches!(status, Some(BrowserStatus::Live))
}

fn clear_omnibar_selection(state: &mut OmnibarState) {
    if state.select_all {
        state.input.clear();
        state.select_all = false;
    }
}

fn rects_intersect(a: Rect, b: Rect) -> bool {
    let ax2 = a.x.saturating_add(a.width);
    let ay2 = a.y.saturating_add(a.height);
    let bx2 = b.x.saturating_add(b.width);
    let by2 = b.y.saturating_add(b.height);
    a.x < bx2 && ax2 > b.x && a.y < by2 && ay2 > b.y
}

fn browser_key_mapping(
    code: KeyCode,
) -> Option<(&'static str, &'static str, u32, Option<&'static str>)> {
    match code {
        KeyCode::Enter => Some(("Enter", "Enter", 13, Some("\r"))),
        KeyCode::Backspace => Some(("Backspace", "Backspace", 8, None)),
        KeyCode::Tab | KeyCode::BackTab => Some(("Tab", "Tab", 9, None)),
        KeyCode::Esc => Some(("Escape", "Escape", 27, None)),
        KeyCode::Left => Some(("ArrowLeft", "ArrowLeft", 37, None)),
        KeyCode::Up => Some(("ArrowUp", "ArrowUp", 38, None)),
        KeyCode::Right => Some(("ArrowRight", "ArrowRight", 39, None)),
        KeyCode::Down => Some(("ArrowDown", "ArrowDown", 40, None)),
        KeyCode::Home => Some(("Home", "Home", 36, None)),
        KeyCode::End => Some(("End", "End", 35, None)),
        KeyCode::PageUp => Some(("PageUp", "PageUp", 33, None)),
        KeyCode::PageDown => Some(("PageDown", "PageDown", 34, None)),
        KeyCode::Delete => Some(("Delete", "Delete", 46, None)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        browser_content_size_for_rect, browser_hover_forward_allowed, pane_parts_for_rect, App,
        PaneArea,
    };
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    use ghostty_vt::{KeyEncoder, RenderState};
    use mux_core::{BrowserStatus, Mux, Node, Rect, SurfaceKind, SurfaceOptions};
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    use crate::browser_input::BrowserInputDispatcher;
    use crate::config::{Config, ScrollbarPosition};
    use crate::session::tree::{PaneView, ScreenView, TabNotificationView, TabView, WorkspaceView};
    use crate::session::{Session, TreeView};

    #[test]
    fn browser_omnibar_reduces_content_rect_for_graphics_and_input() {
        let rect = Rect { x: 10, y: 4, width: 80, height: 24 };
        let (_bar, omnibar, content, track) =
            pane_parts_for_rect(rect, ScrollbarPosition::Column, true);
        assert_eq!(omnibar, Some(Rect { x: 11, y: 5, width: 77, height: 1 }));
        assert_eq!(content, Rect { x: 11, y: 6, width: 77, height: 21 });
        assert_eq!(track, Some(Rect { x: 88, y: 5, width: 1, height: 22 }));
    }

    #[test]
    fn browser_omnibar_degrades_gracefully_with_one_content_row() {
        let rect = Rect { x: 0, y: 0, width: 20, height: 3 };
        let (_bar, omnibar, content, _track) =
            pane_parts_for_rect(rect, ScrollbarPosition::Border, true);
        assert_eq!(omnibar, None);
        assert_eq!(content, Rect { x: 1, y: 1, width: 18, height: 1 });
    }

    #[test]
    fn browser_tab_size_hint_uses_omnibar_reduced_content() {
        let rect = Rect { x: 10, y: 4, width: 80, height: 24 };
        assert_eq!(browser_content_size_for_rect(rect, ScrollbarPosition::Column), Some((77, 21)));
    }

    #[test]
    fn hover_forwarding_only_runs_for_live_non_editing_browser() {
        assert!(browser_hover_forward_allowed(Some(BrowserStatus::Live), false));
        assert!(!browser_hover_forward_allowed(Some(BrowserStatus::Live), true));
        assert!(!browser_hover_forward_allowed(Some(BrowserStatus::Starting), false));
        assert!(!browser_hover_forward_allowed(
            Some(BrowserStatus::Failed("boom".to_string())),
            false
        ));
        assert!(!browser_hover_forward_allowed(None, false));
    }

    #[test]
    fn notify_unread_indicators_render_and_clear() {
        let mux = Mux::new(
            "notify-render-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_width = 12;
        app.tree = notify_tree(surface.id, true);
        app.pane_areas.push(PaneArea {
            pane: 2,
            surface: surface.id,
            rect: Rect { x: 12, y: 1, width: 26, height: 8 },
            bar: Some(Rect { x: 12, y: 1, width: 26, height: 1 }),
            omnibar: None,
            content: Rect { x: 13, y: 2, width: 23, height: 6 },
            track: None,
        });

        let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
        terminal
            .draw(|frame| {
                crate::ui::draw(&mut app, frame);
            })
            .unwrap();
        let buffer = terminal.backend().buffer();
        assert_eq!(buffer[(12, 2)].symbol(), "│");
        assert_eq!(buffer[(12, 2)].style().fg, Some(app.config.theme.notification_warning));
        assert!(row_contains(buffer, 1, "•"), "tab bar should contain unread dot");
        assert_eq!(buffer[(0, 2)].symbol(), "•", "sidebar should contain unread dot");

        app.tree = notify_tree(surface.id, false);
        let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
        terminal
            .draw(|frame| {
                crate::ui::draw(&mut app, frame);
            })
            .unwrap();
        let buffer = terminal.backend().buffer();
        assert_eq!(buffer[(12, 2)].style().fg, Some(app.config.theme.border_active));
        assert!(!row_contains(buffer, 1, "•"), "tab bar dot should clear");
        assert_ne!(buffer[(0, 2)].symbol(), "•", "sidebar dot should clear");

        mux.close_surface(surface.id);
    }

    fn test_app(session: Session) -> App {
        App {
            session,
            config: Config::default(),
            tree: TreeView::default(),
            render_states: HashMap::<u64, RenderState>::new(),
            graphics_writer: None,
            graphics_supported: false,
            stdout_lock: Arc::new(Mutex::new(())),
            pane_areas: Vec::new(),
            prefix_armed: false,
            session_label: "test".to_string(),
            sidebar_visible: true,
            sidebar_width: 0,
            sidebar_width_override: None,
            content_area: Rect::default(),
            hits: Vec::new(),
            tab_scroll: HashMap::new(),
            hover: None,
            menu: None,
            prompt: None,
            omnibar: None,
            toast: None,
            shake_frames: 0,
            selection: None,
            status_message: None,
            cell_pixels: (8, 16),
            pointer_shape: false,
            last_browser_hover: None,
            browser_input: BrowserInputDispatcher::spawn().unwrap(),
            drag: None,
            encoder: KeyEncoder::new().unwrap(),
            encode_buf: Vec::new(),
            quit: false,
        }
    }

    fn notify_tree(surface: u64, unread: bool) -> TreeView {
        TreeView {
            active_workspace: 0,
            workspaces: vec![WorkspaceView {
                id: 4,
                short_id: "000004".to_string(),
                name: "work".to_string(),
                active_screen: 0,
                screens: vec![ScreenView {
                    id: 3,
                    short_id: "000003".to_string(),
                    name: None,
                    layout: Node::Leaf(2),
                    active_pane: 2,
                    panes: vec![PaneView {
                        id: 2,
                        short_id: "000002".to_string(),
                        name: None,
                        active_tab: 0,
                        tabs: vec![TabView {
                            surface,
                            short_id: "000001".to_string(),
                            name: Some("tab".to_string()),
                            title: "shell".to_string(),
                            kind: SurfaceKind::Pty,
                            browser_source: None,
                            browser_frames_stalled: false,
                            notification: unread
                                .then_some(TabNotificationView { unread: true, level: "warning" }),
                        }],
                    }],
                }],
            }],
        }
    }

    fn row_contains(buffer: &ratatui::buffer::Buffer, y: u16, needle: &str) -> bool {
        (0..buffer.area.width).any(|x| buffer[(x, y)].symbol() == needle)
    }
}
