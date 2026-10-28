//! A terminal's screen and modes in a seqlock page.
//!
//! The worker writes the page; the daemon maps it read-only and reads it
//! with no request to the worker (a key encoder or `read-screen` never hops
//! to another process: p01-process-209 and -135). The page is one shared
//! segment the daemon creates ([`create_page`]) and passes to the worker
//! with the terminal's ring. Chrome's `base/synchronization/` has no
//! seqlock; the protocol is the classic one (Linux `include/linux/seqlock.h`):
//! the writer makes `seq` odd, stores the image, makes `seq` even; a reader
//! copies the image between two equal even reads of `seq`. Both sides reach
//! every word atomically (8-byte words), so a torn copy is only ever
//! discarded, never undefined. The reader treats the page as untrusted:
//! it decodes the copy with every length and offset
//! checked against the copy itself.
//!
//! Layout 1, little endian, every section 8-byte aligned:
//!
//! ```text
//!   0 magic "CMVP" | layout u32
//!   8 seq u64
//!  16 status u8 | cursor flags u8 | cursor shape u8 | mouse format u8 | modes u32
//!  24 parsed offset u64
//!  32 frame u64
//!  40 cols u16 | rows u16 | cursor x u16 | cursor y u16
//!  48 cell count u32 | text bytes u32
//!  56 needed bytes u64 (status TOO_SMALL)
//!  64 reserved, to 128
//! 128 row lengths: rows x u16
//!     cells: cell count x 32 bytes
//!     text: the cells' UTF-8, concatenated
//! ```
//!
//! A cell is `text offset u32 | text len u32 | fg u32 | bg u32 |
//! resolved fg u32 | resolved bg u32 | flags u16 | width u8 | underline
//! style u8 | reserved u32`.

use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::sync::atomic::{Ordering, fence};

use ghostty_vt::{
    Cell, CellWidth, ColorSpec, CursorInfo, CursorShape, MouseWireFormat, Rgb, Terminal,
    UnderlineStyle,
};

use crate::shm::{self, Mapping};

const MAGIC: [u8; 4] = *b"CMVP";
const LAYOUT: u32 = 1;
/// Header bytes before the row table.
pub const PAGE_HEADER: usize = 128;
/// Bytes of one cell record.
pub const CELL_BYTES: usize = 32;
/// Rows or columns a page may describe (Ghostty's grid is far below it).
pub const MAX_GRID: u16 = 4096;
/// The largest page the daemon makes or a reader maps.
pub const MAX_PAGE_BYTES: usize = 64 << 20;
const OFF_SEQ: usize = 8;
/// Reads that may see a writer in progress before [`PageError::Busy`].
const READ_ATTEMPTS: u32 = 64;

const STATUS_SCREEN: u8 = 1;
const STATUS_TOO_SMALL: u8 = 2;
const CURSOR_IN_VIEW: u8 = 1;
const CURSOR_BLINKING: u8 = 2;
const FLAG_UNDERLINE: u16 = 0x0100;

/// Terminal modes an encoder needs without asking the worker.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Modes(pub u32);

impl Modes {
    /// DECCKM (DEC 1): cursor keys send application sequences.
    pub const CURSOR_KEYS: u32 = 1 << 0;
    /// DECKPAM (DEC 66): keypad application mode.
    pub const KEYPAD_APPLICATION: u32 = 1 << 1;
    /// Bracketed paste (DEC 2004).
    pub const BRACKETED_PASTE: u32 = 1 << 2;
    /// Focus reporting (DEC 1004).
    pub const FOCUS_EVENTS: u32 = 1 << 3;
    /// The alternate screen is active.
    pub const ALT_SCREEN: u32 = 1 << 4;
    /// Mouse tracking: X10 (DEC 9).
    pub const MOUSE_X10: u32 = 1 << 5;
    /// Mouse tracking: normal (DEC 1000).
    pub const MOUSE_NORMAL: u32 = 1 << 6;
    /// Mouse tracking: button events (DEC 1002).
    pub const MOUSE_BUTTON: u32 = 1 << 7;
    /// Mouse tracking: any event (DEC 1003).
    pub const MOUSE_ANY: u32 = 1 << 8;
    /// DECTCEM (DEC 25): the cursor is shown.
    pub const CURSOR_VISIBLE: u32 = 1 << 9;

