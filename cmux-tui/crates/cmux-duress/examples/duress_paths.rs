//! The no-simulator half of the duress bench (Leo, 2026-11-22: "you should also be able to
//! simulate duress \"offline\" aka without a true agent thing"): each preset's generated load,
//! in memory, through the Rust paths the iPhone's screens rest on, timed by one harness.
//!
//! - `terminal`: the PTY bytes through ghostty-vt (the VT core the phone's Ghostty surface
//!   parses with) at an iPhone width: history ingest, then each stream chunk written and its
//!   frame built (`RenderState::update` + `build_frame`).
//! - `scroll`: the ingested history paged from the bottom to the top, one viewport a step,
//!   each step's frame built.
//! - `projection`: the calculated terminal (`cmux-agent-cli-render`): per stream chunk the
//!   Mac's side (screen grid, `HybridStream::update`, `LeanEncoder::encode`) and the phone's
//!   (`LeanDecoder::decode`, `vt::frame_bytes`, its own ghostty-vt write). Unpaced: one frame
//!   per chunk, an upper bound on what `FramePacer` lets through.
//! - `chat`: every `chat.ndjson` record decoded, and `claude::render` over them (the only Rust
//!   that draws a chat from acpmux records; the phone's chat list reduces records in Swift,
//!   `AgentChatStore`, with no Rust reducer under it). "apply" re-renders the prefix at 64
//!   evenly spaced records, since `render` has no incremental form.
//!
//! Run (release, a full checkout for the recordings):
//! `cargo run --release -p cmux-duress --example duress_paths [-- PRESET...]`

use std::path::Path;
use std::time::{Duration, Instant};

use cmux_agent_cli_render::claude::{self, Chrome};
use cmux_agent_cli_render::lean::{LeanDecoder, LeanEncoder};
use cmux_agent_cli_render::stream::HybridStream;
use cmux_agent_cli_render::{Cell, Color, Grid, Style, UNDERLINE, vt};
use cmux_duress::{Inputs, Knobs, generate};
use serde_json::Value;

/// An iPhone's terminal in portrait: 44 columns, 40 rows.
const COLS: u16 = 44;
const ROWS: u16 = 40;
const SCROLLBACK: usize = 64 * 1024 * 1024;
const INGEST_CHUNK: usize = 64 * 1024;

