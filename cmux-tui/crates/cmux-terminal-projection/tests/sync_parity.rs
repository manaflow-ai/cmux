//! Viewport state sync parity: the phone's screen, carried as newest-wins
//! diffs over a lossy datagram channel, against Ghostty's own grid.
//!
//! Leo, 2026-11-22: "the scroll occurs or whatever on f***ing mac / then it
//! delays on my actual iphone display. thats the asinine part."
//!
//! Per corpus (the golden VT streams, the recorded real sessions and the
//! shared terminal corpus), per chunking, per drop rate:
//!
//! - The host is a projection [`Terminal`] at the corpus's grid, fed the
//!   bytes chunk by chunk; after every chunk its [`ScreenState`] goes to a
//!   [`SyncSender`], whose datagrams cross a seeded channel that drops,
//!   delays, reorders and duplicates them (the acks coming back too).
//! - The phone is a [`SyncReceiver`]. At checkpoints the channel runs with
//!   no new input (the host's resend timer) until the phone acks the latest
//!   state, within a bound.
//! - **sync**: the phone's state equals the host's capture, exactly. This is
//!   the protocol's own correctness, at every drop rate.
//! - **oracle**: the phone's cells equal Ghostty's (`ghostty-vt`, the Mac's
//!   emulator, fed the same bytes) cell by cell: grapheme, width, fg, bg,
//!   attributes, underline style, link; plus cursor, its visibility and
//!   shape, the screen and the input modes. A mismatch here with sync at 0
//!   is a gap in the projection's VT model, not in the sync.
//! - **history**: the rows [`HistoryTracker`] emits as they leave the
//!   viewport, replayed into a fresh Ghostty, equal Ghostty's scrollback.
//!
//! Run with `--nocapture` for the table. The target is 0 everywhere.
//! `SYNC_PARITY_REPORT_ONLY=1` prints without failing on oracle or history
//! gaps (sync and convergence always fail the test).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use cmux_terminal_projection::Terminal;
use cmux_terminal_projection::style::{self, Color};
use cmux_terminal_projection::sync::{
    HistoryTracker, MODE_APP_CURSOR, MODE_BRACKETED_PASTE, MODE_CURSOR_BLINK, MODE_FOCUS_EVENTS,
    MODE_MOUSE_ANY, MODE_MOUSE_BUTTON, MODE_MOUSE_NORMAL, MODE_MOUSE_SGR, MODE_MOUSE_SGR_PIXELS,
    MODE_MOUSE_URXVT, MODE_MOUSE_UTF8, MODE_MOUSE_X10, MODE_REVERSE_VIDEO, ScreenState, SyncCell,
    SyncReceiver, SyncSender,
};
use cmux_terminal_projection::terminal::{NARROW, SPACER_HEAD, WIDE, WIDE_TAIL};
use ghostty_vt::{
    Callbacks, CellWidth, ColorSpec, CursorShape, Rgb, Terminal as Vt, UnderlineStyle,
};

const SCROLLBACK_BYTES: usize = 256 << 20;
const HISTORY_ROWS: usize = 100_000;
const MAX_DATAGRAM: usize = 1200;
const LOSS_RATES: [u64; 4] = [0, 10, 30, 50];
/// Channel steps the phone gets to catch up at a checkpoint.
const SETTLE_STEPS: usize = 5000;

fn vt(cols: usize, rows: usize) -> Vt {
    Vt::new(cols as u16, rows as u16, SCROLLBACK_BYTES, Callbacks::default())
        .expect("ghostty terminal")
}

// ---------------------------------------------------------------------------
// Cells as compared.

#[derive(Debug, Clone, PartialEq, Eq)]
struct Key {
    text: String,
    width: CellWidth,
    fg: ColorSpec,
    bg: ColorSpec,
    attrs: u16,
    underline: Option<UnderlineStyle>,
    link: bool,
}

