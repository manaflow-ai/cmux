//! Screenshot parity: can the phone draw Claude Code's terminal from acpmux records alone?
//!
//! The fixture is one real Claude Code 2.1.310 session on a 100x32 terminal (default permission
//! mode, dark theme), driven by a script: a prompt that writes a file, edits it and runs it,
//! with each of the three permission prompts approved. `pty.jsonl` is every byte the CLI wrote
//! (with the time it wrote it), `moments.json` the times the script looked at the screen, and
//! `transcript.jsonl` the CLI's own transcript (the person's and assistant's lines).
//!
//! For each moment the real screen is the PTY bytes up to then, parsed by ghostty-vt (the
//! terminal the phone draws with). The records are what acpmux makes of the transcript up to
//! then, two ways:
//! - live: what a View Only chat of the terminal logs as the transcript grows (`hub/watch.rs`:
//!   prompts and answer text; no tool calls),
//! - seeded: what adopting the transcript logs (`hub/native_history.rs` `turn_records`:
//!   prompts, tool calls with their results, answers).
//!
//! Parity is the share of cells that draw the same pixels (`Cell::looks_same`). Bytes are the
//! PTY stream against the records, each record framed as acpmux logs it.

use std::path::{Path, PathBuf};

use base64::Engine as _;
use cmux_agent_cli_render::claude::{self, Chrome};
use cmux_agent_cli_render::hybrid::{Delta, Overlay};
use cmux_agent_cli_render::lean::{LeanDecoder, LeanEncoder};
use cmux_agent_cli_render::stream::{FramePacer, HybridStream};
use cmux_agent_cli_render::{Cell, Color, Grid, Style, UNDERLINE, vt};
use serde_json::{Value, json};

const COLS: u16 = 100;
const ROWS: u16 = 32;

const CLAUDE: &str = "claude-code-2.1.310";
/// A real Codex 0.164.0 session on the same script (two approvals). There is no Codex renderer,
/// so it has no transcript: the hybrid over it sends the whole screen as deltas.
const CODEX: &str = "codex-0.164.0";
/// A real opencode 1.19.5 session on the same script (four approvals: edits and commands set
/// to ask), recorded the same way. The model's and the account's names in it are replaced by
/// placeholders of the same width.
const OPENCODE: &str = "opencode-1.19.5";

fn fixture(dir: &str, name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(dir).join(name)
}

struct Session {
    chunks: Vec<(u64, Vec<u8>)>,
    moments: Vec<(String, u64)>,
    transcript: Vec<(Option<u64>, String)>,
}

fn load(dir: &str) -> Session {
    let read = |name: &str| std::fs::read_to_string(fixture(dir, name)).unwrap_or_default();
    let chunks = read("pty.jsonl")
        .lines()
        .map(|line| {
            let v: Value = serde_json::from_str(line).unwrap();
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(v["b64"].as_str().unwrap())
                .unwrap();
            (v["t_ms"].as_u64().unwrap(), bytes)
        })
        .collect();
    let moments: Value = serde_json::from_str(&read("moments.json")).unwrap();
    let moments = moments
        .as_array()
        .unwrap()
        .iter()
        .map(|m| (m["name"].as_str().unwrap().to_owned(), m["t_ms"].as_u64().unwrap()))
        .collect();
    let transcript = read("transcript.jsonl")
        .lines()
        .map(|line| {
            let v: Value = serde_json::from_str(line).unwrap();
            (acpmux::adopt_replay::record_time(&v), line.to_owned())
        })
        .collect();
    Session { chunks, moments, transcript }
}

/// The real screen at `t`: every PTY byte written by then, through ghostty-vt.
fn real_screen(session: &Session, t: u64) -> Grid {
    let mut term = terminal();
    for (at, bytes) in &session.chunks {
        if *at <= t {
            term.vt_write(bytes);
        }
    }
    snapshot(&mut term)
}

fn terminal() -> ghostty_vt::Terminal {
    let mut term =
        ghostty_vt::Terminal::new(COLS, ROWS, 10_000_000, ghostty_vt::Callbacks::default())
            .unwrap();
    term.resize(COLS, ROWS, 8, 16).unwrap();
    term
}

/// The terminal's screen as a grid.
fn snapshot(term: &mut ghostty_vt::Terminal) -> Grid {
    let mut state = ghostty_vt::RenderState::new().unwrap();
    state.update(term).unwrap();
    let frame = state.build_frame().unwrap();
    let color = |c: ghostty_vt::ColorSpec| match c {
        ghostty_vt::ColorSpec::Default => Color::Default,
        ghostty_vt::ColorSpec::Palette(i) => Color::Palette(i),
        ghostty_vt::ColorSpec::Rgb(rgb) => Color::Rgb(rgb.r, rgb.g, rgb.b),
    };
    let mut grid = Grid::blank(COLS, ROWS);
    for (slot, row) in grid.cells.iter_mut().zip(frame.styled_rows()) {
        *slot = row
            .iter()
            .map(|c| Cell {
                text: c.text.clone(),
                style: Style { fg: color(c.fg), bg: color(c.bg), attrs: c.attrs() },
            })
            .collect();
        slot.resize(usize::from(COLS), Cell::default());
    }
    grid
}

