use ghostty_vt::{Callbacks, Cell, CellWidth, RenderState, Terminal, rows_to_runs};

const TEST_COLUMNS: u16 = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WidthExpectation {
    Narrow,
    Wide,
    /// East Asian Width is ambiguous. The active terminal policy decides the
    /// cell count, so this corpus only checks that Ghostty reports one of the
    /// two valid lead-cell roles.
    Policy,
}

#[derive(Clone, Copy, Debug)]
struct CorpusCase {
    id: &'static str,
    category: &'static str,
    text: &'static str,
    width: WidthExpectation,
}

const UNICODE_CORPUS: &[CorpusCase] = &[
    CorpusCase {
        id: "latin-combining-acute",
        category: "latin-combining",
        text: "e\u{301}",
        width: WidthExpectation::Narrow,
    },
    CorpusCase {
        id: "latin-nfc", category: "nfc-nfd", text: "é", width: WidthExpectation::Narrow
    },
    CorpusCase {
        id: "latin-nfd",
        category: "nfc-nfd",
        text: "e\u{301}",
        width: WidthExpectation::Narrow,
    },
    CorpusCase {
        id: "hangul-syllable",
        category: "hangul",
        text: "한",
        width: WidthExpectation::Wide,
    },
    CorpusCase { id: "cjk-han", category: "cjk", text: "界", width: WidthExpectation::Wide },
    CorpusCase {
        id: "emoji-presentation",
        category: "emoji-presentation",
        text: "😀",
        width: WidthExpectation::Wide,
    },
    CorpusCase {
        id: "emoji-zwj-star-wars-regression",
        category: "emoji-zwj",
        text: "🧑‍🚀",
        width: WidthExpectation::Wide,
    },
    CorpusCase {
        id: "emoji-zwj-family",
        category: "emoji-zwj",
        text: "👨‍👩‍👧‍👦",
        width: WidthExpectation::Wide,
    },
    CorpusCase {
        id: "emoji-variation-selector",
        category: "variation-selector",
        text: "☕️",
        width: WidthExpectation::Wide,
    },
    CorpusCase {
        id: "regional-indicator-flag",
        category: "regional-indicator",
        text: "🇺🇸",
        width: WidthExpectation::Wide,
    },
    CorpusCase {
        id: "zero-width-joiner",
        category: "zero-width-joiner",
        text: "👩‍💻",
        width: WidthExpectation::Wide,
    },
    CorpusCase {
        id: "devanagari-conjunct",
        category: "devanagari",
        text: "क्ष",
        width: WidthExpectation::Wide,
    },
    CorpusCase { id: "thai", category: "thai", text: "ก", width: WidthExpectation::Narrow },
    CorpusCase { id: "arabic", category: "arabic", text: "م", width: WidthExpectation::Narrow },
    CorpusCase {
        id: "box-drawing",
        category: "box-drawing",
        text: "┌",
        width: WidthExpectation::Policy,
    },
    CorpusCase {
        id: "east-asian-ambiguous-middle-dot",
        category: "east-asian-ambiguous",
        text: "·",
        width: WidthExpectation::Policy,
    },
];

fn cell_columns(cell: &Cell) -> u16 {
    match cell.width {
        CellWidth::Wide => 2,
        CellWidth::SpacerTail => 0,
        CellWidth::Narrow | CellWidth::SpacerHead => 1,
    }
}

fn row_text(row: &[Cell]) -> String {
    row.iter().filter(|cell| !cell.text.is_empty()).map(|cell| cell.text.as_str()).collect()
}

fn row_signature(row: &[Cell]) -> Vec<(String, CellWidth)> {
    row.iter().map(|cell| (cell.text.clone(), cell.width)).collect()
}

fn corpus_case_frame(case: CorpusCase, cols: u16) -> ghostty_vt::RenderFrame {
    frame_for(&format!("\x1b[?2027h{}", case.text), cols)
}

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

