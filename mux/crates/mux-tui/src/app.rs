//! TUI event loop and tmux-like command handling.
//!
//! Runs against a [`Session`], which is either the in-process mux or a
//! remote session attached over the control socket. All state mutations
//! go through the session; the app only owns presentation state (render
//! snapshots, prefix arming, the current layout).

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
use mux_core::{layout_tab, LayoutResult, MuxEvent, PaneId, Rect, SplitDir};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal as RatatuiTerminal;

use crate::keys;
use crate::session::{Session, TreeView};

pub enum AppEvent {
    Mux(MuxEvent),
    Input(Event),
}

pub struct App {
    pub session: Session,
    pub tree: TreeView,
    pub render_states: HashMap<PaneId, RenderState>,
    pub layout: LayoutResult,
    pub prefix_armed: bool,
    pub session_label: String,
    encoder: KeyEncoder,
    encode_buf: Vec<u8>,
    quit: bool,
}

pub fn run(session: Session, session_label: String) -> anyhow::Result<()> {
    // First workspace/tab/pane before the terminal switches modes, so a
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
        move || loop {
            match crossterm::event::read() {
                Ok(event) => {
                    if tx.send(AppEvent::Input(event)).is_err() {
                        break;
                    }
                }
                Err(_) => break,
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
        layout: LayoutResult::default(),
        prefix_armed: false,
        session_label,
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

    /// Refresh the tree snapshot, recompute the active tab's layout, and
    /// push sizes to its panes.
    fn sync_layout(&mut self, size: (u16, u16)) {
        let (width, height) = size;
        let area = Rect {
            x: 0,
            y: 0,
            width,
            height: height.saturating_sub(1), // status bar
        };
        self.tree = self.session.tree();
        self.layout = self
            .tree
            .active_tab()
            .map(|tab| layout_tab(&tab.layout, area))
            .unwrap_or_default();
        for (pane_id, rect) in self.layout.panes.clone() {
            if rect.width == 0 || rect.height == 0 {
                continue;
            }
            if let Some(pane) = self.session.pane(pane_id) {
                pane.resize(rect.width, rect.height);
            }
        }
    }

    fn handle(&mut self, event: AppEvent) -> anyhow::Result<bool> {
        match event {
            AppEvent::Mux(MuxEvent::Empty) => {
                self.quit = true;
                Ok(false)
            }
            AppEvent::Mux(MuxEvent::PaneExited(id)) => {
                self.render_states.remove(&id);
                self.session.reap_pane(id);
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
        self.tree.active_tab().map(|tab| tab.active_pane)
    }

    fn handle_key(&mut self, key: KeyEvent) -> anyhow::Result<bool> {
        if key.kind == KeyEventKind::Release {
            return Ok(false);
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

    fn handle_prefixed(&mut self, key: KeyEvent) -> anyhow::Result<bool> {
        let active = self.active_pane();
        match (key.code, key.modifiers) {
            // Prefix-Ctrl-b: forward a literal Ctrl-b.
            (KeyCode::Char('b'), m) if m.contains(KeyModifiers::CONTROL) => {
                self.forward_key(&key);
                Ok(true)
            }
            (KeyCode::Char('c'), _) => {
                self.session.new_tab()?;
                Ok(true)
            }
            (KeyCode::Char('%'), _) => {
                if let Some(active) = active {
                    self.session.split(active, SplitDir::Right)?;
                }
                Ok(true)
            }
            (KeyCode::Char('"'), _) => {
                if let Some(active) = active {
                    self.session.split(active, SplitDir::Down)?;
                }
                Ok(true)
            }
            (KeyCode::Char('x'), _) => {
                if let Some(active) = active {
                    self.render_states.remove(&active);
                    self.session.close_pane(active);
                }
                Ok(true)
            }
            (KeyCode::Char('n'), _) => {
                self.session.select_tab(None, Some(1));
                Ok(true)
            }
            (KeyCode::Char('p'), _) => {
                self.session.select_tab(None, Some(-1));
                Ok(true)
            }
            (KeyCode::Char(c @ '1'..='9'), _) => {
                self.session.select_tab(Some(c as usize - '1' as usize), None);
                Ok(true)
            }
            (KeyCode::Char('w'), m) if !m.contains(KeyModifiers::SHIFT) => {
                self.session.select_workspace(1);
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

    fn move_focus(&self, dx: i32, dy: i32) {
        if let Some(active) = self.active_pane() {
            if let Some(next) = self.layout.neighbor(active, dx, dy) {
                self.session.focus_pane(next);
            }
        }
    }

    fn scroll_active(&self, delta: isize) {
        if let Some(pane) = self.active_pane().and_then(|id| self.session.pane(id)) {
            pane.with_terminal(|t| t.scroll_delta(delta));
        }
    }

    fn forward_key(&mut self, key: &KeyEvent) {
        let Some(input) = keys::key_input_from(key) else { return };
        let Some(pane) = self.active_pane().and_then(|id| self.session.pane(id)) else {
            return;
        };
        self.encode_buf.clear();
        let encoded = pane.with_terminal(|term| {
            // New input snaps the viewport back to the live screen.
            term.scroll_to_bottom();
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        });
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            pane.write_bytes(&self.encode_buf);
        }
    }

    fn paste(&mut self, text: &str) {
        let Some(pane) = self.active_pane().and_then(|id| self.session.pane(id)) else {
            return;
        };
        let bracketed = pane.with_terminal(|t| t.mode(2004, false));
        if bracketed {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            pane.write_bytes(&bytes);
        } else {
            pane.write_bytes(text.as_bytes());
        }
    }

    fn handle_mouse(&mut self, mouse: MouseEvent) -> anyhow::Result<bool> {
        match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(pane) = self.layout.pane_at(mouse.column, mouse.row) {
                    self.session.focus_pane(pane);
                    return Ok(true);
                }
                Ok(false)
            }
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                let down = matches!(mouse.kind, MouseEventKind::ScrollDown);
                let Some(pane_id) = self.layout.pane_at(mouse.column, mouse.row) else {
                    return Ok(false);
                };
                let Some(pane) = self.session.pane(pane_id) else { return Ok(false) };
                let sent_arrows = pane.with_terminal(|term| {
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
                    pane.write_bytes(seq);
                }
                Ok(true)
            }
            _ => Ok(false),
        }
    }
}
