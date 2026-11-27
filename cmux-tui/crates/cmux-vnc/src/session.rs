//! A running RFB session: the reading half ([`Session`], one thread) and
//! the writing half ([`Input`], cloneable, any thread). Input never blocks
//! its caller: messages go through a bounded queue to a writer thread. Callers
//! backpressure their input source when the queue fills; accepted input stays ordered.

use std::collections::VecDeque;
use std::io::{self, BufReader, Read, Write};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Condvar, Mutex, PoisonError};
use std::thread;
use std::time::Duration;

use crate::auth::Credentials;
use crate::decode::{self, Cursor, Decoders, encoding};
use crate::error::{Result, VncError};
use crate::framebuffer::{Framebuffer, Rect};
use crate::handshake::{ServerInit, handshake};
use crate::message::{self, Screen};
use crate::pixel::PixelFormat;
use crate::transport::{Closer, Transport};
use crate::wire::{MAX_TEXT_BYTES, WireReader, latin1, to_latin1};

/// Resident input operations. Admission backpressures the source, never the UI.
/// A paste owns its source string and occupies one operation.
const WRITE_QUEUE: usize = 1024;
/// Longest a graceful close waits for a proxy command to forward the last input.
const DRAIN_LIMIT: Duration = Duration::from_millis(400);

/// How to open a session.
#[derive(Debug, Clone)]
pub struct SessionOptions {
    pub credentials: Credentials,
    /// Keep other viewers connected (ClientInit's shared flag).
    pub shared: bool,
    /// Ask the server to send the cursor shape for the client to draw.
    pub local_cursor: bool,
}

impl Default for SessionOptions {
    fn default() -> Self {
        Self { credentials: Credentials::default(), shared: true, local_cursor: true }
    }
}

/// What one server message changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Update(Update),
    Bell,
    /// ServerCutText: the remote clipboard.
    Clipboard(String),
}

/// The outcome of one FramebufferUpdate.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Update {
    /// The area whose pixels changed (empty when only pseudo-rectangles came).
    pub damage: Rect,
    /// The framebuffer changed size (DesktopSize or ExtendedDesktopSize).
    pub resized: bool,
    /// A new cursor shape; an empty one hides the cursor.
    pub cursor: Option<Cursor>,
    /// A new desktop name.
    pub name: Option<String>,
    /// The server refused this client's SetDesktopSize, with its status code.
    pub resize_refused: Option<u32>,
}

/// The reading half: owns the framebuffer and decodes server messages.
pub struct Session {
    reader: WireReader<BufReader<Box<dyn Read + Send>>>,
    input: Input,
    framebuffer: Framebuffer,
    format: PixelFormat,
    decoders: Decoders,
    init: ServerInit,
    name: String,
    screens: Vec<Screen>,
    resize_supported: bool,
}

impl Session {
    /// Handshakes over `transport`, switches the server to RGBX pixels and
    /// the advertised encodings, and asks for the first full frame.
    pub fn start(transport: Transport, options: &SessionOptions) -> Result<Self> {
        let Transport { reader, mut writer, closer } = transport;
        let mut reader = WireReader::new(BufReader::with_capacity(64 * 1024, reader));
        let init = match handshake(&mut reader, &mut writer, &options.credentials, options.shared) {
            Ok(init) => init,
            Err(error) => {
                closer.close();
                return Err(error);
            }
        };
        let framebuffer = match Framebuffer::new(init.width, init.height) {
            Ok(framebuffer) => framebuffer,
            Err(error) => {
                closer.close();
                return Err(error);
            }
        };
        let input = Input::spawn(writer, closer)?;
        let format = PixelFormat::RGBX;
        input.send(&message::set_pixel_format(&format))?;
        input.send(&message::set_encodings(&encoding::advertised(options.local_cursor)))?;
        input.send(&message::update_request(false, &Rect::new(0, 0, init.width, init.height)))?;
        Ok(Self {
            reader,
            input,
            framebuffer,
            format,
            decoders: Decoders::default(),
            name: init.name.clone(),
            init,
            screens: Vec::new(),
            resize_supported: false,
        })
    }

    /// The writing half.
    pub fn input(&self) -> Input {
        self.input.clone()
    }

    pub fn framebuffer(&self) -> &Framebuffer {
        &self.framebuffer
    }

