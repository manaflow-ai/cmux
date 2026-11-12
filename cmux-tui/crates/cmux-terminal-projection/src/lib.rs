//! A terminal's projection on a phone that does not size it.
//!
//! The host's PTY keeps its own grid (the Mac pane's). The phone keeps a VT
//! model at that grid, fed the PTY's bytes ([`terminal::Terminal`]), and
//! shows a view of it at its own grid ([`project::View`]):
//!
//! - **Primary screen** (a shell, an inline TUI such as Claude Code): every
//!   logical line (soft-wrapped host rows joined) is re-wrapped at the
//!   phone's columns and written as VT bytes for a terminal of the phone's
//!   grid. Each feed repaints from the first row that changed, so output and
//!   echoes reach the phone as a few bytes; the cursor is mapped through the
//!   wrap. A change in rows the phone's terminal already scrolled away
//!   (`clear` with its scrollback, a host resize) starts the phone's
//!   terminal over from its scrollback and screen.
//! - **Alternate screen** (vim, htop): positioned cells cannot be re-wrapped.
//!   The bytes pass through unchanged ([`Segment::Raw`]), and the caller
//!   decides how to show the host's grid (claim the phone's size while it is
//!   the active device, or pan).
//!
//! The phone's own terminal answers device queries; cursor position and
//! text area reports are answered here in host cells
//! ([`Projection::take_replies`]).

pub mod project;
pub mod style;
pub mod terminal;

pub use project::{Paint, View};
pub use terminal::Terminal;

/// The scrollback kept, in host rows.
pub const DEFAULT_HISTORY_LIMIT: usize = 10_000;

/// What one feed gives the phone's terminal, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    /// Bytes for the phone's terminal as it is (a repaint of what changed).
    Paint(Vec<u8>),
    /// The phone's terminal starts over (the caller sends `ESC c` first),
    /// then these bytes: its scrollback and screen at the phone's grid.
    Reset(Vec<u8>),
    /// The program switched screens here.
    Alternate(bool),
    /// On the alternate screen: the program's bytes, unchanged.
    Raw(Vec<u8>),
}

/// One terminal's projection.
pub struct Projection {
    term: Terminal,
    view: Option<View>,
    /// How far up the reader is: phone rows from the end of the phone's
    /// document to the top of what they read (0: at the bottom).
    reader_rows_from_end: usize,
}

impl Projection {
    /// A projection of a host terminal of `host_cols` x `host_rows`. Nothing
    /// is painted before [`Projection::set_viewport`].
    pub fn new(host_cols: usize, host_rows: usize, history_limit: usize) -> Projection {
        Projection {
            term: Terminal::new(host_cols, host_rows, history_limit),
            view: None,
            reader_rows_from_end: 0,
        }
    }

    pub fn is_alternate(&self) -> bool {
        self.term.is_alternate()
    }

    pub fn host_grid(&self) -> (usize, usize) {
        (self.term.cols, self.term.rows)
    }

    pub fn viewport(&self) -> Option<(usize, usize)> {
        self.view.as_ref().map(|v| (v.cols, v.rows))
    }

    /// The host PTY's grid changed. The host replays its screen after a
    /// resize; the phone's terminal starts over at the next paint.
    pub fn set_host_grid(&mut self, cols: usize, rows: usize) {
        self.term.resize(cols, rows);
    }

    /// Where the reader is (phone rows from the end of the phone's
    /// document to the top of the screen they read; 0 at the bottom). A
    /// viewport change keeps their lines in the window it paints.
    pub fn set_reader_rows_from_end(&mut self, rows: usize) {
        self.reader_rows_from_end = rows;
    }

