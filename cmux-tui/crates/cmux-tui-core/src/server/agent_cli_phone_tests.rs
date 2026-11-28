//! A phone's viewer of Claude Code gets it drawn at the phone's grid from the transcript and
//! the Mac screen's facts, on the primary screen with no mouse modes. The session is a real
//! Claude Code 2.1.332 recording (cmux-agent-cli-render's `tests/fixtures/phone`).

use std::path::PathBuf;
use std::time::Instant;

use base64::Engine as _;
use serde_json::Value;

use super::super::agent_cli_hybrid::{HybridViewer, Wants};
use super::PhoneGrid;

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../cmux-agent-cli-render/tests/fixtures/phone/claude-code-2.1.332-59x42")
}

/// The Mac's PTY bytes up to the recording's `moment`.
fn bytes_until(moment: &str) -> Vec<u8> {
    let moments: Value =
        serde_json::from_str(&std::fs::read_to_string(fixture().join("moments.json")).unwrap())
            .unwrap();
    let at = moments
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["name"] == moment)
        .and_then(|m| m["t_ms"].as_u64())
        .unwrap();
    let mut out = Vec::new();
    for line in std::fs::read_to_string(fixture().join("pty.jsonl")).unwrap().lines() {
        let v: Value = serde_json::from_str(line).unwrap();
        if let Some(b64) = v["b64"].as_str()
            && v["t_ms"].as_u64().is_some_and(|t| t <= at)
        {
            out.extend(base64::engine::general_purpose::STANDARD.decode(b64).unwrap());
        }
    }
    out
}

fn phone() -> PhoneGrid {
    PhoneGrid::new(50, 34, fixture().join("transcript.jsonl")).unwrap()
}

#[test]
fn claude_code_is_drawn_at_the_phones_grid_from_its_transcript_and_the_macs_screen() {
    let (mut viewer, first) = HybridViewer::start_with(
        7,
        59,
        42,
        &bytes_until("done"),
        None,
        Wants::default(),
        Some(phone()),
    )
    .unwrap();
    let first = first.unwrap();
    assert_eq!((first["cols"].as_u64(), first["rows"].as_u64()), (Some(50), Some(34)));
    // The primary screen (no switch to the alternate one), and its history before the frame.
    let before =
        viewer.screen_before_first_frame().map(|b| String::from_utf8_lossy(&b).into_owned());
    assert!(before.as_deref().is_none_or(|b| !b.contains("1049h")), "{before:?}");
    // Keys and pastes follow the program; touches stay on the phone.
    let modes =
        viewer.input_modes().map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
    assert!(modes.contains("?2004h"), "{modes}");
    for mouse in ["?1000h", "?1002h", "?1003h", "?1006h"] {
        assert!(!modes.contains(mouse), "{modes}");
    }
    // The Mac's terminal resizing keeps the phone's grid.
    let keyframe = viewer.resized(100, 30, &bytes_until("done")).unwrap();
    assert_eq!((keyframe["cols"].as_u64(), keyframe["rows"].as_u64()), (Some(50), Some(34)));
    // Typing on the Mac shows on the phone.
    let now = Instant::now();
    viewer.output(b"", now);
    assert!(viewer.frame_now(now).is_ok());
}

#[test]
fn a_viewer_with_no_phone_grid_keeps_the_macs_screen() {
    let (_viewer, first) =
        HybridViewer::start_with(7, 59, 42, &bytes_until("done"), None, Wants::default(), None)
            .unwrap();
    let first = first.unwrap();
    assert_eq!((first["cols"].as_u64(), first["rows"].as_u64()), (Some(59), Some(42)));
}

#[test]
fn a_grid_too_small_to_draw_is_refused() {
    assert!(PhoneGrid::new(10, 34, fixture().join("transcript.jsonl")).is_none());
    assert!(PhoneGrid::new(50, 4, fixture().join("transcript.jsonl")).is_none());
}

#[test]
fn the_mac_screens_facts_and_the_transcript_make_the_phones_screen() {
    let mut phone = phone();
    assert!(phone.transcript().is_file());
    for (moment, want) in [
        // The transcript is the whole session's (the file as it ended), so only the Mac
        // screen's facts change between the two looks.
        ("start", &["Claude Code v2.1.332", "Opus 5.5", "auto mode on"][..]),
        ("done", &["Create hello.py", "Churned", "Ran 1 shell command"][..]),
    ] {
        let mut term =
            super::super::agent_cli_hybrid::shadow(59, 42, &bytes_until(moment)).unwrap();
        let mut render = ghostty_vt::RenderState::new().unwrap();
        render.update(&mut term).unwrap();
        let mac = super::super::agent_cli_hybrid::grid(&render.build_frame().unwrap());
        let (history, drawn) = phone.draw(&mac, true);
        assert_eq!((drawn.cols, drawn.rows), (50, 34));
        // The phone's screen and the rows above it, which its scrollback holds.
        let above = cmux_agent_cli_render::Grid {
            cols: 50,
            rows: u16::try_from(history.len()).unwrap(),
            cells: history,
        };
        let rows: Vec<String> = (0..above.cells.len())
            .map(|y| above.row_text(y))
            .chain((0..drawn.cells.len()).map(|y| drawn.row_text(y)))
            .collect();
        for want in want {
            assert!(rows.iter().any(|r| r.contains(want)), "{moment}: no {want:?} in {rows:#?}");
        }
    }
}