fn update(update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": update}})
}

fn record(kind: &str, msg: Value, at: Option<u64>) -> Value {
    json!({"kind": kind, "msg": msg, "at": at})
}

/// What a View Only chat logs while it follows the transcript (`hub/watch.rs` `show_watched`),
/// and whether its last turn is still open.
fn live_records(lines: &[&(Option<u64>, String)]) -> (Vec<Value>, bool) {
    let mut out = Vec::new();
    let mut open = false;
    let mut answered = false;
    let mut codex_items = false;
    for (at, line) in lines {
        let v: Value = serde_json::from_str(line).unwrap();
        for step in acpmux::adopt_replay::record_steps("claude", &v, &mut codex_items) {
            match step {
                acpmux::adopt_replay::Step::Prompt(text) => {
                    if open {
                        out.push(record("turn_end", json!({"stopReason": "end_turn"}), *at));
                    }
                    out.push(record(
                        "turn_started",
                        json!({"prompt": text, "client": "watch"}),
                        *at,
                    ));
                    out.push(record("user_message", json!({"text": text, "client": "watch"}), *at));
                    (open, answered) = (true, false);
                }
                acpmux::adopt_replay::Step::Answer(mut text) => {
                    if open && answered {
                        text.insert_str(0, "\n\n");
                    }
                    answered = true;
                    let msg = update(
                        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}),
                    );
                    out.push(record("agent_message_chunk", msg, *at));
                }
                _ => {}
            }
        }
        if open && acpmux::adopt_replay::ends_turn("claude", &v) {
            out.push(record("turn_end", json!({"stopReason": "end_turn"}), *at));
            out.push(record(
                "turn_result",
                json!({"status": "completed", "stopReason": "end_turn"}),
                *at,
            ));
            open = false;
        }
    }
    (out, open)
}

/// What adopting the transcript so far logs (`hub/native_history.rs` `turn_records`), with an
/// open turn left open.
fn seeded_records(lines: &[&(Option<u64>, String)], open: bool, scratch: &Path) -> Vec<Value> {
    let text: String = lines.iter().map(|(_, l)| format!("{l}\n")).collect();
    std::fs::write(scratch, text).unwrap();
    let turns = acpmux::adopt_replay::read("claude", scratch);
    let last = turns.len().saturating_sub(1);
    let mut out = Vec::new();
    for (i, turn) in turns.iter().enumerate() {
        out.push(record(
            "turn_started",
            json!({"prompt": turn.prompt, "client": "adopt"}),
            turn.prompt_at,
        ));
        if !turn.prompt.is_empty() {
            out.push(record(
                "user_message",
                json!({"text": turn.prompt, "client": "adopt"}),
                turn.prompt_at,
            ));
        }
        for tool in &turn.tools {
            let mut call = tool.call.clone();
            call["sessionUpdate"] = json!("tool_call");
            call["toolCallId"] = json!(tool.id);
            call["status"] = json!("in_progress");
            out.push(record("tool_call", update(call), tool.started_at));
            let mut done = tool.done.clone();
            done["sessionUpdate"] = json!("tool_call_update");
            done["toolCallId"] = json!(tool.id);
            out.push(record("tool_call_update", update(done), tool.ended_at.or(tool.started_at)));
        }
        if !turn.answer.is_empty() {
            let msg = update(
                json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": turn.answer}}),
            );
            out.push(record("agent_message_chunk", msg, turn.answer_at));
        }
        if !(open && i == last) {
            let ended = turn.tools.iter().filter_map(|t| t.ended_at).chain(turn.answer_at).max();
            out.push(record("turn_end", json!({"stopReason": "end_turn"}), ended));
            out.push(record(
                "turn_result",
                json!({"status": "completed", "stopReason": "end_turn"}),
                ended,
            ));
        }
    }
    out
}

/// The bytes the records take on the wire, framed as acpmux logs each one.
fn wire_bytes(records: &[Value]) -> usize {
    records
        .iter()
        .enumerate()
        .map(|(seq, r)| {
            let dir = if r["kind"]
                .as_str()
                .is_some_and(|k| k.starts_with("tool") || k.starts_with("agent"))
            {
                "in"
            } else {
                "mux"
            };
            json!({"seq": seq + 1, "dir": dir, "kind": r["kind"], "msg": r["msg"], "at": r["at"]})
                .to_string()
                .len()
                + 1
        })
        .sum()
}

