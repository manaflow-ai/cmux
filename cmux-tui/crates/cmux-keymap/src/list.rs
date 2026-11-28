//! The list layer of `app.keyStyle`: strokes to list commands, with pending sequences (vim's
//! `gg`) and the `inText` rule (key-vectors.json's `$listComment`).

use crate::table::{Row, table};
use crate::{KeyEvent, KeyStyle, ListCommand, ShortcutLayout, stroke_matches};

/// What a key does in a list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The key is this list command; the surface consumes it.
    Command(ListCommand),
    /// The key starts (or continues) a sequence such as vim's `gg`; the surface consumes it
    /// and waits for the next key.
    Pending,
    /// The key is not the style's: it is left to the surface (typing, arrows, shortcuts).
    Pass,
}

/// One list's key state: the style, the shortcut layout and any pending sequence.
#[derive(Debug, Clone)]
pub struct ListKeys {
    style: KeyStyle,
    layout: ShortcutLayout,
    /// Strokes of a sequence matched so far (0: nothing pending).
    depth: usize,
    /// Indexes of the style's rows whose first `depth` strokes matched.
    alive: Vec<usize>,
}

impl ListKeys {
    pub fn new(style: KeyStyle, layout: ShortcutLayout) -> Self {
        ListKeys { style, layout, depth: 0, alive: Vec::new() }
    }

    pub fn style(&self) -> KeyStyle {
        self.style
    }

    pub fn layout(&self) -> ShortcutLayout {
        self.layout
    }

    /// Whether a sequence is pending (the first `g` of `gg`).
    pub fn is_pending(&self) -> bool {
        self.depth > 0
    }

    /// Drops a pending sequence (focus moved, a timeout, the list closed).
    pub fn reset(&mut self) {
        self.depth = 0;
        self.alive.clear();
    }

    /// Feeds one key. `in_text`: a text field has the keyboard, so only `inText` rows apply.
    /// A key that does not continue a pending sequence drops it and is judged on its own.
    pub fn feed(&mut self, event: &KeyEvent<'_>, in_text: bool) -> Outcome {
        let rows = table().rows(self.style);
        if self.depth > 0 {
            let alive = std::mem::take(&mut self.alive);
            let outcome = self.step(rows, alive.into_iter(), event, in_text);
            if outcome != Outcome::Pass {
                return outcome;
            }
            self.reset();
        }
        self.step(rows, 0..rows.len(), event, in_text)
    }

    /// Matches stroke `self.depth` of each candidate row against `event`. A row it completes
    /// wins; else rows it continues stay alive (Pending); else Pass and nothing is pending.
    fn step(
        &mut self,
        rows: &[Row],
        candidates: impl Iterator<Item = usize>,
        event: &KeyEvent<'_>,
        in_text: bool,
    ) -> Outcome {
        let depth = self.depth;
        let next_depth = depth.saturating_add(1);
        let mut continuing = Vec::new();
        for index in candidates {
            let Some(row) = rows.get(index) else { continue };
            if in_text && !row.in_text {
                continue;
            }
            let Some(stroke) = row.strokes.get(depth) else { continue };
            if !stroke_matches(self.layout, stroke, event) {
                continue;
            }
            if row.strokes.len() == next_depth {
                self.reset();
                return Outcome::Command(row.command);
            }
            continuing.push(index);
        }
        if continuing.is_empty() {
            return Outcome::Pass;
        }
        self.depth = next_depth;
        self.alive = continuing;
        Outcome::Pending
    }
}
