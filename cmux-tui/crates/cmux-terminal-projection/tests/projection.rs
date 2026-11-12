//! The phone's terminal, fed what the projection writes, holds the host's
//! logical lines at its own width, with the cursor in the same place.
//! The "phone's terminal" here is the crate's own VT model at the phone's
//! grid (the app feeds Ghostty the same bytes).

use cmux_terminal_projection::terminal::{Row, SPACER_HEAD, Terminal, WIDE_TAIL};
use cmux_terminal_projection::{Projection, Segment};

struct Phone {
    term: Terminal,
    resets: usize,
    bytes: usize,
}

impl Phone {
    fn new(cols: usize, rows: usize) -> Phone {
        Phone { term: Terminal::new(cols, rows, 100_000), resets: 0, bytes: 0 }
    }

    fn apply(&mut self, segments: Vec<Segment>) {
        for segment in segments {
            match segment {
                Segment::Paint(bytes) | Segment::Raw(bytes) => {
                    self.bytes += bytes.len();
                    for b in bytes {
                        self.term.advance(b);
                    }
                }
                Segment::Reset(bytes) => {
                    self.resets += 1;
                    self.bytes += bytes.len();
                    for b in b"\x1bc".iter().chain(bytes.iter()) {
                        self.term.advance(*b);
                    }
                }
                Segment::Alternate(_) => {}
            }
        }
    }
}

fn row_text(term: &Terminal, row: &Row) -> String {
    row.cells
        .iter()
        .filter(|c| c.kind != WIDE_TAIL && c.kind != SPACER_HEAD)
        .map(|c| if c.ch == 0 { " ".to_string() } else { term.cell_text(*c) })
        .collect()
}

/// The terminal's logical lines (history and screen), trailing blanks and
/// trailing empty lines dropped; and the cursor as (line, offset in it).
fn logical(term: &Terminal, skip: usize) -> (Vec<String>, (usize, usize)) {
    let rows: Vec<&Row> =
        term.history.iter().skip(skip).chain(term.primary_rows().iter()).collect();
    let (cx, cy) = term.primary_cursor();
    let cursor_row = term.history.len() - skip + cy;
    let mut lines = Vec::new();
    let mut current = String::new();
    let mut cursor = (0, 0);
    for (i, row) in rows.iter().enumerate() {
        if i == cursor_row {
            let before: String = row
                .cells
                .iter()
                .take(cx)
                .filter(|c| c.kind != WIDE_TAIL && c.kind != SPACER_HEAD)
                .map(|c| if c.ch == 0 { " ".to_string() } else { term.cell_text(*c) })
                .collect();
            cursor = (lines.len(), current.chars().count() + before.chars().count());
        }
        current.push_str(&row_text(term, row));
        if !row.wrapped || i + 1 == rows.len() {
            lines.push(current.trim_end().to_string());
            current = String::new();
        } else {
            // A soft-wrapped row's trailing cells are part of the line.
        }
    }
    // A hidden cursor (the phone's, above its screen) keeps no line.
    let keep = if term.cursor_visible { cursor.0 + 1 } else { 0 };
    while lines.last().is_some_and(|l| l.is_empty()) && lines.len() > keep {
        lines.pop();
    }
    (lines, cursor)
}