/// A growing transcript is folded from where the last read stopped, a line cut mid-write
/// included, and ends with the turns one whole read gives: a long session's change costs its
/// new lines, not the whole file again.
#[test]
fn a_growing_transcript_folds_only_what_it_gained() {
    let whole = std::fs::read(fixture().join("transcript.jsonl")).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-phone-grid-grow-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("transcript.jsonl");
    std::fs::write(&path, b"").unwrap();
    let mut phone = PhoneGrid::new(50, 34, path.clone()).unwrap();
    // Seven appends, cut at arbitrary bytes, so most cuts fall inside a line.
    let step = whole.len() / 7 + 1;
    let mut written = 0;
    while written < whole.len() {
        let end = (written + step).min(whole.len());
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        std::io::Write::write_all(&mut f, &whole[written..end]).unwrap();
        written = end;
        phone.refresh();
        assert_eq!(phone.offset, written as u64);
    }
    let full = acpmux::adopt_replay::read("claude", &fixture().join("transcript.jsonl"));
    assert!(!full.is_empty());
    assert_eq!(phone.turns(), full.as_slice());
    // A rewritten (shorter) file is a new transcript, folded from its start.
    std::fs::write(&path, b"").unwrap();
    phone.refresh();
    assert!(phone.turns().is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// Another file at the transcript's path (a rewrite or a log rotation, even one longer than
/// what was read) is folded from its start: two sessions never mix.
#[test]
fn another_file_at_the_path_is_folded_from_its_start() {
    let whole = std::fs::read(fixture().join("transcript.jsonl")).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-phone-grid-swap-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("transcript.jsonl");
    std::fs::write(&path, &whole).unwrap();
    let mut phone = PhoneGrid::new(50, 34, path.clone()).unwrap();
    phone.refresh();
    let full = phone.turns().to_vec();
    assert!(!full.is_empty());
    // A new file, renamed over the old one, holding the old one's first turn twice over.
    let first_turn_end = whole.iter().position(|&b| b == b'\n').unwrap() + 1;
    let mut other = whole[..first_turn_end].to_vec();
    other.extend_from_slice(&whole);
    let next = dir.join("next.jsonl");
    std::fs::write(&next, &other).unwrap();
    std::fs::rename(&next, &path).unwrap();
    phone.refresh();
    assert_eq!(phone.offset, other.len() as u64);
    let reread = acpmux::adopt_replay::read("claude", &path);
    assert_eq!(phone.turns(), reread.as_slice());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A line that never ends holds at most its bound, is dropped up to its end, and the records
/// after it fold as usual.
#[test]
fn a_runaway_unended_line_is_bounded_and_skipped() {
    let whole = std::fs::read(fixture().join("transcript.jsonl")).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-phone-grid-long-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("transcript.jsonl");
    std::fs::write(&path, b"").unwrap();
    let mut phone = PhoneGrid::new(50, 34, path.clone()).unwrap();
    let chunk = vec![b'x'; 8 << 20];
    for _ in 0..9 {
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        std::io::Write::write_all(&mut f, &chunk).unwrap();
        phone.refresh();
        assert!(phone.partial_len() <= super::MAX_PARTIAL_BYTES);
    }
    let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    std::io::Write::write_all(&mut f, b"\n").unwrap();
    std::io::Write::write_all(&mut f, &whole).unwrap();
    phone.refresh();
    assert_eq!(phone.partial_len(), 0);
    let full = acpmux::adopt_replay::read("claude", &fixture().join("transcript.jsonl"));
    assert_eq!(phone.turns(), full.as_slice());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A record bigger than the old 16 MiB guess (a pasted screenshot's base64, a long tool output)
/// still folds, as the whole reader folds it.
#[test]
fn a_large_valid_record_folds_as_the_whole_reader_folds_it() {
    let whole = std::fs::read(fixture().join("transcript.jsonl")).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-phone-grid-big-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("transcript.jsonl");
    let big = serde_json::json!({
        "type": "user", "timestamp": "2026-11-25T10:00:00.000Z",
        "message": {"role": "user", "content": format!("big {}", "y".repeat(20 << 20))},
    });
    let mut bytes = serde_json::to_vec(&big).unwrap();
    bytes.push(b'\n');
    bytes.extend_from_slice(&whole);
    std::fs::write(&path, b"").unwrap();
    let mut phone = PhoneGrid::new(50, 34, path.clone()).unwrap();
    for piece in bytes.chunks(3 << 20) {
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        std::io::Write::write_all(&mut f, piece).unwrap();
        phone.refresh();
    }
    let reread = acpmux::adopt_replay::read("claude", &path);
    assert_eq!(phone.turns(), reread.as_slice());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// The same file rewritten in place, as long or longer, is folded from its start: the bytes
/// last folded are not there any more.
#[test]
fn a_file_rewritten_in_place_is_folded_from_its_start() {
    let whole = std::fs::read(fixture().join("transcript.jsonl")).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-phone-grid-inplace-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("transcript.jsonl");
    let half = whole.len() / 2;
    let half = whole[..half].iter().rposition(|&b| b == b'\n').unwrap() + 1;
    std::fs::write(&path, &whole[half..]).unwrap();
    let mut phone = PhoneGrid::new(50, 34, path.clone()).unwrap();
    phone.refresh();
    // Same inode, truncated and written again with the whole session (longer than before).
    let mut f = std::fs::OpenOptions::new().write(true).truncate(true).open(&path).unwrap();
    std::io::Write::write_all(&mut f, &whole).unwrap();
    drop(f);
    phone.refresh();
    let full = acpmux::adopt_replay::read("claude", &path);
    assert_eq!(phone.turns(), full.as_slice());
    std::fs::remove_dir_all(&dir).unwrap();
}