fn chrome(draft: &str) -> Chrome {
    Chrome {
        version: Some("2.1.310".into()),
        model_line: Some("Opus 5.5 · API Usage Billing".into()),
        cwd: Some("/tmp/clirender.4kNY/work".into()),
        mode: "manual mode on".into(),
        effort: Some("medium".into()),
        draft: draft.into(),
        utc_offset_minutes: 0,
    }
}

fn pct((same, total): (usize, usize)) -> f64 {
    100.0 * same as f64 / total.max(1) as f64
}

fn diff_rows(real: &Grid, drawn: &Grid) -> String {
    let mut out = String::new();
    for y in 0..usize::from(ROWS) {
        let row_same = real.cells[y].iter().zip(&drawn.cells[y]).all(|(a, b)| a.looks_same(b));
        if !row_same {
            let col = real.cells[y]
                .iter()
                .zip(&drawn.cells[y])
                .position(|(a, b)| !a.looks_same(b))
                .unwrap();
            out.push_str(&format!(
                "    {y:2} real |{}|\n       drawn|{}|  first diff col {col}: real {:?} drawn {:?}\n",
                real.row_text(y),
                drawn.row_text(y),
                real.cells[y][col],
                drawn.cells[y][col]
            ));
        }
    }
    out
}

#[test]
fn claude_code_screens_from_acpmux_records() {
    let session = load(CLAUDE);
    let scratch =
        std::env::temp_dir().join(format!("cmux-agent-cli-render-{}.jsonl", std::process::id()));
    let prompt = session
        .transcript
        .iter()
        .find_map(|(_, l)| {
            let v: Value = serde_json::from_str(l).unwrap();
            (v["type"] == "user")
                .then(|| v["message"]["content"].as_str().map(str::to_owned))
                .flatten()
        })
        .unwrap();
    let mut table =
        String::from("| screen | live records | seeded records |\n| --- | ---: | ---: |\n");
    let mut totals = [(0, 0), (0, 0)];
    let mut dumps = String::new();
    for (name, t) in &session.moments {
        let real = real_screen(&session, *t);
        let lines: Vec<&(Option<u64>, String)> =
            session.transcript.iter().filter(|(at, _)| at.is_none_or(|at| at <= *t)).collect();
        let (live, open) = live_records(&lines);
        let seeded = seeded_records(&lines, open, &scratch);
        // The draft shows only before the prompt is sent; the phone knows it when the person
        // typed it there.
        let draft = if name == "typed" { prompt.as_str() } else { "" };
        let live_grid = claude::render(&live, &chrome(draft), COLS, ROWS);
        let seeded_grid = claude::render(&seeded, &chrome(draft), COLS, ROWS);
        let (a, b) = (real.parity(&live_grid), real.parity(&seeded_grid));
        for (total, p) in totals.iter_mut().zip([a, b]) {
            total.0 += p.0;
            total.1 += p.1;
        }
        table.push_str(&format!("| {name} | {:.1}% | {:.1}% |\n", pct(a), pct(b)));
        dumps.push_str(&format!("  {name} (seeded):\n{}", diff_rows(&real, &seeded_grid)));
    }
    std::fs::remove_file(&scratch).ok();
    table.push_str(&format!("| all | {:.1}% | {:.1}% |", pct(totals[0]), pct(totals[1])));
    println!("rows that differ:\n{dumps}\n{table}");

    // Bytes over the session, first PTY byte to the last screen.
    let start = session.chunks.first().unwrap().0;
    let end = session.moments.last().unwrap().1;
    let secs = (end - start) as f64 / 1000.0;
    let pty: usize = session.chunks.iter().filter(|(t, _)| *t <= end).map(|(_, b)| b.len()).sum();
    let all: Vec<&(Option<u64>, String)> = session.transcript.iter().collect();
    let (live, _) = live_records(&all);
    let seeded = seeded_records(&all, false, &scratch);
    std::fs::remove_file(&scratch).ok();
    let (lb, sb) = (wire_bytes(&live), wire_bytes(&seeded));
    println!("\n| stream | bytes | bytes/s over {secs:.1} s |");
    println!("| --- | ---: | ---: |");
    println!("| PTY | {pty} | {:.0} |", pty as f64 / secs);
    println!("| live records | {lb} | {:.0} |", lb as f64 / secs);
    println!("| seeded records | {sb} | {:.0} |", sb as f64 / secs);

    // Every scripted screen was compared, and the records are smaller than the stream.
    assert_eq!(session.moments.len(), 10);
    assert!(lb < pty && sb < pty);
}

// The hybrid: the phone draws the records, and the Mac sends a delta of the cells that drawing
// gets wrong. The Mac follows the PTY through its own terminal; a frame goes out `interval` ms
// after the first PTY write it holds (0: after every write), with the cells that differ between
// the real screen and what the phone shows, against the records the phone has by then.

/// What the phone draws at a time: the record seq it has and the grid those records draw.
type Draw<'a> = Box<dyn FnMut(u64) -> (u64, Grid) + 'a>;

