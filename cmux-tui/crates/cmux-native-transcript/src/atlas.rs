//! Glyph atlas slots: a shelf packer over a square atlas. Layout interns each distinct glyph once (an index), so a
//! frame looks a glyph up by index, never by hash. A glyph gets its slot the first time it is drawn and is queued
//! for the app to rasterize; the app reports when everything it took is filled.

use std::collections::HashMap;
use std::collections::VecDeque;

/// A glyph's identity: the Unicode scalar and the font (0 text, 1 mono).
#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
pub struct GlyphKey {
    pub scalar: u32,
    pub font: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slot {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    /// The app has rasterized it.
    pub ready: bool,
}

#[derive(Debug)]
pub struct Atlas {
    side: u32,
    cell_w: u32,
    cell_h: u32,
    next_x: u32,
    next_y: u32,
    index: HashMap<GlyphKey, u32>,
    keys: Vec<GlyphKey>,
    slots: Vec<Option<Slot>>,
    pending: VecDeque<u32>,
    /// Taken by the app and not yet reported filled.
    taken: Vec<u32>,
    /// A glyph found no room (it is not drawn).
    pub full: bool,
}

impl Atlas {
    pub fn new(side: u32, cell_w: u32, cell_h: u32) -> Self {
        let side = side.max(1);
        Atlas {
            side,
            cell_w: cell_w.clamp(1, side),
            cell_h: cell_h.clamp(1, side),
            next_x: 0,
            next_y: 0,
            index: HashMap::new(),
            keys: Vec::new(),
            slots: Vec::new(),
            pending: VecDeque::new(),
            taken: Vec::new(),
            full: false,
        }
    }

    pub fn side(&self) -> u32 {
        self.side
    }

    /// The glyph's index (layout time; no slot yet).
    pub fn intern(&mut self, key: GlyphKey) -> u32 {
        if let Some(&i) = self.index.get(&key) {
            return i;
        }
        let i = self.keys.len() as u32;
        self.keys.push(key);
        self.slots.push(None);
        self.index.insert(key, i);
        i
    }

    /// The glyph's slot, placing and queueing it on first use. None when the atlas is full.
    pub fn slot(&mut self, glyph: u32) -> Option<Slot> {
        let i = glyph as usize;
        if let Some(Some(s)) = self.slots.get(i) {
            return Some(*s);
        }
        if i >= self.slots.len() {
            return None;
        }
        if self.next_x + self.cell_w > self.side {
            self.next_x = 0;
            self.next_y += self.cell_h;
        }
        if self.next_y + self.cell_h > self.side {
            self.full = true;
            return None;
        }
        let s =
            Slot { x: self.next_x, y: self.next_y, w: self.cell_w, h: self.cell_h, ready: false };
        self.next_x += self.cell_w;
        self.slots[i] = Some(s);
        self.pending.push_back(glyph);
        Some(s)
    }

    /// Move up to `cap` queued glyphs to the app.
    pub fn take(&mut self, cap: usize) -> Vec<(GlyphKey, Slot)> {
        let n = cap.min(self.pending.len());
        let mut out = Vec::with_capacity(n);
        for glyph in self.pending.drain(..n) {
            self.taken.push(glyph);
            if let Some(s) = self.slots[glyph as usize] {
                out.push((self.keys[glyph as usize], s));
            }
        }
        out
    }

    /// Everything taken so far is filled.
    pub fn ready(&mut self) {
        for glyph in self.taken.drain(..) {
            if let Some(Some(s)) = self.slots.get_mut(glyph as usize) {
                s.ready = true;
            }
        }
    }

    /// Glyphs with a slot.
    pub fn placed(&self) -> usize {
        self.slots.iter().filter(|s| s.is_some()).count()
    }
}
