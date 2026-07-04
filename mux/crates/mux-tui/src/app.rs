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
use std::time::Duration;

use base64::Engine;
use crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event,
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ghostty_vt::{KeyEncoder, RenderState, Screen};
use mux_core::{
    layout_screen, split_for_pane_edge, split_sides, MuxEvent, PaneId, Rect, SplitDir, SplitEdge,
    SurfaceId, WorkspaceId,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal as RatatuiTerminal;

use crate::config::{Action, Config, ScrollbarPosition};
use crate::keys;
use crate::session::{Session, SurfaceHandle, TreeView};
use crate::ui::thumb_geometry;

pub enum AppEvent {
    Mux(MuxEvent),
    Input(Event),
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
    pub content: Rect,
    /// Scrollbar track (inside the box or on the right border).
    pub track: Option<Rect>,
}

/// A context-menu entry: what activating it does (the label is derived).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    RenameWorkspace(WorkspaceId),
    CloseWorkspace(WorkspaceId),
    RenameScreen(mux_core::ScreenId),
    CloseScreen(mux_core::ScreenId),
    RenameTab(PaneId),
    NewTab(PaneId),
    SplitRight(PaneId),
    SplitDown(PaneId),
    CloseTab(PaneId),
    ClosePane(PaneId),
}

impl MenuAction {
    pub fn label(&self) -> &'static str {
        match self {
            MenuAction::RenameWorkspace(_) => "Rename workspace",
            MenuAction::CloseWorkspace(_) => "Close workspace",
            MenuAction::RenameScreen(_) => "Rename screen",
            MenuAction::CloseScreen(_) => "Close screen",
            MenuAction::RenameTab(_) => "Rename tab",
            MenuAction::NewTab(_) => "New tab",
            MenuAction::SplitRight(_) => "Split right",
            MenuAction::SplitDown(_) => "Split down",
            MenuAction::CloseTab(_) => "Close tab",
            MenuAction::ClosePane(_) => "Close pane",
        }
    }
}

/// Right-click context menu overlay. Items get a one-cell padding column
/// on each side (no extra rows above/below); the hover/selection
/// highlight spans the full row including those padding cells.
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
        // one-cell padding column on each side.
        let width = label_w + 2 + Self::PAD * 2;
        let height = items.len() as u16;
        ContextMenu {
            items,
            selected: 0,
            right_press: (x, y),
            right_drag_moved: false,
            rect: Rect { x, y, width, height },
        }
    }

    /// The item row at a screen cell. Rows span the menu's full width,
    /// side padding included.
    pub fn item_at(&self, x: u16, y: u16) -> Option<usize> {
        if !self.rect.contains(x, y) {
            return None;
        }
        let row = (y - self.rect.y) as usize;
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
    pub buffer: String,
    pub target: PromptTarget,
    /// Dialog rect (set by the renderer each frame).
    pub rect: Rect,
    /// OK / Cancel button rects (set by the renderer each frame).
    pub ok: Rect,
    pub cancel: Rect,
}

impl Prompt {
    fn new(label: &'static str, buffer: String, target: PromptTarget) -> Self {
        Prompt {
            label,
            buffer,
            target,
            rect: Rect::default(),
            ok: Rect::default(),
            cancel: Rect::default(),
        }
    }
}

/// A text selection in one surface, in viewport cell coordinates
/// relative to the pane content rect. `anchor` is where the drag
/// started; `head` follows the mouse. Viewport-anchored: scrolling the
/// surface clears it.
#[derive(Debug, Clone, Copy)]
pub struct Selection {
    pub surface: SurfaceId,
    pub anchor: (u16, u16),
    pub head: (u16, u16),
}

impl Selection {
    /// Normalized (start, end) in row-major order, inclusive.
    pub fn range(&self) -> ((u16, u16), (u16, u16)) {
        let a = (self.anchor.1, self.anchor.0);
        let h = (self.head.1, self.head.0);
        if a <= h {
            (self.anchor, self.head)
        } else {
            (self.head, self.anchor)
        }
    }

