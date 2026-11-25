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