    const DEC: [(u16, u32); 9] = [
        (1, Self::CURSOR_KEYS),
        (66, Self::KEYPAD_APPLICATION),
        (2004, Self::BRACKETED_PASTE),
        (1004, Self::FOCUS_EVENTS),
        (9, Self::MOUSE_X10),
        (1000, Self::MOUSE_NORMAL),
        (1002, Self::MOUSE_BUTTON),
        (1003, Self::MOUSE_ANY),
        (25, Self::CURSOR_VISIBLE),
    ];

    /// The modes `terminal` has now.
    pub fn of(terminal: &Terminal) -> Self {
        let mut bits = Self::DEC
            .iter()
            .filter(|(mode, _)| terminal.mode(*mode, false))
            .fold(0, |bits, (_, bit)| bits | bit);
        if terminal.active_screen() == ghostty_vt::Screen::Alternate {
            bits |= Self::ALT_SCREEN;
        }
        Self(bits)
    }

    pub fn contains(self, bit: u32) -> bool {
        self.0 & bit == bit
    }
}

/// One decoded page: what the daemon reads instead of asking the worker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Screen {
    /// The ring offset the parser had consumed when this screen was made.
    pub parsed: u64,
    /// The worker's publish count for this terminal.
    pub frame: u64,
    pub cols: u16,
    pub rows: u16,
    /// The cursor when it is visible and inside the viewport.
    pub cursor: Option<CursorInfo>,
    /// The cursor's shape and blink, even when hidden.
    pub cursor_visual: (CursorShape, bool),
    pub modes: Modes,
    pub mouse_format: MouseWireFormat,
    /// The viewport, top row first.
    pub cells: Vec<Vec<Cell>>,
}

/// A page the reader could not turn into a [`Screen`].
#[derive(Debug, PartialEq, Eq)]
pub enum PageError {
    /// The worker has not published this page yet.
    NotPublished,
    /// The writer was inside a publish on every attempt.
    Busy,
    /// The page is too small for the screen: the worker needs `needed` bytes.
    TooSmall { needed: u64 },
    /// The copy broke a layout rule (a bad message: the broker ends the
    /// worker).
    Corrupt(&'static str),
}

impl std::fmt::Display for PageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotPublished => f.write_str("screen page not published yet"),
            Self::Busy => f.write_str("screen page writer busy"),
            Self::TooSmall { needed } => write!(f, "screen page too small: {needed} bytes needed"),
            Self::Corrupt(what) => write!(f, "corrupt screen page: {what}"),
        }
    }
}

impl std::error::Error for PageError {}

/// A new zeroed page segment of `len` bytes for one terminal (the daemon's
/// side: the worker cannot make shared memory once sandboxed).
pub fn create_page(len: usize) -> io::Result<OwnedFd> {
    if !(PAGE_HEADER..=MAX_PAGE_BYTES).contains(&len) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "screen page length"));
    }
    shm::create_segment(len)
}

/// The page bytes a `cols` x `rows` screen of single-byte cells needs, with
/// room for multi-byte text: the daemon's first size, grown on TOO_SMALL.
pub fn page_len_for(cols: u16, rows: u16) -> usize {
    let cells = usize::from(cols.max(1)) * usize::from(rows.max(1));
    let len = PAGE_HEADER + pad8(usize::from(rows.max(1)) * 2) + cells * CELL_BYTES + cells * 4;
    len.next_multiple_of(4096)
}

fn pad8(len: usize) -> usize {
    len.next_multiple_of(8)
}

/// Builds one page image from a screen walk (the worker's side).
#[derive(Debug, Default)]
pub struct PageEncoder {
    rows: Vec<u16>,
    cells: Vec<u8>,
    text: Vec<u8>,
    image: Vec<u8>,
}