/// The host and the phone hold the same lines (the host's from the
/// phone's window on); the cursor is on the same glyph.
fn assert_same(host: &Projection, phone: &Phone, context: &str) {
    let (host_lines, host_cursor) = logical(host.terminal(), host.older_rows());
    let (phone_lines, phone_cursor) = logical(&phone.term, 0);
    // A wrapped row's trailing spaces are dropped by the phone's own trim.
    let norm = |lines: &[String]| {
        let mut lines: Vec<String> = lines.iter().map(|l| l.trim_end().to_string()).collect();
        while lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        lines
    };
    let (phone_norm, host_norm) = (norm(&phone_lines), norm(&host_lines));
    if phone_norm != host_norm {
        let first = phone_norm
            .iter()
            .zip(&host_norm)
            .position(|(a, b)| a != b)
            .unwrap_or(phone_norm.len().min(host_norm.len()));
        let p: Vec<char> = phone_norm.get(first).map_or(vec![], |l| l.chars().collect());
        let h: Vec<char> = host_norm.get(first).map_or(vec![], |l| l.chars().collect());
        let at = p.iter().zip(&h).position(|(a, b)| a != b).unwrap_or(p.len().min(h.len()));
        let window = |v: &[char]| {
            v[at.saturating_sub(20)..(at + 20).min(v.len())].iter().collect::<String>()
        };
        panic!(
            "lines differ ({context}) at line {first} of {} (phone) / {} (host), char {at} of {} / {}\nphone: {:?}\nhost:  {:?}",
            phone_norm.len(),
            host_norm.len(),
            p.len(),
            h.len(),
            window(&p),
            window(&h)
        );
    }
    // A cursor above the phone's screen (a host row re-wrapped taller than
    // the phone) is hidden there, not placed.
    if !host.is_alternate() && phone.term.cursor_visible {
        assert_eq!(phone_cursor.0, host_cursor.0, "cursor line ({context})");
        let line_len = host_lines.get(host_cursor.0).map_or(0, |l| l.chars().count());
        if host_cursor.1 < line_len {
            assert_eq!(phone_cursor.1, host_cursor.1, "cursor offset ({context})");
        } else {
            // At or past the line's end the cursor may wait on the phone's last cell.
            assert!(
                phone_cursor.1 + 1 >= line_len.min(host_cursor.1)
                    && phone_cursor.1 <= host_cursor.1,
                "cursor offset {} vs {} ({context})",
                phone_cursor.1,
                host_cursor.1
            );
        }
    }
}

fn feed(host: &mut Projection, phone: &mut Phone, bytes: &[u8]) {
    let segments = host.feed(bytes, true);
    phone.apply(segments);
}

#[test]
fn a_shell_session_reflows_at_the_phone_width() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    feed(&mut host, &mut phone, b"\x1b[32m~/src\x1b[0m $ ls\r\n");
    feed(&mut host, &mut phone, "Cargo.toml  README.md  src  target  a-very-long-file-name-that-goes-on.txt  another-one.rs  third_file.md  fourth.json\r\n".as_bytes());
    feed(&mut host, &mut phone, b"\x1b[32m~/src\x1b[0m $ ");
    assert_same(&host, &phone, "after ls");
    // Typing echoes: each key is a few bytes, never a repaint.
    for &key in b"echo hi" {
        let before = phone.bytes;
        feed(&mut host, &mut phone, &[key]);
        assert!(phone.bytes - before <= 4, "an echo wrote {} bytes", phone.bytes - before);
        assert_same(&host, &phone, "typing");
    }
    assert_eq!(phone.resets, 1, "only the first paint resets");
}

#[test]
fn streaming_output_scrolls_into_the_phones_scrollback() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    for i in 0..400 {
        let line = format!("line {i:04} {}\r\n", "word ".repeat(i % 37));
        // Byte by byte for some, whole for others.
        if i % 5 == 0 {
            for b in line.as_bytes() {
                feed(&mut host, &mut phone, &[*b]);
            }
        } else {
            feed(&mut host, &mut phone, line.as_bytes());
        }
    }
    assert_same(&host, &phone, "after 400 lines");
    assert_eq!(phone.resets, 1);
}

