//! Stable row markers for the primary screen's history and the reads that
//! use them (`terminal.history`, `terminal.read_range`).
//!
//! A row marker is `evicted_rows + screen_row`: the number of primary-screen
//! rows ever evicted from the top of scrollback plus the row's screen
//! coordinate (0 = oldest retained row). New output does not move a marker;
//! eviction makes the oldest markers unreachable (`range_evicted`). A reflow,
//! or a write the counter cannot account for (the pinned row itself was
//! evicted, or primary history was evicted while returning from the
//! alternate screen) starts a new marker epoch, and markers of an older
//! epoch are rejected.
//!
//! Counting: before each write a tracked grid ref is pinned to the newest
//! primary history row. After the write, that row's screen coordinate tells
//! how many rows were evicted above it (`rows_before - 1 - y_after`).

use super::*;
use crate::snapshot::{SnapshotHistoryPage, SnapshotPhase, primary_history_pages};

static NEXT_MARKER_EPOCH: AtomicU64 = AtomicU64::new(1);

pub(super) struct HistoryMarkers {
    epoch: u64,
    evicted_rows: u64,
    probe: sys::GhosttyTrackedGridRef,
    /// `(screen before the write, primary history rows before the write)`.
    pending: Option<(Screen, u64)>,
}

impl Default for HistoryMarkers {
    fn default() -> Self {
        Self {
            epoch: NEXT_MARKER_EPOCH.fetch_add(1, Ordering::Relaxed),
            evicted_rows: 0,
            probe: ptr::null_mut(),
            pending: None,
        }
    }
}

impl HistoryMarkers {
    fn new_epoch(&mut self) {
        self.epoch = NEXT_MARKER_EPOCH.fetch_add(1, Ordering::Relaxed);
        self.evicted_rows = 0;
    }

    /// Free the probe. Must run before the terminal is freed.
    pub(super) fn release(&mut self) {
        unsafe { sys::ghostty_tracked_grid_ref_free(self.probe) };
        self.probe = ptr::null_mut();
    }
}

/// One page of `terminal.history`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPage {
    /// Marker of the page's first (oldest) row.
    pub marker: u64,
    pub rows: u16,
    /// One GHOSTSNP PAGE record (header, payload, CRC).
    pub record: Vec<u8>,
}

/// Result of [`Terminal::history_pages`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPages {
    pub marker_epoch: u64,
    /// Newest first.
    pub pages: Vec<HistoryPage>,
    /// Pass as `before` for the next older pages; `None` when done.
    pub next_before: Option<u64>,
    pub done: bool,
}

/// Why a marker read failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkerError {
    /// The marker's rows left scrollback, or its epoch ended.
    RangeEvicted,
    /// The marker is past the end of the screen or the range is reversed.
    Invalid,
    /// libghostty-vt failed.
    Vt(Error),
}

impl Terminal {
    pub(super) fn history_markers_before_write(&mut self) {
        let screen = self.active_screen();
        let rows = if screen == Screen::Primary { self.scrollback_rows() as u64 } else { 0 };
        // Pin the newest history row: only eviction moves it (scrolling down,
        // reverse index or inserted lines move active rows, not history).
        if rows > 0 {
            let point = sys::GhosttyPoint {
                tag: sys::GHOSTTY_POINT_TAG_HISTORY,
                value: sys::GhosttyPointValue {
                    coordinate: sys::GhosttyPointCoordinate {
                        x: 0,
                        y: u32::try_from(rows - 1).unwrap_or(u32::MAX),
                    },
                },
            };
            let markers = &mut self.history_markers;
            let pinned = if markers.probe.is_null() {
                check(unsafe {
                    sys::ghostty_terminal_grid_ref_track(self.raw, point, &mut markers.probe)
                })
            } else {
                check(unsafe { sys::ghostty_tracked_grid_ref_set(markers.probe, self.raw, point) })
            };
            if pinned.is_err() {
                markers.release();
            }
        }
        self.history_markers.pending = Some((screen, rows));
    }

    pub(super) fn history_markers_after_write(&mut self) {
        let Some((before, rows_before)) = self.history_markers.pending.take() else { return };
        match before {
            // The probe resolves against the primary screen that owns it, so
            // this also covers a write that switched to the alternate screen.
            Screen::Primary if rows_before > 0 => {
                let mut y = sys::GhosttyPointCoordinate::default();
                let probe = self.history_markers.probe;
                let located = !probe.is_null()
                    && unsafe { sys::ghostty_tracked_grid_ref_has_value(probe) }
                    && check(unsafe {
                        sys::ghostty_tracked_grid_ref_point(
                            probe,
                            sys::GHOSTTY_POINT_TAG_SCREEN,
                            &mut y,
                        )
                    })
                    .is_ok();
                match located.then(|| (rows_before - 1).checked_sub(u64::from(y.y))).flatten() {
                    Some(evicted) => self.history_markers.evicted_rows += evicted,
                    None => self.history_markers.new_epoch(),
                }
            }
            // No history before the write: rows evicted during it never had
            // a marker, so the numbering stays consistent.
            Screen::Primary => {}
            // Output on the alternate screen cannot evict primary history,
            // but output after a switch back in the same write can. The
            // oldest-row anchor tells whether any primary row was evicted.
            Screen::Alternate => {
                let anchor = self.history_anchor;
                if !anchor.is_null() && !unsafe { sys::ghostty_tracked_grid_ref_has_value(anchor) }
                {
                    self.history_markers.new_epoch();
                }
            }
        }
    }

