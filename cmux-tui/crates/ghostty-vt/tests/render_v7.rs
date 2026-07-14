use std::mem::size_of;

use ghostty_vt::{
    ATTR_BLINK, ATTR_BOLD, ATTR_FAINT, ATTR_INVERSE, ATTR_INVISIBLE, ATTR_ITALIC,
    ATTR_STRIKETHROUGH, Callbacks, Cell, CellWidth, Dirty, RenderFrame, RenderState, Rgb, Terminal,
    UnderlineStyle, rows_to_runs,
};

fn logical_line(cells: &[Cell]) -> String {
    let mut line = String::new();
    for cell in cells {
        if cell.width == CellWidth::SpacerTail {
            continue;
        }
        if cell.text.is_empty() {
            line.push(' ');
        } else {
            line.push_str(&cell.text);
        }
    }
    line.trim_end().to_string()
}

fn consume_dirty_rows(frame: &RenderFrame) -> Vec<u16> {
    frame.dirty_rows.clone()
}

#[test]
fn render_frame_shares_damage_and_preserves_walk_rows_path() {
    let mut term = Terminal::new(12, 3, 1000, Callbacks::default()).unwrap();
    let mut state = RenderState::new().unwrap();

    state.update(&mut term).unwrap();
    let initial = state.build_frame().unwrap();
    assert_eq!(initial.seq, 1);

    term.vt_write(b"A");
    state.update(&mut term).unwrap();
    let frame = state.build_frame().unwrap();

    let local_consumer = consume_dirty_rows(&frame);
    let first_attachment = consume_dirty_rows(&frame);
    let second_attachment = consume_dirty_rows(&frame);
    assert_eq!(local_consumer, first_attachment);
    assert_eq!(first_attachment, second_attachment);
    assert!(frame.dirty_rows.contains(&0));
    assert_eq!(frame.styled_row(0).unwrap()[0].text, "A");

    assert_eq!(state.dirty(), Dirty::Clean);
    let mut dirty_after_frame = Vec::new();
    state
        .walk_rows(|row, dirty, _| {
            if dirty {
                dirty_after_frame.push(row);
            }
        })
        .unwrap();
    assert!(dirty_after_frame.is_empty(), "frame damage was not consumed once");

    // The existing TUI order (set global clean, then walk rows) still sees and
    // consumes fresh per-row damage without going through RenderFrame.
    term.vt_write(b"\r\nB");
    state.update(&mut term).unwrap();
    state.set_clean();
    let mut tui_dirty = Vec::new();
    let mut tui_line = String::new();
    state
        .walk_rows(|row, dirty, cells| {
            if dirty {
                tui_dirty.push(row);
            }
            if row == 1 {
                tui_line = logical_line(cells);
            }
        })
        .unwrap();
    assert!(!tui_dirty.is_empty());
    assert_eq!(tui_line, "B");
}

#[test]
fn wide_cells_emit_each_glyph_once_and_keep_blank_gaps() {
    let mut term = Terminal::new(16, 2, 0, Callbacks::default()).unwrap();
    term.vt_write("日本語🙂\u{1b}[2CX".as_bytes());

    let mut state = RenderState::new().unwrap();
    state.update(&mut term).unwrap();
    let frame = state.build_frame().unwrap();
    let cells = frame.styled_row(0).unwrap();

    assert_eq!(cells.iter().filter(|cell| cell.width == CellWidth::Wide).count(), 4);
    assert_eq!(cells.iter().filter(|cell| cell.width == CellWidth::SpacerTail).count(), 4);
    assert_eq!(cells[8].width, CellWidth::Narrow);
    assert!(cells[8].text.is_empty());
    assert_eq!(cells[9].width, CellWidth::Narrow);
    assert!(cells[9].text.is_empty());

    let runs = frame.row_runs(0).unwrap();
    assert!(runs.iter().all(|run| !run.text.is_empty()));
    assert_eq!(runs.len(), 1, "unchanged style must form one maximal run");
    assert!(runs[0].text.starts_with("日本語🙂  X"), "{:?}", runs[0].text);
    for glyph in ['日', '本', '語', '🙂'] {
        assert_eq!(runs[0].text.matches(glyph).count(), 1);
    }
    assert_eq!(runs[0].width_hint, Some(16));
}

#[test]
fn styled_history_reads_oldest_rows_without_mutating_viewport_or_damage() {
    let mut term = Terminal::new(20, 24, 4_000_000, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b]4;1;#123456\x07");
    for index in 0..100 {
        term.vt_write(format!("\x1b[1;31mline{index:03}\x1b[0m\r\n").as_bytes());
    }

    let history_rows = term.history_rows();
    let scrollbar = term.scrollbar().unwrap();
    assert_eq!(u64::from(history_rows), scrollbar.total - scrollbar.len);
    assert!(history_rows >= 76, "retained {history_rows} rows");

    term.scroll_delta(-5);
    let viewport_before = term.viewport_text().unwrap();
    let scrollbar_before = term.scrollbar().unwrap();

    let mut state = RenderState::new().unwrap();
    state.update(&mut term).unwrap();
    let dirty_before = state.dirty();
    assert_ne!(dirty_before, Dirty::Clean);

    let page = term.styled_history_rows(0, 10).unwrap();
    assert_eq!(page.len(), 10);
    for (index, row) in page.iter().enumerate() {
        assert_eq!(logical_line(row), format!("line{index:03}"));
        assert!(row[0].bold);
        assert_eq!(row[0].resolved_fg, Some(Rgb { r: 0x12, g: 0x34, b: 0x56 }));
    }

    assert_eq!(term.viewport_text().unwrap(), viewport_before);
    assert_eq!(term.scrollbar().unwrap(), scrollbar_before);
    assert_eq!(state.dirty(), dirty_before);
    let pending = state.build_frame().unwrap();
    assert!(!pending.dirty_rows.is_empty(), "pending row damage was lost");
}