#[test]
fn an_inline_tui_redraws_its_live_region_in_place() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    let border = "─".repeat(118);
    for frame in 0..60 {
        let mut out = String::new();
        if frame > 0 {
            // Back to the top of the live region, erase it.
            out.push_str("\x1b[5A\r\x1b[J");
        }
        if frame % 10 == 9 {
            out.push_str(&format!(
                "⏺ Message {frame}: {}\r\n",
                "the reply text goes on for a while ".repeat(5)
            ));
        }
        let spinner = ["·", "✢", "✳", "✶"][frame % 4];
        out.push_str(&format!(
            "\x1b[33m{spinner}\x1b[0m Thinking… ({frame}s · esc to interrupt)\r\n"
        ));
        out.push_str(&format!("╭{border}╮\r\n"));
        out.push_str(&format!("│ > {:<114} │\r\n", "fix the flaky test"));
        out.push_str(&format!("╰{border}╯\r\n"));
        out.push_str("  ? for shortcuts");
        out.push_str("\x1b[3A\x1b[24G");
        feed(&mut host, &mut phone, out.as_bytes());
        assert_same(&host, &phone, &format!("frame {frame}"));
    }
    assert_eq!(phone.resets, 1, "a live region inside the phone's screen never resets it");
}

#[test]
fn clear_with_scrollback_starts_the_phone_over() {
    let mut host = Projection::new(80, 24, 10_000);
    let mut phone = Phone::new(40, 20);
    phone.apply(host.set_viewport(40, 20));
    for i in 0..100 {
        feed(&mut host, &mut phone, format!("output {i}\r\n").as_bytes());
    }
    feed(&mut host, &mut phone, b"$ clear\r\n\x1b[H\x1b[2J\x1b[3J$ ");
    assert_same(&host, &phone, "after clear");
    assert_eq!(phone.resets, 2);
    assert!(phone.term.history.len() <= 1, "the phone's scrollback went too");
}

#[test]
fn ctrl_l_keeps_the_prompt_at_the_top() {
    let mut host = Projection::new(80, 24, 10_000);
    let mut phone = Phone::new(40, 20);
    phone.apply(host.set_viewport(40, 20));
    for i in 0..10 {
        feed(&mut host, &mut phone, format!("output {i}\r\n").as_bytes());
    }
    feed(&mut host, &mut phone, b"$ \x1b[H\x1b[2J$ ");
    assert_same(&host, &phone, "after ^L");
    let (_, y) = phone.term.primary_cursor();
    assert_eq!(y, 0, "the prompt is at the top of the phone's screen");
}

#[test]
fn the_alternate_screen_passes_through_and_the_primary_comes_back() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    feed(&mut host, &mut phone, format!("$ {}\r\n$ vim\r\n", "x".repeat(150)).as_bytes());
    let segments = host.feed(b"\x1b[?1049h\x1b[H\x1b[2Jvim screen\x1b[10;10H", true);
    assert!(segments.contains(&Segment::Alternate(true)));
    assert!(segments.iter().any(|s| matches!(s, Segment::Raw(b) if b.ends_with(b"\x1b[10;10H"))));
    phone.apply(segments);
    let segments = host.feed(b"more\x1b[?1049l", true);
    assert!(segments.contains(&Segment::Alternate(false)));
    phone.apply(segments);
    phone.apply(host.paint().into_iter().collect());
    assert_same(&host, &phone, "back from vim");
}

#[test]
fn a_viewport_change_repaints_as_if_fresh() {
    let script: Vec<u8> = (0..80)
        .flat_map(|i| format!("{i}: {}\r\n", "abc def ghi ".repeat(i % 13)).into_bytes())
        .collect();
    let mut host = Projection::new(100, 30, 10_000);
    let _ = host.set_viewport(40, 30);
    let _ = host.feed(&script, true);
    let rotated = host.set_viewport(70, 20);
    let mut fresh = Projection::new(100, 30, 10_000);
    let _ = fresh.feed(&script, true);
    let direct = fresh.set_viewport(70, 20);
    assert_eq!(rotated, direct, "wrapping at 40 then 70 equals wrapping at 70");
    let mut phone = Phone::new(70, 20);
    phone.apply(rotated);
    assert_same(&host, &phone, "rotated");
}

fn numbered(lines: usize) -> Vec<u8> {
    (0..lines)
        .flat_map(|i| format!("{i:05} {}\r\n", "word ".repeat(5 + i % 17)).into_bytes())
        .collect()
}

