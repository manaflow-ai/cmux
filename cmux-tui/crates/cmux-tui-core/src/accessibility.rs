//! Bounded semantic accessibility snapshots for daemon-owned terminals.
//!
//! The wire payload contains rendered terminal semantics and stable UTF-16
//! coordinates only. It never contains PTY input/output bytes or a VT replay.

use ghostty_vt::{Cell, CellWidth, SelectionPoint, SelectionSnapshot, Terminal};
use serde::Serialize;

use crate::{PresentationId, SurfaceUuid};

pub const TERMINAL_ACCESSIBILITY_SCHEMA_VERSION: u32 = 1;
pub const TERMINAL_ACCESSIBILITY_MAX_ROWS: usize = 4_096;
pub const TERMINAL_ACCESSIBILITY_MAX_CELLS: usize = 65_536;
pub const TERMINAL_ACCESSIBILITY_MAX_TEXT_BYTES: usize = 1_048_576;
pub const TERMINAL_ACCESSIBILITY_MAX_UTF16_UNITS: usize = 1_048_576;
pub const TERMINAL_ACCESSIBILITY_MAX_LINKS: usize = 1_024;
pub const TERMINAL_ACCESSIBILITY_MAX_WIRE_BYTES: usize = 12 * 1_024 * 1_024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct TerminalAccessibilityRange {
    pub location: u32,
    pub length: u32,
}