impl Key {
    fn normalized(mut self) -> Key {
        if matches!(self.width, CellWidth::SpacerTail | CellWidth::SpacerHead) {
            // A spacer draws nothing of its own: compared by kind only.
            return Key {
                text: String::new(),
                width: self.width,
                fg: ColorSpec::Default,
                bg: ColorSpec::Default,
                attrs: 0,
                underline: None,
                link: false,
            };
        }
        if self.text.is_empty() {
            self.text = " ".to_string();
        }
        if self.text == " " {
            // What a blank shows: its background, or its foreground when
            // inverse; an underline or a strike line (as tests/parity.rs).
            if self.attrs & ghostty_vt::ATTR_INVERSE == 0 {
                self.fg = ColorSpec::Default;
            }
            self.attrs &= ghostty_vt::ATTR_INVERSE | ghostty_vt::ATTR_STRIKETHROUGH;
        }
        self
    }

    fn of_ghostty(cell: &ghostty_vt::Cell, link: bool) -> Key {
        Key {
            text: cell.text.clone(),
            width: cell.width,
            fg: cell.fg,
            bg: cell.bg,
            attrs: cell.attrs(),
            underline: if cell.underline {
                cell.underline_style.or(Some(UnderlineStyle::Single))
            } else {
                None
            },
            link,
        }
        .normalized()
    }

    fn of_sync(cell: &SyncCell) -> Key {
        let s = &cell.style;
        let flag = |f: u16, a: u16| if s.flags & f != 0 { a } else { 0 };
        Key {
            text: cell.text.clone(),
            width: match cell.width {
                NARROW => CellWidth::Narrow,
                WIDE => CellWidth::Wide,
                WIDE_TAIL => CellWidth::SpacerTail,
                SPACER_HEAD => CellWidth::SpacerHead,
                _ => CellWidth::Narrow,
            },
            fg: color(s.fg),
            bg: color(s.bg),
            attrs: flag(style::BOLD, ghostty_vt::ATTR_BOLD)
                | flag(style::ITALIC, ghostty_vt::ATTR_ITALIC)
                | flag(style::STRIKE, ghostty_vt::ATTR_STRIKETHROUGH)
                | flag(style::INVERSE, ghostty_vt::ATTR_INVERSE)
                | flag(style::FAINT, ghostty_vt::ATTR_FAINT)
                | flag(style::INVISIBLE, ghostty_vt::ATTR_INVISIBLE)
                | flag(style::BLINK, ghostty_vt::ATTR_BLINK),
            underline: match s.underline {
                0 => None,
                2 => Some(UnderlineStyle::Double),
                3 => Some(UnderlineStyle::Curly),
                4 => Some(UnderlineStyle::Dotted),
                5 => Some(UnderlineStyle::Dashed),
                _ => Some(UnderlineStyle::Single),
            },
            link: !s.link.is_empty(),
        }
        .normalized()
    }

    fn label(&self) -> String {
        let mut s = format!("{:?}", self.text);
        if self.width != CellWidth::Narrow {
            let _ = write!(s, " {:?}", self.width);
        }
        if self.fg != ColorSpec::Default {
            let _ = write!(s, " fg={:?}", self.fg);
        }
        if self.bg != ColorSpec::Default {
            let _ = write!(s, " bg={:?}", self.bg);
        }
        if self.attrs != 0 {
            let _ = write!(s, " attrs={:#x}", self.attrs);
        }
        if let Some(u) = self.underline {
            let _ = write!(s, " ul={u:?}");
        }
        if self.link {
            s.push_str(" link");
        }
        s
    }
}

fn color(c: Color) -> ColorSpec {
    match c {
        Color::Default => ColorSpec::Default,
        Color::Indexed(i) => ColorSpec::Palette(i),
        Color::Rgb(r, g, b) => ColorSpec::Rgb(Rgb { r, g, b }),
    }
}

/// Row `y` of Ghostty's screen (0 is the oldest retained row) as keys.
fn ghostty_row(term: &Vt, y: u64) -> Option<(Vec<Key>, bool)> {
    let (cells, links, wraps) = term.styled_screen_row(y)?;
    let keys = cells.iter().zip(links).map(|(c, l)| Key::of_ghostty(c, l)).collect();
    Some((keys, wraps))
}

