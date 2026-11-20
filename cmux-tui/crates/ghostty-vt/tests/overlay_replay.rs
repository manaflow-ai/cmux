//! A byte mirror must preserve the rows an incremental full-screen program
//! will repaint. Moving an indicator during replay leaves its old cells over
//! the transcript when the program next updates or dismisses it.

use ghostty_vt::{Callbacks, RenderFrame, RenderState, Terminal};

fn terminal(cols: u16, rows: u16) -> Terminal {
    let mut term = Terminal::new(cols, rows, 1_000_000, Callbacks::default()).unwrap();
    term.resize(cols, rows, 8, 16).unwrap();
    term
}

fn frame(term: &mut Terminal, state: &mut RenderState) -> RenderFrame {
    state.update(term).unwrap();
    state.build_frame().unwrap()
}

fn text(frame: &RenderFrame) -> String {
    frame
        .styled_rows()
        .iter()
        .map(|row| row.iter().map(|cell| cell.text.as_str()).collect::<String>())
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn overlay_replay_incremental_update_and_dismiss_leave_no_indicator_cells() {
    let mut failures = Vec::new();
    let mut cases = 0;
    for (cols, rows) in [(80, 24), (120, 40), (160, 50)] {
        for alternate in [false, true] {
            for history in [false, true] {
                // Alternate screens have no history. Keep the history variant
                // too: switching from a primary screen with history is a real
                // attach/reconnect path.
                let label = format!("{cols}x{rows} alternate={alternate} history={history}");
                let mut source = terminal(cols, rows);
                if history {
                    for n in 0..rows * 2 {
                        source.vt_write(format!("history {n}\r\n").as_bytes());
                    }
                }
                if alternate {
                    source.vt_write(b"\x1b[?1049h");
                }
                source.vt_write(b"\x1b[2J\x1b[H");
                // The erased continuation retains the preceding row's wrap
                // mark. Replay must not join it to that row and shift every
                // following row, including the indicator, up one line.
                source.vt_write(
                    format!("\x1b[5;{cols}Hx-wrapped\x1b[48;5;194m\x1b[2K\x1b[0m").as_bytes(),
                );
                source.vt_write(b"\x1b[7;1Hask: Keep this transcript line intact.");
                source.vt_write(b"\x1b[8;20H\x1b[48;5;240mJump to bottom (click) v\x1b[0m");
                source.vt_write(b"\x1b[9;1HRan a tool\x1b[11;1H> ");

                let replay =
                    source.vt_replay_bounded_theme_portable_with_aliases(15 * 1024 * 1024).unwrap();
                let mut mirror = terminal(cols, rows);
                mirror.vt_write(&replay.self_contained_bytes());
                let mut source_state = RenderState::new().unwrap();
                let mut mirror_state = RenderState::new().unwrap();
                let initial = frame(&mut source, &mut source_state);
                assert!(text(&initial).contains("Jump to bottom (click) v"), "{label}");
                let _ = frame(&mut mirror, &mut mirror_state);

                // A program updates just the indicator's original row. It
                // cannot know that a replay moved the previous label.
                let update = b"\x1b[?2026h\x1b[8;1H\x1b[2K\x1b[8;20H\x1b[48;5;240m6 new messages (click) v\x1b[0m\x1b[11;3H\x1b[?2026l";
                source.vt_write(update);
                mirror.vt_write(update);
                let updated = frame(&mut mirror, &mut mirror_state);
                let expected = frame(&mut source, &mut source_state);
                assert!(text(&expected).contains("6 new messages (click) v"), "{label}");
                if text(&updated).contains("Jump to bottom") {
                    failures.push(format!("{label}: previous indicator remains after update"));
                }
                if updated.styled_rows() != expected.styled_rows() {
                    failures.push(format!("{label}: updated cells differ from the source"));
                }

                // At the live bottom the indicator is absent. Compare every
                // styled cell, including blanks, so an erased transcript cell
                // or retained pill background cannot pass a text-only check.
                let dismiss = b"\x1b[?2026h\x1b[8;1H\x1b[2K\x1b[11;3H\x1b[?2026l";
                source.vt_write(dismiss);
                mirror.vt_write(dismiss);
                source.scroll_to_bottom();
                mirror.scroll_to_bottom();
                let dismissed = frame(&mut mirror, &mut mirror_state);
                let expected = frame(&mut source, &mut source_state);
                let visible = text(&dismissed);
                if visible.contains("Jump to bottom") || visible.contains("new messages") {
                    failures.push(format!("{label}: indicator remains at the live bottom"));
                }
                if dismissed.styled_rows() != expected.styled_rows() {
                    failures.push(format!("{label}: dismissed cells differ from the source"));
                }
                cases += 1;
            }
        }
    }
    eprintln!("overlay replay: {cases} cases, {} failed assertions", failures.len());
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