/// The header fields of one image.
#[derive(Clone, Copy, Debug)]
pub struct PageMeta {
    pub parsed: u64,
    pub frame: u64,
    pub cols: u16,
    pub cursor: Option<CursorInfo>,
    pub cursor_visual: (CursorShape, bool),
    pub modes: Modes,
    pub mouse_format: MouseWireFormat,
}

impl PageEncoder {
    /// Start a new image.
    pub fn begin(&mut self) {
        self.rows.clear();
        self.cells.clear();
        self.text.clear();
    }

    /// Append the next row's cells.
    pub fn push_row(&mut self, cells: &[Cell]) {
        self.rows.push(u16::try_from(cells.len()).unwrap_or(u16::MAX));
        for cell in cells.iter().take(usize::from(u16::MAX)) {
            let offset = u32::try_from(self.text.len()).unwrap_or(u32::MAX);
            self.text.extend_from_slice(cell.text.as_bytes());
            let len = u32::try_from(cell.text.len()).unwrap_or(u32::MAX);
            self.cells.extend_from_slice(&offset.to_le_bytes());
            self.cells.extend_from_slice(&len.to_le_bytes());
            self.cells.extend_from_slice(&encode_spec(cell.fg).to_le_bytes());
            self.cells.extend_from_slice(&encode_spec(cell.bg).to_le_bytes());
            self.cells.extend_from_slice(&encode_rgb(cell.resolved_fg).to_le_bytes());
            self.cells.extend_from_slice(&encode_rgb(cell.resolved_bg).to_le_bytes());
            let flags = cell.attrs() | if cell.underline { FLAG_UNDERLINE } else { 0 };
            self.cells.extend_from_slice(&flags.to_le_bytes());
            self.cells.push(encode_width(cell.width));
            self.cells.push(encode_underline(cell.underline_style));
            self.cells.extend_from_slice(&[0; 4]);
        }
    }

    /// The finished image for `meta`, its length a multiple of 8.
    pub fn finish(&mut self, meta: &PageMeta) -> &[u8] {
        let image = &mut self.image;
        image.clear();
        image.extend_from_slice(&MAGIC);
        image.extend_from_slice(&LAYOUT.to_le_bytes());
        image.extend_from_slice(&0u64.to_le_bytes()); // seq: the writer's word
        let mut cursor_flags = 0;
        if meta.cursor.is_some() {
            cursor_flags |= CURSOR_IN_VIEW;
        }
        if meta.cursor_visual.1 {
            cursor_flags |= CURSOR_BLINKING;
        }
        image.extend_from_slice(&[
            STATUS_SCREEN,
            cursor_flags,
            encode_shape(meta.cursor_visual.0),
            encode_mouse(meta.mouse_format),
        ]);
        image.extend_from_slice(&meta.modes.0.to_le_bytes());
        image.extend_from_slice(&meta.parsed.to_le_bytes());
        image.extend_from_slice(&meta.frame.to_le_bytes());
        let (x, y) = meta.cursor.map_or((0, 0), |cursor| (cursor.x, cursor.y));
        for value in [meta.cols, u16::try_from(self.rows.len()).unwrap_or(u16::MAX), x, y] {
            image.extend_from_slice(&value.to_le_bytes());
        }
        let cell_count = u32::try_from(self.cells.len() / CELL_BYTES).unwrap_or(u32::MAX);
        image.extend_from_slice(&cell_count.to_le_bytes());
        image.extend_from_slice(&u32::try_from(self.text.len()).unwrap_or(u32::MAX).to_le_bytes());
        image.extend_from_slice(&0u64.to_le_bytes()); // needed
        image.resize(PAGE_HEADER, 0);
        for row in &self.rows {
            image.extend_from_slice(&row.to_le_bytes());
        }
        image.resize(pad8(image.len()), 0);
        image.extend_from_slice(&self.cells);
        image.extend_from_slice(&self.text);
        image.resize(pad8(image.len()), 0);
        &self.image
    }
}