/// The DECSCUSR parameter and blink mode as Ghostty resolves them.
fn cursor_look(state: &ScreenState, cols: usize, rows: usize) -> (CursorShape, bool) {
    let mut t = vt(cols, rows);
    if state.cursor_shape != 0 {
        t.vt_write(format!("\x1b[{} q", state.cursor_shape).as_bytes());
    }
    if state.modes & MODE_CURSOR_BLINK != 0 {
        t.vt_write(b"\x1b[?12h");
    }
    t.effective_cursor_visual().unwrap_or((CursorShape::Block, false))
}

/// DEC modes compared with Ghostty's.
const MODES: [(u16, u32); 12] = [
    (1, MODE_APP_CURSOR),
    (5, MODE_REVERSE_VIDEO),
    (9, MODE_MOUSE_X10),
    (1000, MODE_MOUSE_NORMAL),
    (1002, MODE_MOUSE_BUTTON),
    (1003, MODE_MOUSE_ANY),
    (1004, MODE_FOCUS_EVENTS),
    (1005, MODE_MOUSE_UTF8),
    (1006, MODE_MOUSE_SGR),
    (1015, MODE_MOUSE_URXVT),
    (1016, MODE_MOUSE_SGR_PIXELS),
    (2004, MODE_BRACKETED_PASTE),
];

// ---------------------------------------------------------------------------
// Scores.

#[derive(Default, Clone)]
struct Score {
    runs: usize,
    checkpoints: usize,
    /// Phone state != host capture (cells, plus 1 for any other field).
    sync: usize,
    /// Checkpoints the phone did not catch up within the bound.
    unconverged: usize,
    cells: usize,
    /// Phone cells != Ghostty's.
    oracle: usize,
    /// Cursor position, visibility, shape, screen or modes != Ghostty's.
    cursor: usize,
    history_rows: usize,
    /// History rows != Ghostty's scrollback (cells, plus missing or extra rows).
    history: usize,
    datagrams: u64,
    bytes: u64,
    /// Payload bytes of every diff made at 0% loss (one per redraw).
    payloads: Vec<usize>,
    /// Max states the phone kept.
    kept: usize,
    notes: Vec<String>,
}

impl Score {
    fn note(&mut self, what: String) {
        if self.notes.len() < 4 {
            self.notes.push(what);
        }
    }

    fn add(&mut self, o: Score) {
        self.runs += o.runs;
        self.checkpoints += o.checkpoints;
        self.sync += o.sync;
        self.unconverged += o.unconverged;
        self.cells += o.cells;
        self.oracle += o.oracle;
        self.cursor += o.cursor;
        self.history_rows += o.history_rows;
        self.history += o.history;
        self.datagrams += o.datagrams;
        self.bytes += o.bytes;
        self.payloads.extend(o.payloads);
        self.kept = self.kept.max(o.kept);
        for n in o.notes {
            self.note(n);
        }
    }
}

// ---------------------------------------------------------------------------
// The channel.

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn pct(&mut self) -> u64 {
        self.next() % 100
    }
}

/// One direction: drops `loss`%, delays 0-3 steps, duplicates 10%, and
/// delivers what is due in a shuffled order.
struct Link {
    loss: u64,
    flight: Vec<(u64, Vec<u8>)>,
}

impl Link {
    fn send(&mut self, rng: &mut Rng, now: u64, d: Vec<u8>) {
        if rng.pct() < 10 {
            self.flight.push((now + rng.next() % 4, d.clone()));
        }
        if rng.pct() >= self.loss {
            self.flight.push((now + rng.next() % 4, d));
        }
    }

    fn due(&mut self, rng: &mut Rng, now: u64) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < self.flight.len() {
            if self.flight[i].0 <= now {
                out.push(self.flight.swap_remove(i).1);
            } else {
                i += 1;
            }
        }
        for i in (1..out.len()).rev() {
            out.swap(i, (rng.next() % (i as u64 + 1)) as usize);
        }
        out
    }
}

