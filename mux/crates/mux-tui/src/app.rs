//! TUI event loop and tmux-like command handling.
//!
//! Runs against a [`Session`], which is either the in-process mux or a
//! remote session attached over the control socket. All state mutations
//! go through the session; the app only owns presentation state (render
//! snapshots, prefix arming, the current layout, menu/prompt overlays).

use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::time::Duration;

use crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event,
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ghostty_vt::{KeyEncoder, RenderState, Screen};
use mux_core::{layout_workspace, MuxEvent, PaneId, Rect, SplitDir, SurfaceId, WorkspaceId};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal as RatatuiTerminal;

use crate::keys;
use crate::session::{Session, SurfaceHandle, TreeView};

pub enum AppEvent {
    Mux(MuxEvent),
    Input(Event),
}

/// What a click on a sidebar row does. Rebuilt by the sidebar renderer
/// each frame so hit-testing always matches what is on screen.
#[derive(Debug, Clone, Copy)]
pub enum SidebarRow {
    Workspace { index: usize, id: WorkspaceId },
    NewWorkspace,
}

/// A clickable span in a pane's tab bar.
#[derive(Debug, Clone, Copy)]
pub enum TabBarHit {
    Select { pane: PaneId, index: usize },
    NewTab { pane: PaneId },
}

/// One pane's screen real estate for the current frame: an optional
/// one-row tab bar above the terminal content.
#[derive(Debug, Clone, Copy)]
pub struct PaneArea {
    pub pane: PaneId,
    pub surface: SurfaceId,
    pub rect: Rect,
    pub bar: Option<Rect>,
    pub content: Rect,
}

/// A context-menu entry: what activating it does (the label is derived).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    RenameWorkspace(WorkspaceId),
    CloseWorkspace(WorkspaceId),
    RenamePane(PaneId),
    NewTab(PaneId),
    SplitRight(PaneId),
    SplitDown(PaneId),
    ClosePane(PaneId),
}

impl MenuAction {
    pub fn label(&self) -> &'static str {
        match self {
            MenuAction::RenameWorkspace(_) => "Rename workspace",
            MenuAction::CloseWorkspace(_) => "Close workspace",
            MenuAction::RenamePane(_) => "Rename pane",
            MenuAction::NewTab(_) => "New tab",
            MenuAction::SplitRight(_) => "Split right",
            MenuAction::SplitDown(_) => "Split down",
            MenuAction::ClosePane(_) => "Close pane",
        }
    }
}

/// Right-click context menu overlay.
pub struct ContextMenu {
    pub items: Vec<MenuAction>,
    pub selected: usize,
    /// Where the menu is drawn (clamped to the screen by the renderer,
    /// which writes the final rect back for hit-testing).
    pub rect: Rect,
}

impl ContextMenu {
    fn at(x: u16, y: u16, items: Vec<MenuAction>) -> Self {
        let width = items.iter().map(|i| i.label().len()).max().unwrap_or(0) as u16 + 2;
        let height = items.len() as u16;
        ContextMenu { items, selected: 0, rect: Rect { x, y, width, height } }
    }
}

/// What a committed rename prompt applies to.
#[derive(Debug, Clone, Copy)]
pub enum PromptTarget {
    Workspace(WorkspaceId),
    Pane(PaneId),
}

/// Status-line text input (rename).
pub struct Prompt {
    pub label: &'static str,
    pub buffer: String,
    pub target: PromptTarget,
}

pub struct App {
    pub session: Session,
    pub tree: TreeView,
    pub render_states: HashMap<SurfaceId, RenderState>,
    pub pane_areas: Vec<PaneArea>,
    pub separators: Vec<mux_core::Separator>,
    pub prefix_armed: bool,
    pub session_label: String,
    pub sidebar_visible: bool,
    /// Width of the sidebar in the current frame (0 when hidden).
    pub sidebar_width: u16,
    /// (row, hit) map for the current frame's sidebar.
    pub sidebar_hits: Vec<(u16, SidebarRow)>,
    /// Clickable spans in the current frame's pane tab bars.
    pub tab_hits: Vec<(Rect, TabBarHit)>,
    pub menu: Option<ContextMenu>,
    pub prompt: Option<Prompt>,
    encoder: KeyEncoder,
    encode_buf: Vec<u8>,
    quit: bool,
}