/// The header of `image`, saying the page needs `needed` bytes and
/// holding no rows.
fn too_small_image(image: &[u8], needed: usize) -> Vec<u8> {
    let mut header = image[..PAGE_HEADER.min(image.len())].to_vec();
    header.resize(PAGE_HEADER, 0);
    header[16] = STATUS_TOO_SMALL;
    header[42..44].copy_from_slice(&0u16.to_le_bytes());
    header[48..56].copy_from_slice(&[0; 8]);
    header[56..64].copy_from_slice(&(needed as u64).to_le_bytes());
    header
}

/// The worker's writable mapping of a page.
#[derive(Debug)]
pub struct PageWriter {
    map: Mapping,
    seq: u64,
}

/// What a [`PageWriter::publish`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Published {
    Screen,
    /// The image did not fit: the page says so, and the daemon should
    /// pass a page of at least `needed` bytes.
    TooSmall {
        needed: usize,
    },
}

impl PageWriter {
    /// Map `page` (`len` bytes) writable. A page an earlier worker wrote
    /// continues its sequence.
    pub fn open(page: OwnedFd, len: usize) -> io::Result<Self> {
        if !(PAGE_HEADER..=MAX_PAGE_BYTES).contains(&len) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "screen page length"));
        }
        let map = Mapping::map(page.as_fd(), len, true)?;
        let seq = map.word(OFF_SEQ).map_or(0, |word| word.load(Ordering::Relaxed)) & !1;
        Ok(Self { map, seq })
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.len() == 0
    }

    /// Store `image` (from [`PageEncoder::finish`]) under the seqlock, or
    /// the TOO_SMALL header when it does not fit.
    pub fn publish(&mut self, image: &[u8]) -> Published {
        if image.len() > self.map.len() {
            let needed = image.len();
            self.store(&too_small_image(image, needed));
            return Published::TooSmall { needed };
        }
        self.store(image);
        Published::Screen
    }

    fn store(&mut self, image: &[u8]) {
        let Some(seq) = self.map.word(OFF_SEQ) else { return };
        let odd = self.seq.wrapping_add(1);
        seq.store(odd, Ordering::Relaxed);
        // No data store becomes visible before the odd sequence.
        fence(Ordering::Release);
        for (index, chunk) in image.chunks_exact(8).enumerate() {
            let offset = index * 8;
            if offset == OFF_SEQ {
                continue;
            }
            if let Some(word) = self.map.word(offset) {
                let mut bytes = [0u8; 8];
                bytes.copy_from_slice(chunk);
                word.store(u64::from_le_bytes(bytes), Ordering::Relaxed);
            }
        }
        self.seq = odd.wrapping_add(1);
        seq.store(self.seq, Ordering::Release);
    }
}

/// The daemon's read-only mapping of a page.
#[derive(Debug)]
pub struct PageReader {
    map: Mapping,
    copy: Vec<u8>,
}

impl PageReader {
    /// Map `page` (`len` bytes, as created) read-only.
    pub fn open(page: &OwnedFd, len: usize) -> io::Result<Self> {
        if !(PAGE_HEADER..=MAX_PAGE_BYTES).contains(&len) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "screen page length"));
        }
        Ok(Self { map: Mapping::map(page.as_fd(), len, false)?, copy: Vec::new() })
    }

    /// Copy the page between two equal even sequence reads, then decode.
    pub fn read(&mut self) -> Result<Screen, PageError> {
        let Some(seq_word) = self.map.word(OFF_SEQ) else {
            return Err(PageError::Corrupt("page shorter than its header"));
        };
        for _ in 0..READ_ATTEMPTS {
            let before = seq_word.load(Ordering::Acquire);
            if before == 0 {
                return Err(PageError::NotPublished);
            }
            if before & 1 == 1 {
                std::hint::spin_loop();
                continue;
            }
            self.copy.clear();
            copy_words(&self.map, 0, PAGE_HEADER, &mut self.copy);
            let body = body_len(&self.copy).min(self.map.len() - PAGE_HEADER);
            copy_words(&self.map, PAGE_HEADER, body, &mut self.copy);
            // The copies above happen before the second sequence read.
            fence(Ordering::Acquire);
            if seq_word.load(Ordering::Relaxed) == before {
                return decode(&self.copy);
            }
        }
        Err(PageError::Busy)
    }
}