struct Wire {
    tx: SyncSender,
    rx: SyncReceiver,
    down: Link,
    up: Link,
    rng: Rng,
    now: u64,
    /// The (seq, base) of the last payload made.
    made: Option<(u64, u64)>,
}

impl Wire {
    fn new(loss: u64, seed: u64) -> Wire {
        Wire {
            tx: SyncSender::with_epoch(MAX_DATAGRAM, 7),
            rx: SyncReceiver::new(),
            down: Link { loss, flight: Vec::new() },
            up: Link { loss, flight: Vec::new() },
            rng: Rng(seed | 1),
            now: 0,
            made: None,
        }
    }

    /// One tick: the host (re)sends the diff from the acked state, the phone
    /// takes what arrived and acks, the host takes the acks.
    fn step(&mut self, payloads: Option<&mut Vec<usize>>) {
        self.now += 1;
        let datagrams = self.tx.datagrams();
        let pair = (self.tx.latest_seq(), self.tx.acked_seq());
        if let Some(p) = payloads
            && !datagrams.is_empty()
            && self.made != Some(pair)
        {
            // A new payload for this (seq, base): one redraw's diff.
            p.push(self.tx.last_payload_len());
        }
        if !datagrams.is_empty() {
            self.made = Some(pair);
        }
        for d in datagrams {
            self.down.send(&mut self.rng, self.now, d);
        }
        for d in self.down.due(&mut self.rng, self.now) {
            if let Some(ack) = self.rx.on_datagram(&d) {
                self.up.send(&mut self.rng, self.now, ack);
            }
        }
        for a in self.up.due(&mut self.rng, self.now) {
            self.tx.on_ack(&a);
        }
    }

    fn settled(&self) -> bool {
        !self.tx.unacked() && self.rx.seq() == self.tx.latest_seq()
    }
}

// ---------------------------------------------------------------------------
// Comparisons.

fn compare_sync(phone: Option<&ScreenState>, host: &ScreenState, score: &mut Score, at: &str) {
    let Some(phone) = phone else {
        score.sync += 1;
        score.note(format!("{at}: sync: the phone holds nothing"));
        return;
    };
    if phone == host {
        return;
    }
    if phone.cols != host.cols || phone.rows != host.rows {
        score.sync += 1;
        score.note(format!(
            "{at}: sync: grid {}x{} vs {}x{}",
            phone.cols, phone.rows, host.cols, host.rows
        ));
        return;
    }
    for (i, (p, h)) in phone.cells.iter().zip(&host.cells).enumerate() {
        if p != h {
            score.sync += 1;
            let (x, y) = (i % host.cols as usize, i / host.cols as usize);
            score.note(format!("{at}: sync: ({x},{y}) phone {p:?} host {h:?}"));
        }
    }
    let meta =
        (phone.cursor, phone.cursor_visible, phone.cursor_shape, phone.modes, phone.alternate);
    let want = (host.cursor, host.cursor_visible, host.cursor_shape, host.modes, host.alternate);
    if meta != want {
        score.sync += 1;
        score.note(format!("{at}: sync: cursor/modes {meta:?} vs {want:?}"));
    }
}

