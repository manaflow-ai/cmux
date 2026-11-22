//! `foreign_viewport` strings of the CLI catalog (English and Japanese).

use super::{FOREIGN_VIEWPORT_HINT_CAPACITY, ForeignViewportHint, decimal_width};
use std::io::Cursor;
use std::io::Write;
use unicode_width::UnicodeWidthStr;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ForeignViewportMessages {
    pub terminal_grid: &'static str,
}

impl ForeignViewportMessages {
    pub fn hint(&self, cols: u16, rows: u16) -> Option<ForeignViewportHint> {
        let mut bytes = [0_u8; FOREIGN_VIEWPORT_HINT_CAPACITY];
        let len = {
            let mut cursor = Cursor::new(bytes.as_mut_slice());
            write!(&mut cursor, "{} ({cols}x{rows})", self.terminal_grid).ok()?;
            cursor.position() as usize
        };
        Some(ForeignViewportHint { bytes, len })
    }

    pub fn hint_width(&self, cols: u16, rows: u16) -> usize {
        self.terminal_grid.width() + 4 + decimal_width(cols) + decimal_width(rows)
    }
}

pub(super) const ENGLISH: ForeignViewportMessages =
    ForeignViewportMessages { terminal_grid: "terminal grid" };

pub(super) const JAPANESE: ForeignViewportMessages =
    ForeignViewportMessages { terminal_grid: "端末グリッド" };