    pub fn server_init(&self) -> &ServerInit {
        &self.init
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// The screen layout from the last ExtendedDesktopSize.
    pub fn screens(&self) -> &[Screen] {
        &self.screens
    }

    /// True once the server sent ExtendedDesktopSize, so it accepts SetDesktopSize.
    pub fn resize_supported(&self) -> bool {
        self.resize_supported
    }

    /// Reads and applies the next server message. Blocks until one arrives;
    /// [`Input::close`] from another thread ends the wait with an error.
    pub fn next_event(&mut self) -> Result<Event> {
        loop {
            match self.reader.u8()? {
                0 => return self.framebuffer_update().map(Event::Update),
                1 => {
                    // SetColourMapEntries: true color was requested; read and drop.
                    self.reader.skip(1)?;
                    let _first = self.reader.u16()?;
                    let count = self.reader.u16()?;
                    self.reader.skip(usize::from(count) * 6)?;
                }
                2 => return Ok(Event::Bell),
                3 => {
                    self.reader.skip(3)?;
                    let len = self.reader.u32()? as usize;
                    if len > MAX_TEXT_BYTES {
                        self.reader.skip(len)?;
                        continue;
                    }
                    let text = latin1(&self.reader.bytes(len)?);
                    return Ok(Event::Clipboard(text));
                }
                other => return Err(VncError::protocol(format!("server message type {other}"))),
            }
        }
    }

    fn framebuffer_update(&mut self) -> Result<Update> {
        self.reader.skip(1)?;
        let count = self.reader.u16()?;
        let mut update = Update::default();
        for _ in 0..count {
            let rect = Rect::new(
                self.reader.u16()?,
                self.reader.u16()?,
                self.reader.u16()?,
                self.reader.u16()?,
            );
            let kind = self.reader.i32()?;
            match kind {
                encoding::LAST_RECT => break,
                encoding::DESKTOP_SIZE => {
                    self.framebuffer.resize(rect.width, rect.height)?;
                    update.resized = true;
                }
                encoding::EXTENDED_DESKTOP_SIZE => {
                    self.extended_desktop_size(&rect, &mut update)?;
                }
                encoding::CURSOR => {
                    update.cursor = Some(if rect.is_empty() {
                        Cursor { hotspot_x: 0, hotspot_y: 0, width: 0, height: 0, rgba: Vec::new() }
                    } else {
                        decode::cursor(&mut self.reader, &self.format, &rect)?
                    });
                }
                encoding::DESKTOP_NAME => {
                    let name = self.reader.text("desktop name")?;
                    self.name = name.clone();
                    update.name = Some(name);
                }
                _ => {
                    self.decoders.decode(
                        &mut self.reader,
                        &mut self.framebuffer,
                        &self.format,
                        kind,
                        &rect,
                    )?;
                    update.damage = update.damage.union(&rect);
                }
            }
        }
        let full = Rect::new(0, 0, self.framebuffer.width(), self.framebuffer.height());
        if update.resized {
            update.damage = full;
        }
        // Ask for the next change; after a resize, the whole new frame.
        self.input.request_frame(!update.resized, full.width, full.height)?;
        Ok(update)
    }

    fn extended_desktop_size(&mut self, rect: &Rect, update: &mut Update) -> Result<()> {
        // x is the reason (1: this client's request), y the status.
        let count = self.reader.u8()?;
        self.reader.skip(3)?;
        let mut screens = Vec::with_capacity(usize::from(count));
        for _ in 0..count {
            let id = self.reader.u32()?;
            let screen = Rect::new(
                self.reader.u16()?,
                self.reader.u16()?,
                self.reader.u16()?,
                self.reader.u16()?,
            );
            let flags = self.reader.u32()?;
            screens.push(Screen { id, rect: screen, flags });
        }
        self.resize_supported = true;
        if rect.x == 1 && rect.y != 0 {
            update.resize_refused = Some(u32::from(rect.y));
            return Ok(());
        }
        self.screens = screens;
        if (rect.width, rect.height) != (self.framebuffer.width(), self.framebuffer.height()) {
            self.framebuffer.resize(rect.width, rect.height)?;
            update.resized = true;
        }
        Ok(())
    }
}

/// The writing half of a session: input, clipboard, resize, close.
#[derive(Clone)]
pub struct Input {
    inner: Arc<InputInner>,
}

struct InputInner {
    queue: Arc<InputQueue>,
    closer: Closer,
    /// Signalled when the writer thread ends.
    done: Mutex<Receiver<()>>,
}

#[derive(Default)]
struct InputQueue {
    state: Mutex<QueueState>,
    ready: Condvar,
    capacity_notifier: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

#[derive(Default)]
struct QueueState {
    pending: VecDeque<PendingInput>,
    pastes: usize,
    /// Frame requests do not consume input slots. They may pass between paste key batches.
    refresh: Option<(bool, u16, u16)>,
    /// Operations queued before the first coalesced refresh request.
    refresh_ahead: usize,
    closing: bool,
    closed: bool,
}

enum PendingInput {
    Bytes(Vec<u8>),
    Paste(String),
}

impl InputQueue {
    fn notify_capacity(&self) {
        let notify = self.capacity_notifier.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(notify) = notify {
            notify();
        }
    }