fn compare_oracle(phone: &ScreenState, oracle: &Vt, score: &mut Score, at: &str) {
    let (cols, rows) = (phone.cols as usize, phone.rows as usize);
    let total = (oracle.scrollback_rows() + usize::from(oracle.rows())) as u64;
    let top = total.saturating_sub(rows as u64);
    for y in 0..rows {
        let want = ghostty_row(oracle, top + y as u64).map(|r| r.0).unwrap_or_default();
        for x in 0..cols {
            score.cells += 1;
            let got = Key::of_sync(&phone.cells[y * cols + x]);
            let Some(w) = want.get(x) else {
                score.oracle += 1;
                continue;
            };
            if got != *w {
                score.oracle += 1;
                score.note(format!(
                    "{at}: oracle ({x},{y}): phone {} ghostty {}",
                    got.label(),
                    w.label()
                ));
            }
        }
    }
    let alternate = matches!(oracle.active_screen(), ghostty_vt::Screen::Alternate);
    let (ox, oy) = oracle.cursor_position().unwrap_or((0, 0));
    let mut gaps = Vec::new();
    if phone.alternate != alternate {
        gaps.push(format!("alternate {} vs {alternate}", phone.alternate));
    }
    if phone.cursor != (ox, oy) {
        gaps.push(format!("cursor {:?} vs {:?}", phone.cursor, (ox, oy)));
    }
    if phone.cursor_visible != oracle.mode(25, false) {
        gaps.push(format!("cursor visible {}", phone.cursor_visible));
    }
    let look = cursor_look(phone, cols, rows);
    let want = oracle.effective_cursor_visual().unwrap_or((CursorShape::Block, false));
    if look != want {
        gaps.push(format!("cursor look {look:?} vs {want:?} (DECSCUSR {})", phone.cursor_shape));
    }
    for (n, bit) in MODES {
        if (phone.modes & bit != 0) != oracle.mode(n, false) {
            gaps.push(format!("mode ?{n} {}", phone.modes & bit != 0));
        }
    }
    if !gaps.is_empty() {
        score.cursor += gaps.len();
        score.note(format!("{at}: {}", gaps.join(", ")));
    }
}

/// The tracker's rows, replayed, against Ghostty's scrollback.
fn compare_history(
    history: &[u8],
    cols: usize,
    rows: usize,
    oracle: &Vt,
    score: &mut Score,
    at: &str,
) {
    let mut replay = vt(cols, rows);
    replay.vt_write(history);
    // The replay's rows from the top are the history rows, then the blank
    // line its cursor waits on.
    let replay_total = replay.scrollback_rows() + usize::from(replay.rows());
    let (rx, ry) = replay.cursor_position().unwrap_or((0, 0));
    let replay_rows =
        replay_total - usize::from(replay.rows()) + usize::from(ry) + usize::from(rx > 0);
    let want = oracle.scrollback_rows();
    score.history_rows += want;
    if replay_rows != want {
        score.history += replay_rows.abs_diff(want);
        score.note(format!("{at}: history: {replay_rows} rows vs ghostty's {want}"));
    }
    for y in 0..want.min(replay_rows) {
        let (Some((got, gw)), Some((w, ww))) =
            (ghostty_row(&replay, y as u64), ghostty_row(oracle, y as u64))
        else {
            score.history += 1;
            continue;
        };
        let mut bad = 0;
        for x in 0..cols {
            if got.get(x) != w.get(x) {
                bad += 1;
                if bad == 1 {
                    score.note(format!(
                        "{at}: history row {y} col {x}: replay {} ghostty {}",
                        got.get(x).map(Key::label).unwrap_or_default(),
                        w.get(x).map(Key::label).unwrap_or_default()
                    ));
                }
            }
        }
        if gw != ww && y + 1 < want {
            bad += 1;
            score.note(format!("{at}: history row {y}: wrap {gw} vs {ww}"));
        }
        score.history += bad;
    }
}

// ---------------------------------------------------------------------------
// Corpora.

struct Corpus {
    name: String,
    grid: (usize, usize),
    bytes: Vec<u8>,
    /// Recorded read boundaries (`.steps`), when there are some.
    steps: Option<Vec<usize>>,
}

fn load_dir(
    dir: &Path,
    grid_of: &dyn Fn(&Path, &str) -> Option<(usize, usize)>,
    out: &mut Vec<Corpus>,
) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for path in paths {
        if path.extension().and_then(|e| e.to_str()) != Some("vt") {
            continue;
        }
        let name = path.file_stem().unwrap().to_string_lossy().to_string();
        let Some(grid) = grid_of(&path, &name) else { continue };
        let bytes = std::fs::read(&path).unwrap();
        let steps = std::fs::read_to_string(path.with_extension("steps")).ok().map(|s| {
            s.lines()
                .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
                .filter_map(|l| l.split_whitespace().nth(2)?.parse().ok())
                .collect::<Vec<usize>>()
        });
        if let Some(s) = &steps {
            assert_eq!(s.iter().sum::<usize>(), bytes.len(), "{name}.steps covers {name}.vt");
        }
        out.push(Corpus { name, grid, bytes, steps });
    }
}

