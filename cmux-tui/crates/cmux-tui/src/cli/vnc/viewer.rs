//! The viewer: the remote screen in this terminal pane through the Kitty
//! graphics protocol, the person's keys and mouse sent back, the remote
//! desktop resized to the pane when the server allows it, and a reconnect
//! with backoff when the connection drops.
//!
//! Threads: one reads terminal events; one per connection runs
//! [`Session::next_event`] and scales each update to the pane; the main
//! thread owns the terminal and every decision. They meet on one channel,
//! and frames coalesce: a frame the main thread has not drawn yet is
//! replaced, never queued.

use std::io::{self, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_vnc::message::button;
use cmux_vnc::{Backoff, Cursor, Event, Input, Session, SessionOptions, VncError};
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use crossterm::event::{
    self as term, DisableBracketedPaste, DisableFocusChange, DisableMouseCapture,
    EnableBracketedPaste, EnableFocusChange, EnableMouseCapture, KeyboardEnhancementFlags,
    MouseButton, MouseEventKind, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::{cursor, execute, queue, terminal};

use super::keys::{Command, KeyAction, Keyboard};
use super::layout::{Pane, Placement, scale_rgb};
use super::{Config, ResizeMode, kitty, printable};

/// Image id of the cursor overlay.
const CURSOR_ID: u32 = 0x5643_0003;
/// A pane resize settles this long before the remote desktop follows it.
const RESIZE_SETTLE: Duration = Duration::from_millis(300);
/// Longest wait on quit or reconnect for queued key and button releases to reach the server.
const RELEASE_FLUSH: Duration = Duration::from_millis(500);
/// Most characters a paste types into the remote screen.
const MAX_PASTE_CHARS: usize = 64 * 1024;

enum Msg {
    Term(term::Event),
    Net(u64, Net),
}

enum Net {
    Connected(Input, String),
    /// A scaled frame is waiting in [`Canvas`].
    Frame,
    Info(Info),
    Bell,
    Clipboard(String),
    Ended(VncError, Duration),
}

/// What the main thread needs to know about the remote desktop.
#[derive(Clone)]
struct Info {
    width: u16,
    height: u16,
    resize_supported: bool,
    screen_id: u32,
    resize_refused: bool,
    cursor: Option<Cursor>,
    name: Option<String>,
}

/// The picture the reader thread scaled for the main thread.
struct Canvas {
    pane: Pane,
    frame: Option<(Vec<u8>, Placement)>,
}

enum State {
    Connecting,
    Connected { input: Input },
    Waiting { until: Instant, reason: String },
    Stopped(String),
}

pub(super) fn run(config: Config, first: Session) -> io::Result<()> {
    let (tx, rx) = crossbeam_channel::unbounded();
    let mut terminal_guard = TerminalGuard::enter()?;
    let enhanced = terminal::supports_keyboard_enhancement().unwrap_or(false);
    if enhanced {
        // Alternate keys: Shift-1 reports its shifted `!`, which is the keysym.
        execute!(
            io::stdout(),
            PushKeyboardEnhancementFlags(
                KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
                    | KeyboardEnhancementFlags::REPORT_EVENT_TYPES
                    | KeyboardEnhancementFlags::REPORT_ALTERNATE_KEYS
                    | KeyboardEnhancementFlags::REPORT_ALL_KEYS_AS_ESCAPE_CODES
            )
        )?;
        terminal_guard.keyboard_flags = true;
    }
    let pixel_mouse = config.pixel_mouse.unwrap_or_else(terminal_reports_pixels);
    if pixel_mouse {
        // SGR-Pixels (1016): mouse reports in pixels, so a pointer lands on
        // the remote pixel, not a whole cell.
        terminal_guard.pixel_mouse = true;
        io::stdout().write_all(b"\x1b[?1016h")?;
    }
    let input_tx = tx.clone();
    thread::Builder::new().name("vnc-terminal-input".into()).spawn(move || {
        while let Ok(event) = term::read() {
            if input_tx.send(Msg::Term(event)).is_err() {
                return;
            }
        }
    })?;

    let mut viewer = Viewer {
        canvas: Arc::new(Mutex::new(Canvas { pane: current_pane(), frame: None })),
        config,
        tx,
        generation: Arc::new(AtomicU64::new(0)),
        state: State::Connecting,
        backoff: Backoff::default(),
        keyboard: Keyboard::new(enhanced),
        buttons: 0,
        pointer: (0, 0),
        info: None,
        placement: None,
        image: 0,
        shown: None,
        cursor_shown: false,
        resize_at: None,
        resize_sent: None,
        last_render: None,
        frame_waiting: false,
        name: String::new(),
        pixel_mouse,
        out: io::stdout(),
    };
    viewer.adopt(first);
    let result = viewer.run(&rx);
    viewer.release_input();
    if let State::Connected { input, .. } = &viewer.state {
        input.close_after_pending(RELEASE_FLUSH);
    }
    // The guard deletes the images and restores every terminal mode,
    // here and on any error or panic.
    drop(terminal_guard);
    result
}

struct Viewer {
    config: Config,
    canvas: Arc<Mutex<Canvas>>,
    tx: Sender<Msg>,
    /// The live connection's number, shared with the reader threads: a
    /// thread whose number is no longer current closes its connection.
    generation: Arc<AtomicU64>,
    state: State,
    backoff: Backoff,
    keyboard: Keyboard,
    buttons: u8,
    /// The pointer in remote pixels.
    pointer: (u16, u16),
    info: Option<Info>,
    placement: Option<Placement>,
    /// Index into [`kitty::IMAGE_IDS`] of the next frame.
    image: usize,
    /// The image id on screen.
    shown: Option<u32>,
    cursor_shown: bool,
    resize_at: Option<Instant>,
    /// The size last asked of the server, not asked again.
    resize_sent: Option<(u16, u16)>,
    last_render: Option<Instant>,
    frame_waiting: bool,
    name: String,
    pixel_mouse: bool,
    out: io::Stdout,
}

impl Viewer {
    fn run(&mut self, rx: &Receiver<Msg>) -> io::Result<()> {
        self.draw_status()?;
        loop {
            let deadline = self.next_deadline();
            let msg = match deadline {
                Some(at) => match rx.recv_deadline(at) {
                    Ok(msg) => Some(msg),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return Ok(()),
                },
                None => match rx.recv() {
                    Ok(msg) => Some(msg),
                    Err(_) => return Ok(()),
                },
            };
            if let Some(msg) = msg
                && self.handle(msg)?
            {
                return Ok(());
            }
            self.fire_timers()?;
        }
    }

    fn frame_interval(&self) -> Duration {
        Duration::from_secs(1) / self.config.fps.max(1)
    }

    fn next_deadline(&self) -> Option<Instant> {
        let mut deadlines = Vec::new();
        if let State::Waiting { until, .. } = self.state {
            deadlines.push(until);
        }
        if let Some(at) = self.resize_at {
            deadlines.push(at);
        }
        if self.frame_waiting
            && let Some(last) = self.last_render
        {
            deadlines.push(last + self.frame_interval());
        }
        deadlines.into_iter().min()
    }

    fn fire_timers(&mut self) -> io::Result<()> {
        let now = Instant::now();
        if let State::Waiting { until, .. } = self.state
            && now >= until
        {
            self.connect();
            self.draw_status()?;
        }
        if self.resize_at.is_some_and(|at| now >= at) {
            self.resize_at = None;
            self.send_remote_resize();
        }
        if self.frame_waiting
            && self.last_render.is_none_or(|last| now >= last + self.frame_interval())
        {
            self.render()?;
        }
        Ok(())
    }

    /// Handles one message; `true` ends the viewer.
    fn handle(&mut self, msg: Msg) -> io::Result<bool> {
        match msg {
            Msg::Term(event) => return self.terminal_event(event),
            Msg::Net(generation, _) if generation != self.current_generation() => {}
            Msg::Net(_, net) => match net {
                Net::Connected(input, name) => {
                    // The backoff resets only when this session lives long enough.
                    self.name = name;
                    self.state = State::Connected { input };
                    self.info = None;
                    self.resize_sent = None;
                    self.draw_status()?;
                }
                Net::Frame => self.frame_waiting = true,
                Net::Info(info) => self.update_info(info)?,
                Net::Bell => self.out.write_all(b"\x07")?,
                Net::Clipboard(_) if !self.config.remote_clipboard => {}
                Net::Clipboard(text) => {
                    // OSC 52: the remote clipboard becomes the local one (opted in).
                    let encoded = base64::engine::general_purpose::STANDARD.encode(text);
                    write!(self.out, "\x1b]52;c;{encoded}\x07")?;
                    self.out.flush()?;
                }
                Net::Ended(error, lived) => self.ended(error, lived)?,
            },
        }
        Ok(false)
    }

    fn ended(&mut self, error: VncError, lived: Duration) -> io::Result<()> {
        self.keyboard.release_all();
        self.buttons = 0;
        if !self.config.reconnect {
            self.state = State::Stopped(format!("{error}"));
        } else {
            match self.backoff.after_failure(lived, &error) {
                Some(delay) => {
                    self.state =
                        State::Waiting { until: Instant::now() + delay, reason: format!("{error}") }
                }
                None => self.state = State::Stopped(format!("{error}")),
            }
        }
        self.draw_status()
    }

    fn update_info(&mut self, info: Info) -> io::Result<()> {
        if let Some(name) = &info.name {
            self.name.clone_from(name);
        }
        let cursor_changed = info.cursor.is_some();
        let mut merged = info;
        if let Some(previous) = &self.info
            && merged.cursor.is_none()
        {
            merged.cursor.clone_from(&previous.cursor);
        }
        let size_changed = self
            .info
            .as_ref()
            .is_none_or(|old| (old.width, old.height) != (merged.width, merged.height));
        let refused_before = self.info.as_ref().is_some_and(|old| old.resize_refused);
        merged.resize_refused |= refused_before;
        self.info = Some(merged);
        if size_changed {
            self.schedule_remote_resize(false);
        }
        if cursor_changed {
            self.cursor_shown = false;
            self.draw_cursor()?;
        }
        if size_changed {
            self.draw_status()?;
        }
        Ok(())
    }

    /// Starts a new connection on its own thread; it becomes that
    /// connection's reader.
    fn current_generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    fn connect(&mut self) {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        self.state = State::Connecting;
        let current = self.generation.clone();
        let config = self.config.clone();
        let tx = self.tx.clone();
        let canvas = self.canvas.clone();
        let started = Instant::now();
        let spawned = thread::Builder::new().name("vnc-session".into()).spawn(move || {
            let options = SessionOptions {
                credentials: config.credentials.clone(),
                ..SessionOptions::default()
            };
            match super::open(&config.target, &options) {
                Ok(session) => read_loop(session, generation, &current, &tx, &canvas, started),
                Err(error) => {
                    let _ = tx.send(Msg::Net(generation, Net::Ended(error, started.elapsed())));
                }
            }
        });
        if let Err(error) = spawned {
            self.state = State::Stopped(format!("cannot start the connection thread: {error}"));
        }
    }

    /// Runs the first, already connected session.
    fn adopt(&mut self, session: Session) {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let current = self.generation.clone();
        self.name = session.name().to_owned();
        self.state = State::Connected { input: session.input() };
        let tx = self.tx.clone();
        let canvas = self.canvas.clone();
        let started = Instant::now();
        let spawned = thread::Builder::new()
            .name("vnc-session".into())
            .spawn(move || read_loop(session, generation, &current, &tx, &canvas, started));
        if let Err(error) = spawned {
            self.state = State::Stopped(format!("cannot start the connection thread: {error}"));
        }
    }

    fn input(&self) -> Option<&Input> {
        match &self.state {
            State::Connected { input, .. } => Some(input),
            _ => None,
        }
    }

    /// Sends input unless view only; a failed send ends with the reader's error.
    fn send_keys(&self, keys: &[(u32, bool)]) {
        if self.config.view_only {
            return;
        }
        if let Some(input) = self.input() {
            let _ = input.keys(keys);
        }
    }

    fn release_input(&mut self) {
        let keys = self.keyboard.release_all();
        self.send_keys(&keys);
        if self.buttons != 0 {
            self.buttons = 0;
            if let Some(input) = self.input()
                && !self.config.view_only
            {
                let _ = input.pointer(self.pointer.0, self.pointer.1, 0);
            }
        }
    }

    fn terminal_event(&mut self, event: term::Event) -> io::Result<bool> {
        match event {
            term::Event::Key(key) => return self.key(&key, None),
            term::Event::EnhancedKey(enhanced) => {
                return self.key(&enhanced.key_event, enhanced.shifted_key);
            }
            term::Event::Mouse(mouse) => self.mouse(mouse)?,
            term::Event::Paste(text) => self.paste(&text),
            term::Event::Resize(..) => self.pane_resized()?,
            term::Event::FocusLost => self.release_input(),
            term::Event::FocusGained => {}
        }
        Ok(false)
    }

    fn key(&mut self, key: &term::KeyEvent, shifted: Option<char>) -> io::Result<bool> {
        match self.keyboard.handle(key, shifted) {
            KeyAction::Send(keys) => self.send_keys(&keys),
            KeyAction::AwaitCommand => self.draw_status_text(
                "Ctrl-] then: q quit · r reconnect · v view only · f refresh · Ctrl-] send Ctrl-]",
            )?,
            KeyAction::Command(command) => {
                match command {
                    Command::Quit => return Ok(true),
                    Command::Reconnect => {
                        self.release_input();
                        if let State::Connected { input, .. } = &self.state {
                            input.close_after_pending(RELEASE_FLUSH);
                        }
                        self.backoff.reset();
                        self.connect();
                    }
                    Command::ToggleViewOnly => {
                        self.release_input();
                        self.config.view_only = !self.config.view_only;
                    }
                    Command::Refresh => self.request_refresh(),
                    Command::SendEscape => self.send_keys(&[
                        (0xFFE3, true),
                        (0x5D, true),
                        (0x5D, false),
                        (0xFFE3, false),
                    ]),
                    Command::Cancel => {}
                }
                self.draw_status()?;
            }
            KeyAction::None => {}
        }
        Ok(false)
    }

    fn mouse(&mut self, mouse: term::MouseEvent) -> io::Result<()> {
        let Some(placement) = self.placement else { return Ok(()) };
        let pane = self.pane();
        let (x, y) = if self.pixel_mouse {
            (u32::from(mouse.column), u32::from(mouse.row))
        } else {
            if mouse.row >= pane.rows - 1 {
                return Ok(());
            }
            (
                u32::from(mouse.column) * pane.cell_w + pane.cell_w / 2,
                u32::from(mouse.row) * pane.cell_h + pane.cell_h / 2,
            )
        };
        self.pointer = placement.remote_point(x, y);
        let bit = |b: MouseButton| match b {
            MouseButton::Left => button::LEFT,
            MouseButton::Middle => button::MIDDLE,
            MouseButton::Right => button::RIGHT,
        };
        let wheel = match mouse.kind {
            MouseEventKind::Down(b) => {
                self.buttons |= bit(b);
                None
            }
            MouseEventKind::Up(b) => {
                self.buttons &= !bit(b);
                None
            }
            MouseEventKind::ScrollUp => Some(button::WHEEL_UP),
            MouseEventKind::ScrollDown => Some(button::WHEEL_DOWN),
            MouseEventKind::ScrollLeft => Some(button::WHEEL_LEFT),
            MouseEventKind::ScrollRight => Some(button::WHEEL_RIGHT),
            MouseEventKind::Drag(_) | MouseEventKind::Moved => None,
        };
        if !self.config.view_only
            && let Some(input) = self.input()
        {
            let (px, py) = self.pointer;
            // A failed send surfaces as the reader's error.
            let _ = match wheel {
                Some(wheel) => input
                    .pointer(px, py, self.buttons | wheel)
                    .and_then(|()| input.pointer(px, py, self.buttons)),
                None => input.pointer(px, py, self.buttons),
            };
        }
        self.draw_cursor()
    }

    /// A paste types its text into the remote screen and sets the remote clipboard.
    fn paste(&mut self, text: &str) {
        if self.config.view_only {
            return;
        }
        let Some(input) = self.input() else { return };
        let _ = input.clipboard(text);
        let keys: Vec<(u32, bool)> = text
            .chars()
            .filter(|&c| c != '\r')
            .take(MAX_PASTE_CHARS)
            .map(cmux_vnc::keysym::char_keysym)
            .flat_map(|sym| [(sym, true), (sym, false)])
            .collect();
        // One write: a slow server holds the writer thread, not this one.
        let _ = input.keys(&keys);
    }

    fn pane(&self) -> Pane {
        self.canvas.lock().map(|canvas| canvas.pane).unwrap_or_else(|_| current_pane())
    }

    fn pane_resized(&mut self) -> io::Result<()> {
        let pane = current_pane();
        if let Ok(mut canvas) = self.canvas.lock() {
            canvas.pane = pane;
            canvas.frame = None;
        }
        self.clear_images()?;
        queue!(self.out, terminal::Clear(terminal::ClearType::All))?;
        self.request_refresh();
        self.schedule_remote_resize(true);
        self.draw_status()
    }

    /// Asks for a full frame, which the reader scales to the current pane.
    fn request_refresh(&self) {
        if let (Some(input), Some(info)) = (self.input(), &self.info) {
            let _ = input.refresh(info.width, info.height);
        }
    }

    fn remote_resize_target(&self) -> Option<(u16, u16, u32)> {
        let info = self.info.as_ref()?;
        let wanted = match self.config.resize {
            ResizeMode::Scale => false,
            ResizeMode::Remote | ResizeMode::Auto => info.resize_supported && !info.resize_refused,
        };
        if !wanted {
            return None;
        }
        let (w, h) = self.pane().area();
        let (w, h) = (w.clamp(64, 8192) as u16, h.clamp(64, 8192) as u16);
        ((w, h) != (info.width, info.height) && self.resize_sent != Some((w, h))).then_some((
            w,
            h,
            info.screen_id,
        ))
    }

    fn schedule_remote_resize(&mut self, settle: bool) {
        if self.remote_resize_target().is_some() {
            self.resize_at =
                Some(Instant::now() + if settle { RESIZE_SETTLE } else { Duration::ZERO });
        }
    }

    /// Asks the server once per target size; its answer arrives as an update.
    fn send_remote_resize(&mut self) {
        if let (Some((w, h, screen)), Some(input)) = (self.remote_resize_target(), self.input()) {
            let _ = input.resize(w, h, screen);
            self.resize_sent = Some((w, h));
        }
    }

    fn render(&mut self) -> io::Result<()> {
        self.frame_waiting = false;
        let taken = self
            .canvas
            .lock()
            .ok()
            .and_then(|mut canvas| canvas.frame.take().map(|f| (f, canvas.pane)));
        let Some(((rgb, placement), pane)) = taken else { return Ok(()) };
        self.last_render = Some(Instant::now());
        let moved = self.placement != Some(placement);
        if moved && self.shown.is_some() {
            queue!(self.out, terminal::Clear(terminal::ClearType::All))?;
        }
        self.placement = Some(placement);
        let (col, row, x_off, y_off) = placement.anchor(&pane);
        let id = *kitty::IMAGE_IDS
            .get(self.image)
            .ok_or_else(|| io::Error::other("invalid VNC image index"))?;
        self.image = 1 - self.image;
        kitty::frame(
            &mut self.out,
            &rgb,
            placement.width,
            placement.height,
            col,
            row,
            x_off,
            y_off,
            id,
            self.shown,
        )?;
        self.shown = Some(id);
        if moved {
            self.cursor_shown = false;
            self.draw_status()?;
        }
        self.draw_cursor()
    }

    /// Places the remote cursor shape over the picture at the pointer,
    /// as its own small image above the frame.
    fn draw_cursor(&mut self) -> io::Result<()> {
        let (Some(placement), Some(cursor)) =
            (self.placement, self.info.as_ref().and_then(|info| info.cursor.clone()))
        else {
            return Ok(());
        };
        let pane = self.pane();
        if cursor.width == 0 || cursor.height == 0 {
            if self.cursor_shown {
                kitty::delete(&mut self.out, CURSOR_ID)?;
                self.cursor_shown = false;
            }
            return self.out.flush();
        }
        let scale = f64::from(placement.width) / f64::from(placement.remote_w);
        let w = ((f64::from(cursor.width) * scale).ceil() as u32).max(1);
        let h = ((f64::from(cursor.height) * scale).ceil() as u32).max(1);
        let px = placement.left + (f64::from(self.pointer.0) * scale) as u32;
        let py = placement.top + (f64::from(self.pointer.1) * scale) as u32;
        let left = px.saturating_sub((f64::from(cursor.hotspot_x) * scale) as u32);
        let top = py.saturating_sub((f64::from(cursor.hotspot_y) * scale) as u32);
        let (col, row) = ((left / pane.cell_w) as u16, (top / pane.cell_h) as u16);
        if row >= pane.rows - 1 {
            return Ok(());
        }
        let (x_off, y_off) = (left % pane.cell_w, top % pane.cell_h);
        write!(self.out, "\x1b7\x1b[{};{}H", row + 1, col + 1)?;
        if self.cursor_shown {
            write!(self.out, "\x1b_Ga=p,i={CURSOR_ID},p=1,X={x_off},Y={y_off},z=1,C=1,q=2\x1b\\")?;
        } else {
            let mut rgba = vec![0u8; (w * h * 4) as usize];
            for (index, pixel) in rgba.chunks_exact_mut(4).enumerate() {
                let (x, y) = (index as u32 % w, index as u32 / w);
                let sx = ((f64::from(x) / scale) as u32).min(u32::from(cursor.width) - 1);
                let sy = ((f64::from(y) / scale) as u32).min(u32::from(cursor.height) - 1);
                let from = ((sy * u32::from(cursor.width) + sx) * 4) as usize;
                let source = cursor
                    .rgba
                    .get(from..from + 4)
                    .ok_or_else(|| io::Error::other("invalid VNC cursor pixels"))?;
                pixel.copy_from_slice(source);
            }
            let encoded = base64::engine::general_purpose::STANDARD.encode(&rgba);
            write!(
                self.out,
                "\x1b_Ga=T,f=32,s={w},v={h},i={CURSOR_ID},p=1,X={x_off},Y={y_off},z=1,C=1,q=2;{encoded}\x1b\\"
            )?;
            self.cursor_shown = true;
        }
        write!(self.out, "\x1b8")?;
        self.out.flush()
    }

    fn clear_images(&mut self) -> io::Result<()> {
        for id in kitty::IMAGE_IDS.into_iter().chain([CURSOR_ID]) {
            kitty::delete(&mut self.out, id)?;
        }
        self.shown = None;
        self.cursor_shown = false;
        self.placement = None;
        self.out.flush()
    }

    fn status_text(&self) -> String {
        let target = &self.config.label;
        let mode = if self.config.view_only { " · view only" } else { "" };
        let state = match &self.state {
            State::Connecting => format!("Connecting to {target}…"),
            State::Connected { .. } => {
                let size = self
                    .info
                    .as_ref()
                    .map(|info| {
                        let scale =
                            self.placement.map_or(100, |p| p.width * 100 / p.remote_w.max(1));
                        if scale == 100 {
                            format!(" · {}×{}", info.width, info.height)
                        } else {
                            format!(" · {}×{} at {scale}%", info.width, info.height)
                        }
                    })
                    .unwrap_or_default();
                let name = if self.name.is_empty() { target.clone() } else { self.name.clone() };
                format!("{name}{size}")
            }
            State::Waiting { until, reason } => {
                let left = until.saturating_duration_since(Instant::now()).as_secs_f32();
                format!("{reason} · reconnecting in {left:.1}s")
            }
            State::Stopped(reason) => format!("{reason} · Ctrl-] r to retry"),
        };
        format!("{state}{mode} · Ctrl-] q quit")
    }

    fn draw_status(&mut self) -> io::Result<()> {
        let text = self.status_text();
        self.draw_status_text(&text)
    }

    fn draw_status_text(&mut self, text: &str) -> io::Result<()> {
        let pane = self.pane();
        let text: String = printable(text).chars().take(usize::from(pane.cols)).collect();
        write!(self.out, "\x1b7\x1b[{};1H\x1b[2K\x1b[7m{text}\x1b[0m\x1b8", pane.rows)?;
        self.out.flush()
    }
}

/// The reader thread of one connection: decodes, scales into the canvas,
/// tells the main thread, and reports the end.
fn read_loop(
    mut session: Session,
    generation: u64,
    current: &AtomicU64,
    tx: &Sender<Msg>,
    canvas: &Mutex<Canvas>,
    started: Instant,
) {
    // A connection the viewer replaced (Ctrl-] r while it was opening) closes
    // itself instead of decoding into the shared canvas.
    let live = || current.load(Ordering::SeqCst) == generation;
    let send = |net: Net| live() && tx.send(Msg::Net(generation, net)).is_ok();
    if !send(Net::Connected(session.input(), session.name().to_owned())) {
        session.input().close();
        return;
    }
    loop {
        let event = match session.next_event() {
            Ok(event) => event,
            Err(error) => {
                session.input().close();
                let _ = send(Net::Ended(error, started.elapsed()));
                return;
            }
        };
        let ok = match event {
            Event::Bell => send(Net::Bell),
            Event::Clipboard(text) => send(Net::Clipboard(text)),
            Event::Update(update) => {
                let fb = session.framebuffer();
                let info = Info {
                    width: fb.width(),
                    height: fb.height(),
                    resize_supported: session.resize_supported(),
                    screen_id: session.screens().first().map_or(0, |screen| screen.id),
                    resize_refused: update.resize_refused.is_some(),
                    cursor: update.cursor,
                    name: update.name,
                };
                let info_ok = send(Net::Info(info));
                let mut ok = info_ok;
                if !update.damage.is_empty() || update.resized {
                    let pane = canvas.lock().map(|c| c.pane).ok();
                    if let Some(pane) = pane {
                        let placement = Placement::fit(&pane, fb.width(), fb.height());
                        let rgb = match scale_rgb(
                            fb.pixels(),
                            u32::from(fb.width()),
                            u32::from(fb.height()),
                            placement.width,
                            placement.height,
                        ) {
                            Ok(rgb) => rgb,
                            Err(error) => {
                                session.input().close();
                                let _ = send(Net::Ended(error, started.elapsed()));
                                return;
                            }
                        };
                        let was_waiting = canvas
                            .lock()
                            .map(|mut c| {
                                let waiting = c.frame.is_some();
                                if c.pane == pane && live() {
                                    c.frame = Some((rgb, placement));
                                }
                                waiting
                            })
                            .unwrap_or(true);
                        if !was_waiting {
                            ok &= send(Net::Frame);
                        }
                    }
                }
                ok
            }
        };
        if !ok {
            session.input().close();
            return;
        }
    }
}

fn current_pane() -> Pane {
    match terminal::window_size() {
        Ok(size) => Pane::new(size.columns, size.rows, size.width, size.height),
        Err(_) => {
            let (cols, rows) = terminal::size().unwrap_or((80, 24));
            Pane::new(cols, rows, 0, 0)
        }
    }
}

/// Terminals known to report SGR-Pixels mouse positions (cmux's terminals are Ghostty).
fn terminal_reports_pixels() -> bool {
    matches!(std::env::var("TERM_PROGRAM").as_deref(), Ok("ghostty" | "WezTerm"))
        || std::env::var_os("KITTY_WINDOW_ID").is_some()
}

/// Raw mode, the alternate screen, mouse, focus and paste reporting, and
/// (once set) the keyboard flags and pixel mouse, all undone on drop, with
/// the images deleted: on a normal exit, an error and a panic alike.
struct TerminalGuard {
    keyboard_flags: bool,
    pixel_mouse: bool,
}

impl TerminalGuard {
    fn enter() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        let guard = Self { keyboard_flags: false, pixel_mouse: false };
        execute!(
            io::stdout(),
            terminal::EnterAlternateScreen,
            cursor::Hide,
            EnableMouseCapture,
            EnableFocusChange,
            EnableBracketedPaste,
            terminal::Clear(terminal::ClearType::All)
        )?;
        Ok(guard)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let mut out = io::stdout();
        for id in kitty::IMAGE_IDS.into_iter().chain([CURSOR_ID]) {
            let _ = kitty::delete(&mut out, id);
        }
        if self.keyboard_flags {
            let _ = execute!(out, PopKeyboardEnhancementFlags);
        }
        if self.pixel_mouse {
            let _ = out.write_all(b"\x1b[?1016l");
        }
        let _ = execute!(
            io::stdout(),
            DisableBracketedPaste,
            DisableFocusChange,
            DisableMouseCapture,
            cursor::Show,
            terminal::LeaveAlternateScreen
        );
        let _ = terminal::disable_raw_mode();
    }
}