#[test]
fn history_eviction_is_byte_capped_and_oldest_index_advances() {
    const COLS: usize = 20;
    const VIEWPORT_ROWS: usize = 4;
    const SCROLLBACK_CAP_BYTES: usize = 1_000_000;
    const TERMINAL_PAGE_BYTES: usize = 512 * 1024;
    const WRITTEN_ROWS: usize = 20_000;

    // Ghostty stores each row descriptor and cell in packed u64s. Its cap is
    // bytes and eviction is terminal-page-granular, so allow one standard
    // page of slack instead of asserting an allocator-dependent row count.
    const MIN_BACKING_BYTES_PER_ROW: usize = (COLS + 1) * size_of::<u64>();

    let mut term = Terminal::new(
        COLS as u16,
        VIEWPORT_ROWS as u16,
        SCROLLBACK_CAP_BYTES,
        Callbacks::default(),
    )
    .unwrap();
    for index in 0..WRITTEN_ROWS {
        term.vt_write(format!("line{index:04}\r\n").as_bytes());
    }

    let retained = term.history_rows();
    assert!(retained > 0);
    let written_history = WRITTEN_ROWS - (VIEWPORT_ROWS - 1);
    assert!(
        (retained as usize) < written_history,
        "cap did not evict history: retained {retained} of {written_history}"
    );
    let retained_backing_bytes = retained as usize * MIN_BACKING_BYTES_PER_ROW;
    assert!(
        retained_backing_bytes <= SCROLLBACK_CAP_BYTES + TERMINAL_PAGE_BYTES,
        "retained history exceeds cap plus one page: {retained_backing_bytes} bytes"
    );

    let oldest = term.styled_history_rows(0, 1).unwrap();
    let newest = term.styled_history_rows(retained - 1, 1).unwrap();
    let oldest_index: usize = logical_line(&oldest[0]).trim_start_matches("line").parse().unwrap();
    let newest_index: usize = logical_line(&newest[0]).trim_start_matches("line").parse().unwrap();
    assert!(oldest_index > 0, "the original oldest row should have been evicted");
    assert!(newest_index > oldest_index);
}

#[test]
fn rows_to_runs_uses_protocol_attrs_underlines_and_resolved_indexed_rgb() {
    let mut term = Terminal::new(32, 2, 0, Callbacks::default()).unwrap();
    term.vt_write(
        b"\x1b]4;1;#112233\x07\x1b[31mAA\x1b[1mBB\x1b[4:1mS\x1b[4:2mD\x1b[4:3mC\x1b[4:4mO\x1b[4:5mA\x1b[3;9;2;7;8;5mZ\x1b[0mQ",
    );

    let mut state = RenderState::new().unwrap();
    state.update(&mut term).unwrap();
    let frame = state.build_frame().unwrap();
    let all_runs = rows_to_runs(frame.styled_rows());
    let runs = &all_runs[0];

    assert_eq!(runs.len(), 9, "{runs:#?}");
    assert_eq!(runs[0].text, "AA");
    assert_eq!(runs[0].fg, Some(Rgb { r: 0x11, g: 0x22, b: 0x33 }));
    assert_eq!(runs[0].attrs, 0);
    assert_eq!(runs[1].text, "BB");
    assert_eq!(runs[1].attrs, ATTR_BOLD);

    let underline_variants = [
        UnderlineStyle::Single,
        UnderlineStyle::Double,
        UnderlineStyle::Curly,
        UnderlineStyle::Dotted,
        UnderlineStyle::Dashed,
    ];
    for (run, expected) in runs[2..7].iter().zip(underline_variants) {
        assert_eq!(run.attrs, ATTR_BOLD);
        assert_eq!(run.underline, Some(expected));
    }

    assert_eq!(runs[7].text, "Z");
    assert_eq!(
        runs[7].attrs,
        ATTR_BOLD
            | ATTR_ITALIC
            | ATTR_STRIKETHROUGH
            | ATTR_INVERSE
            | ATTR_FAINT
            | ATTR_INVISIBLE
            | ATTR_BLINK
    );
    assert_eq!(runs[7].underline, Some(UnderlineStyle::Dashed));
    assert!(runs[8].text.starts_with('Q'));
    assert_eq!(runs[8].fg, None);
    assert!(runs.iter().all(|run| run.width_hint.is_none()));
}
