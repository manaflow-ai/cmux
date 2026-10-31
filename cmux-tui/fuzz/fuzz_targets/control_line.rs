//! One control line, as a socket client sends it, through the daemon's own
//! parse (cmux-tui-core `server::fuzz_seam::parse_control_line`).
//!
//! Input: byte 0 picks the client's API revision (0: this daemon's own, so
//! no upgrade; else a revision in or just past the translated range, or any
//! u32), the rest is the line. The socket reader drops a connection on
//! invalid UTF-8 before any parse, so only UTF-8 reaches here.
//!
//! Oracle: no panic (a panic in the parse kills the connection thread and,
//! with `panic = "abort"`, the daemon); an over-limit line is refused before
//! any parse; every refusal is typed: a catalog error code for a
//! cmux.protocol/2 line, a serde error text for a legacy line; the same line
//! parses the same way twice.
#![no_main]

use cmux_tui_core::server::fuzz_seam::{ControlLine, parse_control_line, revision_range};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&pick, rest)) = data.split_first() else { return };
    let Ok(line) = std::str::from_utf8(rest) else { return };
    let (base, current) = revision_range();
    let revision = match pick {
        0 => None,
        255 => Some(u32::from_le_bytes([pick, rest.first().copied().unwrap_or(0), 0, 0])),
        n => Some(base.saturating_sub(1) + u32::from(n - 1) % (current - base + 3)),
    };
    let first = parse_control_line(line, revision);
    match &first {
        ControlLine::TooLarge => {}
        ControlLine::Resource(Err(code)) => assert!(!code.is_empty(), "untyped resource error"),
        ControlLine::Legacy(Err(text)) => assert!(!text.is_empty(), "untyped legacy error"),
        ControlLine::Resource(Ok(())) | ControlLine::Legacy(Ok(())) => {}
    }
    let second = parse_control_line(line, revision);
    assert_eq!(format!("{first:?}"), format!("{second:?}"), "the same line parsed two ways");
});