struct Hybrid {
    delta_bytes: usize,
    frames: usize,
    /// Per moment, the cells the phone shows as the real screen has them.
    parity: Vec<(usize, usize)>,
}

fn hybrid(session: &Session, interval: u64, end: u64, draw: &mut Draw<'_>) -> Hybrid {
    let start = session.chunks.first().unwrap().0;
    let mut term = terminal();
    let mut overlay = Overlay::new(COLS, ROWS);
    let mut sent: Vec<(u64, Overlay)> = Vec::new();
    let mut delta_bytes = 0;
    let mut send = |at: u64, term: &mut ghostty_vt::Terminal, overlay: &mut Overlay| {
        let real = snapshot(term);
        let (seq, drawn) = draw(at);
        let delta = overlay.delta(&drawn, &real, seq, at - start);
        if delta.shift == 0 && delta.spans.is_empty() {
            return;
        }
        overlay.apply_delta(&delta, &drawn);
        // The phone, applying it over the same drawing, shows the real screen.
        assert_eq!(real.parity(&overlay.compose(&drawn)), (3200, 3200));
        let bytes = delta.encode();
        assert_eq!(Delta::decode(&bytes).as_ref(), Some(&delta));
        delta_bytes += bytes.len();
        sent.push((at, overlay.clone()));
    };
    let mut due: Option<u64> = None;
    for (t, bytes) in session.chunks.iter().filter(|(t, _)| *t <= end) {
        if let Some(at) = due.filter(|at| t > at) {
            send(at, &mut term, &mut overlay);
            due = None;
        }
        term.vt_write(bytes);
        due.get_or_insert(t + interval);
    }
    if let Some(at) = due {
        send(at, &mut term, &mut overlay);
    }
    let parity = session
        .moments
        .iter()
        .map(|(_, t)| {
            let shown = sent
                .iter()
                .rev()
                .find(|(at, _)| at <= t)
                .map_or_else(|| Overlay::new(COLS, ROWS), |(_, o)| o.clone());
            let (_, drawn) = draw(*t);
            real_screen(session, *t).parity(&shown.compose(&drawn))
        })
        .collect();
    Hybrid { delta_bytes, frames: sent.len(), parity }
}

/// The phone drawing Claude Code from its live or seeded records, redrawn when they change.
fn claude_draw<'a>(session: &'a Session, seeded: bool, scratch: &'a Path) -> Draw<'a> {
    let mut last: Option<(usize, u64, Grid)> = None;
    Box::new(move |t| {
        let lines: Vec<&(Option<u64>, String)> =
            session.transcript.iter().filter(|(at, _)| at.is_none_or(|at| at <= t)).collect();
        if let Some((n, seq, grid)) = &last
            && *n == lines.len()
        {
            return (*seq, grid.clone());
        }
        let (live, open) = live_records(&lines);
        let records = if seeded { seeded_records(&lines, open, scratch) } else { live };
        // No draft: the person types in the Mac's terminal, so the deltas carry it.
        let grid = claude::render(&records, &chrome(""), COLS, ROWS);
        let seq = records.len() as u64;
        last = Some((lines.len(), seq, grid.clone()));
        (seq, grid)
    })
}

fn blank_draw<'a>() -> Draw<'a> {
    Box::new(|_| (0, Grid::blank(COLS, ROWS)))
}

fn sum(parity: &[(usize, usize)]) -> (usize, usize) {
    parity.iter().fold((0, 0), |(s, t), (a, b)| (s + a, t + b))
}

/// One table row per base and interval; answers each row's (parity %, bytes/s).
fn bench(
    session: &Session,
    rows: &mut String,
    base: &str,
    record_bytes: usize,
    mut draw: impl FnMut() -> Draw<'static>,
) -> Vec<(f64, f64)> {
    let start = session.chunks.first().unwrap().0;
    let end = session.moments.last().unwrap().1;
    let secs = (end - start) as f64 / 1000.0;
    let mut out = Vec::new();
    for interval in [0, 100, 250] {
        let h = hybrid(session, interval, end, &mut draw());
        let worst = session
            .moments
            .iter()
            .zip(&h.parity)
            .map(|((name, _), p)| (pct(*p), name.as_str()))
            .min_by(|a, b| a.0.total_cmp(&b.0))
            .unwrap();
        let total = record_bytes + h.delta_bytes;
        let rate = total as f64 / secs;
        let all = pct(sum(&h.parity));
        rows.push_str(&format!(
            "| {base} + deltas | {interval} ms | {record_bytes} | {} | {} | {total} | {rate:.0} | {all:.1}% | {:.1}% ({}) |\n",
            h.delta_bytes, h.frames, worst.0, worst.1
        ));
        out.push((all, rate));
    }
    out
}

const HEADER: &str = "| stream | frame | record bytes | delta bytes | frames | total bytes | bytes/s | parity, all screens | worst screen |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n";

