//! The terminals one worker parses.
//!
//! Each terminal has a ghostty-vt parser set up as the daemon's own
//! (`cmux-tui-core` surface/spawn.rs: grid, cell size, default colors,
//! palette, cursor, Kitty limits and the OSC 7501 owner), its ring mapped
//! read-only and its page mapped writable. The ring's bytes reach the parser
//! through the daemon's own per-chunk rewrites (surface/local_output.rs):
//! Kitty file media first, then `cmux_vt_stream::write_output` (title stack
//! and OSC 1, mode resets at prompt marks), so both parsers read one stream.
//! [`Shard::step`] parses one slice of at most [`SLICE_BYTES`] for the next
//! terminal with unparsed bytes, round robin, publishes its page and returns
//! the events the slice made: one flooding terminal never holds another back
//! by more than one slice (the vt-pool rule of p01-process-120, as Chrome's
//! scheduler yields between tasks).

use std::collections::BTreeMap;
use std::sync::mpsc::{Receiver, Sender, channel};

use cmux_kitty_media::{KittyMediaRewriter, Limits, MediaRefusal};
use cmux_vt_stream::ShellMarks;
use ghostty_vt::{Callbacks, KittyGraphicsLimits, ProgramStatusEvent, RenderState, Terminal};

use crate::ring_view::{RingCopy, RingView};
use crate::screen_page::{Modes, PageEncoder, PageMeta, PageWriter, Published};
use crate::wire::{Attach, AttachFailure, Colors, Event, Geometry};

/// The most ring bytes one [`Shard::step`] parses.
pub const SLICE_BYTES: usize = 64 << 10;
/// CAN: the parser gets it where the ring lost bytes, so an escape sequence
/// cut there ends instead of eating the bytes after the gap.
const CANCEL: &[u8] = &[0x18];

/// What a parser callback recorded during `vt_write`; read after it
/// returns (callbacks must not touch the terminal).
enum Effect {
    PtyWrite(Vec<u8>),
    Title,
    Bell,
    ProgramStatus(ProgramStatusEvent),
}

/// The daemon's per-terminal output rewrites, carried across slices.
struct OutputStream {
    /// Defers each file read to the daemon: the sandbox opens no file.
    kitty: KittyMediaRewriter,
    marks: ShellMarks,
    rewritten: Vec<u8>,
}

impl OutputStream {
    /// A parser that starts past the stream's first byte joined it midway:
    /// a command may be running, as for the daemon's adopted mirrors.
    fn new(start: u64) -> Self {
        Self {
            kitty: KittyMediaRewriter::deferring(Limits::default()),
            marks: if start == 0 { ShellMarks::default() } else { ShellMarks::joined_midway() },
            rewritten: Vec::new(),
        }
    }

    /// Rewrite and parse `input` up to the end of its first file-medium
    /// Kitty command; the bytes of `input` consumed.
    fn write(&mut self, terminal: &mut Terminal, input: &[u8]) -> usize {
        self.rewritten.clear();
        let consumed = self.kitty.rewrite_until_media(input, &mut self.rewritten);
        self.parse(terminal);
        consumed
    }

    /// Finish the waiting Kitty command with the daemon's read.
    fn resume(&mut self, terminal: &mut Terminal, read: Result<Vec<u8>, MediaRefusal>) {
        self.rewritten.clear();
        self.kitty.resume_media(read, &mut self.rewritten);
        self.parse(terminal);
    }

    fn parse(&mut self, terminal: &mut Terminal) {
        if !self.rewritten.is_empty() {
            let _ = cmux_vt_stream::write_output(terminal, &self.rewritten, &mut self.marks);
        }
    }

    fn awaiting_media(&self) -> bool {
        self.kitty.media_request().is_some()
    }
}

struct Slot {
    terminal: Terminal,
    render: RenderState,
    ring: RingView,
    page: PageWriter,
    effects: Receiver<Effect>,
    stream: OutputStream,
    /// The next ring offset to parse.
    parsed: u64,
    /// The ring end the daemon announced.
    target: u64,
    frame: u64,
    pwd: Option<String>,
}

impl Slot {
    /// Unparsed bytes and no Kitty read pending.
    fn has_work(&self) -> bool {
        self.parsed < self.target && !self.stream.awaiting_media()
    }
}

/// One worker's terminals.
#[derive(Default)]
pub struct Shard {
    slots: BTreeMap<u64, Slot>,
    /// The id the next round-robin search starts after.
    last: Option<u64>,
    chunk: Vec<u8>,
    encoder: PageEncoder,
}

