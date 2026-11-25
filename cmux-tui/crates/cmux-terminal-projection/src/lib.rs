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
//!   wrap. A row the program laid out by the host's width (a right prompt
//!   or status at the last column, a header box padded to the edge) is laid
//!   out at the phone's width instead of broken in two: its padding shrinks
//!   ([`Projection::set_compact`]). A change in rows the phone's terminal already scrolled away
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

pub mod fit_policy;
pub mod held;
pub mod project;
pub mod style;
pub mod terminal;
pub mod unicode;
pub mod zoom;

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

/// What a vertical pan over the alternate screen does
/// ([`Projection::alt_pan`]): bytes the phone paints on its own surface
/// (nothing sent), then rows of wheel for the app on the Mac, as before
/// held rows (0: nothing goes to the Mac).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AltPan {
    pub paint: Vec<u8>,
    /// Rows of wheel for the app (positive: toward older content).
    pub forward_rows: f64,
}

/// One terminal's projection.
pub struct Projection {
    term: Terminal,
    view: Option<View>,
    /// How far up the reader is: phone rows from the end of the phone's
    /// document to the top of what they read (0: at the bottom).
    reader_rows_from_end: usize,
    /// Right-anchored rows are laid out at the phone's width
    /// ([`project::View::compact`]).
    compact: bool,
    /// How many held rows back the phone's surface shows the alternate
    /// screen (0: the app's live screen).
    alt_back: usize,
    /// The part of a row a pan moved that no row moved for yet.
    alt_fraction: f64,
    /// The rows back went to the app with a pan past the held rows: only
    /// what moves further goes, until the app's repaint shows live.
    alt_forwarded: bool,
}

