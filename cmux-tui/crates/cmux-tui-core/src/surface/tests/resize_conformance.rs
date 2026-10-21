//! Resize conformance of the PTY server against plain Ghostty.
//!
//! Each scenario sends the same scripted output and the same resize sequence
//! through a cmux PTY surface (the daemon's terminal: output normalization,
//! the resize path to the PTY and the grid, cell pixels, the daemon-side
//! viewport) and through a reference: a fresh libghostty-vt terminal that
//! parses the bytes and resizes directly, as a Ghostty surface with its own
//! pty does. After every step the two must agree on the history and screen
//! text, the cursor, the scrollbar and a scrolled-back viewport, and the PTY
//! must hold the grid's size (the size the program sees on SIGWINCH).
//!
//! The demo scenario is shaped like Claude Code: a main-screen program that
//! keeps a box-drawn prompt at the bottom and redraws it at the new width
//! after each resize, over soft-wrapped and styled scrollback, plus an
//! alternate-screen program. The mirror half (the app's GhosttyNextKit
//! surface restoring the daemon's snapshots) is the same suite in
//! ghostty-next `src/termio/Termio.zig`, tests "manual: snapshot ...".

use super::*;

/// The reference terminal: plain Ghostty with the same scrollback.
struct Reference {
    term: Terminal,
    cell: (u16, u16),
}

impl Reference {
    fn new(cols: u16, rows: u16, scrollback: usize, cell: (u16, u16)) -> Self {
        let mut term = Terminal::new(cols, rows, scrollback, Callbacks::default()).unwrap();
        term.resize(cols, rows, u32::from(cell.0), u32::from(cell.1)).unwrap();
        Self { term, cell }
    }

    fn resize(&mut self, cols: u16, rows: u16) {
        self.term.resize(cols, rows, u32::from(self.cell.0), u32::from(self.cell.1)).unwrap();
    }
}

/// One scenario: a surface, the reference, and the program's idea of the size.
struct Scenario {
    _mux: Arc<Mux>,
    surface: Arc<Surface>,
    reference: Reference,
    cols: u16,
    rows: u16,
}

impl Scenario {
    fn new(name: &str, cols: u16, rows: u16) -> Self {
        let opts = SurfaceOptions { cols, rows, ..SurfaceOptions::default() };
        let mux = Mux::new_for_test(name, opts.clone());
        let surface = Surface::spawn_for_test(1, opts.clone(), Arc::downgrade(&mux)).unwrap();
        let reference = Reference::new(cols, rows, opts.scrollback, surface.test_cell_pixel_size());
        Self { _mux: mux, surface, reference, cols, rows }
    }

    fn output(&mut self, bytes: &[u8]) {
        self.surface.inject_output_for_test(bytes);
        self.reference.term.vt_write(bytes);
    }

    /// The window changes: the PTY server resizes, then the program redraws
    /// for the size it reads from the PTY (`redraw`).
    fn resize(&mut self, cols: u16, rows: u16, redraw: impl Fn(u16, u16) -> Vec<u8>) {
        self.surface.resize(cols, rows).unwrap();
        self.reference.resize(cols, rows);
        let pty = self.surface.test_master_size();
        assert_eq!((pty.cols, pty.rows), (cols, rows), "the PTY holds the grid's size");
        self.cols = pty.cols;
        self.rows = pty.rows;
        let bytes = redraw(self.cols, self.rows);
        self.output(&bytes);
        self.check(&format!("after resize to {cols}x{rows}"));
    }

    fn check(&mut self, step: &str) {
        let reference = &mut self.reference.term;
        let owner = self.surface.as_pty().unwrap();
        let mut term = owner.term.lock().unwrap();
        assert_eq!(
            (term.cols(), term.rows()),
            (reference.cols(), reference.rows()),
            "{step}: grid"
        );
        assert_eq!(
            term.plain_text().unwrap(),
            reference.plain_text().unwrap(),
            "{step}: history and screen text"
        );
        assert_eq!(term.cursor_position(), reference.cursor_position(), "{step}: cursor");
        assert_eq!(term.active_screen(), reference.active_screen(), "{step}: active screen");
        let bar = term.scrollbar().map(|bar| (bar.total, bar.len));
        assert_eq!(
            bar,
            reference.scrollbar().map(|bar| (bar.total, bar.len)),
            "{step}: scrollback rows"
        );
        drop(term);
        assert_eq!(self.surface.size(), (self.cols, self.rows), "{step}: surface size");
    }
}