impl Shard {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// Add a terminal and publish its first (empty) screen.
    pub fn attach(&mut self, attach: Attach, events: &mut Vec<Event>) {
        let id = attach.id;
        if self.slots.contains_key(&id) {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Duplicate });
            return;
        }
        let Ok(ring) = RingView::open(attach.ring, attach.ring_capacity) else {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Ring });
            return;
        };
        let Ok(page) = usize::try_from(attach.page_len)
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))
            .and_then(|len| PageWriter::open(attach.page, len))
        else {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Page });
            return;
        };
        let (sender, effects) = channel();
        let scrollback = usize::try_from(attach.scrollback).unwrap_or(usize::MAX);
        let Ok((terminal, render)) =
            new_parser(attach.geometry, scrollback, attach.kitty_limits, sender)
        else {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Parser });
            return;
        };
        let slot = Slot {
            terminal,
            render,
            ring,
            page,
            effects,
            stream: OutputStream::new(attach.start),
            parsed: attach.start,
            target: attach.start,
            frame: 0,
            pwd: None,
        };
        self.slots.insert(id, slot);
        self.publish(id, events);
    }

    /// The holder published `id`'s ring up to `end`.
    pub fn advance(&mut self, id: u64, end: u64) {
        if let Some(slot) = self.slots.get_mut(&id) {
            slot.target = slot.target.max(end);
        }
    }

    /// A new grid (and page, when given); the screen is republished.
    pub fn resize(
        &mut self,
        id: u64,
        geometry: Geometry,
        page: Option<(std::os::fd::OwnedFd, u64)>,
        events: &mut Vec<Event>,
    ) {
        let Some(slot) = self.slots.get_mut(&id) else {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Unknown });
            return;
        };
        if let Some((fd, len)) = page {
            match usize::try_from(len)
                .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))
                .and_then(|len| PageWriter::open(fd, len))
            {
                Ok(page) => slot.page = page,
                Err(_) => {
                    events.push(Event::AttachFailed { id, reason: AttachFailure::Page });
                    return;
                }
            }
        }
        let resized = slot.terminal.resize(
            geometry.cols,
            geometry.rows,
            u32::from(geometry.cell_width),
            u32::from(geometry.cell_height),
        );
        if resized.is_err() {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Parser });
            return;
        }
        self.publish(id, events);
    }

    /// Default colors, palette and cursor as the daemon's parser has them.
    pub fn colors(&mut self, id: u64, colors: &Colors, events: &mut Vec<Event>) {
        let Some(slot) = self.slots.get_mut(&id) else { return };
        apply_colors(&mut slot.terminal, colors);
        self.publish(id, events);
    }

    /// The terminal's Kitty budget changed: applied where the parser is,
    /// as the daemon applies it to its own parser between reads
    /// (host_kitty_limits.rs). An eviction shows on the republished page.
    pub fn kitty_limits(&mut self, id: u64, limits: KittyGraphicsLimits, events: &mut Vec<Event>) {
        let Some(slot) = self.slots.get_mut(&id) else {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Unknown });
            return;
        };
        if slot.terminal.set_kitty_graphics_limits(limits).is_err() {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Parser });
            return;
        }
        self.publish(id, events);
    }

    /// The daemon answered `id`'s Kitty file read: the command is parsed
    /// and the terminal's parse continues. An answer nothing waits for (the
    /// terminal detached and came back) is dropped.
    pub fn kitty_media(
        &mut self,
        id: u64,
        read: Result<Vec<u8>, MediaRefusal>,
        events: &mut Vec<Event>,
    ) {
        let Some(slot) = self.slots.get_mut(&id) else { return };
        if !slot.stream.awaiting_media() {
            return;
        }
        slot.stream.resume(&mut slot.terminal, read);
        drain_effects(id, slot, events);
        self.publish(id, events);
    }

    pub fn detach(&mut self, id: u64) {
        self.slots.remove(&id);
        if self.last == Some(id) {
            self.last = self.slots.range(..id).next_back().map(|(id, _)| *id);
        }
    }

    /// Whether a terminal has bytes announced and not parsed.
    pub fn has_work(&self) -> bool {
        self.slots.values().any(Slot::has_work)
    }

    /// Parse one slice for the next terminal with work, publish its page
    /// and append its events. False when no terminal had work.
    pub fn step(&mut self, events: &mut Vec<Event>) -> bool {
        let after = self.last.map_or(0, |id| id.wrapping_add(1));
        let next = self
            .slots
            .range(after..)
            .chain(self.slots.range(..after))
            .find(|(_, slot)| slot.has_work())
            .map(|(id, _)| *id);
        let Some(id) = next else { return false };
        self.last = Some(id);
        let Some(slot) = self.slots.get_mut(&id) else { return false };
        match slot.ring.copy(slot.parsed, slot.target, SLICE_BYTES, &mut self.chunk) {
            RingCopy::Empty => {
                // The ring has not reached the announced end (an ADVANCE
                // ahead of the segment): wait for the next one.
                slot.target = slot.parsed;
                return true;
            }
            RingCopy::Lapped { from, oldest } => {
                // The daemon's sink queues the same CAN into its rewrites.
                slot.stream.write(&mut slot.terminal, CANCEL);
                slot.parsed = oldest.max(from);
                slot.target = slot.target.max(slot.parsed);
                events.push(Event::Lapped { id, from, oldest });
            }
            RingCopy::Bytes { from, .. } => {
                let consumed = slot.stream.write(&mut slot.terminal, &self.chunk);
                slot.parsed = from + consumed as u64;
                if let Some(request) = slot.stream.kitty.media_request() {
                    events.push(Event::KittyMediaRequest { id, request: request.clone() });
                }
            }
        }
        drain_effects(id, slot, events);
        self.publish(id, events);
        true
    }

    /// Encode `id`'s screen into its page and report the parsed offset.
    fn publish(&mut self, id: u64, events: &mut Vec<Event>) {
        let Some(slot) = self.slots.get_mut(&id) else { return };
        if slot.render.update(&mut slot.terminal).is_err() {
            return;
        }
        self.encoder.begin();
        let encoder = &mut self.encoder;
        if slot.render.walk_rows(|_, _, cells| encoder.push_row(cells)).is_err() {
            return;
        }
        slot.render.set_clean();
        slot.frame += 1;
        let cursor_visual =
            slot.render.cursor_visual().unwrap_or((ghostty_vt::CursorShape::Block, false));
        let meta = PageMeta {
            parsed: slot.parsed,
            frame: slot.frame,
            cols: slot.terminal.cols(),
            cursor: slot.render.cursor(),
            cursor_visual,
            modes: Modes::of(&slot.terminal),
            mouse_format: slot.terminal.active_mouse_format(),
        };
        let image = self.encoder.finish(&meta);
        if let Published::TooSmall { needed } = slot.page.publish(image) {
            events.push(Event::PageTooSmall { id, needed: needed as u64 });
        }
        events.push(Event::Parsed { id, offset: slot.parsed, frame: slot.frame });
    }
}