impl TerminalAccessibilityRange {
    fn end(self) -> u32 {
        self.location.saturating_add(self.length)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalAccessibilityCell {
    pub column: u16,
    pub column_span: u16,
    pub utf16_range: TerminalAccessibilityRange,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalAccessibilityLine {
    pub row: u64,
    pub utf16_range: TerminalAccessibilityRange,
    pub cells: Vec<TerminalAccessibilityCell>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalAccessibilityCursor {
    pub column: u16,
    pub row: u64,
    pub insertion_range: TerminalAccessibilityRange,
    pub line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalAccessibilitySelection {
    pub text: String,
    pub utf16_ranges: Vec<TerminalAccessibilityRange>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalAccessibilityLink {
    pub id: String,
    pub target: String,
    pub utf16_range: TerminalAccessibilityRange,
    pub row: u64,
    pub start_column: u16,
    pub end_column: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalAccessibilitySnapshot {
    pub schema_version: u32,
    pub surface_uuid: SurfaceUuid,
    pub presentation_id: PresentationId,
    pub presentation_generation: u64,
    /// Exact canonical semantic-scene sequence whose pixels this snapshot describes.
    pub content_sequence: u64,
    pub terminal_revision: u64,
    pub content_revision: u64,
    pub viewport_revision: u64,
    pub viewport_offset: u64,
    pub columns: u16,
    pub rows: u16,
    pub text: String,
    pub lines: Vec<TerminalAccessibilityLine>,
    pub cursor: Option<TerminalAccessibilityCursor>,
    pub selections: Vec<TerminalAccessibilitySelection>,
    pub links: Vec<TerminalAccessibilityLink>,
    pub focused: bool,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct TerminalAccessibilityIdentity {
    pub surface_uuid: SurfaceUuid,
    pub presentation_id: PresentationId,
    pub presentation_generation: u64,
    pub content_sequence: u64,
    pub terminal_revision: u64,
    pub content_revision: u64,
    pub viewport_revision: u64,
    pub focused: bool,
}

pub(crate) fn build_terminal_accessibility_snapshot(
    terminal: &mut Terminal,
    identity: TerminalAccessibilityIdentity,
) -> anyhow::Result<TerminalAccessibilitySnapshot> {
    let columns = terminal.cols();
    let rows = terminal.rows();
    let scrollbar =
        terminal.scrollbar().ok_or_else(|| anyhow::anyhow!("terminal viewport is unavailable"))?;
    let visible_rows = usize::from(rows);
    let cell_count = usize::from(columns)
        .checked_mul(visible_rows)
        .ok_or_else(|| anyhow::anyhow!("terminal accessibility cell count overflow"))?;
    if visible_rows > TERMINAL_ACCESSIBILITY_MAX_ROWS
        || cell_count > TERMINAL_ACCESSIBILITY_MAX_CELLS
    {
        anyhow::bail!(
            "terminal accessibility viewport exceeds bounds (rows {}, cells {})",
            visible_rows,
            cell_count
        );
    }
    let viewport_offset = u32::try_from(scrollbar.offset)
        .map_err(|_| anyhow::anyhow!("terminal accessibility viewport offset is out of range"))?;
    let styled = terminal.styled_screen_rows(viewport_offset, rows)?;
    if styled.len() != visible_rows {
        anyhow::bail!(
            "terminal accessibility snapshot row mismatch (expected {}, got {})",
            visible_rows,
            styled.len()
        );
    }

    let mut text = String::new();
    let mut utf16_length = 0usize;
    let mut lines = Vec::with_capacity(styled.len());
    let mut links = Vec::new();

    for (visible_index, row) in styled.iter().enumerate() {
        let absolute_row = scrollbar.offset.saturating_add(visible_index as u64);
        let line_start = utf16_length;
        let mut cells = Vec::with_capacity(row.len());
        let mut active_link: Option<(String, u16, u16, usize, usize)> = None;

        for (column, cell) in row.iter().enumerate() {
            let column = u16::try_from(column)
                .map_err(|_| anyhow::anyhow!("terminal accessibility column overflow"))?;
            if cell.width == CellWidth::SpacerTail {
                continue;
            }
            let column_span = if cell.width == CellWidth::Wide { 2 } else { 1 };
            let rendered = accessible_cell_text(cell);
            let cell_start = utf16_length;
            utf16_length = utf16_length
                .checked_add(rendered.encode_utf16().count())
                .ok_or_else(|| anyhow::anyhow!("terminal accessibility UTF-16 overflow"))?;
            if utf16_length > TERMINAL_ACCESSIBILITY_MAX_UTF16_UNITS {
                anyhow::bail!("terminal accessibility text exceeds UTF-16 bound");
            }
            text.push_str(rendered.as_ref());
            if text.len() > TERMINAL_ACCESSIBILITY_MAX_TEXT_BYTES {
                anyhow::bail!("terminal accessibility text exceeds byte bound");
            }
            let mapping = TerminalAccessibilityCell {
                column,
                column_span,
                utf16_range: checked_range(cell_start, utf16_length - cell_start)?,
            };
            cells.push(mapping);

            match (&mut active_link, cell.hyperlink_uri.as_deref()) {
                (Some((target, _, end_column, _, end_utf16)), Some(uri)) if target == uri => {
                    *end_column = column.saturating_add(column_span).saturating_sub(1);
                    *end_utf16 = utf16_length;
                }
                (Some(previous), next) => {
                    finish_link(
                        &mut links,
                        previous,
                        absolute_row,
                        identity.content_revision,
                        identity.viewport_revision,
                    )?;
                    active_link = next.map(|uri| {
                        (
                            uri.to_owned(),
                            column,
                            column.saturating_add(column_span).saturating_sub(1),
                            cell_start,
                            utf16_length,
                        )
                    });
                }
                (None, Some(uri)) => {
                    active_link = Some((
                        uri.to_owned(),
                        column,
                        column.saturating_add(column_span).saturating_sub(1),
                        cell_start,
                        utf16_length,
                    ));
                }
                (None, None) => {}
            }
        }
        if let Some(active_link) = active_link.take() {
            finish_link(
                &mut links,
                &active_link,
                absolute_row,
                identity.content_revision,
                identity.viewport_revision,
            )?;
        }
        let line_end = utf16_length;
        lines.push(TerminalAccessibilityLine {
            row: absolute_row,
            utf16_range: checked_range(line_start, line_end - line_start)?,
            cells,
        });
        if visible_index + 1 < styled.len() {
            text.push('\n');
            utf16_length += 1;
        }
    }

    if links.len() > TERMINAL_ACCESSIBILITY_MAX_LINKS {
        anyhow::bail!("terminal accessibility links exceed bound");
    }

    let cursor = terminal
        .cursor_screen_point()
        .and_then(|cursor| cursor_mapping(cursor, &lines, scrollbar.offset));
    let selections = terminal
        .current_selection()?
        .map(|selection| selection_mapping(&selection, &lines))
        .transpose()?
        .into_iter()
        .collect();

    Ok(TerminalAccessibilitySnapshot {
        schema_version: TERMINAL_ACCESSIBILITY_SCHEMA_VERSION,
        surface_uuid: identity.surface_uuid,
        presentation_id: identity.presentation_id,
        presentation_generation: identity.presentation_generation,
        content_sequence: identity.content_sequence,
        terminal_revision: identity.terminal_revision,
        content_revision: identity.content_revision,
        viewport_revision: identity.viewport_revision,
        viewport_offset: scrollbar.offset,
        columns,
        rows,
        text,
        lines,
        cursor,
        selections,
        links,
        focused: identity.focused,
    })
}

fn accessible_cell_text(cell: &Cell) -> std::borrow::Cow<'_, str> {
    if cell.invisible || cell.text.is_empty() {
        std::borrow::Cow::Borrowed(" ")
    } else {
        std::borrow::Cow::Borrowed(cell.text.as_str())
    }
}

fn checked_range(location: usize, length: usize) -> anyhow::Result<TerminalAccessibilityRange> {
    Ok(TerminalAccessibilityRange {
        location: u32::try_from(location)
            .map_err(|_| anyhow::anyhow!("terminal accessibility range location overflow"))?,
        length: u32::try_from(length)
            .map_err(|_| anyhow::anyhow!("terminal accessibility range length overflow"))?,
    })
}

fn finish_link(
    links: &mut Vec<TerminalAccessibilityLink>,
    link: &(String, u16, u16, usize, usize),
    row: u64,
    content_revision: u64,
    viewport_revision: u64,
) -> anyhow::Result<()> {
    if links.len() >= TERMINAL_ACCESSIBILITY_MAX_LINKS {
        anyhow::bail!("terminal accessibility links exceed bound");
    }
    let (target, start_column, end_column, start_utf16, end_utf16) = link;
    let mut hash = 0xcbf29ce484222325u64;
    for byte in target
        .as_bytes()
        .iter()
        .copied()
        .chain(row.to_le_bytes())
        .chain(start_column.to_le_bytes())
        .chain(end_column.to_le_bytes())
    {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    links.push(TerminalAccessibilityLink {
        id: format!("{content_revision:x}:{viewport_revision:x}:{hash:016x}"),
        target: target.clone(),
        utf16_range: checked_range(*start_utf16, end_utf16 - start_utf16)?,
        row,
        start_column: *start_column,
        end_column: *end_column,
    });
    Ok(())
}

fn cursor_mapping(
    cursor: SelectionPoint,
    lines: &[TerminalAccessibilityLine],
    viewport_offset: u64,
) -> Option<TerminalAccessibilityCursor> {
    let line_index = u64::from(cursor.row).checked_sub(viewport_offset)?;
    let line_index = usize::try_from(line_index).ok()?;
    let line = lines.get(line_index)?;
    let cell = cell_for_column(line, cursor.column)?;
    Some(TerminalAccessibilityCursor {
        column: cursor.column,
        row: u64::from(cursor.row),
        insertion_range: TerminalAccessibilityRange {
            location: cell.utf16_range.location,
            length: 0,
        },
        line: u32::try_from(line_index).ok()?,
    })
}

fn selection_mapping(
    selection: &SelectionSnapshot,
    lines: &[TerminalAccessibilityLine],
) -> anyhow::Result<TerminalAccessibilitySelection> {
    if selection.text.len() > TERMINAL_ACCESSIBILITY_MAX_TEXT_BYTES
        || selection.text.encode_utf16().count() > TERMINAL_ACCESSIBILITY_MAX_UTF16_UNITS
    {
        anyhow::bail!("terminal accessibility selection text exceeds bound");
    }
    let mut ranges = Vec::new();
    for line in lines {
        let row = u32::try_from(line.row).unwrap_or(u32::MAX);
        if row < selection.top_left.row || row > selection.bottom_right.row {
            continue;
        }
        let (start_column, end_column) = if selection.rectangle {
            (selection.top_left.column, selection.bottom_right.column)
        } else {
            (
                if row == selection.top_left.row { selection.top_left.column } else { 0 },
                if row == selection.bottom_right.row {
                    selection.bottom_right.column
                } else {
                    u16::MAX
                },
            )
        };
        if let Some(range) = range_for_columns(line, start_column, end_column) {
            ranges.push(range);
        }
    }
    Ok(TerminalAccessibilitySelection { text: selection.text.clone(), utf16_ranges: ranges })
}

fn range_for_columns(
    line: &TerminalAccessibilityLine,
    start_column: u16,
    end_column: u16,
) -> Option<TerminalAccessibilityRange> {
    let first = line.cells.iter().find(|cell| {
        cell.column.saturating_add(cell.column_span).saturating_sub(1) >= start_column
            && cell.column <= end_column
    })?;
    let last = line
        .cells
        .iter()
        .rev()
        .find(|cell| cell.column <= end_column && cell.column >= first.column)?;
    Some(TerminalAccessibilityRange {
        location: first.utf16_range.location,
        length: last.utf16_range.end().saturating_sub(first.utf16_range.location),
    })
}

fn cell_for_column(
    line: &TerminalAccessibilityLine,
    column: u16,
) -> Option<&TerminalAccessibilityCell> {
    line.cells.iter().find(|cell| {
        column >= cell.column && column < cell.column.saturating_add(cell.column_span.max(1))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ghostty_vt::Callbacks;

    fn identity() -> TerminalAccessibilityIdentity {
        TerminalAccessibilityIdentity {
            surface_uuid: SurfaceUuid::new(),
            presentation_id: PresentationId::new(),
            presentation_generation: 7,
            content_sequence: 11,
            terminal_revision: 11,
            content_revision: 9,
            viewport_revision: 3,
            focused: true,
        }
    }

    #[test]
    fn utf16_mapping_is_exact_for_emoji_combining_and_cjk_cells() {
        let mut terminal = Terminal::new(12, 2, 1_000_000, Callbacks::default()).unwrap();
        terminal.vt_write("🙂e\u{301}界".as_bytes());
        let snapshot = build_terminal_accessibility_snapshot(&mut terminal, identity()).unwrap();
        let cells = &snapshot.lines[0].cells;
        assert_eq!(&snapshot.text[.."🙂e\u{301}界".len()], "🙂e\u{301}界");
        assert_eq!(cells[0].utf16_range, TerminalAccessibilityRange { location: 0, length: 2 });
        assert_eq!(cells[0].column_span, 2);
        assert_eq!(cells[1].column, 2);
        assert_eq!(cells[1].utf16_range, TerminalAccessibilityRange { location: 2, length: 2 });
        assert_eq!(cells[2].column, 3);
        assert_eq!(cells[2].column_span, 2);
        assert_eq!(cells[2].utf16_range, TerminalAccessibilityRange { location: 4, length: 1 });
    }

    #[test]
    fn multiline_selection_cursor_and_resize_scroll_revisions_are_projectable() {
        let mut terminal = Terminal::new(8, 3, 1_000_000, Callbacks::default()).unwrap();
        terminal.vt_write(b"one\r\ntwo\r\nthree");
        let start = SelectionPoint { column: 1, row: 0 };
        let end = SelectionPoint { column: 2, row: 1 };
        terminal.select_range_screen(start, end, false).unwrap();
        let snapshot = build_terminal_accessibility_snapshot(&mut terminal, identity()).unwrap();
        assert_eq!(snapshot.selections.len(), 1);
        assert_eq!(snapshot.selections[0].utf16_ranges.len(), 2);
        assert!(snapshot.cursor.is_some());
        assert_eq!(snapshot.terminal_revision, 11);
        assert_eq!(snapshot.viewport_revision, 3);

        terminal.resize(10, 2, 8, 16).unwrap();
        terminal.scroll_to_top();
        let mut next = identity();
        next.terminal_revision = 12;
        next.viewport_revision = 4;
        let resized = build_terminal_accessibility_snapshot(&mut terminal, next).unwrap();
        assert_eq!(resized.columns, 10);
        assert_eq!(resized.rows, 2);
        assert_eq!(resized.viewport_revision, 4);
    }

    #[test]
    fn osc8_links_are_bounded_stable_and_revision_fenced_by_identity() {
        let mut terminal = Terminal::new(16, 2, 1_000_000, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b]8;;https://example.com/a\x1b\\link\x1b]8;;\x1b\\");
        let first = build_terminal_accessibility_snapshot(&mut terminal, identity()).unwrap();
        assert_eq!(first.links.len(), 1);
        assert_eq!(first.links[0].target, "https://example.com/a");
        assert_eq!(
            first.links[0].utf16_range,
            TerminalAccessibilityRange { location: 0, length: 4 }
        );
        let repeated = build_terminal_accessibility_snapshot(&mut terminal, identity()).unwrap();
        assert_eq!(first.links[0].id, repeated.links[0].id);
        let mut next = identity();
        next.content_revision += 1;
        let changed = build_terminal_accessibility_snapshot(&mut terminal, next).unwrap();
        assert_ne!(first.links[0].id, changed.links[0].id);
    }
}
