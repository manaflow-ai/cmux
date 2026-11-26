use super::*;

#[test]
fn the_seed_is_the_screen_then_one_dim_marker_line_within_the_bound() {
    let seed = respawn_seed(Some(b"old screen".to_vec()), Some("restored"));
    let text = String::from_utf8(seed).unwrap_or_default();
    assert!(text.starts_with("old screen\x1b7\x1b[?1049l"), "{text:?}");
    assert!(text.ends_with("\r\n\x1b[2mrestored\x1b[0m\r\n"), "{text:?}");

    let alone = respawn_seed(None, Some("restored"));
    assert!(!alone.starts_with(b"\r\n") && alone.ends_with(b"restored\x1b[0m\r\n"));

    let huge = vec![b'x'; crate::surface::VT_REPLAY_MAX_BYTES];
    let bounded = respawn_seed(Some(huge), Some("restored"));
    assert!(bounded.len() < MARKER_HEADROOM_BYTES, "an oversized screen is dropped whole");

    let quiet = respawn_seed(Some(b"old screen".to_vec()), None);
    assert!(quiet.ends_with(MODE_RESET) || quiet.ends_with(b"\r\n"));
    assert!(!quiet.windows(4).any(|window| window == b"\x1b[2m"), "no marker line");
}

/// The rows a terminal of `cols`x`rows` shows after `bytes`, trimmed.
fn shown(cols: u16, rows: u16, bytes: &[u8]) -> Vec<String> {
    let mut term = ghostty_vt::Terminal::new(cols, rows, 1_000, Default::default()).unwrap();
    term.vt_write(bytes);
    (0..rows)
        .map(|row| term.selection_text((0, row), (cols - 1, row)).unwrap_or_default())
        .map(|text| text.trim_end().to_string())
        .collect()
}

/// Muse Code's screen at its host's death (dogfood, Oct 27): transcript,
/// one blank row, then its input frame with the cursor on the prompt.
fn muse_screen() -> TerminalReplay {
    let bytes = "Worked for 17m 28s \u{b7} 8:35 PM\r\n\
             \u{25c7} Running command\r\n\
             \r\n\
             \u{2500}\u{2500} Voice input (\u{2325} + v to start) \u{2500}\u{2500}\r\n\
             \u{276f} \r\n\
             \u{2500}\u{2500}\u{2500}\u{2500}\r\n\
             \x20 muse-wonder-1.0 \u{b7} high \u{b7} YOLO\x1b[2A\r\x1b[2C";
    TerminalReplay { cols: 60, rows: 10, bytes: bytes.as_bytes().to_vec() }
}

#[test]
fn an_agents_input_frame_starts_below_the_blank_row_above_its_cursor() {
    assert_eq!(agent_frame_rows(&muse_screen()), Some(1), "the voice bar, one row up");
    // The cursor on a blank row: from that row.
    let blank = TerminalReplay { cols: 20, rows: 4, bytes: b"text\r\n\r\n".to_vec() };
    assert_eq!(agent_frame_rows(&blank), Some(0));
    // No blank row near the cursor: only from its row.
    let dense = (0..30).map(|row| format!("line {row}\r\n")).collect::<String>() + "last";
    let dense = TerminalReplay { cols: 20, rows: 30, bytes: dense.into_bytes() };
    assert_eq!(agent_frame_rows(&dense), Some(0));
    // A full-screen program: the mode reset leaves its screen already.
    let full = TerminalReplay { cols: 20, rows: 4, bytes: b"\x1b[?1049hframe".to_vec() };
    assert_eq!(agent_frame_rows(&full), None);
}

#[test]
fn a_respawned_agent_terminal_keeps_the_transcript_but_not_the_input_frame() {
    let screen = muse_screen();
    let frame = agent_frame_rows(&screen);
    let seed = respawn_seed_without_frame(Some(screen.bytes), frame, Some("restored"));
    let rows = shown(60, 10, &seed);
    let text = rows.join("\n");
    assert!(text.contains("Worked for 17m 28s"), "{text}");
    assert!(text.contains("Running command"), "{text}");
    for chrome in ["Voice input", "\u{276f}", "muse-wonder", "\u{2500}"] {
        assert!(!text.contains(chrome), "{chrome:?} was replayed: {text}");
    }
    assert_eq!(rows[3], "restored", "the marker takes the frame's place: {text}");
    // Without a frame the seed is the plain one.
    assert_eq!(
        respawn_seed_without_frame(Some(b"old".to_vec()), None, Some("restored")),
        respawn_seed(Some(b"old".to_vec()), Some("restored"))
    );
}

#[test]
fn a_stale_terminfo_drops_term() {
    let env = vec![
        ("TERM".to_string(), "xterm-ghostty".to_string()),
        ("TERMINFO".to_string(), "/definitely/missing/terminfo".to_string()),
        ("CMUX_TAG".to_string(), "dev".to_string()),
    ];
    assert_eq!(usable_env(&env), vec![("CMUX_TAG".to_string(), "dev".to_string())]);
}

/// Failure-mode table, "unreplayable screen": a previous screen that ends
/// inside a control string (a Kitty upload the lost program never ended)
/// does not swallow the reset and the marker line. (Coverage: it held
/// before this PR too; the parser leaves the string at the reset's ESC.)
#[test]
fn a_screen_that_ends_inside_a_control_string_keeps_the_marker_line() {
    let seed = respawn_seed(Some(b"text\r\n\x1b_Ga=t,f=100,m=1;AAAA".to_vec()), Some("restored"));
    let rows = shown(40, 5, &seed);
    assert!(rows.iter().any(|row| row == "restored"), "the marker was swallowed: {rows:?}");
}