/// Scrollback like an agent session: numbered, styled, every fourth line
/// longer than a wide window so it soft-wraps.
fn transcript(first: usize, count: usize) -> Vec<u8> {
    let mut out = String::new();
    for i in first..first + count {
        if i % 4 == 0 {
            out.push_str(&format!(
                "\x1b[1m⏺ step {i:04}\x1b[0m {}\r\n",
                "the quick brown fox jumps over the lazy dog ".repeat(4)
            ));
        } else {
            out.push_str(&format!(
                "  \x1b[2m⎿ \x1b[0m\x1b[3{}mresult {i:04}\x1b[0m ok\r\n",
                i % 7 + 1
            ));
        }
    }
    out.into_bytes()
}

/// The prompt box a main-screen agent keeps at the bottom, `cols` wide.
fn prompt_box(cols: u16, text: &str) -> String {
    let inner = usize::from(cols.max(4)) - 2;
    let body: String = format!(" > {text}").chars().take(inner).collect();
    let pad = inner - body.chars().count();
    format!(
        "\x1b[38;5;244m╭{}╮\r\n│\x1b[0m{body}{}\x1b[38;5;244m│\r\n╰{}╯\x1b[0m\r\n  ? for shortcuts",
        "─".repeat(inner),
        " ".repeat(pad),
        "─".repeat(inner),
    )
}

/// An Ink-style frame: under synchronized output, erase the last frame's
/// lines (cursor up, erase line) and write the new one.
fn agent_frame(cols: u16, last_lines: usize, text: &str) -> Vec<u8> {
    let mut out = String::from("\x1b[?2026h\r");
    for _ in 0..last_lines {
        out.push_str("\x1b[2K\x1b[1A");
    }
    out.push_str("\x1b[2K");
    out.push_str(&prompt_box(cols, text));
    out.push_str("\x1b[?2026l");
    out.into_bytes()
}

const FRAME_LINES: usize = 3;

/// The resize schedule: narrower, wider, taller, an A-B-A drag, a burst.
const SIZES: [(u16, u16); 9] =
    [(60, 24), (120, 30), (100, 30), (80, 24), (100, 30), (41, 12), (42, 12), (43, 13), (80, 24)];

#[test]
fn resize_conformance_main_screen_agent_matches_ghostty() {
    let mut s = Scenario::new("resize-conformance-agent", 80, 24);
    s.output(&transcript(0, 600));
    s.output(&agent_frame(80, 0, "fix the resize bug"));
    s.check("before any resize");
    for (cols, rows) in SIZES {
        s.resize(cols, rows, |cols, _| agent_frame(cols, FRAME_LINES, "fix the resize bug"));
        // The agent keeps writing at the new width while the person reads.
        let mut more = transcript(600 + usize::from(cols), 5);
        more.extend(agent_frame(cols, FRAME_LINES, "still going"));
        s.output(&more);
        s.check(&format!("output at {cols}x{rows}"));
    }
}

#[test]
fn resize_conformance_scrolled_back_daemon_viewport_matches_ghostty() {
    let mut s = Scenario::new("resize-conformance-scrolled", 80, 24);
    s.output(&transcript(0, 600));
    s.output(&agent_frame(80, 0, "read the history"));
    s.surface.view_scroll_delta(-200).unwrap();
    s.reference.term.scroll_delta(-200);
    for (cols, rows) in SIZES {
        s.resize(cols, rows, |cols, _| agent_frame(cols, FRAME_LINES, "read the history"));
        let owner = s.surface.view_scrollbar().expect("owner scrollbar");
        let reference = s.reference.term.scrollbar().expect("reference scrollbar");
        assert!(owner.offset + owner.len < owner.total, "{cols}x{rows}: still scrolled back");
        assert_eq!(
            owner.total - owner.offset,
            reference.total - reference.offset,
            "{cols}x{rows}: the viewport stays on the rows it showed, as in Ghostty"
        );
    }
}

#[test]
fn resize_conformance_alternate_screen_program_matches_ghostty() {
    fn full_screen(cols: u16, rows: u16) -> Vec<u8> {
        let mut out = String::from("\x1b[?2026h\x1b[H\x1b[2J");
        for row in 1..=rows {
            let label = format!("row {row:02} of {rows} at {cols} cols ");
            let line: String = label.chars().cycle().take(usize::from(cols)).collect();
            out.push_str(&format!("\x1b[{row};1H{line}"));
        }
        out.push_str(&format!("\x1b[{rows};1H\x1b[7m status \x1b[0m\x1b[?2026l"));
        out.into_bytes()
    }
    let mut s = Scenario::new("resize-conformance-alternate", 80, 24);
    s.output(&transcript(0, 300));
    s.output(b"\x1b[?1049h");
    s.output(&full_screen(80, 24));
    s.check("alternate screen");
    for (cols, rows) in SIZES {
        s.resize(cols, rows, full_screen);
    }
    // Leaving the program shows the primary screen and its scrollback, as reflowed.
    s.output(b"\x1b[?1049l");
    s.output(&transcript(300, 3));
    s.check("back on the primary screen");
}
