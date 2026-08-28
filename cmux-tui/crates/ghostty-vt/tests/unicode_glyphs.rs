use ghostty_vt::{Callbacks, CellWidth, RenderState, Terminal, rows_to_runs};

fn frame_for(input: &str, cols: u16) -> ghostty_vt::RenderFrame {
    let mut terminal = Terminal::new(cols, 2, 0, Callbacks::default()).unwrap();
    terminal.vt_write(input.as_bytes());
    let mut state = RenderState::new().unwrap();
    state.update(&mut terminal).unwrap();
    state.build_frame().unwrap()
}

#[test]
fn unicode_conformance_preserves_grapheme_clusters_and_cell_roles() {
    for input in ["e\u{301}", "日本語", "क्ष"] {
        let frame = frame_for(input, 16);
        let row = frame.styled_row(0).unwrap();
        let visible: String = row
            .iter()
            .filter(|c| c.width != CellWidth::SpacerTail)
            .filter_map(|c| (!c.text.is_empty()).then_some(c.text.as_str()))
            .collect();
        assert_eq!(visible, input);
        for (index, cell) in row.iter().enumerate() {
            if cell.width == CellWidth::Wide {
                assert!(!cell.text.is_empty());
                assert_eq!(row.get(index + 1).map(|next| next.width), Some(CellWidth::SpacerTail));
            }
            if cell.width == CellWidth::SpacerTail {
                assert!(cell.text.is_empty());
                assert!(index > 0 && row[index - 1].width == CellWidth::Wide);
            }
        }
    }
}

#[test]
fn unicode_conformance_rows_to_runs_are_width_accounted() {
    let frame = frame_for("e\u{301} 日本語", 16);
    let row = frame.styled_row(0).unwrap();
    assert_eq!(row.len(), usize::from(frame.size.0));
    let runs = rows_to_runs(frame.styled_rows());
    assert!(runs.iter().flat_map(|row| row.iter()).all(|run| !run.text.is_empty()));
    assert!(runs[0].iter().any(|run| run.width_hint.is_some()));
}

#[test]
fn unicode_conformance_utf8_chunking_preserves_rendered_text() {
    let input = "before λ 🙂 e\u{301} 赤";
    let expected = frame_for(input, 32);
    let mut terminal = Terminal::new(32, 2, 0, Callbacks::default()).unwrap();
    for chunk in input.as_bytes().chunks(1) {
        terminal.vt_write(chunk);
    }
    let mut state = RenderState::new().unwrap();
    state.update(&mut terminal).unwrap();
    let actual = state.build_frame().unwrap();
    let text = |frame: &ghostty_vt::RenderFrame| {
        frame
            .styled_row(0)
            .unwrap()
            .iter()
            .filter_map(|c| (!c.text.is_empty()).then_some(c.text.as_str()))
            .collect::<String>()
    };
    assert_eq!(text(&actual), text(&expected));
}