fn grid_file(path: &Path) -> Option<(usize, usize)> {
    let g = std::fs::read_to_string(path.with_extension("grid")).ok()?;
    let (c, r) = g.trim().split_once('x')?;
    Some((c.parse().ok()?, r.parse().ok()?))
}

/// `"file": "x.vt"` with its `"cols"` and `"rows"`, from the manifest.
fn manifest_grids(manifest: &str) -> Vec<(String, (usize, usize))> {
    let number = |s: &str, key: &str| -> Option<usize> {
        let at = s.find(key)? + key.len();
        let rest = s[at..].trim_start_matches([':', ' ']);
        rest[..rest.find(|c: char| !c.is_ascii_digit())?].parse().ok()
    };
    manifest
        .split('{')
        .filter_map(|case| {
            let at = case.find("\"file\"")? + 6;
            let rest = &case[at..];
            let open = rest.find('"')? + 1;
            let close = open + rest[open..].find('"')?;
            let file = rest[open..close].to_string();
            Some((file, (number(case, "\"cols\"")?, number(case, "\"rows\"")?)))
        })
        .collect()
}

fn corpora() -> Vec<Corpus> {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut out = Vec::new();
    load_dir(
        &crate_dir.join("tests/golden/vt"),
        &|p, name| {
            grid_file(p).or(Some(if name == "alternate_screen_codex_and_back" {
                (120, 40)
            } else {
                (120, 24)
            }))
        },
        &mut out,
    );
    load_dir(
        &crate_dir.join("tests/parity/real"),
        &|p, _| grid_file(p).or(Some((120, 40))),
        &mut out,
    );
    let shared = crate_dir.join("../../../schemas/terminal-corpus");
    let manifest = std::fs::read_to_string(shared.join("manifest.json")).unwrap_or_default();
    let grids = manifest_grids(&manifest);
    let before = out.len();
    load_dir(
        &shared,
        &|p, _| {
            let file = p.file_name()?.to_str()?;
            grids.iter().find(|g| g.0 == file).map(|g| g.1)
        },
        &mut out,
    );
    for c in &mut out[before..] {
        c.name = format!("corpus/{}", c.name);
    }
    out
}

/// Chunkings of a corpus: (name, chunk lengths, drop rates).
fn chunkings(c: &Corpus) -> Vec<(String, Vec<usize>, Vec<u64>)> {
    let len = c.bytes.len();
    let fixed =
        |n: usize| -> Vec<usize> { (0..len).step_by(n).map(|at| n.min(len - at)).collect() };
    let all = LOSS_RATES.to_vec();
    let mut out = vec![("whole".to_string(), vec![len], all.clone())];
    out.push(("4096".to_string(), fixed(4096), all.clone()));
    if len <= 64 << 10 {
        out.push(("61".to_string(), fixed(61), all.clone()));
    }
    if len <= 4 << 10 {
        out.push(("1".to_string(), fixed(1), vec![0, 30]));
    }
    if let Some(steps) = &c.steps {
        out.push(("reads".to_string(), steps.clone(), all));
    }
    out
}

fn seed_of(name: &str, chunking: &str, loss: u64) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325_u64;
    for b in name.bytes().chain(chunking.bytes()).chain([loss as u8]) {
        h = (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3);
    }
    h
}