#[test]
fn a_rotation_repaints_a_window_and_older_rows_come_on_demand() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    feed(&mut host, &mut phone, &numbered(3_000));
    assert_eq!(host.older_rows(), 0, "streamed output keeps all of it");
    assert_same(&host, &phone, "streamed");
    let mut phone = Phone::new(116, 16);
    let rotated = host.set_viewport(116, 16);
    let bytes: usize = rotated
        .iter()
        .map(|s| match s {
            Segment::Reset(b) | Segment::Paint(b) => b.len(),
            _ => 0,
        })
        .sum();
    phone.apply(rotated);
    assert!(host.older_rows() > 2_000, "the rotation painted a window, not 3,000 lines");
    assert!(bytes < 20_000, "a window's bytes ({bytes})");
    assert_same(&host, &phone, "rotated window");
    // Scrolling up brings the rest, a chunk at a time.
    let mut loads = 0;
    while host.older_rows() > 0 {
        let before = host.older_rows();
        let mut fresh = Phone::new(116, 16);
        fresh.apply(host.load_older(1_000));
        assert!(host.older_rows() < before);
        phone = fresh;
        assert_same(&host, &phone, "older rows");
        loads += 1;
    }
    assert!((2..=4).contains(&loads), "{loads} loads");
    assert!(host.load_older(1_000).is_empty(), "nothing older");
    // Output after it is still incremental.
    feed(&mut host, &mut phone, b"$ ls\r\n");
    assert_same(&host, &phone, "after loading");
}

#[test]
fn a_rotation_keeps_the_lines_being_read() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    feed(&mut host, &mut phone, &numbered(3_000));
    // Reading the 1000th line from the end, roughly: the phone's rows to it.
    let phone_rows = phone.term.history.len() + 38;
    let target = phone
        .term
        .history
        .iter()
        .position(|r| row_text(&phone.term, r).starts_with("02000 "))
        .unwrap();
    host.set_reader_rows_from_end(phone_rows - target);
    let mut phone = Phone::new(116, 16);
    phone.apply(host.set_viewport(116, 16));
    let (lines, _) = logical(&phone.term, 0);
    assert!(lines.iter().any(|l| l.starts_with("02000 ")), "the line read is on the phone");
    assert!(lines.iter().any(|l| l.starts_with("01999 ")), "and a screen above it");
    assert!(host.older_rows() > 1_000, "but not the whole scrollback");
    assert_same(&host, &phone, "anchored");
}

#[test]
fn wide_and_combining_glyphs_keep_their_cells() {
    let mut host = Projection::new(20, 10, 10_000);
    let mut phone = Phone::new(7, 10);
    phone.apply(host.set_viewport(7, 10));
    feed(&mut host, &mut phone, "日本語のテキストと e\u{301}t\u{e9} 🎉 done\r\n$ ".as_bytes());
    assert_same(&host, &phone, "wide");
}

#[test]
fn on_the_alternate_screen_the_phone_answers_reports_alone() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    let segments = host.feed(b"\x1b[?1049h\x1b[6n\x1b[?6n\x1b[18t", true);
    let raw: Vec<u8> = segments
        .iter()
        .filter_map(|s| if let Segment::Raw(b) = s { Some(b.clone()) } else { None })
        .flatten()
        .collect();
    assert!(raw.ends_with(b"\x1b[6n\x1b[?6n\x1b[18t"), "the queries reach the phone's terminal");
    assert!(host.take_replies().is_empty(), "and only it answers them");
    // Back on the primary screen the projection answers (the phone's terminal never sees them).
    let _ = host.feed(b"\x1b[?1049l\x1b[6n", true);
    assert_eq!(host.take_replies(), b"\x1b[1;1R");
}