    /// Whether a viewport cell is inside the (linear) selection.
    pub fn contains(&self, x: u16, y: u16) -> bool {
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

/// Mouse drag in progress.
enum Drag {
    /// Text selection inside a pane's content rect.
    Select { content: Rect },
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
    pub(crate) shake_frames: u8,
    pub selection: Option<Selection>,
    /// Whether the terminal pointer is currently the hand shape (over a
    /// clickable element); tracked to avoid re-emitting OSC 22.
    pointer_shape: bool,
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
    let w = override_width.unwrap_or(config.sidebar.width);
    if !visible || width < w.saturating_add(48) {
        0
    } else {
        w
    }
}

fn content_size_for_rect(rect: Rect, scrollbar: ScrollbarPosition) -> Option<(u16, u16)> {
    if rect.width > 2 && rect.height > 2 {
        let reserved_cols = match scrollbar {
            ScrollbarPosition::Column => 3,
            ScrollbarPosition::Border => 2,
        };
        Some((rect.width.saturating_sub(reserved_cols).max(1), rect.height - 2))
    } else {
        (rect.width > 0 && rect.height > 0).then_some((rect.width, rect.height))
    }
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

    enable_raw_mode()?;
    if let Err(e) = (|| -> anyhow::Result<()> {
        let mut stdout = std::io::stdout();
        stdout.execute(EnterAlternateScreen)?;
        stdout.execute(EnableMouseCapture)?;
        stdout.execute(EnableBracketedPaste)?;
        Ok(())
    })() {
        let _ = restore_terminal();
        return Err(e);
    }
    // Restore the host terminal even if we panic mid-frame.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = restore_terminal();
        default_hook(info);
    }));

    let backend = CrosstermBackend::new(std::io::stdout());
    let mut terminal = match RatatuiTerminal::new(backend) {
        Ok(terminal) => terminal,
        Err(e) => {
            let _ = restore_terminal();
            return Err(e.into());
        }
    };

    let mut app = App {
        session,
        config,
        tree: TreeView::default(),
        render_states: HashMap::new(),
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
        shake_frames: 0,
        selection: None,
        pointer_shape: false,
        drag: None,
        encoder,
        encode_buf: Vec::with_capacity(64),
        quit: false,
    };

    let result = app.event_loop(&mut terminal, rx);
    let _ = std::panic::take_hook();
    restore_terminal()?;
    result
}