fn copy_words(map: &Mapping, from: usize, len: usize, out: &mut Vec<u8>) {
    for offset in (from..from + pad8(len)).step_by(8) {
        let value = map.word(offset).map_or(0, |word| word.load(Ordering::Relaxed));
        out.extend_from_slice(&value.to_le_bytes());
    }
}

/// The body bytes a header claims (saturating: the caller clamps it).
fn body_len(header: &[u8]) -> usize {
    let rows = usize::from(Fields { bytes: header, at: 42 }.u16().unwrap_or(0));
    let mut counts = Fields { bytes: header, at: 48 };
    let cells = counts.u32().unwrap_or(0) as usize;
    let text = counts.u32().unwrap_or(0) as usize;
    pad8(rows * 2).saturating_add(cells.saturating_mul(CELL_BYTES)).saturating_add(pad8(text))
}

/// A little-endian cursor over a copy.
struct Fields<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Fields<'_> {
    fn take<const N: usize>(&mut self) -> Option<[u8; N]> {
        let end = self.at.checked_add(N)?;
        let out = self.bytes.get(self.at..end)?.try_into().ok()?;
        self.at = end;
        Some(out)
    }

    fn u8(&mut self) -> Option<u8> {
        self.take::<1>().map(|[byte]| byte)
    }

    fn u16(&mut self) -> Option<u16> {
        self.take().map(u16::from_le_bytes)
    }

    fn u32(&mut self) -> Option<u32> {
        self.take().map(u32::from_le_bytes)
    }

    fn u64(&mut self) -> Option<u64> {
        self.take().map(u64::from_le_bytes)
    }
}

/// Decode a consistent copy. Every count, offset and enum is checked
/// against the copy: a bad page is an error, never an out-of-bounds read.
pub fn decode(copy: &[u8]) -> Result<Screen, PageError> {
    const SHORT: PageError = PageError::Corrupt("truncated header");
    let mut header = Fields { bytes: copy, at: 0 };
    let magic: [u8; 4] = header.take().ok_or(SHORT)?;
    if magic != MAGIC {
        return Err(PageError::Corrupt("magic"));
    }
    if header.u32().ok_or(SHORT)? != LAYOUT {
        return Err(PageError::Corrupt("layout"));
    }
    let _seq = header.u64().ok_or(SHORT)?;
    let status = header.u8().ok_or(SHORT)?;
    let cursor_flags = header.u8().ok_or(SHORT)?;
    let shape = decode_shape(header.u8().ok_or(SHORT)?)?;
    let mouse_format = decode_mouse(header.u8().ok_or(SHORT)?)?;
    let modes = Modes(header.u32().ok_or(SHORT)?);
    let parsed = header.u64().ok_or(SHORT)?;
    let frame = header.u64().ok_or(SHORT)?;
    let cols = header.u16().ok_or(SHORT)?;
    let rows = header.u16().ok_or(SHORT)?;
    let cursor_x = header.u16().ok_or(SHORT)?;
    let cursor_y = header.u16().ok_or(SHORT)?;
    let cell_count = header.u32().ok_or(SHORT)? as usize;
    let text_len = header.u32().ok_or(SHORT)? as usize;
    let needed = header.u64().ok_or(SHORT)?;
    match status {
        STATUS_SCREEN => {}
        STATUS_TOO_SMALL => return Err(PageError::TooSmall { needed }),
        _ => return Err(PageError::Corrupt("status")),
    }
    if cols > MAX_GRID || rows > MAX_GRID {
        return Err(PageError::Corrupt("grid size"));
    }
    let blinking = cursor_flags & CURSOR_BLINKING != 0;
    let cursor = (cursor_flags & CURSOR_IN_VIEW != 0).then_some(CursorInfo {
        x: cursor_x,
        y: cursor_y,
        shape,
        blinking,
    });
    if cursor.is_some_and(|cursor| cursor.x >= cols || cursor.y >= rows) {
        return Err(PageError::Corrupt("cursor outside the grid"));
    }

    let rows_at = PAGE_HEADER;
    let cells_at = rows_at + pad8(usize::from(rows) * 2);
    let text_at = cell_count
        .checked_mul(CELL_BYTES)
        .and_then(|len| cells_at.checked_add(len))
        .ok_or(PageError::Corrupt("cell count"))?;
    let text_end = text_at.checked_add(text_len).ok_or(PageError::Corrupt("text length"))?;
    if text_end > copy.len() {
        return Err(PageError::Corrupt("sections past the page"));
    }
    let text = &copy[text_at..text_end];
    let mut row_lengths = Fields { bytes: copy, at: rows_at };
    let mut cells = Fields { bytes: copy, at: cells_at };
    let mut remaining = cell_count;
    let mut grid = Vec::with_capacity(usize::from(rows));
    for _ in 0..rows {
        let len = usize::from(row_lengths.u16().ok_or(PageError::Corrupt("row table"))?);
        if len > usize::from(cols) || len > remaining {
            return Err(PageError::Corrupt("row length"));
        }
        remaining -= len;
        let mut row = Vec::with_capacity(len);
        for _ in 0..len {
            row.push(decode_cell(&mut cells, text)?);
        }
        grid.push(row);
    }
    if remaining != 0 {
        return Err(PageError::Corrupt("cells outside the rows"));
    }
    Ok(Screen {
        parsed,
        frame,
        cols,
        rows,
        cursor,
        cursor_visual: (shape, blinking),
        modes,
        mouse_format,
        cells: grid,
    })
}

