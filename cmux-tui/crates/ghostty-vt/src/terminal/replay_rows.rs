//! The text rows of a VT replay: one formatter segment per run of rows, with
//! every physical row kept in place and soft wraps re-created where the
//! target can print on into the continuation row.

use super::*;

impl Terminal {
    pub(super) fn vt_replay_text_range_bounded(
        &mut self,
        range: ReplayRowRange,
        placement_rows: &KittyReplayRowIndex,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<Option<ReplayText>> {
        match self.vt_replay_text_range_bounded_with(
            range,
            placement_rows,
            max_bytes,
            include_palette,
            true,
        ) {
            // The formatter emitted more row breaks than the joined soft
            // wraps predict: keep every row boundary instead, so no row moves.
            Err(Error::InvalidValue) if self.cols() != 0 && range.start <= range.end => self
                .vt_replay_text_range_bounded_with(
                    range,
                    placement_rows,
                    max_bytes,
                    include_palette,
                    false,
                ),
            other => other,
        }
    }

    /// Rows of `range` (all but its last) that end in a soft wrap the replay
    /// can re-create by printing on: the row ends in text at its last column
    /// and the next row continues it starting with text. Printing the next
    /// row's text right after such a row wraps the target exactly where the
    /// source wrapped, keeping the physical row count, and marks the wrap so
    /// the target re-flows the line at another width. Every other row keeps
    /// its own line break.
    fn replay_soft_wrap_rows(&self, range: ReplayRowRange) -> (BTreeSet<u64>, BTreeSet<u64>) {
        let mut joins = BTreeSet::new();
        let mut breaks = BTreeSet::new();
        let last_col = self.cols().saturating_sub(1);
        for row in range.start..range.end {
            if self.row_flag(sys::GHOSTTY_POINT_TAG_SCREEN, row, sys::GHOSTTY_ROW_DATA_WRAP)
                != Some(true)
            {
                continue;
            }
            let joinable = self.row_flag(
                sys::GHOSTTY_POINT_TAG_SCREEN,
                row.saturating_add(1),
                sys::GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
            ) == Some(true)
                && self.row_prints_to_its_end(last_col, row)
                && self.screen_cell_has_text(0, row.saturating_add(1));
            if joinable {
                joins.insert(row);
            } else {
                breaks.insert(row);
            }
        }
        (joins, breaks)
    }

    pub(super) fn row_flag(
        &self,
        tag: sys::GhosttyPointTag,
        y: u64,
        data: sys::GhosttyRowData,
    ) -> Option<bool> {
        let grid_ref = self.grid_ref(tag, 0, y)?;
        let mut row = sys::GhosttyRow::default();
        check(unsafe { sys::ghostty_grid_ref_row(&grid_ref, &mut row) }).ok()?;
        let mut value = false;
        check(unsafe { sys::ghostty_row_get(row, data, (&mut value as *mut bool).cast()) }).ok()?;
        Some(value)
    }

    /// Whether printing the row's cells leaves the cursor at its last column:
    /// the row ends in text or a wide character's tail, or in the spacer a
    /// wide character left when it wrapped (the formatter skips that spacer,
    /// and the wide character wraps again on the target).
    fn row_prints_to_its_end(&self, last_col: u16, y: u64) -> bool {
        match self.screen_cell(last_col, y) {
            Some((true, _) | (_, CellWidth::SpacerTail)) => true,
            Some((_, CellWidth::SpacerHead)) => matches!(
                last_col.checked_sub(1).and_then(|x| self.screen_cell(x, y)),
                Some((true, _) | (_, CellWidth::SpacerTail))
            ),
            _ => false,
        }
    }

    fn screen_cell_has_text(&self, x: u16, y: u64) -> bool {
        matches!(self.screen_cell(x, y), Some((true, _)))
    }

    /// Whether the screen cell holds text, and its width.
    fn screen_cell(&self, x: u16, y: u64) -> Option<(bool, CellWidth)> {
        let grid_ref = self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, x, y)?;
        let mut raw = sys::GhosttyCell::default();
        check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut raw) }).ok()?;
        let mut has_text = false;
        check(unsafe {
            sys::ghostty_cell_get(
                raw,
                sys::GHOSTTY_CELL_DATA_HAS_TEXT,
                (&mut has_text as *mut bool).cast(),
            )
        })
        .ok()?;
        Some((has_text, crate::render::cell_width(raw)))
    }

    fn vt_replay_text_range_bounded_with(
        &mut self,
        range: ReplayRowRange,
        placement_rows: &KittyReplayRowIndex,
        max_bytes: usize,
        include_palette: bool,
        join_soft_wraps: bool,
    ) -> Result<Option<ReplayText>> {
        let cols = self.cols();
        if cols == 0 || range.start > range.end {
            return Err(Error::InvalidValue);
        }
        let suffix = self.cursor_position_escape()?;
        let suffix_len = suffix.as_ref().map_or(0, Vec::len);
        let Some(format_max_bytes) = max_bytes.checked_sub(suffix_len) else {
            return Ok(None);
        };
        let insert_at_start = placement_rows.overlaps(range.start);
        let has_placement_anchor =
            placement_rows.anchors.range(range.start..=range.end).next().is_some();
        let mut segment_ends =
            placement_rows.anchors.range(range.start..=range.end).copied().collect::<BTreeSet<_>>();
        if insert_at_start {
            segment_ends.insert(range.start);
        }
        segment_ends.insert(range.end);
        let mut bytes = Vec::new();
        let mut insertion_offsets = BTreeMap::new();
        let mut segment_start = range.start;
        let replay_rows = range.end - range.start + 1;
        let screen_rows = u64::from(self.rows().max(1));
        // A replay with retained scrollback can contain exactly one viewport
        // of rows while still carrying a sparse history prefix in Ghostty's
        // screen coordinate space. Keep every row boundary in that case so
        // the target cannot retain stale history above the active TUI.
        let history_bearing = self.history_rows() > 0 || replay_rows > screen_rows;
        // A replay without image placement anchors can let the target terminal
        // recreate soft wraps naturally. Placement commands and history-bearing
        // ranges depend on physical row cursor positions, so retain the
        // row-delimited form for those cases.
        let preserve_soft_wrap = !history_bearing && !insert_at_start && !has_placement_anchor;
        // Row-delimited history still keeps soft wraps: a joinable wrapped row
        // (see `replay_soft_wrap_rows`) prints on into its continuation, which
        // re-creates the wrap on the same physical rows; any other wrapped row
        // ends its segment and keeps a line break. Without this, a line that
        // soft-wrapped at an older width comes back split there for good.
        let joining = join_soft_wraps && !preserve_soft_wrap && history_bearing;
        let joins = if joining {
            let (mut joins, breaks) = self.replay_soft_wrap_rows(range);
            segment_ends.extend(breaks);
            joins.retain(|row| !segment_ends.contains(row));
            joins
        } else {
            BTreeSet::new()
        };
        let joins_before = |row: u64| joins.range(range.start..row).count();
        let mut emitted_breaks = 0usize;
        for segment_end in segment_ends.iter().copied() {
            if segment_end < segment_start {
                continue;
            }
            let mut selection = self.screen_selection(segment_start, segment_end)?;
            // A segment that ends on the spacer head a wide character left when it wrapped ends one column earlier: the
            // spacer holds no text, and an unwrapping formatter extends a selection that ends on it into the next row's
            // wide character (formatter.zig, "if our end x/y falls on a spacer head AND we're unwrapping"), which the
            // next segment then prints again (VT fuzz finding E2: the replay drew the character twice and scrolled).
            if cols > 1
                && matches!(
                    self.screen_cell(cols - 1, segment_end),
                    Some((_, CellWidth::SpacerHead))
                )
            {
                selection.end = self
                    .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, cols - 2, segment_end)
                    .ok_or(Error::InvalidValue)?;
            }
            let first = segment_start == range.start;
            let last = segment_end == range.end;
            let remaining = format_max_bytes.saturating_sub(bytes.len());
            let Some(chunk) = self.format_bounded(
                Self::vt_replay_segment_options(
                    &selection,
                    first,
                    last,
                    include_palette,
                    preserve_soft_wrap || joining,
                ),
                remaining,
            )?
            else {
                return Ok(None);
            };
            if !preserve_soft_wrap {
                emitted_breaks = emitted_breaks
                    .saturating_add(chunk.windows(2).filter(|bytes| *bytes == b"\r\n").count());
            }
            bytes.extend_from_slice(&chunk);
            if !preserve_soft_wrap && history_bearing {
                let expected_breaks = usize::try_from(segment_end - range.start)
                    .unwrap_or(usize::MAX)
                    .saturating_sub(joins_before(segment_end));
                if joining && emitted_breaks > expected_breaks {
                    return Err(Error::InvalidValue);
                }
                while emitted_breaks < expected_breaks {
                    if bytes.len().saturating_add(2) > format_max_bytes {
                        return Ok(None);
                    }
                    bytes.extend_from_slice(b"\r\n");
                    emitted_breaks = emitted_breaks.saturating_add(1);
                }
            }
            if placement_rows.anchors.contains(&segment_end)
                || (insert_at_start && segment_end == range.start)
            {
                insertion_offsets.insert(segment_end, bytes.len());
            }
            if !last {
                if !preserve_soft_wrap {
                    if bytes.len().saturating_add(2) > format_max_bytes {
                        return Ok(None);
                    }
                    bytes.extend_from_slice(b"\r\n");
                    emitted_breaks = emitted_breaks.saturating_add(1);
                }
                segment_start = segment_end.saturating_add(1);
            }
        }
        if !preserve_soft_wrap && history_bearing {
            let expected_breaks =
                usize::try_from(replay_rows - 1).unwrap_or(usize::MAX).saturating_sub(joins.len());
            if joining && emitted_breaks > expected_breaks {
                return Err(Error::InvalidValue);
            }
            for _ in emitted_breaks..expected_breaks {
                if bytes.len().saturating_add(2) > format_max_bytes {
                    return Ok(None);
                }
                bytes.extend_from_slice(b"\r\n");
            }
        }
        if let Some(suffix) = suffix {
            bytes.extend_from_slice(&suffix);
        }
        Ok(Some(ReplayText { bytes, range: Some(range), insertion_offsets }))
    }
}