fn restore_terminal() -> anyhow::Result<()> {
    let mut stdout = std::io::stdout();
    // Reset the mouse pointer shape in case we left it as a hand.
    let _ = write!(stdout, "\x1b]22;default\x07");
    let _ = stdout.execute(DisableBracketedPaste);
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
        terminal.draw(|f| crate::ui::draw(self, f))?;

        while !self.quit {
            // Block for the first event, then drain whatever queued so a
            // torrent of pty output coalesces into one frame.
            let timeout = if self.shake_frames > 0 {
                Duration::from_millis(30)
            } else {
                Duration::from_millis(250)
            };
            let mut needs_draw = false;
            let first = match rx.recv_timeout(timeout) {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => {
                    needs_draw = self.shake_frames > 0;
                    None
                }
                Err(RecvTimeoutError::Disconnected) => break,
            };
            if let Some(event) = first {
                needs_draw |= self.handle(event)?;
            }
            for _ in 0..256 {
                match rx.try_recv() {
                    Ok(event) => needs_draw |= self.handle(event)?,
                    Err(_) => break,
                }
            }
            if self.quit {
                break;
            }
            if needs_draw {
                let size = terminal.size()?;
                self.sync_layout((size.width, size.height));
                terminal.draw(|f| crate::ui::draw(self, f))?;
            }
        }
        Ok(())
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
            let (bar, content, track) = if rect.width >= 3 && rect.height >= 3 {
                // The border box: top row is the tab bar. The scrollbar
                // either overlays the right border or gets a dedicated
                // column just inside it.
                let inner_height = rect.height - 2;
                let track_y = rect.y + 1;
                let right_border_x = rect.x + rect.width - 1;
                let content_w = match self.config.scrollbar.position {
                    ScrollbarPosition::Column => rect.width.saturating_sub(3),
                    ScrollbarPosition::Border => rect.width - 2,
                };
                let track_x = match self.config.scrollbar.position {
                    ScrollbarPosition::Column => right_border_x.saturating_sub(1),
                    ScrollbarPosition::Border => right_border_x,
                };
                (
                    Some(Rect { height: 1, ..rect }),
                    Rect { x: rect.x + 1, y: rect.y + 1, width: content_w, height: inner_height },
                    Some(Rect { x: track_x, y: track_y, width: 1, height: inner_height }),
                )
            } else {
                // Degenerate rect: no box, content fills it.
                (None, rect, None)
            };
            self.pane_areas.push(PaneArea {
                pane: pane_id,
                surface: surface_id,
                rect,
                bar,
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

    fn handle(&mut self, event: AppEvent) -> anyhow::Result<bool> {
        match event {
            AppEvent::Mux(MuxEvent::Empty) => {
                self.quit = true;
                Ok(false)
            }
            AppEvent::Mux(MuxEvent::SurfaceExited(id)) => {
                self.render_states.remove(&id);
                self.session.forget_surface(id);
                if self.selection.is_some_and(|s| s.surface == id) {
                    self.selection = None;
                }
                Ok(true)
            }
            AppEvent::Mux(_) => Ok(true),
            AppEvent::Input(Event::Key(key)) => self.handle_key(key),
            AppEvent::Input(Event::Mouse(mouse)) => self.handle_mouse(mouse),
            AppEvent::Input(Event::Paste(text)) => {
                self.paste(&text);
                Ok(false)
            }
            AppEvent::Input(Event::Resize(_, _)) => Ok(true),
            AppEvent::Input(_) => Ok(false),
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

    pub fn dragging_scrollbar(&self) -> Option<SurfaceId> {
        match self.drag {
            Some(Drag::Scrollbar { surface, .. }) => Some(surface),
            _ => None,
        }
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

    fn new_workspace(&mut self) -> anyhow::Result<()> {
        self.session.new_workspace(self.size_of_rect(self.content_area))
    }

    fn new_screen(&mut self) -> anyhow::Result<()> {
        self.session.new_screen(self.size_of_rect(self.content_area))
    }

    fn handle_key(&mut self, key: KeyEvent) -> anyhow::Result<bool> {
        if key.kind == KeyEventKind::Release {
            return Ok(false);
        }
        if self.prompt.is_some() {
            return self.handle_prompt_key(key);
        }
        if self.menu.is_some() {
            return self.handle_menu_key(key);
        }
        if self.prefix_armed {
            self.prefix_armed = false;
            return self.handle_prefixed(key);
        }
        if self.config.keys.prefix.matches(&key) {
            self.prefix_armed = true;
            return Ok(true);
        }
        // Typing replaces any selection highlight.
        self.selection = None;
        self.forward_key(&key);
        Ok(false)
    }

    /// Commit the open rename dialog (Enter or the OK button).
    fn commit_prompt(&mut self) {
        let Some(prompt) = self.take_prompt() else { return };
        match prompt.target {
            PromptTarget::Workspace(id) => {
                if !prompt.buffer.is_empty() {
                    self.session.rename_workspace(id, prompt.buffer);
                }
            }
            // Empty screen/tab names clear back to the default.
            PromptTarget::Screen(id) => self.session.rename_screen(id, prompt.buffer),
            PromptTarget::Surface(id) => self.session.rename_surface(id, prompt.buffer),
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

    fn handle_prompt_key(&mut self, key: KeyEvent) -> anyhow::Result<bool> {
        if self.prompt.is_none() {
            return Ok(false);
        }
        match key.code {
            KeyCode::Esc => {
                self.close_prompt();
            }
            KeyCode::Enter => self.commit_prompt(),
            KeyCode::Backspace => {
                if let Some(prompt) = self.prompt.as_mut() {
                    prompt.buffer.pop();
                }
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(prompt) = self.prompt.as_mut() {
                    prompt.buffer.push(c);
                }
            }
            _ => {}
        }
        Ok(true)
    }

    /// Clicks while the rename dialog is open: OK commits, Cancel (or a
    /// click outside the dialog) dismisses; clicks inside are swallowed.
    fn handle_prompt_click(&mut self, x: u16, y: u16) -> anyhow::Result<bool> {
        let Some(prompt) = self.prompt.as_ref() else { return Ok(false) };
        if prompt.ok.contains(x, y) {
            self.commit_prompt();
        } else if prompt.cancel.contains(x, y) || !prompt.rect.contains(x, y) {
            self.close_prompt();
        }
        Ok(true)
    }

    fn handle_menu_key(&mut self, key: KeyEvent) -> anyhow::Result<bool> {
        let Some(menu) = self.menu.as_mut() else { return Ok(false) };
        match key.code {
            KeyCode::Esc => {
                self.menu = None;
                Ok(true)
            }
            KeyCode::Up => {
                menu.selected = menu.selected.saturating_sub(1);
                Ok(true)
            }
            KeyCode::Down => {
                menu.selected = (menu.selected + 1).min(menu.items.len().saturating_sub(1));
                Ok(true)
            }
            KeyCode::Enter => {
                let action = menu.items[menu.selected];
                self.menu = None;
                self.activate_menu(action)?;
                Ok(true)
            }
            _ => Ok(true), // swallow while a menu is open
        }
    }

    fn handle_prefixed(&mut self, key: KeyEvent) -> anyhow::Result<bool> {
        // Prefix twice forwards the prefix chord literally.
        if self.config.keys.prefix.matches(&key) {
            self.forward_key(&key);
            return Ok(true);
        }
        // 1-9 select a tab by number (fixed: they mirror the tab labels).
        if let KeyCode::Char(c @ '1'..='9') = key.code {
            let pane = self.active_pane();
            self.session.select_tab(pane, Some(c as usize - '1' as usize), None);
            return Ok(true);
        }
        let Some(action) = self.config.keys.action_for(&key) else {
            return Ok(true); // unknown prefix command: swallow, redraw indicator
        };
        self.run_action(action)
    }

    /// Execute one bound action. Shared by the (configurable) prefix keys
    /// and any future command surface.
    fn run_action(&mut self, action: Action) -> anyhow::Result<bool> {
        let pane = self.active_pane();
        match action {
            Action::NewTab => {
                self.session.new_tab(pane, None)?;
            }
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
            Action::RenameTab => self.open_rename_tab_prompt(pane),
            Action::RenameWorkspace => self.open_rename_workspace_prompt(),
            Action::NextScreen => self.session.select_screen(None, Some(1)),
            Action::NewScreen => self.new_screen()?,
            Action::NextWorkspace => self.session.select_workspace(None, Some(1)),
            Action::NewWorkspace => self.new_workspace()?,
            Action::ToggleSidebar => self.sidebar_visible = !self.sidebar_visible,
            Action::FocusLeft => self.move_focus(-1, 0),
            Action::FocusRight => self.move_focus(1, 0),
            Action::FocusUp => self.move_focus(0, -1),
            Action::FocusDown => self.move_focus(0, 1),
            Action::ScrollUp => self.scroll_active(-10),
            Action::ScrollDown => self.scroll_active(10),
            Action::Detach => {
                // Local sessions end with the TUI; remote sessions keep
                // running server-side (detach).
                self.quit = true;
                return Ok(false);
            }
        }
        Ok(true)
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
            MenuAction::RenameTab(id) => self.open_rename_tab_prompt(Some(id)),
            MenuAction::NewTab(id) => self.session.new_tab(Some(id), None)?,
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
            surface.with_terminal(|t| t.scroll_delta(delta));
        }
        if let (Some(sel), Some(active)) = (self.selection, self.active_surface()) {
            if sel.surface == active {
                self.selection = None;
            }
        }
    }

    fn forward_key(&mut self, key: &KeyEvent) {
        let Some(input) = keys::key_input_from(key) else { return };
        let Some(surface) = self.active_surface_handle() else { return };
        self.encode_buf.clear();
        let encoded = surface.with_terminal(|term| {
            // New input snaps the viewport back to the live screen.
            term.scroll_to_bottom();
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        });
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            surface.write_bytes(&self.encode_buf);
        }
    }

    fn paste(&mut self, text: &str) {
        let Some(surface) = self.active_surface_handle() else { return };
        let bracketed = surface.with_terminal(|t| t.mode(2004, false));
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

    fn handle_mouse(&mut self, mouse: MouseEvent) -> anyhow::Result<bool> {
        match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                self.handle_left_down(mouse.column, mouse.row)
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                self.handle_left_drag(mouse.column, mouse.row)
            }
            MouseEventKind::Up(MouseButton::Left) => self.handle_left_up(),
            MouseEventKind::Down(MouseButton::Right) => {
                if self.prompt.is_some() {
                    self.shake_frames = 6;
                    return Ok(true);
                }
                self.open_context_menu(mouse.column, mouse.row);
                Ok(true)
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
            _ => Ok(false),
        }
    }

    /// Whether the cell is over something clickable (any hit, a menu row,
    /// or a dialog button): these render the hand pointer.
    fn is_clickable(&self, x: u16, y: u16) -> bool {
        if let Some(prompt) = &self.prompt {
            return prompt.ok.contains(x, y) || prompt.cancel.contains(x, y);
        }
        if let Some(menu) = &self.menu {
            if menu.item_at(x, y).is_some() {
                return true;
            }
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
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]22;{shape}\x07");
        let _ = stdout.flush();
    }

    /// Mouse-move: sync the pointer shape, highlight the hovered menu
    /// item, and track the mouse position so tab-bar controls (+, ‹, ›)
    /// and the scrollbar render a hover state. Only redraws when the
    /// hovered element actually changes.
    fn handle_hover(&mut self, x: u16, y: u16) -> anyhow::Result<bool> {
        self.sync_pointer_shape(x, y);
        if let Some(menu) = self.menu.as_mut() {
            if let Some(item) = menu.item_at(x, y) {
                if item != menu.selected {
                    menu.selected = item;
                    return Ok(true);
                }
                return Ok(false);
            }
        }
        let hoverable = |pos: Option<(u16, u16)>| {
            pos.and_then(|(px, py)| self.hit_at(px, py)).filter(|hit| {
                matches!(hit, Hit::NewTab { .. } | Hit::TabScroll { .. } | Hit::Scrollbar { .. })
            })
        };
        let before = hoverable(self.hover);
        let after = hoverable(Some((x, y)));
        self.hover = Some((x, y));
        Ok(before != after)
    }

    fn handle_right_drag(&mut self, x: u16, y: u16) -> anyhow::Result<bool> {
        self.hover = Some((x, y));
        let Some(menu) = self.menu.as_mut() else { return Ok(false) };
        if (x, y) != menu.right_press {
            menu.right_drag_moved = true;
        }
        if let Some(item) = menu.item_at(x, y) {
            if item != menu.selected {
                menu.selected = item;
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn handle_right_up(&mut self, x: u16, y: u16) -> anyhow::Result<bool> {
        let Some(menu) = self.menu.take() else { return Ok(false) };
        let plain_open_click = !menu.right_drag_moved && (x, y) == menu.right_press;
        if plain_open_click {
            self.menu = Some(menu);
        } else if let Some(item) = menu.item_at(x, y) {
            let action = menu.items[item];
            self.activate_menu(action)?;
        } else {
            self.menu = Some(menu);
        }
        Ok(true)
    }

    fn handle_left_down(&mut self, x: u16, y: u16) -> anyhow::Result<bool> {
        self.selection = None;
        self.drag = None;

        // An open rename dialog captures the click.
        if self.prompt.is_some() {
            return self.handle_prompt_click(x, y);
        }

        // An open menu captures the click: activate or dismiss. Clicks on
        // the padding border dismiss without activating.
        if let Some(menu) = self.menu.take() {
            if let Some(item) = menu.item_at(x, y) {
                self.activate_menu(menu.items[item])?;
            } else if menu.rect.contains(x, y) {
                self.menu = Some(menu); // padding click: keep it open
            }
            return Ok(true);
        }

        if let Some(hit) = self.hit_at(x, y) {
            match hit {
                Hit::Workspace { index, .. } => {
                    self.session.select_workspace(Some(index), None);
                }
                Hit::NewWorkspace => self.new_workspace()?,
                Hit::ScreenEntry { index, .. } => {
                    self.session.select_screen(Some(index), None);
                }
                Hit::NewScreen => self.new_screen()?,
                Hit::Tab { pane, index } => {
                    self.session.focus_pane(pane);
                    self.session.select_tab(Some(pane), Some(index), None);
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
            return Ok(true);
        }

        if let Some(area) = self.pane_area_at(x, y).copied() {
            self.session.focus_pane(area.pane);
            if area.content.contains(x, y) {
                // Begin a text selection; it becomes visible once the
                // mouse moves to a second cell.
                let cell = (x - area.content.x, y - area.content.y);
                self.selection =
                    Some(Selection { surface: area.surface, anchor: cell, head: cell });
                self.drag = Some(Drag::Select { content: area.content });
            }
            return Ok(true);
        }
        Ok(false)
    }

    fn handle_left_drag(&mut self, x: u16, y: u16) -> anyhow::Result<bool> {
        match &self.drag {
            Some(Drag::Select { content }) => {
                let content = *content;
                let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
                let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
                if let Some(sel) = self.selection.as_mut() {
                    sel.head = (cx - content.x, cy - content.y);
                }
                Ok(true)
            }
            Some(Drag::Scrollbar { surface, track, anchor_y, anchor_offset }) => {
                let (surface, track, anchor_y, anchor_offset) =
                    (*surface, *track, *anchor_y, *anchor_offset);
                self.drag_scrollbar(surface, track, anchor_y, anchor_offset, y);
                Ok(true)
            }
            Some(Drag::SidebarResize) => {
                self.sidebar_width_override = Some(x.saturating_add(1).clamp(10, 60));
                Ok(true)
            }
            Some(Drag::ResizeSplit { horizontal, vertical }) => {
                let (horizontal, vertical) = (*horizontal, *vertical);
                if let Some((pane, edge)) = horizontal {
                    self.resize_split(pane, edge, x, y);
                }
                if let Some((pane, edge)) = vertical {
                    self.resize_split(pane, edge, x, y);
                }
                Ok(true)
            }
            None => Ok(false),
        }
    }

    fn handle_left_up(&mut self) -> anyhow::Result<bool> {
        let was_select = matches!(self.drag, Some(Drag::Select { .. }));
        let was_drag = self.drag.is_some();
        self.drag = None;
        if !was_select {
            return Ok(was_drag);
        }
        match self.selection {
            Some(sel) if sel.anchor != sel.head => {
                self.copy_selection(sel);
                Ok(true)
            }
            _ => {
                // A plain click: no selection to keep.
                self.selection = None;
                Ok(true)
            }
        }
    }

    /// Copy the selected text to the host clipboard via OSC 52 (the host
    /// terminal owns the clipboard; this works over SSH too).
    fn copy_selection(&mut self, sel: Selection) {
        let Some(surface) = self.session.surface(sel.surface) else { return };
        let (start, end) = sel.range();
        let Some(text) = surface.with_terminal(|t| t.selection_text(start, end)) else { return };
        if text.is_empty() {
            return;
        }
        let encoded = base64::engine::general_purpose::STANDARD.encode(text.as_bytes());
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]52;c;{encoded}\x07");
        let _ = stdout.flush();
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
        let mut moved = false;
        handle.with_terminal(|t| {
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
                    moved = true;
                }
            }
            anchor_offset = t.scrollbar().map(|after| after.offset);
        });
        if moved && self.selection.is_some_and(|s| s.surface == surface) {
            self.selection = None;
        }
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
        let mut moved = false;
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
                moved = true;
            }
        });
        if moved && self.selection.is_some_and(|s| s.surface == surface) {
            self.selection = None;
        }
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
        match self.hit_at(x, y) {
            Some(Hit::Workspace { id, .. }) => {
                self.menu = Some(ContextMenu::at(
                    x,
                    y,
                    vec![MenuAction::RenameWorkspace(id), MenuAction::CloseWorkspace(id)],
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
            self.menu = Some(ContextMenu::at(
                x,
                y,
                vec![
                    MenuAction::RenameTab(area.pane),
                    MenuAction::NewTab(area.pane),
                    MenuAction::SplitRight(area.pane),
                    MenuAction::SplitDown(area.pane),
                    MenuAction::CloseTab(area.pane),
                    MenuAction::ClosePane(area.pane),
                ],
            ));
        }
    }

    fn handle_scroll(&mut self, x: u16, y: u16, down: bool) -> anyhow::Result<bool> {
        let Some(area) = self.pane_area_at(x, y).copied() else { return Ok(false) };
        if self.active_pane() != Some(area.pane) {
            self.session.focus_pane(area.pane);
        }
        // Wheel over the tab bar scrolls the tabs, not the terminal.
        if area.bar.is_some_and(|bar| bar.contains(x, y)) {
            self.scroll_tabs(area.pane, if down { 1 } else { -1 });
            return Ok(true);
        }
        let (surface_id, _) = (area.surface, area.pane);
        let Some(surface) = self.session.surface(surface_id) else { return Ok(false) };
        let sent_arrows = surface.with_terminal(|term| {
            if term.active_screen() == Screen::Alternate && !term.mouse_tracking() {
                term.scroll_to_bottom();
                true
            } else {
                term.scroll_delta(if down { 3 } else { -3 });
                false
            }
        });
        if sent_arrows {
            // Alt-screen apps without mouse support get arrow keys
            // (the usual alternate-scroll behavior).
            let seq: &[u8] = if down { b"\x1b[B\x1b[B\x1b[B" } else { b"\x1b[A\x1b[A\x1b[A" };
            surface.write_bytes(seq);
        }
        // The viewport moved: a viewport-anchored selection is stale.
        if self.selection.is_some_and(|s| s.surface == surface_id) {
            self.selection = None;
        }
        Ok(true)
    }
}