fn pty_row(session: &Session) -> (usize, f64, String) {
    let start = session.chunks.first().unwrap().0;
    let end = session.moments.last().unwrap().1;
    let secs = (end - start) as f64 / 1000.0;
    let pty: usize = session.chunks.iter().filter(|(t, _)| *t <= end).map(|(_, b)| b.len()).sum();
    let rate = pty as f64 / secs;
    (
        pty,
        rate,
        format!(
            "| PTY | every write | 0 | 0 | {} | {pty} | {rate:.0} | 100.0% | 100.0% |\n",
            session.chunks.len()
        ),
    )
}

#[test]
fn claude_code_hybrid_records_plus_screen_deltas() {
    let session: &'static Session = Box::leak(Box::new(load(CLAUDE)));
    let scratch: &'static Path = Box::leak(
        std::env::temp_dir()
            .join(format!("cmux-agent-cli-render-hybrid-{}.jsonl", std::process::id()))
            .into_boxed_path(),
    );
    let all: Vec<&(Option<u64>, String)> = session.transcript.iter().collect();
    let (live, _) = live_records(&all);
    let (lb, sb) = (wire_bytes(&live), wire_bytes(&seeded_records(&all, false, scratch)));
    let (_, pty_rate, mut rows) = pty_row(session);
    let live_rows =
        bench(session, &mut rows, "live records", lb, || claude_draw(session, false, scratch));
    let seeded_rows =
        bench(session, &mut rows, "seeded records", sb, || claude_draw(session, true, scratch));
    let blank_rows = bench(session, &mut rows, "no records", 0, blank_draw);
    std::fs::remove_file(scratch).ok();
    println!("\nClaude Code 2.1.310, 100x32:\n{HEADER}{rows}");

    // With frames at most 100 ms apart, the phone shows every scripted screen as the PTY does,
    // for fewer bytes than the PTY however the records draw.
    for rows in [&live_rows, &seeded_rows, &blank_rows] {
        for (all, rate) in rows.iter().take(2) {
            assert!(*all >= 98.0, "parity {all:.1}%");
            assert!(*rate < pty_rate, "{rate:.0} B/s against the PTY's {pty_rate:.0}");
        }
    }
}

#[test]
fn codex_screen_deltas_with_no_renderer() {
    let session: &'static Session = Box::leak(Box::new(load(CODEX)));
    let (_, pty_rate, mut rows) = pty_row(session);
    let blank_rows = bench(session, &mut rows, "no records", 0, blank_draw);
    println!("\nCodex 0.164.0, 100x32:\n{HEADER}{rows}");
    assert_eq!(session.moments.len(), 8);
    let (all, rate) = blank_rows.first().copied().unwrap();
    assert!(all >= 98.0, "parity {all:.1}%");
    assert!(rate < pty_rate, "{rate:.0} B/s against the PTY's {pty_rate:.0}");
}

/// The terminal's screen as the hybrid stream sends it (underline included) and its cursor.
fn live_screen(term: &mut ghostty_vt::Terminal) -> (Grid, vt::Cursor) {
    let mut state = ghostty_vt::RenderState::new().unwrap();
    state.update(term).unwrap();
    let frame = state.build_frame().unwrap();
    let color = |c: ghostty_vt::ColorSpec| match c {
        ghostty_vt::ColorSpec::Default => Color::Default,
        ghostty_vt::ColorSpec::Palette(i) => Color::Palette(i),
        ghostty_vt::ColorSpec::Rgb(rgb) => Color::Rgb(rgb.r, rgb.g, rgb.b),
    };
    let (cols, rows) = frame.size;
    let mut grid = Grid::blank(cols, rows);
    for (slot, row) in grid.cells.iter_mut().zip(frame.styled_rows()) {
        *slot = row
            .iter()
            .map(|c| Cell {
                text: c.text.clone(),
                style: Style {
                    fg: color(c.fg),
                    bg: color(c.bg),
                    attrs: c.attrs() | if c.underline { UNDERLINE } else { 0 },
                },
            })
            .collect();
        slot.resize(usize::from(cols), Cell::default());
    }
    let cursor = frame.cursor.map_or(vt::Cursor::default(), |c| vt::Cursor {
        x: c.x,
        y: c.y,
        visible: true,
    });
    (grid, cursor)
}

struct Streamed {
    /// Frame bytes the viewer read (each frame's `data`).
    wire: usize,
    frames: usize,
    keyframe: usize,
    resume: Option<(usize, usize)>,
    /// What the viewer's link carried, as the daemon's event lines (JSON, base64): v1
    /// `agent-cli-frame` events, and lean `agent-cli-lean` events (`agent-cli-hybrid-v2`).
    v1_link: usize,
    lean_link: usize,
}