/// One corpus, one chunking, one drop rate.
fn run(c: &Corpus, chunking: &str, chunks: &[usize], loss: u64) -> Score {
    let (cols, rows) = c.grid;
    let mut score = Score { runs: 1, ..Score::default() };
    let mut host = Terminal::new(cols, rows, HISTORY_ROWS);
    let mut oracle = vt(cols, rows);
    let mut tracker = HistoryTracker::new();
    let mut history = Vec::new();
    let mut sync = Wire::new(loss, seed_of(&c.name, chunking, loss));
    let checkpoints: Vec<usize> =
        (1..=4).map(|i| chunks.len() * i / 4).filter(|&i| i > 0).collect();
    let mut at = 0;
    for (i, &n) in chunks.iter().enumerate() {
        let bytes = &c.bytes[at..at + n];
        at += n;
        for &b in bytes {
            host.advance(b);
        }
        host.passthrough.clear();
        host.replies.clear();
        oracle.vt_write(bytes);
        sync.tx.update(ScreenState::capture(&host));
        history.extend(tracker.take_new_rows(&host));
        sync.step(if loss == 0 { Some(&mut score.payloads) } else { None });
        score.kept = score.kept.max(sync.rx.kept());
        if !checkpoints.contains(&(i + 1)) {
            continue;
        }
        let label = format!("{} {chunking} {loss}% @{at}", c.name);
        score.checkpoints += 1;
        let mut steps = 0;
        while !sync.settled() && steps < SETTLE_STEPS {
            sync.step(None);
            steps += 1;
        }
        if !sync.settled() {
            score.unconverged += 1;
            score.note(format!("{label}: not caught up in {SETTLE_STEPS} steps"));
        }
        let capture = ScreenState::capture(&host);
        compare_sync(sync.rx.screen(), &capture, &mut score, &label);
        if let Some(phone) = sync.rx.screen() {
            compare_oracle(phone, &oracle, &mut score, &label);
        }
        // The tracker is host-side only: the drop rate changes nothing.
        let primary = !host.is_alternate()
            && !matches!(oracle.active_screen(), ghostty_vt::Screen::Alternate);
        if loss == 0 && primary {
            compare_history(&history, cols, rows, &oracle, &mut score, &label);
        }
    }
    score.datagrams = sync.tx.datagrams_sent();
    score.bytes = sync.tx.bytes_sent();
    score
}

fn pct(sorted: &[usize], p: usize) -> usize {
    if sorted.is_empty() {
        return 0;
    }
    sorted[((sorted.len() - 1) * p / 100).min(sorted.len() - 1)]
}