    /// The phone's grid. A change starts the phone's terminal over, painted
    /// at once (on the primary screen): the host's screen and
    /// [`project::TAIL_SCREENS`] screens of scrollback above it, plus the
    /// lines the reader is on, re-wrapped at the new width. The cost is that
    /// window, not the scrollback; older rows come with
    /// [`Projection::load_older`] as the reader scrolls up to them.
    pub fn set_viewport(&mut self, cols: usize, rows: usize) -> Vec<Segment> {
        let (cols, rows) = (cols.max(2), rows.max(1));
        if self.viewport() == Some((cols, rows)) {
            return Vec::new();
        }
        let mut view = View::new(cols, rows);
        if let Some(old) = &self.view {
            view.bytes_out = old.bytes_out;
            view.resets = old.resets;
            // The reader's lines (in the old view's rows, above its live
            // part) and a screen above them stay in the window.
            let live = old.live_rows();
            if self.reader_rows_from_end > live {
                let back = self.reader_rows_from_end - live + old.rows;
                let from = project::rows_back(&self.term, self.term.history.len(), old.cols, back);
                view.keep_from = Some(self.term.history_dropped + from as u64);
            }
        }
        self.view = Some(view);
        if self.term.is_alternate() {
            return Vec::new();
        }
        self.paint().into_iter().collect()
    }

    /// Host scrollback rows the phone's terminal does not hold yet (older
    /// than its window).
    pub fn older_rows(&self) -> usize {
        self.view.as_ref().map_or(0, |v| v.older_rows(&self.term))
    }

    /// The reader scrolled up to the oldest row the phone holds: `host_rows`
    /// more of the scrollback, as a reset (the page keeps the reader's place
    /// across it). Empty when the phone holds all of it, or on the
    /// alternate screen.
    pub fn load_older(&mut self, host_rows: usize) -> Vec<Segment> {
        let Some(view) = &mut self.view else { return Vec::new() };
        if self.term.is_alternate() || !view.load_older(&self.term, host_rows) {
            return Vec::new();
        }
        self.paint().into_iter().collect()
    }

    /// The next paint starts the phone's terminal over.
    pub fn request_reset(&mut self) {
        if let Some(view) = &mut self.view {
            view.request_reset();
        }
    }

    /// The program's bytes. With `paint` false, the model takes them and the
    /// phone is painted at the next feed (a reset whose replay follows).
    pub fn feed(&mut self, bytes: &[u8], paint: bool) -> Vec<Segment> {
        let mut segments = Vec::new();
        let mut raw_start: Option<usize> = self.term.is_alternate().then_some(0);
        for (i, &byte) in bytes.iter().enumerate() {
            let was = self.term.is_alternate();
            self.term.advance(byte);
            let now = self.term.is_alternate();
            if was == now {
                continue;
            }
            if now {
                // Entering: what the primary screen drew so far, then the switch.
                if let Some(paint) = self.paint() {
                    segments.push(paint);
                }
                self.term.passthrough.clear();
                segments.push(Segment::Alternate(true));
                // The mode it was entered with (47 and 1047 neither save the
                // cursor nor clear as 1049 does).
                segments.push(Segment::Raw(format!("\x1b[?{}h", self.term.alt_mode).into_bytes()));
                raw_start = Some(i + 1);
            } else {
                let start = raw_start.take().unwrap_or(0);
                segments.push(Segment::Raw(bytes[start..=i].to_vec()));
                self.term.passthrough.clear();
                segments.push(Segment::Alternate(false));
                // The phone's primary screen was drawn at another grid meanwhile.
                self.request_reset();
            }
        }
        if let Some(start) = raw_start {
            if start < bytes.len() {
                segments.push(Segment::Raw(bytes[start..].to_vec()));
            }
            self.term.passthrough.clear();
        } else if paint && let Some(paint) = self.paint() {
            segments.push(paint);
        }
        segments
    }

    /// Answers for the program (cursor and text area reports, in host cells).
    pub fn take_replies(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.term.replies)
    }

    /// Paints the primary screen now (nil: nothing changed, or no viewport).
    pub fn paint(&mut self) -> Option<Segment> {
        let view = self.view.as_mut()?;
        let passthrough = std::mem::take(&mut self.term.passthrough);
        match view.paint(&mut self.term, &passthrough)? {
            Paint::Update(bytes) => Some(Segment::Paint(bytes)),
            Paint::Reset(bytes) => Some(Segment::Reset(bytes)),
        }
    }

    /// Bytes painted and resets since creation.
    pub fn stats(&self) -> (u64, u64) {
        self.view.as_ref().map_or((0, 0), |v| (v.bytes_out, v.resets))
    }

    pub fn terminal(&self) -> &Terminal {
        &self.term
    }
}