#[test]
fn unicode_corpus_preserves_text_and_cell_geometry() {
    let required_categories = [
        "latin-combining",
        "nfc-nfd",
        "hangul",
        "cjk",
        "emoji-presentation",
        "emoji-zwj",
        "variation-selector",
        "regional-indicator",
        "zero-width-joiner",
        "devanagari",
        "thai",
        "arabic",
        "box-drawing",
        "east-asian-ambiguous",
    ];

    for category in required_categories {
        assert!(
            UNICODE_CORPUS.iter().any(|case| case.category == category),
            "reviewed corpus is missing category {category}"
        );
    }

    for &case in UNICODE_CORPUS {
        assert!(!case.text.contains('\u{FFFD}'), "corpus case {} contains U+FFFD", case.id);
        let frame = corpus_case_frame(case, TEST_COLUMNS);
        let row = frame.styled_row(0).unwrap();
        assert_eq!(row.len(), usize::from(TEST_COLUMNS), "case {} changed viewport width", case.id);
        let occupied: Vec<&Cell> = row.iter().filter(|cell| !cell.text.is_empty()).collect();
        assert_eq!(occupied.len(), 1, "case {} split grapheme text across cells", case.id);
        assert_eq!(occupied[0].text, case.text, "case {} changed grapheme text", case.id);
        assert!(
            row.iter().all(|cell| !cell.text.contains('\u{FFFD}')),
            "case {} introduced U+FFFD in rendered cells",
            case.id
        );
        assert_eq!(
            row.iter().map(cell_columns).sum::<u16>(),
            TEST_COLUMNS,
            "case {} has inconsistent cell-column accounting",
            case.id
        );

        let lead = row
            .iter()
            .find(|cell| !cell.text.is_empty())
            .unwrap_or_else(|| panic!("case {} produced no lead cell", case.id));
        match case.width {
            WidthExpectation::Narrow => {
                assert_eq!(lead.width, CellWidth::Narrow, "case {}", case.id);
            }
            WidthExpectation::Wide => assert_eq!(lead.width, CellWidth::Wide, "case {}", case.id),
            WidthExpectation::Policy => {
                assert!(
                    matches!(lead.width, CellWidth::Narrow | CellWidth::Wide),
                    "case {} has invalid policy-selected lead role {:?}",
                    case.id,
                    lead.width
                );
            }
        }

        if lead.width == CellWidth::Wide {
            let lead_index = row.iter().position(|cell| !cell.text.is_empty()).unwrap();
            let tail = row
                .get(lead_index + 1)
                .unwrap_or_else(|| panic!("case {} wide lead has no spacer tail", case.id));
            assert_eq!(tail.width, CellWidth::SpacerTail, "case {}", case.id);
            assert!(tail.text.is_empty(), "case {} spacer tail contains text", case.id);
        }
    }
}

#[test]
fn unicode_corpus_resize_and_replay_preserve_cells() {
    for &case in UNICODE_CORPUS {
        // Keep each case isolated. A zero-scrollback terminal would otherwise
        // evict earlier rows from a multi-case transcript before replay.
        let mut source = Terminal::new(32, 4, 0, Callbacks::default()).unwrap();
        source.vt_write(format!("\x1b[?2027h{}", case.text).as_bytes());
        source.resize(20, 4, 8, 16).unwrap();

        let mut source_state = RenderState::new().unwrap();
        source_state.update(&mut source).unwrap();
        let source_frame = source_state.build_frame().unwrap();
        assert_eq!(row_text(source_frame.styled_row(0).unwrap()), case.text, "case {}", case.id);

        let replay = source.vt_replay().unwrap();
        let mut restored = Terminal::new(20, 4, 0, Callbacks::default()).unwrap();
        restored.apply_vt_replay(&replay).unwrap();
        let mut restored_state = RenderState::new().unwrap();
        restored_state.update(&mut restored).unwrap();
        let restored_frame = restored_state.build_frame().unwrap();

        assert_eq!(restored_frame.size, source_frame.size, "case {}", case.id);
        assert_eq!(
            restored_frame.styled_rows().len(),
            source_frame.styled_rows().len(),
            "case {} row count",
            case.id
        );
        for (row_index, (source_row, restored_row)) in
            source_frame.styled_rows().iter().zip(restored_frame.styled_rows()).enumerate()
        {
            assert_eq!(
                row_signature(restored_row),
                row_signature(source_row),
                "case {} resize/replay changed cell roles in row {row_index}",
                case.id
            );
            assert!(
                !row_text(restored_row).contains('\u{FFFD}'),
                "case {} resize/replay introduced U+FFFD in row {row_index}",
                case.id
            );
        }
    }
}