    fn write_refresh(&self, writer: &mut dyn Write, interrupt_paste: bool) -> io::Result<()> {
        let refresh = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            if state.closed {
                return Err(io::Error::from(io::ErrorKind::BrokenPipe));
            }
            if interrupt_paste || state.refresh_ahead == 0 { state.refresh.take() } else { None }
        };
        if let Some((incremental, width, height)) = refresh {
            writer.write_all(&message::update_request(
                incremental,
                &Rect::new(0, 0, width, height),
            ))?;
            writer.flush()?;
        }
        Ok(())
    }

    fn next(&self) -> Option<PendingInput> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if state.closed {
                return None;
            }
            if state.refresh_ahead == 0
                && let Some((incremental, width, height)) = state.refresh.take()
            {
                return Some(PendingInput::Bytes(message::update_request(
                    incremental,
                    &Rect::new(0, 0, width, height),
                )));
            }
            if let Some(message) = state.pending.pop_front() {
                state.refresh_ahead = state.refresh_ahead.saturating_sub(1);
                drop(state);
                self.notify_capacity();
                return Some(message);
            }
            if state.closing {
                return None;
            }
            state = self.ready.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }
}

impl Drop for InputInner {
    fn drop(&mut self) {
        self.queue.state.lock().unwrap_or_else(PoisonError::into_inner).closing = true;
        self.queue.ready.notify_one();
    }
}

impl Input {
    /// Starts the writer thread. It drains when every `Input` is dropped; a
    /// failed write closes the transport, so the reader sees the failure.
    fn spawn(mut writer: Box<dyn Write + Send>, closer: Closer) -> Result<Self> {
        let queue = Arc::new(InputQueue::default());
        let pending = queue.clone();
        let (done_tx, done) = mpsc::channel();
        let writer_closer = closer.clone();
        let spawned = thread::Builder::new().name("vnc-writer".into()).spawn(move || {
            let mut failed = false;
            while let Some(message) = pending.next() {
                let is_paste = matches!(&message, PendingInput::Paste(_));
                let written = match message {
                    PendingInput::Bytes(bytes) => writer.write_all(&bytes),
                    PendingInput::Paste(text) => {
                        crate::paste::write(&mut writer, &text, |writer| {
                            pending.write_refresh(writer, true)
                        })
                    }
                };
                if written
                    .and_then(|()| pending.write_refresh(&mut writer, false))
                    .and_then(|()| writer.flush())
                    .is_err()
                {
                    let already_closed =
                        pending.state.lock().unwrap_or_else(PoisonError::into_inner).closed;
                    if !already_closed {
                        writer_closer.close();
                    }
                    failed = true;
                    break;
                }
                if is_paste {
                    let mut state = pending.state.lock().unwrap_or_else(PoisonError::into_inner);
                    state.pastes = state.pastes.saturating_sub(1);
                    drop(state);
                    pending.notify_capacity();
                }
            }
            let (graceful, discarded) = {
                let mut state = pending.state.lock().unwrap_or_else(PoisonError::into_inner);
                let graceful = !state.closed && !failed;
                state.closed = true;
                (graceful, std::mem::take(&mut state.pending))
            };
            drop(discarded);
            pending.notify_capacity();
            drop(writer);
            if graceful {
                writer_closer.finish(DRAIN_LIMIT);
            }
            let _ = done_tx.send(());
        });
        if let Err(error) = spawned {
            closer.close();
            return Err(error.into());
        }
        Ok(Self { inner: Arc::new(InputInner { queue, closer, done: Mutex::new(done) }) })
    }

    /// Whether a sole input producer can admit `operations` without waiting.
    /// Framebuffer requests use a separate coalesced slot and cannot consume this room.
    /// A paste pauses source admission until complete, retaining only its existing
    /// source string rather than accumulating more large pastes in the queue.
    pub fn has_capacity(&self, operations: usize) -> bool {
        let state = self.inner.queue.state.lock().unwrap_or_else(PoisonError::into_inner);
        !state.closed
            && !state.closing
            && state.pastes == 0
            && operations <= WRITE_QUEUE.saturating_sub(state.pending.len())
    }

    /// Wake a source that paused admission. The callback must not block.
    /// Install before checking capacity, so a dequeue cannot lose its wakeup.
    pub fn set_capacity_notifier(&self, notify: impl Fn() + Send + Sync + 'static) {
        *self.inner.queue.capacity_notifier.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(Arc::new(notify));
    }