impl Projection {
    /// A projection of a host terminal of `host_cols` x `host_rows`. Nothing
    /// is painted before [`Projection::set_viewport`].
    pub fn new(host_cols: usize, host_rows: usize, history_limit: usize) -> Projection {
        Projection {
            term: Terminal::new(host_cols, host_rows, history_limit),
            view: None,
            reader_rows_from_end: 0,
            compact: true,
            alt_back: 0,
            alt_fraction: 0.0,
            alt_forwarded: false,
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
        self.alt_back = 0;
        self.alt_forwarded = false;
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
        // The grid it resizes from: the phone's, or the host's at first.
        let old = match &self.view {
            Some(old) => Some((old.cols, old.rows, old.rows_below)),
            None => project::host_rows_below(&self.term)
                .map(|below| (self.term.cols, self.term.rows, below)),
        };
        self.set_viewport_from(cols, rows, old)
    }

    /// A new view at `cols` x `rows`, its grid's rows as a terminal resized
    /// from `old` (cols, rows, blank rows below the content) has them.
    fn set_viewport_from(
        &mut self,
        cols: usize,
        rows: usize,
        old: Option<(usize, usize, usize)>,
    ) -> Vec<Segment> {
        let mut view = View::new(cols, rows);
        view.compact = self.compact;
        view.set_rows_below(
            old.and_then(|old| {
                project::rows_below_after_resize(&self.term, self.compact, old, (cols, rows))
            }),
            self.term.screen_cleared,
        );
        if let Some(old) = &self.view {
            view.bytes_out = old.bytes_out;
            view.resets = old.resets;
            view.pushed_at_paint = old.pushed_at_paint;
            // The reader's lines (in the old view's rows, above its live
            // part) and a screen above them stay in the window.
            let live = old.live_rows();
            if self.reader_rows_from_end > live {
                let back = self.reader_rows_from_end - live + old.rows;
                let from = project::rows_back(
                    &self.term,
                    self.term.history.len(),
                    old.cols,
                    back,
                    old.compact,
                );
                view.keep_from = Some(self.term.history_dropped + from as u64);
            }
        }
        self.view = Some(view);
        if self.term.is_alternate() {
            return Vec::new();
        }
        self.paint().into_iter().collect()
    }

    /// Whether right-anchored rows wider than the phone (a right prompt, a
    /// header box padded to the host's edge) are laid out at the phone's
    /// width (on, the default) or re-wrapped like any line (off: the
    /// phone's lines are the host's exactly). A change repaints.
    pub fn set_compact(&mut self, compact: bool) -> Vec<Segment> {
        if self.compact == compact {
            return Vec::new();
        }
        self.compact = compact;
        let Some(old) = &self.view else { return Vec::new() };
        let (cols, rows, below) = (old.cols, old.rows, old.rows_below);
        // A fresh view at the same grid: its line cache was written the other way.
        self.view = None;
        self.set_viewport_from(cols, rows, Some((cols, rows, below)))
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

    /// The next paint starts the phone's terminal over: the host's reset
    /// (`TerminalProjectingSession` on iOS, at attach and every reconnect),
    /// whose replay rebuilds the model. The replay's rows were never
    /// streamed to the phone, so its reset paints the window
    /// ([`project::TAIL_SCREENS`] screens), not every row the replay pushed
    /// since the last paint (that was the whole scrollback on attach).
    pub fn request_reset(&mut self) {
        if let Some(view) = &mut self.view {
            view.request_reset();
            view.pushed_at_paint = None;
        }
    }

    /// The program's bytes. With `paint` false, the model takes them and the
    /// phone is painted at the next feed (a reset whose replay follows).
    pub fn feed(&mut self, bytes: &[u8], paint: bool) -> Vec<Segment> {
        let mut segments = Vec::new();
        // New output while the reader is back in the held rows (Claude
        // Code's spinner repaints several times a second while it works,
        // which is when one reads back): the reader stays where they are.
        // In one synchronized update the surface shows the live screen, so
        // the app's bytes draw on what they expect, takes them, then shows
        // the same held rows again. The reader's place is kept in rows ever
        // held, so rows held meanwhile do not move what they read. After a
        // pan past the held rows the app's answer is what they asked for:
        // that shows live.
        let reading = (self.alt_back > 0 && self.term.is_alternate() && !self.alt_forwarded)
            .then(|| self.term.held.pushed().saturating_sub(self.alt_back as u64));
        let mut sync_open = false;
        if reading.is_some() {
            let mut live = held::paint_live(&self.term);
            live.truncate(live.len() - b"\x1b[?2026l".len());
            segments.push(Segment::Raw(live));
            sync_open = true;
        } else {
            let live = self.alt_return_live();
            if !live.is_empty() {
                segments.push(Segment::Raw(live));
            }
        }
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
                let mut raw = bytes.get(start..=i).unwrap_or_default().to_vec();
                if std::mem::take(&mut sync_open) {
                    raw.extend_from_slice(b"\x1b[?2026l");
                }
                self.alt_back = 0;
                self.alt_fraction = 0.0;
                segments.push(Segment::Raw(raw));
                self.term.passthrough.clear();
                segments.push(Segment::Alternate(false));
                // The phone's primary screen was drawn at another grid
                // meanwhile (rows pushed since its last paint still paint).
                if let Some(view) = &mut self.view {
                    view.request_reset();
                }
            }
        }
        if let Some(start) = raw_start {
            if start < bytes.len() {
                segments.push(Segment::Raw(bytes.get(start..).unwrap_or_default().to_vec()));
            }
            self.term.passthrough.clear();
        } else if paint && let Some(paint) = self.paint() {
            segments.push(paint);
        }
        if self.term.is_alternate() {
            self.term.observe_held();
        }
        if std::mem::take(&mut sync_open) {
            match reading {
                Some(anchor) if self.term.is_alternate() && !self.term.held.is_empty() => {
                    let held = &self.term.held;
                    let back = held.pushed().saturating_sub(anchor) as usize;
                    self.alt_back = back.clamp(1, held.len());
                    segments.push(Segment::Raw(held::paint_back(&self.term, held, self.alt_back)));
                }
                _ => {
                    // What was held is gone (the app cleared it): live.
                    self.alt_back = 0;
                    self.alt_fraction = 0.0;
                    let mut end = held::paint_live(&self.term);
                    if !self.term.is_alternate() {
                        end = b"\x1b[?2026l".to_vec();
                    }
                    segments.push(Segment::Raw(end));
                }
            }
        }
        segments
    }

