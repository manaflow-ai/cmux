//! The terminals one worker parses.
//!
//! Each terminal has a ghostty-vt parser set up as the daemon's own
//! (`cmux-tui-core` surface/spawn.rs: grid, cell size, default colors,
//! palette and cursor), its ring mapped read-only and its page mapped
//! writable. [`Shard::step`] parses one slice of at most [`SLICE_BYTES`]
//! for the next terminal with unparsed bytes, round robin, publishes its
//! page and returns the events the slice made: one flooding terminal never
//! holds another back by more than one slice (the vt-pool rule of
//! p01-process-120, as Chrome's scheduler yields between tasks).

use std::collections::BTreeMap;
use std::sync::mpsc::{Receiver, Sender, channel};

use ghostty_vt::{Callbacks, RenderState, Terminal};

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
}

struct Slot {
    terminal: Terminal,
    render: RenderState,
    ring: RingView,
    page: PageWriter,
    effects: Receiver<Effect>,
    /// The next ring offset to parse.
    parsed: u64,
    /// The ring end the daemon announced.
    target: u64,
    frame: u64,
    pwd: Option<String>,
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
        let Ok((terminal, render)) = new_parser(attach.geometry, scrollback, sender) else {
            events.push(Event::AttachFailed { id, reason: AttachFailure::Parser });
            return;
        };
        let slot = Slot {
            terminal,
            render,
            ring,
            page,
            effects,
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

    pub fn detach(&mut self, id: u64) {
        self.slots.remove(&id);
        if self.last == Some(id) {
            self.last = self.slots.range(..id).next_back().map(|(id, _)| *id);
        }
    }

    /// Whether a terminal has bytes announced and not parsed.
    pub fn has_work(&self) -> bool {
        self.slots.values().any(|slot| slot.parsed < slot.target)
    }

    /// Parse one slice for the next terminal with work, publish its page
    /// and append its events. False when no terminal had work.
    pub fn step(&mut self, events: &mut Vec<Event>) -> bool {
        let after = self.last.map_or(0, |id| id.wrapping_add(1));
        let next = self
            .slots
            .range(after..)
            .chain(self.slots.range(..after))
            .find(|(_, slot)| slot.parsed < slot.target)
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
                slot.terminal.vt_write(CANCEL);
                slot.parsed = oldest.max(from);
                slot.target = slot.target.max(slot.parsed);
                events.push(Event::Lapped { id, from, oldest });
            }
            RingCopy::Bytes { from, len } => {
                slot.terminal.vt_write(&self.chunk);
                slot.parsed = from + len as u64;
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
        on_bell: Some(Box::new(move || {
            let _ = effects.send(Effect::Bell);
        })),
        on_clipboard_read: None,
        on_program_status: None,
    };
    let mut terminal = Terminal::new(geometry.cols, geometry.rows, scrollback, callbacks)?;
    terminal.resize(
        geometry.cols,
        geometry.rows,
        u32::from(geometry.cell_width),
        u32::from(geometry.cell_height),
    )?;
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