/// A stream id as the daemon makes them (a UUID).
const STREAM_ID: &str = "0b7c8f9e-4a1d-4c3e-9f2a-6d5e4b3a2c1d";

/// One event line's bytes on the link, its newline included.
fn line_len(event: &Value) -> usize {
    serde_json::to_vec(event).unwrap().len() + 1
}

/// The PTY's `output` event lines over `session` up to its last moment.
fn pty_link(session: &Session) -> usize {
    let end = session.moments.last().unwrap().1;
    session
        .chunks
        .iter()
        .filter(|(t, _)| *t <= end)
        .map(|(_, bytes)| line_len(&json!({"event": "output", "surface": 1, "data": b64(bytes)})))
        .sum()
}

/// The daemon's hybrid stream over `session`, paced as the daemon paces it, sent in the lean
/// form (`agent-cli-hybrid-v2`) and applied to a second terminal as the phone applies it (each
/// lean frame decoded, then `vt::frame_bytes`). After every frame the viewer's screen must be
/// the real one, cell for cell. With `drop`, the viewer misses the frames sent in that window
/// (ms from the start), then reconnects (a new connection: its lean state starts over) and
/// resumes from the last frame it applied.
fn stream(session: &Session, drop: Option<(u64, u64)>) -> Streamed {
    let origin = std::time::Instant::now();
    let at = |ms: u64| origin + std::time::Duration::from_millis(ms);
    let start = session.chunks.first().unwrap().0;
    let end = session.moments.last().unwrap().1;
    let mut mac = terminal();
    let mut phone = terminal();
    let mut hybrid = HybridStream::new(COLS, ROWS);
    let mut pacer = FramePacer::default();
    let mut encoder = LeanEncoder::new();
    let mut decoder = LeanDecoder::new();
    let mut out =
        Streamed { wire: 0, frames: 0, keyframe: 0, resume: None, v1_link: 0, lean_link: 0 };
    let mut applied = 0;
    let deliver = |frame: &cmux_agent_cli_render::stream::Frame,
                   cursor: vt::Cursor,
                   encoder: &mut LeanEncoder,
                   decoder: &mut LeanDecoder,
                   phone: &mut ghostty_vt::Terminal,
                   out: &mut Streamed| {
        let lean = encoder.encode(STREAM_ID, COLS, ROWS, frame, cursor).unwrap();
        let decoded = decoder.decode(&lean).expect("the viewer reads every lean frame");
        assert_eq!(
            (decoded.frame.frame, decoded.frame.base, decoded.cursor, decoded.stream.as_str()),
            (frame.frame, frame.base, cursor, STREAM_ID)
        );
        phone.vt_write(&vt::frame_bytes(&decoded.frame, ROWS, decoded.cursor).unwrap());
        let mut v1 = frame_event(frame, cursor);
        v1["stream"] = json!(STREAM_ID);
        out.v1_link += line_len(&v1);
        out.lean_link +=
            line_len(&json!({"event": "agent-cli-lean", "surface": 1, "f": b64(&lean)}));
        out.wire += frame.data.len();
        out.frames += 1;
    };
    let key = hybrid.keyframe(0);
    deliver(&key, vt::Cursor::default(), &mut encoder, &mut decoder, &mut phone, &mut out);
    let mut dropped = false;
    let mut send = |now: u64,
                    mac: &mut ghostty_vt::Terminal,
                    phone: &mut ghostty_vt::Terminal,
                    out: &mut Streamed| {
        let (real, cursor) = live_screen(mac);
        let Some(frame) = hybrid.update(&real, now - start) else { return };
        let offline = drop.is_some_and(|(from, to)| now - start >= from && now - start < to);
        if offline {
            dropped = true;
            return;
        }
        let frame = if dropped {
            dropped = false;
            // A new connection: its lean encoder and decoder start empty.
            encoder = LeanEncoder::new();
            decoder = LeanDecoder::new();
            let resumed = hybrid.resume(applied, now - start).expect("the stream holds it");
            out.resume = Some((resumed.data.len(), hybrid.keyframe(now - start).data.len()));
            resumed
        } else {
            frame
        };
        assert_eq!(frame.base, Some(applied));
        deliver(&frame, cursor, &mut encoder, &mut decoder, phone, out);
        applied = frame.frame;
        let (shown, _) = live_screen(phone);
        assert_eq!(real.parity(&shown), (3200, 3200), "{}", diff_rows(&real, &shown));
    };
    for (t, bytes) in session.chunks.iter().filter(|(t, _)| *t <= end) {
        while let Some(due) = pacer.due().filter(|due| *due <= at(*t)) {
            let now = u64::try_from((due - origin).as_millis()).unwrap();
            send(now, &mut mac, &mut phone, &mut out);
            pacer.sent(due);
        }
        mac.vt_write(bytes);
        pacer.wrote(at(*t));
    }
    if let Some(due) = pacer.due() {
        let now = u64::try_from((due - origin).as_millis()).unwrap();
        send(now, &mut mac, &mut phone, &mut out);
    }
    // A viewer attaching at the end gets one keyframe of the last screen.
    let last = hybrid.keyframe(end - start);
    let mut fresh = terminal();
    let (real, cursor) = live_screen(&mut mac);
    let lean = LeanEncoder::new().encode(STREAM_ID, COLS, ROWS, &last, cursor).unwrap();
    let decoded = LeanDecoder::new().decode(&lean).unwrap();
    fresh.vt_write(&vt::frame_bytes(&decoded.frame, ROWS, decoded.cursor).unwrap());
    assert_eq!(real.parity(&live_screen(&mut fresh).0), (3200, 3200));
    out.keyframe = last.data.len();
    out
}