    /// A reflow renumbers every row: markers of the old layout end.
    pub(super) fn history_markers_reflowed(&mut self) {
        self.history_markers.new_epoch();
    }

    /// The current marker epoch.
    pub fn history_marker_epoch(&self) -> u64 {
        self.history_markers.epoch
    }

    /// Marker of primary screen row `screen_row` (0 = oldest retained row).
    pub fn history_marker(&self, screen_row: u64) -> u64 {
        self.history_markers.evicted_rows + screen_row
    }

    /// Screen row of a marker in the current epoch.
    pub fn history_marker_row(
        &self,
        epoch: Option<u64>,
        marker: u64,
    ) -> std::result::Result<u64, MarkerError> {
        if epoch.is_some_and(|epoch| epoch != self.history_markers.epoch) {
            return Err(MarkerError::RangeEvicted);
        }
        marker.checked_sub(self.history_markers.evicted_rows).ok_or(MarkerError::RangeEvicted)
    }

    /// Marker of the top row of the active area.
    pub fn active_top_marker(&self) -> u64 {
        self.history_marker(self.scrollback_rows() as u64)
    }

    /// GHOSTSNP HISTORY pages of the primary screen that start above
    /// `before` (absent: the top of the active area), newest first, until
    /// `max_bytes` of page records (always at least one page). A page that
    /// straddles `before` is included (overlap, never a gap); `next_before`
    /// values are page starts, so paging with them never overlaps.
    ///
    /// Cost: one COMPLETE encode of the scrollback under the caller's
    /// terminal lock per call.
    pub fn history_pages(
        &self,
        epoch: Option<u64>,
        before: Option<u64>,
        max_bytes: usize,
    ) -> std::result::Result<HistoryPages, MarkerError> {
        let before_row = match before {
            Some(marker) => self.history_marker_row(epoch, marker)?,
            None => u64::MAX,
        };
        let complete = self.encode_snapshot(SnapshotPhase::Complete).map_err(MarkerError::Vt)?;
        let all = primary_history_pages(&complete).map_err(MarkerError::Vt)?;
        let mut pages = Vec::new();
        let mut bytes = 0usize;
        let mut oldest: Option<SnapshotHistoryPage> = None;
        for page in all.into_iter().filter(|page| page.first_row < before_row) {
            if !pages.is_empty() && bytes + page.record.len() > max_bytes {
                break;
            }
            bytes += page.record.len();
            pages.push(HistoryPage {
                marker: self.history_marker(page.first_row),
                rows: page.rows,
                record: page.record.clone(),
            });
            oldest = Some(page);
        }
        let done = oldest.as_ref().is_none_or(|page| page.first_row == 0);
        Ok(HistoryPages {
            marker_epoch: self.history_markers.epoch,
            next_before: (!done).then(|| pages.last().map(|page| page.marker)).flatten(),
            pages,
            done,
        })
    }

    /// Text (`vt = false`, unwrapped lines joined with `\n`) or VT of the
    /// primary screen range `from..=to`, each `(marker, col)`.
    pub fn read_marker_range(
        &mut self,
        epoch: Option<u64>,
        from: (u64, u16),
        to: (u64, u16),
        vt: bool,
    ) -> std::result::Result<String, MarkerError> {
        if self.active_screen() != Screen::Primary {
            return Err(MarkerError::Invalid);
        }
        let start = self.history_marker_row(epoch, from.0)?;
        let end = self.history_marker_row(epoch, to.0)?;
        let total = self.scrollbar().map(|bar| bar.total).ok_or(MarkerError::Invalid)?;
        if start >= total || (end, to.1) < (start, from.1) {
            return Err(MarkerError::Invalid);
        }
        let end = end.min(total - 1);
        let tag = sys::GHOSTTY_POINT_TAG_SCREEN;
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self.grid_ref(tag, from.1, start).ok_or(MarkerError::Invalid)?,
            end: self.grid_ref(tag, to.1, end).ok_or(MarkerError::Invalid)?,
            rectangle: false,
        };
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: if vt {
                sys::GHOSTTY_FORMATTER_FORMAT_VT
            } else {
                sys::GHOSTTY_FORMATTER_FORMAT_PLAIN
            },
            unwrap: !vt,
            trim: !vt,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                ..Default::default()
            },
            selection: &selection,
        };
        let bytes = self.format(opts).map_err(MarkerError::Vt)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }
}

#[cfg(test)]
#[path = "terminal_history_tests.rs"]
mod tests;
