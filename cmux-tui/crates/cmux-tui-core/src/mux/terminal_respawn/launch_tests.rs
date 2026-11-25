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

/// Every row `terminal` retains, oldest first: its history, then its screen.
fn retained_rows(terminal: &mut ghostty_vt::Terminal) -> Vec<String> {
    const PAGE: u16 = 1_000;
    let history = terminal.history_rows();
    let mut out = Vec::with_capacity(history as usize + usize::from(terminal.rows()));
    let mut start = 0_u32;
    while start < history {
        let page = terminal.styled_history_rows(start, PAGE).unwrap();
        if page.is_empty() {
            break;
        }
        start += page.len() as u32;
        out.extend(page.iter().map(|row| row.iter().map(|cell| cell.text.as_str()).collect()));
    }
    let cols = terminal.cols();
    for row in 0..terminal.rows() {
        out.push(terminal.selection_text((0, row), (cols - 1, row)).unwrap_or_default());
    }
    out
}

/// Leo (ask-e1f74d3ee2): "can we make the terminal restore all its possible
/// scroll-ups?" Ten thousand styled lines go to a terminal of the default
/// size (80x24) and the default scrollback (`DEFAULT_SCROLLBACK_LIMIT_BYTES`,
/// which holds about 13k such rows at 80 columns and about 9.2k at 120); each
/// line fills 75 columns, so the history outgrows the old 2,000-line snapshot
/// budget; the output store persists it as its writer does (the
/// snapshot, then the tail after it); the process is replaced: the respawn
/// reads the store (`previous_screen`: the snapshot and the tail rebuilt),
/// fits the seed, and a new terminal with the same scrollback replays the
/// seed. Every row the live terminal retained, line 1 included, must be in
/// the new terminal's retained rows (scrollable), found by a line search.
#[test]
fn a_respawned_terminal_keeps_ten_thousand_lines_for_scroll_and_find() {
    let (cols, rows) = (80_u16, 24_u16);
    let scrollback = crate::DEFAULT_SCROLLBACK_LIMIT_BYTES;
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let root =
        std::env::temp_dir().join(format!("cmux-respawn-10k-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let store = crate::output_store::OutputStore::new(Some(&root));
    let id =
        crate::resource::TerminalPublicId::parse("term_00000000000000000000000000000f4b").unwrap();
    let line = |n: usize| {
        let detail = format!("compiling crate {n} of the workspace, target/debug/deps ");
        format!("\x1b[3{}mline-{n:05}\x1b[0m {detail:.<64}\r\n", n % 8)
    };
    let before: String = (1..=9_000).map(line).collect();
    let after: String = (9_001..=10_000).map(line).collect();
    let mut live =
        ghostty_vt::Terminal::new(cols, rows, scrollback, ghostty_vt::Callbacks::default())
            .unwrap();
    live.vt_write(before.as_bytes());
    store.persist_for_test(&id, "g", &mut live, before.len() as u64, after.as_bytes()).unwrap();
    live.vt_write(after.as_bytes());
    let live_rows = retained_rows(&mut live);

    let previous = store.previous_screen(&id, scrollback);
    let _ = std::fs::remove_dir_all(&root);
    let previous = previous.expect("the store kept a screen");
    let replay_bytes = previous.bytes.len();
    let previous = fit_seed(previous, scrollback).expect("the screen fits a seed");
    let seed = respawn_seed(Some(previous.bytes), Some("restarted 05:34"));
    let mut respawned =
        ghostty_vt::Terminal::new(cols, rows, scrollback, ghostty_vt::Callbacks::default())
            .unwrap();
    respawned.vt_write(&seed);
    let restored = retained_rows(&mut respawned);
    eprintln!(
        "live rows {} (history {}, resident {:?} bytes); replay {replay_bytes} bytes; seed {} \
         bytes; respawned rows {}",
        live_rows.len(),
        live.history_rows(),
        live.primary_resident_bytes(),
        seed.len(),
        restored.len(),
    );
    let found = |rows: &[String], needle: &str| rows.iter().position(|row| row.contains(needle));
    assert!(found(&live_rows, "line-00001 ").is_some(), "the live terminal itself lost line 1");
    assert!(
        found(&restored, "line-00001 ").is_some(),
        "line 1 was lost across the respawn; the oldest restored row is {:?}",
        restored.first()
    );
    assert!(found(&restored, "line-10000 ").is_some(), "the newest line was lost");
    let kept: std::collections::HashSet<&String> = restored.iter().collect();
    let lost = live_rows.iter().filter(|row| !kept.contains(row)).count();
    assert_eq!(lost, 0, "{lost} of the live terminal's {} rows were lost", live_rows.len());
    assert!(found(&restored, "restarted 05:34").is_some(), "the seam marker is missing");
}