/// The link's bytes per second: (PTY, hybrid v1, lean).
fn stream_table(name: &str, session: &Session) -> (f64, f64, f64) {
    let (_, pty_rate, _) = pty_row(session);
    let start = session.chunks.first().unwrap().0;
    let secs = (session.moments.last().unwrap().1 - start) as f64 / 1000.0;
    let s = stream(session, None);
    let rate = s.wire as f64 / secs;
    let dropped = stream(session, Some((8_000, 12_000)));
    let (resume, key) = dropped.resume.expect("a resume");
    let link = |bytes: usize| bytes as f64 / secs;
    let (pty_link, v1_link, lean_link) =
        (link(pty_link(session)), link(s.v1_link), link(s.lean_link));
    println!(
        "\n{name}, 100x32, the daemon's stream (8 ms settle, 100 ms frames):\n\
         | stream | bytes | frames | bytes/s | parity | keyframe at the end | resume after a 4 s drop |\n\
         | --- | ---: | ---: | ---: | ---: | ---: | ---: |\n\
         | PTY | - | - | {pty_rate:.0} | 100% | - | - |\n\
         | hybrid | {} | {} | {rate:.0} | 100% (every frame) | {} B | {resume} B (keyframe {key} B) |\n\
         {name}, the viewer's link (event lines: JSON, base64), bytes/s:\n\
         | PTY `output` | hybrid v1 `agent-cli-frame` | lean `agent-cli-lean` | lean, with a 4 s drop |\n\
         | ---: | ---: | ---: | ---: |\n\
         | {pty_link:.0} | {v1_link:.0} | {lean_link:.0} | {:.0} |",
        s.wire,
        s.frames,
        s.keyframe,
        link(dropped.lean_link),
    );
    (pty_link, v1_link, lean_link)
}

