//! A running RFB session: the reading half ([`Session`], one thread) and
//! the writing half ([`Input`], cloneable, any thread).

use std::io::{BufReader, Read, Write};
use std::sync::{Arc, Mutex};

use crate::auth::Credentials;
use crate::decode::{self, Cursor, Decoders, encoding};
use crate::error::{Result, VncError};
use crate::framebuffer::{Framebuffer, Rect};
use crate::handshake::{ServerInit, handshake};
use crate::message::{self, Screen};
use crate::pixel::PixelFormat;
use crate::transport::{Closer, Transport};
use crate::wire::{MAX_TEXT_BYTES, WireReader, latin1, to_latin1};

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
        let framebuffer = Framebuffer::new(init.width, init.height)?;
        let input = Input { inner: Arc::new(InputInner { writer: Mutex::new(writer), closer }) };
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
        self.input.send(&message::update_request(!update.resized, &full))?;
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
    writer: Mutex<Box<dyn Write + Send>>,
    closer: Closer,
}

impl Input {
    fn send(&self, bytes: &[u8]) -> Result<()> {
        let mut writer =
            self.inner.writer.lock().map_err(|_| VncError::protocol("input lock poisoned"))?;
        writer.write_all(bytes)?;
        writer.flush()?;
        Ok(())
    }

    /// A key press or release (`keysym` from [`crate::keysym`]).
    pub fn key(&self, keysym: u32, down: bool) -> Result<()> {
        self.send(&message::key_event(keysym, down))
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
        self.send(&message::update_request(false, &Rect::new(0, 0, width, height)))
    }

    /// Ends the session; the reading thread's `next_event` then fails.
    pub fn close(&self) {
        self.inner.closer.close();
    }
}