#[test]
fn the_alternate_screen_is_entered_with_the_programs_own_mode() {
    for mode in [47, 1047, 1049] {
        let mut host = Projection::new(80, 24, 10_000);
        let _ = host.set_viewport(40, 20);
        let segments = host.feed(format!("$ \x1b[?{mode}hfull").as_bytes(), true);
        let entry = format!("\x1b[?{mode}h").into_bytes();
        assert!(
            segments.iter().any(|s| matches!(s, Segment::Raw(b) if b.starts_with(&entry))),
            "mode {mode}: {segments:?}"
        );
        assert!(
            !segments.iter().any(|s| matches!(s, Segment::Raw(b) if mode != 1049 && b.windows(7).any(|w| w == b"?1049h"))),
            "mode {mode} is not rewritten as 1049"
        );
    }
}

#[test]
fn cursor_reports_are_in_host_cells() {
    let mut host = Projection::new(120, 40, 10_000);
    let mut phone = Phone::new(54, 38);
    phone.apply(host.set_viewport(54, 38));
    feed(&mut host, &mut phone, b"\x1b[3;100H\x1b[6n\x1b[18t");
    assert_eq!(host.take_replies(), b"\x1b[3;100R\x1b[8;40;120t");
}

/// A small deterministic generator (no dependency).
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

#[test]
fn random_streams_keep_the_phone_identical() {
    for seed in 1..=200u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15));
        let host_cols = 20 + rng.below(100) as usize;
        let host_rows = 5 + rng.below(40) as usize;
        let phone_cols = 10 + rng.below(60) as usize;
        let phone_rows = 5 + rng.below(40) as usize;
        let mut host = Projection::new(host_cols, host_rows, 100_000);
        let mut phone = Phone::new(phone_cols, phone_rows);
        phone.apply(host.set_viewport(phone_cols, phone_rows));
        for step in 0..300 {
            let mut chunk = Vec::new();
            for _ in 0..1 + rng.below(6) {
                match rng.below(16) {
                    0..=5 => {
                        let len = rng.below(150) as usize;
                        for _ in 0..len {
                            let c = b'a' + rng.below(26) as u8;
                            chunk.push(if rng.below(9) == 0 { b' ' } else { c });
                        }
                    }
                    6 => chunk.extend_from_slice(b"\r\n"),
                    7 => chunk.extend_from_slice(format!("\x1b[{}m", 30 + rng.below(8)).as_bytes()),
                    8 => chunk.extend_from_slice(format!("\x1b[{}A", 1 + rng.below(4)).as_bytes()),
                    9 => chunk.extend_from_slice(b"\r\x1b[K"),
                    10 => chunk.extend_from_slice(b"\x1b[J"),
                    11 => chunk.extend_from_slice(
                        format!("\x1b[{}G", 1 + rng.below(host_cols as u64)).as_bytes(),
                    ),
                    12 => chunk.extend_from_slice("世界".as_bytes()),
                    13 => chunk.extend_from_slice(
                        format!(
                            "\x1b[{};{}H",
                            1 + rng.below(host_rows as u64),
                            1 + rng.below(host_cols as u64)
                        )
                        .as_bytes(),
                    ),
                    14 => chunk.extend_from_slice(b"\x1b[0m"),
                    _ => chunk.extend_from_slice(format!("\x1b[{}B", 1 + rng.below(3)).as_bytes()),
                }
            }
            // Split the chunk at a random point (sequences cross feeds).
            let cut = rng.below(chunk.len() as u64 + 1) as usize;
            if std::env::var("PROJ_DEBUG").ok() == Some(format!("{seed}:{step}")) {
                for part in [&chunk[..cut], &chunk[cut..]] {
                    let segs = host.feed(part, true);
                    eprintln!("IN {:?}", String::from_utf8_lossy(part));
                    for seg in &segs {
                        if let Segment::Paint(b) | Segment::Reset(b) = seg {
                            eprintln!("OUT {:?}", String::from_utf8_lossy(b));
                        }
                    }
                    phone.apply(segs);
                }
            } else {
                feed(&mut host, &mut phone, &chunk[..cut]);
                feed(&mut host, &mut phone, &chunk[cut..]);
            }
            assert_same(
                &host,
                &phone,
                &format!(
                    "seed {seed} step {step} host {host_cols}x{host_rows} phone {phone_cols}x{phone_rows}"
                ),
            );
        }
    }
}