#[test]
fn the_daemons_stream_keeps_every_frame_at_parity_through_a_drop() {
    for (name, dir) in
        [("Claude Code 2.1.310", CLAUDE), ("Codex 0.164.0", CODEX), ("opencode 1.19.5", OPENCODE)]
    {
        let (pty, _, lean) = stream_table(name, &load(dir));
        assert!(lean < pty, "{name}: the lean link {lean:.0} B/s against the PTY's {pty:.0}");
    }
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// A frame as the daemon sends it (`agent-cli-frame`, `HybridViewer::event` in cmux-tui-core).
fn frame_event(frame: &cmux_agent_cli_render::stream::Frame, cursor: vt::Cursor) -> Value {
    json!({
        "event": "agent-cli-frame", "surface": 1, "stream": STREAM_ID, "frame": frame.frame,
        "base": frame.base, "cols": COLS, "rows": ROWS, "data": b64(&frame.data),
        "cursor_x": cursor.x, "cursor_y": cursor.y, "cursor_visible": cursor.visible,
    })
}

/// The bench's stream as the daemon runs it: one frame check, the frame (if any) into
/// `frames`, and the text the viewer shows after it.
struct BenchStream {
    hybrid: HybridStream,
    frames: Vec<Value>,
    shown: String,
    cursor: vt::Cursor,
}

impl BenchStream {
    fn check(&mut self, mac: &mut ghostty_vt::Terminal, at_ms: u64) {
        let (real, cursor) = live_screen(mac);
        if let Some(frame) = self.hybrid.update(&real, at_ms) {
            self.frames.push(json!([at_ms, frame_event(&frame, cursor)]));
        }
        self.cursor = cursor;
        self.shown = mac.viewport_text().unwrap();
    }
}

/// A session as the phone's in-app bench (`AgentCLIHybridBench`, cmux-next-ios) replays it:
/// its PTY chunks, the daemon's `agent-cli-frame` events paced as the daemon paces them, what
/// a viewer attaching at the `working` moment gets each way (the `vt-state` replay of the
/// screen, or the stream's keyframe), and at every moment the real screen's text (`text`) and
/// the text a hybrid viewer shows then, as of the newest frame check (`shown`). Written only
/// when `HYBRID_EXPORT_DIR` names a directory.
fn export(session: &Session) -> Value {
    let origin = std::time::Instant::now();
    let at = |ms: u64| origin + std::time::Duration::from_millis(ms);
    let ms = |due: std::time::Instant| u64::try_from((due - origin).as_millis()).unwrap();
    let start = session.chunks.first().unwrap().0;
    let end = session.moments.last().unwrap().1;
    let attach = session.moments.iter().find(|(name, _)| name == "working").unwrap().1;
    let mut mac = terminal();
    let mut pacer = FramePacer::default();
    let mut stream = BenchStream {
        hybrid: HybridStream::new(COLS, ROWS),
        frames: Vec::new(),
        shown: String::new(),
        cursor: vt::Cursor::default(),
    };
    let first = stream.hybrid.keyframe(0);
    stream.frames.push(json!([0, frame_event(&first, vt::Cursor::default())]));
    let mut attached = None;
    let mut moments = Vec::new();
    let mut next_moment = 0;
    let mut pty = Vec::new();
    let mut note_moments = |until: u64,
                            mac: &mut ghostty_vt::Terminal,
                            stream: &BenchStream,
                            moments: &mut Vec<Value>| {
        while let Some((name, moment)) = session.moments.get(next_moment).filter(|m| m.1 < until) {
            let text = mac.viewport_text().unwrap();
            moments.push(json!({
                "name": name, "t_ms": moment - start, "text": text, "shown": stream.shown,
            }));
            if attached.is_none() && *moment >= attach {
                let replay = mac
                    .vt_replay_tail_theme_portable_with_aliases(4 << 20, 0)
                    .unwrap()
                    .replay
                    .into_self_contained_bytes();
                let key = stream.hybrid.keyframe(moment - start);
                attached = Some(json!({
                    "t_ms": moment - start, "pty": b64(&replay), "text": text,
                    "hybrid": frame_event(&key, stream.cursor), "shown": stream.shown,
                }));
            }
            next_moment += 1;
        }
    };
    for (t, bytes) in session.chunks.iter().filter(|(t, _)| *t <= end) {
        while let Some(due) = pacer.due().filter(|due| *due <= at(*t)) {
            // In time order: the moments before this frame check see the screen without it.
            note_moments(ms(due), &mut mac, &stream, &mut moments);
            stream.check(&mut mac, ms(due) - start);
            pacer.sent(due);
        }
        note_moments(*t, &mut mac, &stream, &mut moments);
        mac.vt_write(bytes);
        pty.push(json!([t - start, b64(bytes)]));
        pacer.wrote(at(*t));
    }
    if let Some(due) = pacer.due() {
        note_moments(ms(due), &mut mac, &stream, &mut moments);
        stream.check(&mut mac, ms(due) - start);
    }
    note_moments(u64::MAX, &mut mac, &stream, &mut moments);
    // The same frames as a lean connection that attached at the attach moment sends them.
    let attached = attached.expect("an attach moment");
    let mut encoder = LeanEncoder::new();
    let mut lean = |event: &Value| {
        let frame = cmux_agent_cli_render::stream::Frame {
            frame: event["frame"].as_u64().unwrap(),
            base: event["base"].as_u64(),
            data: base64::engine::general_purpose::STANDARD
                .decode(event["data"].as_str().unwrap())
                .unwrap(),
        };
        let cursor = vt::Cursor {
            x: u16::try_from(event["cursor_x"].as_u64().unwrap()).unwrap(),
            y: u16::try_from(event["cursor_y"].as_u64().unwrap()).unwrap(),
            visible: event["cursor_visible"].as_bool().unwrap(),
        };
        let f = encoder.encode(STREAM_ID, COLS, ROWS, &frame, cursor).unwrap();
        json!({"event": "agent-cli-lean", "surface": 1, "f": b64(&f)})
    };
    let attach_frame = attached["hybrid"]["frame"].as_u64().unwrap();
    let lean_attach = lean(&attached["hybrid"]);
    let lean_frames: Vec<Value> = stream
        .frames
        .iter()
        .filter(|entry| entry[1]["frame"].as_u64().unwrap() > attach_frame)
        .map(|entry| json!([entry[0], lean(&entry[1])]))
        .collect();
    let mut attached = attached;
    attached["lean"] = lean_attach;
    json!({
        "cols": COLS, "rows": ROWS, "duration_ms": end - start, "pty": pty,
        "frames": stream.frames, "lean_frames": lean_frames, "attach": attached,
        "moments": moments,
    })
}

#[test]
fn export_sessions_for_the_phone_bench() {
    let Some(dir) = std::env::var_os("HYBRID_EXPORT_DIR") else { return };
    for dir_name in [CLAUDE, CODEX, OPENCODE] {
        let out = export(&load(dir_name));
        let path = Path::new(&dir).join(format!("{dir_name}.json"));
        std::fs::write(&path, serde_json::to_vec(&out).unwrap()).unwrap();
        println!("wrote {}", path.display());
    }
}