fn decode_cell(fields: &mut Fields<'_>, text: &[u8]) -> Result<Cell, PageError> {
    const SHORT: PageError = PageError::Corrupt("truncated cell");
    let offset = fields.u32().ok_or(SHORT)? as usize;
    let len = fields.u32().ok_or(SHORT)? as usize;
    let fg = decode_spec(fields.u32().ok_or(SHORT)?)?;
    let bg = decode_spec(fields.u32().ok_or(SHORT)?)?;
    let resolved_fg = decode_rgb(fields.u32().ok_or(SHORT)?)?;
    let resolved_bg = decode_rgb(fields.u32().ok_or(SHORT)?)?;
    let flags = fields.u16().ok_or(SHORT)?;
    let width = decode_width(fields.u8().ok_or(SHORT)?)?;
    let underline_style = decode_underline(fields.u8().ok_or(SHORT)?)?;
    let _reserved = fields.u32().ok_or(SHORT)?;
    let bytes = offset
        .checked_add(len)
        .and_then(|end| text.get(offset..end))
        .ok_or(PageError::Corrupt("cell text outside the text"))?;
    let text = std::str::from_utf8(bytes).map_err(|_| PageError::Corrupt("cell text UTF-8"))?;
    Ok(Cell {
        text: text.to_owned(),
        width,
        fg,
        bg,
        resolved_fg,
        resolved_bg,
        bold: flags & ghostty_vt::ATTR_BOLD != 0,
        faint: flags & ghostty_vt::ATTR_FAINT != 0,
        italic: flags & ghostty_vt::ATTR_ITALIC != 0,
        underline: flags & FLAG_UNDERLINE != 0,
        underline_style,
        strikethrough: flags & ghostty_vt::ATTR_STRIKETHROUGH != 0,
        inverse: flags & ghostty_vt::ATTR_INVERSE != 0,
        blink: flags & ghostty_vt::ATTR_BLINK != 0,
        invisible: flags & ghostty_vt::ATTR_INVISIBLE != 0,
    })
}

fn rgb_bits(rgb: Rgb) -> u32 {
    (u32::from(rgb.r) << 16) | (u32::from(rgb.g) << 8) | u32::from(rgb.b)
}

fn bits_rgb(bits: u32) -> Rgb {
    Rgb { r: (bits >> 16) as u8, g: (bits >> 8) as u8, b: bits as u8 }
}