#[test]
fn viewport_sync_matches_ghostty_over_a_lossy_channel() {
    let corpora = corpora();
    assert!(corpora.len() >= 20, "corpora found: {}", corpora.len());
    assert!(corpora.iter().any(|c| c.name == "claude_code_scroll" && c.steps.is_some()));
    // Every (corpus, chunking, drop rate), spread over threads.
    let mut jobs: Vec<(usize, String, Vec<usize>, u64)> = Vec::new();
    for (i, c) in corpora.iter().enumerate() {
        for (name, chunks, losses) in chunkings(c) {
            for loss in losses {
                jobs.push((i, name.clone(), chunks.clone(), loss));
            }
        }
    }
    // Longest first.
    jobs.sort_by_key(|j| std::cmp::Reverse(j.2.len() * corpora[j.0].grid.0 * corpora[j.0].grid.1));
    let jobs = std::sync::Mutex::new(jobs.into_iter());
    let results = std::sync::Mutex::new(Vec::new());
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).min(16);
    std::thread::scope(|s| {
        for _ in 0..threads {
            s.spawn(|| {
                loop {
                    let Some((i, name, chunks, loss)) = jobs.lock().unwrap().next() else {
                        break;
                    };
                    let score = run(&corpora[i], &name, &chunks, loss);
                    results.lock().unwrap().push((i, name, loss, score));
                }
            });
        }
    });
    let mut results = results.into_inner().unwrap();
    results.sort_by(|a, b| (a.0, &a.1, a.2).cmp(&(b.0, &b.1, b.2)));

    let mut out = String::new();
    let _ = writeln!(
        out,
        "\nviewport sync parity: {} corpora, drop rates {LOSS_RATES:?}% each way (acks too), \
         10% duplicated, 0-3 step delay, reordered; datagrams <= {MAX_DATAGRAM} B\n",
        corpora.len()
    );
    let _ = writeln!(
        out,
        "| corpus | grid | bytes | runs | checkpoints | sync | unconverged | cells | oracle | cursor/modes | history rows | history | payload p50/p90/max B (0%) | sent KB (all) | kept max | result |"
    );
    let _ = writeln!(
        out,
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---|"
    );
    let mut total = Score::default();
    let mut notes = Vec::new();
    for (i, c) in corpora.iter().enumerate() {
        let mut sc = Score::default();
        for (_, chunking, loss, s) in results.iter().filter(|r| r.0 == i) {
            if s.sync + s.unconverged + s.oracle + s.cursor + s.history > 0 {
                for n in &s.notes {
                    notes.push(format!("[{chunking} {loss}%] {n}"));
                }
            }
            sc.add(s.clone());
        }
        let mut p = sc.payloads.clone();
        p.sort_unstable();
        let ok = sc.sync + sc.unconverged + sc.oracle + sc.cursor + sc.history == 0;
        let _ = writeln!(
            out,
            "| {} | {}x{} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {}/{}/{} | {} | {} | {} |",
            c.name,
            c.grid.0,
            c.grid.1,
            c.bytes.len(),
            sc.runs,
            sc.checkpoints,
            sc.sync,
            sc.unconverged,
            sc.cells,
            sc.oracle,
            sc.cursor,
            sc.history_rows,
            sc.history,
            pct(&p, 50),
            pct(&p, 90),
            p.last().copied().unwrap_or(0),
            sc.bytes / 1024,
            sc.kept,
            if ok { "pass" } else { "FAIL" }
        );
        total.add(sc);
    }
    let mut p = total.payloads.clone();
    p.sort_unstable();
    let _ = writeln!(
        out,
        "| **total** | | | {} | {} | {} | {} | {} | {} | {} | {} | {} | {}/{}/{} | {} | {} | |",
        total.runs,
        total.checkpoints,
        total.sync,
        total.unconverged,
        total.cells,
        total.oracle,
        total.cursor,
        total.history_rows,
        total.history,
        pct(&p, 50),
        pct(&p, 90),
        p.last().copied().unwrap_or(0),
        total.bytes / 1024,
        total.kept
    );
    // Recorded reads, one redraw per PTY read, as the host would send them.
    for (i, chunking, loss, sc) in &results {
        if chunking == "reads" && *loss == 0 {
            let mut p = sc.payloads.clone();
            p.sort_unstable();
            let _ = writeln!(
                out,
                "{} by its {} recorded reads at 0%: diff payload p50 {} B, p90 {} B, max {} B over {} redraws",
                corpora[*i].name,
                corpora[*i].steps.as_ref().map_or(0, Vec::len),
                pct(&p, 50),
                pct(&p, 90),
                p.last().copied().unwrap_or(0),
                p.len()
            );
        }
    }
    // Per drop rate: what the channel cost.
    for loss in LOSS_RATES {
        let (mut d, mut b, mut u) = (0, 0, 0);
        for (_, _, l, s) in &results {
            if *l == loss {
                d += s.datagrams;
                b += s.bytes;
                u += s.unconverged;
            }
        }
        let _ = writeln!(out, "drop {loss}%: {d} datagrams, {} KB sent, {u} unconverged", b / 1024);
    }
    if !notes.is_empty() {
        let _ = writeln!(out, "\nfirst mismatches ({} notes):", notes.len());
        for n in notes.iter().take(40) {
            let _ = writeln!(out, "  {n}");
        }
    }
    println!("{out}");

    assert_eq!(total.sync, 0, "the phone's state differs from the host's");
    assert_eq!(total.unconverged, 0, "the phone did not catch up");
    if std::env::var_os("SYNC_PARITY_REPORT_ONLY").is_none() {
        assert_eq!(total.oracle, 0, "phone cells differ from Ghostty's (projection model gaps)");
        assert_eq!(total.cursor, 0, "cursor or modes differ from Ghostty's");
        assert_eq!(total.history, 0, "history rows differ from Ghostty's scrollback");
    }
}