    /// Queues one message without waiting for the network.
    fn send(&self, bytes: &[u8]) -> Result<()> {
        self.enqueue(PendingInput::Bytes(bytes.to_vec()))
    }

    fn enqueue(&self, message: PendingInput) -> Result<()> {
        let mut state = self.inner.queue.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.closed || state.closing {
            return Err(io::Error::from(io::ErrorKind::BrokenPipe).into());
        }
        if state.pending.len() == WRITE_QUEUE {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "input source must wait for capacity",
            )
            .into());
        }
        if matches!(&message, PendingInput::Paste(_)) {
            state.pastes = state.pastes.saturating_add(1);
        }
        state.pending.push_back(message);
        drop(state);
        self.inner.queue.ready.notify_one();
        Ok(())
    }

    fn request_frame(&self, incremental: bool, width: u16, height: u16) -> Result<()> {
        let mut state = self.inner.queue.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.closed || state.closing {
            return Err(io::Error::from(io::ErrorKind::BrokenPipe).into());
        }
        // Coalescing retains the first request's place relative to input. Only
        // an in-flight paste may service it early, between complete key batches.
        if state.refresh.is_none() {
            state.refresh_ahead = state.pending.len();
        }
        // A pending full refresh must not be downgraded to an incremental one.
        let incremental = incremental && state.refresh.is_none_or(|(old, _, _)| old);
        state.refresh = Some((incremental, width, height));
        drop(state);
        self.inner.queue.ready.notify_one();
        Ok(())
    }

    /// A key press or release (`keysym` from [`crate::keysym`]).
    pub fn key(&self, keysym: u32, down: bool) -> Result<()> {
        self.send(&message::key_event(keysym, down))
    }

    /// Key events in order, sent as one write: (keysym, down).
    pub fn keys(&self, keys: &[(u32, bool)]) -> Result<()> {
        if keys.is_empty() {
            return Ok(());
        }
        let bytes: Vec<u8> =
            keys.iter().flat_map(|&(keysym, down)| message::key_event(keysym, down)).collect();
        self.send(&bytes)
    }

    /// Types an entire paste, then mirrors it to the classic RFB clipboard.
    ///
    /// Takes ownership of the clipboard text without an additional full-size
    /// copy. One ordered operation streams fixed-size key batches on the writer
    /// thread, with socket backpressure; later input cannot split the paste.
    /// Carriage returns are ignored, as in the terminal viewer's paste path.
    /// RFB's clipboard length is u32; text beyond that wire field is still
    /// typed in full, without replacing the clipboard with a truncated prefix.
    pub fn paste(&self, text: String) -> Result<()> {
        self.enqueue(PendingInput::Paste(text))
    }

    /// Pointer position and the buttons held ([`message::button`] bits).
    pub fn pointer(&self, x: u16, y: u16, buttons: u8) -> Result<()> {
        self.send(&message::pointer_event(buttons, x, y))
    }

    /// Sends the local clipboard (Latin-1; other characters become `?`).
    pub fn clipboard(&self, text: &str) -> Result<()> {
        self.send(&message::client_cut_text(&to_latin1(text)))
    }

    /// Asks the server to resize its desktop (only after
    /// [`Session::resize_supported`]); the answer is an [`Update`].
    pub fn resize(&self, width: u16, height: u16, screen_id: u32) -> Result<()> {
        self.send(&message::set_desktop_size(width, height, screen_id))
    }

    /// Asks for a full frame (after a local redraw lost the picture).
    pub fn refresh(&self, width: u16, height: u16) -> Result<()> {
        self.request_frame(false, width, height)
    }

    /// Ends the session now; the reading thread's `next_event` then fails.
    /// Queued input may be dropped: use [`Input::close_after_pending`] when
    /// it matters (key releases on quit).
    pub fn close(&self) {
        self.inner.queue.state.lock().unwrap_or_else(PoisonError::into_inner).closed = true;
        self.inner.queue.ready.notify_one();
        self.inner.closer.close();
    }

    /// Sends what is queued (key and button releases), then ends the
    /// session (a proxy command first forwards it, up to 400 ms). Waits at
    /// most `limit` for the writer; past it, closes at once.
    pub fn close_after_pending(&self, limit: Duration) {
        self.inner.queue.state.lock().unwrap_or_else(PoisonError::into_inner).closing = true;
        self.inner.queue.ready.notify_one();
        let done = self.inner.done.lock().unwrap_or_else(PoisonError::into_inner);
        if done.recv_timeout(limit).is_err() {
            self.close();
        }
    }
}

#[cfg(test)]
#[path = "session_backpressure.rs"]
mod backpressure_tests;