    /// A vertical pan of `rows` (positive: toward older content; a part of a
    /// row carries to the next pan) over the alternate screen. Within the
    /// held rows the phone paints them itself and nothing goes to the Mac.
    /// Past the oldest held row, the rest goes to the app as wheel rows (and
    /// the rows already back, so the app scrolls to where the reader is);
    /// past the live screen, likewise. An app that asked for mouse reports
    /// pans its held rows on the phone too, and gets the wheel past them.
    /// Everything goes to the app, as before held rows, on the primary
    /// screen and while nothing is held.
    pub fn alt_pan(&mut self, rows: f64) -> AltPan {
        if !rows.is_finite() || rows == 0.0 {
            return AltPan::default();
        }
        if !self.term.is_alternate() || (self.alt_back == 0 && self.term.held.is_empty()) {
            let paint = self.alt_return_live();
            self.alt_fraction = 0.0;
            return AltPan { paint, forward_rows: rows };
        }
        self.alt_fraction += rows;
        let whole = self.alt_fraction.trunc();
        self.alt_fraction -= whole;
        let step = whole.abs().min(1e9) as usize;
        if step == 0 {
            return AltPan::default();
        }
        let held = self.term.held.len();
        let before = self.alt_back;
        let mut forward = 0.0;
        if whole > 0.0 {
            let take = step.min(held.saturating_sub(self.alt_back));
            self.alt_back += take;
            let past = step - take;
            if past > 0 {
                let back = if self.alt_forwarded { 0 } else { self.alt_back };
                forward = (back + past) as f64;
                self.alt_forwarded = true;
            }
        } else {
            let take = step.min(self.alt_back);
            self.alt_back -= take;
            let past = step - take;
            if past > 0 {
                forward = -(past as f64);
            }
        }
        let paint = if self.alt_back == before {
            Vec::new()
        } else if self.alt_back == 0 {
            self.alt_forwarded = false;
            held::paint_live(&self.term)
        } else {
            held::paint_back(&self.term, &self.term.held, self.alt_back)
        };
        AltPan { paint, forward_rows: forward }
    }

    /// A key or a tap (or the app's answer to a pan past the held rows): the
    /// phone's surface shows the app's live screen again. The bytes that repaint it (empty when it
    /// already does).
    pub fn alt_return_live(&mut self) -> Vec<u8> {
        self.alt_fraction = 0.0;
        self.alt_forwarded = false;
        if self.alt_back == 0 {
            return Vec::new();
        }
        self.alt_back = 0;
        if !self.term.is_alternate() {
            return Vec::new();
        }
        held::paint_live(&self.term)
    }

    /// The bytes that paint the app's live screen, wherever the reader is
    /// (tests, the bench).
    pub fn alt_live_paint(&self) -> Vec<u8> {
        held::paint_live(&self.term)
    }

    /// How many held rows back the surface shows the alternate screen.
    pub fn alt_rows_back(&self) -> usize {
        self.alt_back
    }

    /// Rows held for a pan over the alternate screen, and their bytes.
    pub fn held(&self) -> (usize, usize) {
        (self.term.held.len(), self.term.held.bytes())
    }

    /// Paints what feeds with `paint` false changed since the last paint:
    /// a phone that takes several chunks before it draws paints them once.
    /// Nothing on the alternate screen (its bytes went through as they came).
    pub fn flush(&mut self) -> Vec<Segment> {
        if self.term.is_alternate() {
            return Vec::new();
        }
        self.paint().into_iter().collect()
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