fn encode_spec(spec: ColorSpec) -> u32 {
    match spec {
        ColorSpec::Default => 0,
        ColorSpec::Palette(index) => (1 << 24) | u32::from(index),
        ColorSpec::Rgb(rgb) => (2 << 24) | rgb_bits(rgb),
    }
}

fn decode_spec(bits: u32) -> Result<ColorSpec, PageError> {
    match bits >> 24 {
        0 if bits == 0 => Ok(ColorSpec::Default),
        1 if bits & 0x00ff_ff00 == 0 => Ok(ColorSpec::Palette(bits as u8)),
        2 => Ok(ColorSpec::Rgb(bits_rgb(bits))),
        _ => Err(PageError::Corrupt("color")),
    }
}

fn encode_rgb(rgb: Option<Rgb>) -> u32 {
    rgb.map_or(0, |rgb| (1 << 24) | rgb_bits(rgb))
}

fn decode_rgb(bits: u32) -> Result<Option<Rgb>, PageError> {
    match bits >> 24 {
        0 if bits == 0 => Ok(None),
        1 => Ok(Some(bits_rgb(bits))),
        _ => Err(PageError::Corrupt("resolved color")),
    }
}

fn encode_width(width: CellWidth) -> u8 {
    match width {
        CellWidth::Narrow => 0,
        CellWidth::Wide => 1,
        CellWidth::SpacerTail => 2,
        CellWidth::SpacerHead => 3,
    }
}

fn decode_width(value: u8) -> Result<CellWidth, PageError> {
    Ok(match value {
        0 => CellWidth::Narrow,
        1 => CellWidth::Wide,
        2 => CellWidth::SpacerTail,
        3 => CellWidth::SpacerHead,
        _ => return Err(PageError::Corrupt("cell width")),
    })
}

fn encode_underline(style: Option<UnderlineStyle>) -> u8 {
    match style {
        None => 0,
        Some(UnderlineStyle::Single) => 1,
        Some(UnderlineStyle::Double) => 2,
        Some(UnderlineStyle::Curly) => 3,
        Some(UnderlineStyle::Dotted) => 4,
        Some(UnderlineStyle::Dashed) => 5,
    }
}

fn decode_underline(value: u8) -> Result<Option<UnderlineStyle>, PageError> {
    Ok(match value {
        0 => None,
        1 => Some(UnderlineStyle::Single),
        2 => Some(UnderlineStyle::Double),
        3 => Some(UnderlineStyle::Curly),
        4 => Some(UnderlineStyle::Dotted),
        5 => Some(UnderlineStyle::Dashed),
        _ => return Err(PageError::Corrupt("underline style")),
    })
}

fn encode_shape(shape: CursorShape) -> u8 {
    match shape {
        CursorShape::Bar => 0,
        CursorShape::Block => 1,
        CursorShape::Underline => 2,
        CursorShape::BlockHollow => 3,
    }
}

fn decode_shape(value: u8) -> Result<CursorShape, PageError> {
    Ok(match value {
        0 => CursorShape::Bar,
        1 => CursorShape::Block,
        2 => CursorShape::Underline,
        3 => CursorShape::BlockHollow,
        _ => return Err(PageError::Corrupt("cursor shape")),
    })
}

fn encode_mouse(format: MouseWireFormat) -> u8 {
    match format {
        MouseWireFormat::X10 => 0,
        MouseWireFormat::Utf8 => 1,
        MouseWireFormat::Sgr => 2,
        MouseWireFormat::Urxvt => 3,
        MouseWireFormat::SgrPixels => 4,
    }
}

fn decode_mouse(value: u8) -> Result<MouseWireFormat, PageError> {
    Ok(match value {
        0 => MouseWireFormat::X10,
        1 => MouseWireFormat::Utf8,
        2 => MouseWireFormat::Sgr,
        3 => MouseWireFormat::Urxvt,
        4 => MouseWireFormat::SgrPixels,
        _ => return Err(PageError::Corrupt("mouse format")),
    })
}

#[cfg(test)]
#[path = "screen_page_tests.rs"]
mod tests;
