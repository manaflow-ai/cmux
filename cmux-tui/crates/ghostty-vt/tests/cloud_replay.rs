use ghostty_vt::{Callbacks, RenderFrame, RenderState, Terminal};

fn codex_screen(history: usize) -> (Terminal, Terminal) {
    let mut source = Terminal::new(80, 40, 1024 * 1024, Callbacks::default()).unwrap();
    for _ in 0..history {
        source.vt_write(b"history\r\n");
    }
    source.vt_write(
        "\x1b[2J\x1b[H╭── OpenAI Codex ──╮\x1b[3;1H╰──────────────────╯\
         \x1b[26;1HTip: Build faster with Codex.\x1b[29;1H› 2+2\x1b[31;1H• 4"
            .as_bytes(),
    );
    source.vt_write(b"\x1b[48;2;243;243;243m");
    for row in 32..=36 {
        source.vt_write(format!("\x1b[{row};1H\x1b[2K").as_bytes());
    }
    source.vt_write(
        "\x1b[33;1H\x1b[38;2;130;130;130m› Ask Codex to do anything\
         \x1b[0m\x1b[37;1Hgpt-6-astra default · Calculate 2+2\x1b[33;3H"
            .as_bytes(),
    );
    let replay = source.vt_replay_bounded_theme_portable(128 * 1024).unwrap();
    let mut restored = Terminal::new(80, 40, 1024 * 1024, Callbacks::default()).unwrap();
    restored.vt_write(&replay);
    (source, restored)
}

fn frame(terminal: &mut Terminal) -> RenderFrame {
    let mut state = RenderState::new().unwrap();
    state.update(terminal).unwrap();
    state.build_frame().unwrap()
}

fn assert_cells_match(source: &mut Terminal, restored: &mut Terminal, history: usize) {
    let expected = frame(source);
    let actual = frame(restored);
    assert_eq!(actual.size, expected.size);
    assert_eq!(restored.cursor_position(), source.cursor_position(), "history={history}");
    assert_eq!(actual.styled_rows().len(), expected.styled_rows().len());
    for (y, (actual_row, expected_row)) in
        actual.styled_rows().iter().zip(expected.styled_rows()).enumerate()
    {
        assert_eq!(actual_row.len(), expected_row.len(), "history={history} row={y}");
        for (x, (actual_cell, expected_cell)) in actual_row.iter().zip(expected_row).enumerate() {
            let mut actual_cell = actual_cell.clone();
            let mut expected_cell = expected_cell.clone();
            // A replay can represent an erased blank as a literal space.
            // Its color, width and attributes must still agree.
            if actual_cell.text == " " {
                actual_cell.text.clear();
            }
            if expected_cell.text == " " {
                expected_cell.text.clear();
            }
            assert_eq!(actual_cell, expected_cell, "history={history} cell=({x},{y})");
        }
    }
}

#[test]
fn cloud_codex_replay_preserves_composer_cells_and_blank_tail() {
    for history in [0, 80, 574, 580, 595, 612, 1024] {
        let (mut source, mut restored) = codex_screen(history);
        assert_cells_match(&mut source, &mut restored, history);
    }
}

#[test]
fn cloud_codex_replay_then_incremental_redraw_preserves_composer_cells() {
    for history in [0, 80, 574, 580, 595, 612, 1024] {
        let (mut source, mut restored) = codex_screen(history);
        // Apply the redraw before checking, so a red test exercises the
        // incremental path as well as the initial replacement replay.
        let update = "\x1b[33;3H\x1b[48;2;243;243;243m\x1b[0Knext prompt\
                      \x1b[0m\x1b[37;22HDone\x1b[33;14H";
        source.vt_write(update.as_bytes());
        restored.vt_write(update.as_bytes());
        assert_cells_match(&mut source, &mut restored, history);
    }
}