fn main() {
    // affected-reads: cmux-tui webviews/test/fixtures/chat-sim/replay-lane-session.ndjson
    // affected-reads: cmux-tui/crates/cmux-agent-cli-render/tests/fixtures/claude-code-2.1.310/pty.jsonl webviews/test/fixtures/chat-sim/replay-lane-session.ndjson
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let inputs = Inputs::load_repo(&repo).expect("the PTY and chat recordings (a full checkout)");
    let args: Vec<String> = std::env::args().skip(1).collect();
    let presets: Vec<String> = if args.is_empty() {
        cmux_duress::knobs::PRESETS.iter().map(|p| (*p).to_owned()).collect()
    } else {
        args
    };
    let mut table: Vec<(String, String, Vec<String>)> = Vec::new();
    let mut put = |path: &str, metric: &str, column: usize, value: String| {
        let row = match table.iter().position(|(p, m, _)| p == path && m == metric) {
            Some(i) => i,
            None => {
                table.push((
                    path.to_owned(),
                    metric.to_owned(),
                    vec![String::new(); presets.len()],
                ));
                table.len() - 1
            }
        };
        table[row].2[column] = value;
    };
    for (column, preset) in presets.iter().enumerate() {
        let knobs = Knobs::parse(preset).expect("a preset spec");
        let generated = generate(&knobs, &inputs).expect("generate");
        let counts = generated.counts();
        put(
            "load",
            "history bytes / rows",
            column,
            format!("{} / {}", counts.history_bytes, counts.history_rows),
        );
        put(
            "load",
            "stream chunks / bytes",
            column,
            format!("{} / {}", counts.stream_chunks, counts.stream_bytes),
        );
        put(
            "load",
            "chat records / bytes",
            column,
            format!("{} / {}", counts.chat_records, counts.chat_bytes),
        );

        // terminal: history ingest, then the stream with a frame per chunk.
        let mut term = terminal();
        let started = Instant::now();
        for piece in generated.history.chunks(INGEST_CHUNK) {
            term.vt_write(piece);
        }
        let ingest = started.elapsed();
        put("terminal", "history ingest", column, ms(ingest));
        put("terminal", "history MB/s", column, rate(counts.history_bytes, ingest));
        put("terminal", "scrollback rows", column, term.scrollback_rows().to_string());
        let mut state = ghostty_vt::RenderState::new().unwrap();
        let mut writes = Vec::new();
        let mut frames = Vec::new();
        for chunk in &generated.stream {
            let started = Instant::now();
            term.vt_write(&chunk.bytes);
            let written = started.elapsed();
            state.update(&mut term).unwrap();
            let _ = state.build_frame().unwrap();
            writes.push(written);
            frames.push(started.elapsed());
        }
        stats(&mut put, "terminal", "chunk vt_write", column, &mut writes);
        stats(&mut put, "terminal", "chunk write+frame", column, &mut frames);

        // scroll: page the history from the bottom to the top.
        term.scroll_to_bottom();
        let pages = term.scrollback_rows() / usize::from(ROWS);
        let mut steps = Vec::with_capacity(pages);
        for _ in 0..pages {
            let started = Instant::now();
            term.scroll_delta(-isize::from(ROWS as i16));
            state.update(&mut term).unwrap();
            let _ = state.build_frame().unwrap();
            steps.push(started.elapsed());
        }
        put("scroll", "pages", column, pages.to_string());
        stats(&mut put, "scroll", "page", column, &mut steps);
        drop(term);

        // projection: Mac grid -> hybrid delta -> lean frame -> phone terminal.
        let mut mac = terminal();
        let mut phone = terminal();
        for piece in generated.history.chunks(INGEST_CHUNK) {
            mac.vt_write(piece);
            phone.vt_write(piece);
        }
        let mut hybrid = HybridStream::new(COLS, ROWS);
        let mut encoder = LeanEncoder::new();
        let mut decoder = LeanDecoder::new();
        let mut mac_side = Vec::new();
        let mut phone_side = Vec::new();
        let mut wire = 0u64;
        for chunk in &generated.stream {
            mac.vt_write(&chunk.bytes);
            let started = Instant::now();
            let (grid, cursor) = screen(&mut mac);
            let lean = hybrid
                .update(&grid, chunk.t_ms)
                .and_then(|frame| encoder.encode("duress", COLS, ROWS, &frame, cursor));
            mac_side.push(started.elapsed());
            let Some(lean) = lean else { continue };
            wire += lean.len() as u64;
            let started = Instant::now();
            let decoded = decoder.decode(&lean).expect("a lean frame the decoder reads");
            if let Some(bytes) = vt::frame_bytes(&decoded.frame, ROWS, decoded.cursor) {
                phone.vt_write(&bytes);
            }
            phone_side.push(started.elapsed());
        }
        put("projection", "frames / wire bytes", column, format!("{} / {wire}", phone_side.len()));
        stats(&mut put, "projection", "mac per chunk", column, &mut mac_side);
        stats(&mut put, "projection", "phone per frame", column, &mut phone_side);
        drop((mac, phone));

        // chat: decode each record, render the whole chat, re-render sampled prefixes.
        let started = Instant::now();
        let mut decodes = Vec::with_capacity(generated.chat.len());
        let mut records = Vec::with_capacity(generated.chat.len());
        for line in &generated.chat {
            let one = Instant::now();
            let record: Value = serde_json::from_str(line).expect("a chat record");
            decodes.push(one.elapsed());
            records.push(record);
        }
        let chrome = Chrome::default();
        let _ = claude::render(&records, &chrome, COLS, ROWS);
        put("chat", "open (decode+render)", column, ms(started.elapsed()));
        stats(&mut put, "chat", "record decode", column, &mut decodes);
        let mut applies = Vec::new();
        if !records.is_empty() {
            for i in 1..=64usize {
                let end = (records.len() * i).div_ceil(64).max(1);
                let started = Instant::now();
                let _ = claude::render(&records[..end], &chrome, COLS, ROWS);
                applies.push(started.elapsed());
            }
        }
        stats(&mut put, "chat", "apply (re-render)", column, &mut applies);
    }

    let headers: Vec<&str> =
        ["path", "metric"].into_iter().chain(presets.iter().map(String::as_str)).collect();
    let mut widths: Vec<usize> = headers.iter().map(|h| h.len()).collect();
    for (path, metric, values) in &table {
        widths[0] = widths[0].max(path.len());
        widths[1] = widths[1].max(metric.len());
        for (i, value) in values.iter().enumerate() {
            widths[i + 2] = widths[i + 2].max(value.len());
        }
    }
    let line = |cells: Vec<&str>| {
        let padded: Vec<String> =
            cells.iter().zip(&widths).map(|(c, w)| format!("{c:<w$}")).collect();
        println!("| {} |", padded.join(" | "));
    };
    println!("{COLS}x{ROWS}, release, one pane; times in ms, p50/p95/max then total");
    line(headers.clone());
    line(
        widths
            .iter()
            .map(|w| "-".repeat(*w))
            .collect::<Vec<_>>()
            .iter()
            .map(String::as_str)
            .collect(),
    );
    for (path, metric, values) in &table {
        line(
            [path.as_str(), metric.as_str()]
                .into_iter()
                .chain(values.iter().map(String::as_str))
                .collect(),
        );
    }
}

fn terminal() -> ghostty_vt::Terminal {
    let mut term =
        ghostty_vt::Terminal::new(COLS, ROWS, SCROLLBACK, ghostty_vt::Callbacks::default())
            .unwrap();
    term.resize(COLS, ROWS, 8, 16).unwrap();
    term
}

/// The terminal's screen as the hybrid stream sends it, and its cursor (`tests/parity.rs`
/// `live_screen` in cmux-agent-cli-render).
fn screen(term: &mut ghostty_vt::Terminal) -> (Grid, vt::Cursor) {
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

fn ms(d: Duration) -> String {
    format!("{:.2}", d.as_secs_f64() * 1000.0)
}

fn rate(bytes: u64, d: Duration) -> String {
    if bytes == 0 || d.is_zero() {
        return "-".to_owned();
    }
    format!("{:.0}", bytes as f64 / 1e6 / d.as_secs_f64())
}

fn stats(
    put: &mut impl FnMut(&str, &str, usize, String),
    path: &str,
    metric: &str,
    column: usize,
    samples: &mut [Duration],
) {
    if samples.is_empty() {
        put(path, metric, column, "-".to_owned());
        return;
    }
    let total: Duration = samples.iter().sum();
    samples.sort_unstable();
    let at = |q: f64| samples[((samples.len() - 1) as f64 * q).round() as usize];
    let value = format!(
        "{}/{}/{} ({})",
        ms(at(0.5)),
        ms(at(0.95)),
        ms(samples[samples.len() - 1]),
        ms(total)
    );
    put(path, metric, column, value);
}