pub fn run(session: Session, session_label: String) -> anyhow::Result<()> {
    // First workspace/pane before the terminal switches modes, so a
    // spawn failure prints a normal error.
    session.ensure_initial()?;
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
        tree: TreeView::default(),
        render_states: HashMap::new(),
        pane_areas: Vec::new(),
        separators: Vec::new(),
        prefix_armed: false,
        session_label,
        sidebar_visible: true,
        sidebar_width: 0,
        sidebar_hits: Vec::new(),
        tab_hits: Vec::new(),
        menu: None,
        prompt: None,
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
            let first = match rx.recv_timeout(Duration::from_millis(250)) {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => break,
            };
            let mut needs_draw = false;
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

    /// Sidebar width for a given terminal width: fixed, but it hides on
    /// narrow terminals where panes need every column.
    fn sidebar_width_for(&self, width: u16) -> u16 {
        if !self.sidebar_visible || width < 70 {
            0
        } else {
            22
        }
    }

    /// Refresh the tree snapshot, recompute the active workspace's layout
    /// (reserving tab-bar rows), and push content sizes to surfaces.
    fn sync_layout(&mut self, size: (u16, u16)) {
        let (width, height) = size;
        self.sidebar_width = self.sidebar_width_for(width);
        let area = Rect {
            x: self.sidebar_width,
            y: 0,
            width: width.saturating_sub(self.sidebar_width),
            height: height.saturating_sub(1), // status bar
        };
        self.tree = self.session.tree();
        let layout = self
            .tree
            .active_workspace()
            .map(|ws| layout_workspace(&ws.layout, area))
            .unwrap_or_default();
        self.separators = layout.separators;

        self.pane_areas.clear();
        let Some(ws) = self.tree.active_workspace() else { return };
        for (pane_id, rect) in layout.panes {
            let Some(pane) = ws.pane(pane_id) else { continue };
            let Some(surface_id) = pane.active_surface() else { continue };
            // Panes with several tabs get a one-row tab bar above the
            // terminal content.
            let (bar, content) = if pane.tabs.len() > 1 && rect.height > 1 {
                (
                    Some(Rect { height: 1, ..rect }),
                    Rect { y: rect.y + 1, height: rect.height - 1, ..rect },
                )
            } else {
                (None, rect)
            };
            self.pane_areas.push(PaneArea {
                pane: pane_id,
                surface: surface_id,
                rect,
                bar,
                content,
            });
            if content.width == 0 || content.height == 0 {
                continue;
            }
            // Size every tab in the pane, so switching tabs doesn't
            // trigger a resize flash.
            for tab in &pane.tabs {
                if let Some(surface) = self.session.surface(tab.surface) {
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
        self.tree.active_workspace().map(|ws| ws.active_pane)
    }

    fn active_surface(&self) -> Option<SurfaceId> {
        self.tree.active_surface()
    }

    fn active_surface_handle(&self) -> Option<SurfaceHandle> {
        self.active_surface().and_then(|id| self.session.surface(id))
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
        if key.code == KeyCode::Char('b') && key.modifiers.contains(KeyModifiers::CONTROL) {
            self.prefix_armed = true;
            return Ok(true);
        }
        self.forward_key(&key);
        Ok(false)
    }

    fn handle_prompt_key(&mut self, key: KeyEvent) -> anyhow::Result<bool> {
        let Some(prompt) = self.prompt.as_mut() else { return Ok(false) };
        match key.code {
            KeyCode::Esc => {
                self.prompt = None;
            }
            KeyCode::Enter => {
                let prompt = self.prompt.take().expect("prompt checked above");
                match prompt.target {
                    PromptTarget::Workspace(id) => {
                        if !prompt.buffer.is_empty() {
                            self.session.rename_workspace(id, prompt.buffer);
                        }
                    }
                    // An empty pane name clears it (back to the tab title).
                    PromptTarget::Pane(id) => self.session.rename_pane(id, prompt.buffer),
                }
            }
            KeyCode::Backspace => {
                prompt.buffer.pop();
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                prompt.buffer.push(c);
            }
            _ => {}
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
        let pane = self.active_pane();
        match (key.code, key.modifiers) {
            // Prefix-Ctrl-b: forward a literal Ctrl-b.
            (KeyCode::Char('b'), m) if m.contains(KeyModifiers::CONTROL) => {
                self.forward_key(&key);
                Ok(true)
            }
            (KeyCode::Char('c'), _) => {
                self.session.new_tab(pane)?;
                Ok(true)
            }
            (KeyCode::Char('%'), _) => {
                if let Some(pane) = pane {
                    self.session.split(pane, SplitDir::Right)?;
                }
                Ok(true)
            }
            (KeyCode::Char('"'), _) => {
                if let Some(pane) = pane {
                    self.session.split(pane, SplitDir::Down)?;
                }
                Ok(true)
            }
            (KeyCode::Char('x'), _) => {
                // Close the active tab; the pane collapses with its last
                // tab, so this is also "close pane" for single-tab panes.
                if let Some(surface) = self.active_surface() {
                    self.render_states.remove(&surface);
                    self.session.close_surface(surface);
                }
                Ok(true)
            }
            (KeyCode::Char('n'), _) => {
                self.session.select_tab(pane, None, Some(1));
                Ok(true)
            }
            (KeyCode::Char('p'), _) => {
                self.session.select_tab(pane, None, Some(-1));
                Ok(true)
            }
            (KeyCode::Char(c @ '1'..='9'), _) => {
                self.session.select_tab(pane, Some(c as usize - '1' as usize), None);
                Ok(true)
            }
            (KeyCode::Char(','), _) => {
                self.open_rename_pane_prompt(pane);
                Ok(true)
            }
            (KeyCode::Char('$'), _) => {
                self.open_rename_workspace_prompt();
                Ok(true)
            }
            (KeyCode::Char('s'), _) => {
                self.sidebar_visible = !self.sidebar_visible;
                Ok(true)
            }
            (KeyCode::Char('w'), m) if !m.contains(KeyModifiers::SHIFT) => {
                self.session.select_workspace(None, Some(1));
                Ok(true)
            }
            (KeyCode::Char('W'), _) => {
                self.session.new_workspace()?;
                Ok(true)
            }
            (KeyCode::Char('d'), _) => {
                // Local sessions end with the TUI; remote sessions keep
                // running server-side (detach).
                self.quit = true;
                Ok(false)
            }
            (KeyCode::Char('h'), _) | (KeyCode::Left, _) => {
                self.move_focus(-1, 0);
                Ok(true)
            }
            (KeyCode::Char('l'), _) | (KeyCode::Right, _) => {
                self.move_focus(1, 0);
                Ok(true)
            }
            (KeyCode::Char('k'), _) | (KeyCode::Up, _) => {
                self.move_focus(0, -1);
                Ok(true)
            }
            (KeyCode::Char('j'), _) | (KeyCode::Down, _) => {
                self.move_focus(0, 1);
                Ok(true)
            }
            (KeyCode::PageUp, _) => {
                self.scroll_active(-10);
                Ok(true)
            }
            (KeyCode::PageDown, _) => {
                self.scroll_active(10);
                Ok(true)
            }
            _ => Ok(true), // unknown prefix command: swallow, redraw indicator
        }
    }

    fn open_rename_pane_prompt(&mut self, pane: Option<PaneId>) {
        let Some(pane) = pane else { return };
        let buffer = self.tree.pane(pane).and_then(|p| p.name.clone()).unwrap_or_default();
        self.prompt =
            Some(Prompt { label: "Rename pane", buffer, target: PromptTarget::Pane(pane) });
    }

    fn open_rename_workspace_prompt(&mut self) {
        let Some(ws) = self.tree.active_workspace() else { return };
        self.prompt = Some(Prompt {
            label: "Rename workspace",
            buffer: ws.name.clone(),
            target: PromptTarget::Workspace(ws.id),
        });
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
                self.prompt = Some(Prompt {
                    label: "Rename workspace",
                    buffer,
                    target: PromptTarget::Workspace(id),
                });
            }
            MenuAction::CloseWorkspace(id) => self.session.close_workspace(id),
            MenuAction::RenamePane(id) => self.open_rename_pane_prompt(Some(id)),
            MenuAction::NewTab(id) => self.session.new_tab(Some(id))?,
            MenuAction::SplitRight(id) => self.session.split(id, SplitDir::Right)?,
            MenuAction::SplitDown(id) => self.session.split(id, SplitDir::Down)?,
            MenuAction::ClosePane(id) => self.session.close_pane(id),
        }
        Ok(())
    }

    fn move_focus(&self, dx: i32, dy: i32) {
        let Some(active) = self.active_pane() else { return };
        // Re-derive the layout geometry from the frame's pane areas.
        let layout = mux_core::LayoutResult {
            panes: self.pane_areas.iter().map(|a| (a.pane, a.rect)).collect(),
            separators: Vec::new(),
        };
        if let Some(next) = layout.neighbor(active, dx, dy) {
            self.session.focus_pane(next);
        }
    }

    fn scroll_active(&self, delta: isize) {
        if let Some(surface) = self.active_surface_handle() {
            surface.with_terminal(|t| t.scroll_delta(delta));
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

    fn sidebar_hit_at(&self, x: u16, y: u16) -> Option<SidebarRow> {
        if self.sidebar_width == 0 || x >= self.sidebar_width {
            return None;
        }
        self.sidebar_hits.iter().find(|(row, _)| *row == y).map(|(_, hit)| *hit)
    }

    fn handle_mouse(&mut self, mouse: MouseEvent) -> anyhow::Result<bool> {
        match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                self.handle_left_click(mouse.column, mouse.row)
            }
            MouseEventKind::Down(MouseButton::Right) => {
                self.open_context_menu(mouse.column, mouse.row);
                Ok(true)
            }
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                let down = matches!(mouse.kind, MouseEventKind::ScrollDown);
                self.handle_scroll(mouse.column, mouse.row, down)
            }
            _ => Ok(false),
        }
    }

    fn handle_left_click(&mut self, x: u16, y: u16) -> anyhow::Result<bool> {
        // An open menu captures the click: activate or dismiss.
        if let Some(menu) = self.menu.take() {
            if menu.rect.contains(x, y) {
                let action = menu.items[(y - menu.rect.y) as usize];
                self.activate_menu(action)?;
            }
            return Ok(true);
        }

        match self.sidebar_hit_at(x, y) {
            Some(SidebarRow::Workspace { index, .. }) => {
                self.session.select_workspace(Some(index), None);
                return Ok(true);
            }
            Some(SidebarRow::NewWorkspace) => {
                self.session.new_workspace()?;
                return Ok(true);
            }
            None => {}
        }

        if let Some((_, hit)) = self.tab_hits.iter().find(|(rect, _)| rect.contains(x, y)).copied()
        {
            match hit {
                TabBarHit::Select { pane, index } => {
                    self.session.focus_pane(pane);
                    self.session.select_tab(Some(pane), Some(index), None);
                }
                TabBarHit::NewTab { pane } => {
                    self.session.focus_pane(pane);
                    self.session.new_tab(Some(pane))?;
                }
            }
            return Ok(true);
        }

        if let Some(area) = self.pane_area_at(x, y) {
            self.session.focus_pane(area.pane);
            return Ok(true);
        }
        Ok(false)
    }

    fn open_context_menu(&mut self, x: u16, y: u16) {
        self.menu = None;
        if let Some(SidebarRow::Workspace { id, .. }) = self.sidebar_hit_at(x, y) {
            self.menu = Some(ContextMenu::at(
                x,
                y,
                vec![MenuAction::RenameWorkspace(id), MenuAction::CloseWorkspace(id)],
            ));
            return;
        }
        if let Some(area) = self.pane_area_at(x, y) {
            self.menu = Some(ContextMenu::at(
                x,
                y,
                vec![
                    MenuAction::RenamePane(area.pane),
                    MenuAction::NewTab(area.pane),
                    MenuAction::SplitRight(area.pane),
                    MenuAction::SplitDown(area.pane),
                    MenuAction::ClosePane(area.pane),
                ],
            ));
        }
    }

    fn handle_scroll(&mut self, x: u16, y: u16, down: bool) -> anyhow::Result<bool> {
        let Some(area) = self.pane_area_at(x, y) else { return Ok(false) };
        let Some(surface) = self.session.surface(area.surface) else { return Ok(false) };
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
        Ok(true)
    }
}
