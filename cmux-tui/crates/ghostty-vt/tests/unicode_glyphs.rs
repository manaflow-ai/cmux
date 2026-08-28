use ghostty_vt::{Callbacks, CellWidth, RenderState, Terminal, rows_to_runs};

const TEST_COLUMNS: u16 = 16;

fn frame_for(input: &str, cols: u16) -> ghostty_vt::RenderFrame {
    let mut terminal = Terminal::new(cols, 2, 0, Callbacks::default()).unwrap();
    terminal.vt_write(input.as_bytes());
    let mut state = RenderState::new().unwrap();
    state.update(&mut terminal).unwrap();
    state.build_frame().unwrap()
}

fn styled_row_cells(frame: &ghostty_vt::RenderFrame) -> Vec<(String, CellWidth)> {
    frame.styled_row(0).unwrap().iter().map(|cell| (cell.text.clone(), cell.width)).collect()
}

fn assert_grapheme_cells(input: &str, expected: &[(&str, CellWidth)]) {
    // Mode 2027 uses the terminal's extended grapheme segmentation. UAX #29
    // keeps combining marks and Indic conjuncts in one cluster, while UAX #11
    // classifies Han ideographs as wide. Ghostty represents a two-column
    // cluster with a Wide lead and a SpacerTail.
    let frame = frame_for(&format!("\x1b[?2027h{input}"), TEST_COLUMNS);
    let row = frame.styled_row(0).unwrap();
    assert_eq!(row.len(), usize::from(TEST_COLUMNS), "unexpected viewport width for {input:?}");

    let mut column = 0;
    for &(expected_text, expected_width) in expected {
        let cell = row
            .get(column)
            .unwrap_or_else(|| panic!("missing lead cell at column {column} for {input:?}"));
        assert_eq!(cell.text, expected_text, "cluster text at column {column} for {input:?}");
        assert_eq!(cell.width, expected_width, "cluster width at column {column} for {input:?}");

        match expected_width {
            CellWidth::Narrow => column += 1,
            CellWidth::Wide => {
                let tail = row.get(column + 1).unwrap_or_else(|| {
                    panic!("missing spacer tail after column {column} for {input:?}")
                });
                assert!(tail.text.is_empty(), "spacer tail must not contain text");
                assert_eq!(tail.width, CellWidth::SpacerTail);
                column += 2;
            }
            CellWidth::SpacerTail | CellWidth::SpacerHead => {
                panic!("expected entries must name grapheme lead cells")
            }
        }
    }

    assert!(
        row[column..].iter().all(|cell| cell.width == CellWidth::Narrow && cell.text.is_empty()),
        "unexpected occupied cells after column {column} for {input:?}"
    );
}

#[test]
fn unicode_conformance_preserves_grapheme_clusters_and_cell_roles() {
    assert_grapheme_cells("e\u{301}", &[("e\u{301}", CellWidth::Narrow)]);
    assert_grapheme_cells(
        "日本語",
        &[("日", CellWidth::Wide), ("本", CellWidth::Wide), ("語", CellWidth::Wide)],
    );
    assert_grapheme_cells("क्ष", &[("क्ष", CellWidth::Wide)]);
}

#[test]
fn unicode_conformance_rows_to_runs_preserve_terminal_columns() {
    let frame = frame_for("\x1b[?2027he\u{301} 日本語", TEST_COLUMNS);
    let row = frame.styled_row(0).unwrap();
    let runs = rows_to_runs(frame.styled_rows());
    assert!(runs.iter().flat_map(|row| row.iter()).all(|run| !run.text.is_empty()));

    let source_columns: u16 = row
        .iter()
        .map(|cell| match cell.width {
            CellWidth::Wide => 2,
            CellWidth::SpacerTail => 0,
            CellWidth::Narrow | CellWidth::SpacerHead => 1,
        })
        .sum();
    assert_eq!(source_columns, TEST_COLUMNS);
    assert_eq!(frame.size.0, TEST_COLUMNS);

    assert_eq!(runs[0].len(), 1, "default styling should form one maximal run");
    assert_eq!(runs[0][0].width_hint, Some(TEST_COLUMNS));
}

#[test]
fn unicode_conformance_utf8_chunking_preserves_rendered_text() {
    let input = "\x1b[?2027hbefore λ 🙂 e\u{301} 赤";
    let expected = frame_for(input, 32);
    let mut terminal = Terminal::new(32, 2, 0, Callbacks::default()).unwrap();
    for chunk in input.as_bytes().chunks(1) {
        terminal.vt_write(chunk);
    }
    let mut state = RenderState::new().unwrap();
    state.update(&mut terminal).unwrap();
    let actual = state.build_frame().unwrap();
    let expected_cells = styled_row_cells(&expected);
    let actual_cells = styled_row_cells(&actual);
    assert_eq!(actual_cells, expected_cells);
    assert!(
        expected_cells
            .iter()
            .any(|(text, width)| text.is_empty() && *width == CellWidth::SpacerTail),
        "expected fixture must retain the empty spacer tail cell"
    );
}