/// A parser and render state set up as the daemon sets up its own.
fn new_parser(
    geometry: Geometry,
    scrollback: usize,
    kitty_limits: KittyGraphicsLimits,
    effects: Sender<Effect>,
) -> ghostty_vt::Result<(Terminal, RenderState)> {
    let callbacks = Callbacks {
        on_pty_write: Some(Box::new({
            let effects = effects.clone();
            move |bytes| {
                let _ = effects.send(Effect::PtyWrite(bytes.to_vec()));
            }
        })),
        on_title_changed: Some(Box::new({
            let effects = effects.clone();
            move || {
                let _ = effects.send(Effect::Title);
            }
        })),
        on_bell: Some(Box::new({
            let effects = effects.clone();
            move || {
                let _ = effects.send(Effect::Bell);
            }
        })),
        on_clipboard_read: None,
        // The daemon owns the OSC 7501 records, as for its own parser
        // (surface/spawn.rs): with an owner set, libghostty answers the
        // support query through `on_pty_write` and reports prompt starts.
        on_program_status: Some(Box::new(move |event| {
            let _ = effects.send(Effect::ProgramStatus(event));
        })),
    };
    let mut terminal = Terminal::new(geometry.cols, geometry.rows, scrollback, callbacks)?;
    terminal.resize(
        geometry.cols,
        geometry.rows,
        u32::from(geometry.cell_width),
        u32::from(geometry.cell_height),
    )?;
    terminal.set_kitty_graphics_limits(kitty_limits)?;
    Ok((terminal, RenderState::new()?))
}

/// Apply the daemon's color and cursor defaults (surface/spawn.rs order).
pub fn apply_colors(terminal: &mut Terminal, colors: &Colors) {
    terminal.replace_default_colors(colors.fg, colors.bg, colors.cursor);
    terminal.set_default_palette(&colors.palette);
    terminal.replace_default_cursor(colors.cursor_style, colors.cursor_blink);
}

fn drain_effects(id: u64, slot: &mut Slot, events: &mut Vec<Event>) {
    let mut bells = 0u32;
    let mut title = false;
    let mut answer = Vec::new();
    while let Ok(effect) = slot.effects.try_recv() {
        match effect {
            Effect::PtyWrite(bytes) => answer.extend_from_slice(&bytes),
            Effect::Title => title = true,
            Effect::Bell => bells = bells.saturating_add(1),
            Effect::ProgramStatus(event) => events.push(Event::ProgramStatus { id, event }),
        }
    }
    if !answer.is_empty() {
        events.push(Event::PtyWrite { id, bytes: answer });
    }
    if title {
        events.push(Event::Title { id, title: slot.terminal.title().unwrap_or_default() });
    }
    if bells > 0 {
        events.push(Event::Bell { id, count: bells });
    }
    let pwd = slot.terminal.pwd();
    if pwd != slot.pwd {
        if let Some(pwd) = &pwd {
            events.push(Event::Pwd { id, pwd: pwd.clone() });
        }
        slot.pwd = pwd;
    }
}

#[cfg(test)]
#[path = "shard_tests.rs"]
mod tests;
