//! A scenario's headless run: its generated load and events through the Rust paths the phone's
//! screens rest on, on a virtual 60 Hz clock, timed by one harness (the same paths as
//! `examples/duress_paths.rs`).
//!
//! - `terminal`: PTY bytes into the phone's ghostty-vt at their (event-shaped) delivery times. A
//!   frame writes what is due, at most `frame_bytes`, then builds its frame
//!   (`RenderState::update` + `build_frame`); the clock moves one frame, or the frame's compute
//!   when that is longer, so a slow path shows as a later catch-up. Resizes, scrolls and theme
//!   switches are applied at the start of the frame they fall in.
//! - `projection`: a full-screen TUI on a Mac terminal, scrolled by inputs; each redraw goes
//!   through the Mac's stages (waiting for its CPU, screen grid, `HybridStream::update`,
//!   `LeanEncoder::encode`), the link (`cmux-fault` profile), and the phone's
//!   (`LeanDecoder::decode`, `vt::frame_bytes` written and its frame built, then the next vsync,
//!   which presents whatever the phone has applied by then), each stage its own metric.
//! - `terminal` with `[tui]`: the same TUI as `projection`, sent as a phone without Agent CLI
//!   Screen Changes (the default) gets it: each redraw's PTY bytes as an `output` event (base64
//!   in JSON), or held to one per `coalesce_ms`; the link; the phone's JSON and base64 decode,
//!   its terminal's parse of the bytes and its frame build, then the next vsync.
//! - chat: when the spec has chat records, `claude::render` over all of them.
//!
//! Compute is wall time on the machine that runs it; delivery, pauses and stalls are the
//! schedule's virtual time. Both are in ms.

use std::time::Instant;

use cmux_agent_cli_render::claude::{self, Chrome};
use cmux_agent_cli_render::lean::{LeanDecoder, LeanEncoder};
use cmux_agent_cli_render::stream::HybridStream;
use cmux_agent_cli_render::{Cell, Color, Grid, Style, UNDERLINE, vt};
use cmux_fault::Rng;
use ghostty_vt::{RenderState, Rgb, Terminal};

use crate::link::Link;
use crate::scenario::{
    self, Event, FRAME_MS, Mark, Metrics, PathKind, Scenario, apply_pause, apply_reset,
    reset_times, scroll_steps, ticks,
};
use crate::{Inputs, generate_with_link, inputs};

const SCROLLBACK: usize = 64 * 1024 * 1024;
const INGEST_CHUNK: usize = 64 * 1024;
/// The scenario's own draws (reset times, echo jitter), apart from the generator's streams.
const SCENARIO_SALT: u64 = 0x5CE7_A210;

/// One headless run.
pub struct Run {
    pub seed: u64,
    pub metrics: Metrics,
    pub wall_ms: f64,
}

/// Runs `scenario` (which must be headless) over `inputs`.
pub fn run(scenario: &Scenario, inputs: &Inputs) -> Result<Run, String> {
    if !scenario.headless {
        return Err(format!(
            "{} is sim-only: {}",
            scenario.name,
            scenario.headless_reason.as_deref().unwrap_or_default()
        ));
    }
    let started = Instant::now();
    let knobs = scenario.knobs()?;
    let mut metrics = Metrics::default();
    match scenario.path {
        PathKind::Terminal if scenario.tui.is_some() => {
            tui_bytes_run(scenario, inputs, &mut metrics)?
        }
        PathKind::Terminal => terminal_run(scenario, inputs, &mut metrics)?,
        PathKind::Projection => projection_run(scenario, inputs, &mut metrics)?,
    }
    Ok(Run { seed: knobs.seed, metrics, wall_ms: ms(started) })
}

fn ms(started: Instant) -> f64 {
    started.elapsed().as_secs_f64() * 1000.0
}

fn terminal(cols: u16, rows: u16) -> Result<Terminal, String> {
    let mut term = Terminal::new(cols, rows, SCROLLBACK, ghostty_vt::Callbacks::default())
        .map_err(|error| format!("ghostty-vt terminal: {error:?}"))?;
    term.resize(cols, rows, 8, 16).map_err(|error| format!("ghostty-vt resize: {error:?}"))?;
    Ok(term)
}

fn vt_err(error: impl std::fmt::Debug) -> String {
    format!("ghostty-vt: {error:?}")
}

/// Something applied at the start of a frame.
enum Action {
    Resize(u16),
    Scroll(i64),
    Theme { fg: [u8; 3], bg: [u8; 3] },
}

/// A mark being caught up on.
struct Pending {
    mark: Mark,
    /// Chunks with a delivery time at or before the target.
    upto: usize,
    frames: u64,
}

fn terminal_run(scenario: &Scenario, inputs: &Inputs, metrics: &mut Metrics) -> Result<(), String> {
    let knobs = scenario.knobs()?;
    let link = scenario.link_profile(&knobs)?;
    let generated = generate_with_link(&knobs, link.clone(), inputs)?;
    let mut draws = Rng::new(knobs.seed ^ SCENARIO_SALT);
    let length_ms = (knobs.stream_seconds * 1000) as f64;
    let rtt_ms = link.as_ref().map_or(0.0, |link| link.rtt_ms as f64);

    // The schedule, then the events laid over it.
    let mut times: Vec<f64> = generated.stream.iter().map(|chunk| chunk.t_ms as f64).collect();
    let mut marks = Vec::new();
    let mut dark: Vec<(f64, f64)> = Vec::new();
    let mut actions: Vec<(f64, Action)> = Vec::new();
    let mut echoes: Vec<(u64, Option<u64>, u64)> = Vec::new();
    for event in &scenario.events {
        match event {
            Event::Pause { at_ms, ms } => {
                marks.push(apply_pause(&mut times, *at_ms, *ms));
                dark.push((*at_ms as f64, (*at_ms + *ms) as f64));
            }
            Event::PathReset { every_ms, stall_ms, from_ms } => {
                let stall = match stall_ms {
                    Some(stall) => *stall,
                    None => match link.as_ref().and_then(|link| link.disruption.clone()) {
                        Some(cmux_fault::shaper::Disruption::AddressChange { stall_ms }) => {
                            stall_ms
                        }
                        _ => return Err("path_reset: no stall_ms and no address_change".into()),
                    },
                };
                let resets = reset_times(*every_ms, stall, *from_ms, length_ms, &mut draws);
                metrics.count("reset_count", resets.len() as f64);
                for (at, stall) in resets {
                    metrics.push("reset_stall_ms", "ms", stall);
                    marks.push(apply_reset(&mut times, at, stall, rtt_ms));
                    dark.push((at, at + stall + rtt_ms));
                }
            }
            Event::Resize { every_ms, rows, from_ms, until_ms } => {
                // Each tick switches to the next height; the first leaves the opening one.
                let ticks = ticks(*every_ms, *from_ms, *until_ms, length_ms);
                for (at, to) in ticks.into_iter().zip(rows.iter().cycle().skip(1)) {
                    actions.push((at, Action::Resize(*to)));
                }
            }
            Event::Scroll { every_ms, rows, steps_each_way, from_ms, until_ms } => {
                let at = ticks(*every_ms, *from_ms, *until_ms, length_ms);
                let steps = scroll_steps(at.len(), *rows, *steps_each_way);
                actions
                    .extend(at.into_iter().zip(steps).map(|(at, step)| (at, Action::Scroll(step))));
            }
            Event::Theme { every_ms, themes, from_ms, until_ms } => {
                let ticks = ticks(*every_ms, *from_ms, *until_ms, length_ms);
                for (at, theme) in ticks.into_iter().zip(themes.iter().cycle().skip(1)) {
                    let (fg, bg) = theme.rgb()?;
                    actions.push((at, Action::Theme { fg, bg }));
                }
            }
            Event::Echo { every_ms, from_ms, until_ms } => {
                echoes.push((*every_ms, *until_ms, *from_ms));
            }
        }
    }
    actions.sort_by(|a, b| a.0.total_cmp(&b.0));
    // Pauses and resets can only hold a delivery later, never past the one after it, so the
    // schedule stays in order; sort anyway in case two windows overlap.
    // (delivery time, stream chunk), in delivery order.
    let mut order: Vec<(f64, usize)> = times.iter().copied().zip(0..).collect();
    order.sort_by(|a, b| a.0.total_cmp(&b.0));

    // Key echoes outside the dark windows: one byte up, its echo down.
    for (every_ms, until_ms, from_ms) in echoes {
        let mut up = Link::new(link.clone(), draws.split(10));
        let mut down = Link::new(link.clone(), draws.split(11));
        for at in ticks(every_ms, from_ms, until_ms, length_ms) {
            if dark.iter().any(|(from, to)| at >= *from && at < *to) {
                continue;
            }
            let sent = (at * 1000.0) as u64;
            let back = down.deliver(up.deliver(sent, 1), 1);
            metrics.push("echo_ms", "ms", (back - sent) as f64 / 1000.0);
        }
    }

    let mut phone = terminal(scenario.cols, scenario.rows)?;
    let started = Instant::now();
    for piece in generated.history.chunks(INGEST_CHUNK) {
        phone.vt_write(piece);
    }
    metrics.push("history_ingest_ms", "ms", ms(started));
    metrics.count("stream_bytes", generated.stream.iter().map(|c| c.bytes.len() as f64).sum());
    let mut state = RenderState::new().map_err(vt_err)?;

    let mut pending: Vec<Pending> = marks
        .into_iter()
        .map(|mark| {
            let upto = order.iter().take_while(|(at, _)| *at <= mark.target_ms).count();
            Pending { mark, upto, frames: 0 }
        })
        .collect();
    for prefix in pending.iter().map(|p| p.mark.kind).collect::<std::collections::BTreeSet<_>>() {
        metrics.declare(&format!("{prefix}_catch_up_ms"), "ms");
    }
    let (mut next, mut offset, mut action) = (0usize, 0usize, 0usize);
    let mut theme: Option<([u8; 3], [u8; 3])> = None;
    let mut t = 0.0f64;
    loop {
        let due_chunk = order.get(next).map(|(at, _)| *at);
        let due_action = actions.get(action).map(|a| a.0);
        let due = match (due_chunk, due_action) {
            (Some(a), Some(b)) => a.min(b),
            (Some(a), None) | (None, Some(a)) => a,
            (None, None) => break,
        };
        if due > t {
            t = (due / FRAME_MS).ceil() * FRAME_MS;
        }
        let frame_started = Instant::now();
        let mut applied: Vec<(&'static str, f64)> = Vec::new();
        let mut resized_to = None;
        let mut themed = false;
        while let Some((at, act)) = actions.get(action)
            && *at <= t
        {
            let started = Instant::now();
            let kind = match act {
                Action::Resize(to) => {
                    phone.resize(scenario.cols, *to, 8, 16).map_err(vt_err)?;
                    resized_to = Some(*to);
                    "resize"
                }
                Action::Scroll(step) => {
                    phone.scroll_delta(*step as isize);
                    "scroll"
                }
                Action::Theme { fg, bg } => {
                    let rgb = |c: [u8; 3]| Rgb { r: c[0], g: c[1], b: c[2] };
                    phone.set_default_colors(Some(rgb(*fg)), Some(rgb(*bg)), None);
                    theme = Some((*fg, *bg));
                    themed = true;
                    "theme"
                }
            };
            applied.push((kind, ms(started)));
            action += 1;
        }
        let mut written = 0usize;
        while let Some(&(at, index)) = order.get(next)
            && at <= t
            && written < scenario.frame_bytes
        {
            let rest = generated
                .stream
                .get(index)
                .and_then(|chunk| chunk.bytes.get(offset..))
                .unwrap_or_default();
            let piece = rest.get(..scenario.frame_bytes - written).unwrap_or(rest);
            phone.vt_write(piece);
            written += piece.len();
            offset += piece.len();
            if piece.len() == rest.len() {
                next += 1;
                offset = 0;
            }
        }
        let build_started = Instant::now();
        state.update(&mut phone).map_err(vt_err)?;
        let frame = state.build_frame().map_err(vt_err)?;
        let build_ms = ms(build_started);
        let compute = ms(frame_started);
        metrics.push("frame_ms", "ms", compute);
        metrics.count("dropped_frames", if compute > FRAME_MS { 1.0 } else { 0.0 });
        for (kind, apply_ms) in applied {
            metrics.push(&format!("{kind}_ms"), "ms", apply_ms + build_ms);
        }
        if let Some(to) = resized_to {
            metrics.count(
                "resize_mismatch",
                if frame.size != (scenario.cols, to) { 1.0 } else { 0.0 },
            );
        }
        if themed && let Some((fg, bg)) = theme {
            let (got_bg, got_fg) = state.default_colors();
            let same = |got: Rgb, want: [u8; 3]| [got.r, got.g, got.b] == want;
            let ok = same(got_bg, bg) && same(got_fg, fg);
            metrics.count("theme_mismatch", if ok { 0.0 } else { 1.0 });
        }
        let end = t + compute;
        let done_upto = next; // chunks fully written
        pending.retain_mut(|p| {
            if p.mark.from_ms > t {
                return true;
            }
            p.frames += 1;
            if done_upto < p.upto {
                return true;
            }
            metrics.push(&format!("{}_catch_up_ms", p.mark.kind), "ms", end - p.mark.burst_ms);
            metrics.push(&format!("{}_catch_up_frames", p.mark.kind), "frames", p.frames as f64);
            if p.mark.kind == "reset" {
                metrics.push("reset_recovery_ms", "ms", end - p.mark.from_ms);
            }
            false
        });
        t += FRAME_MS.max(compute);
        t = (t / FRAME_MS).ceil() * FRAME_MS;
    }
    metrics.count("unfinished_marks", pending.len() as f64);
    chat_open(&generated.chat, scenario.cols, scenario.rows, metrics)?;
    Ok(())
}

fn chat_open(chat: &[String], cols: u16, rows: u16, metrics: &mut Metrics) -> Result<(), String> {
    if chat.is_empty() {
        return Ok(());
    }
    let started = Instant::now();
    let mut records = Vec::with_capacity(chat.len());
    for line in chat {
        records.push(serde_json::from_str::<serde_json::Value>(line).map_err(|e| e.to_string())?);
    }
    let _ = claude::render(&records, &Chrome::default(), cols, rows);
    metrics.push("chat_open_ms", "ms", ms(started));
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// projection: a TUI on the Mac, scrolled, through the hybrid/lean path to the phone.

/// The TUI's document line `index`, plain ASCII, at most `cols` wide.
fn doc_line(index: u64, words: &[String], cols: u16) -> String {
    let mut line = format!("{index:>6} ");
    let mut k = 0u64;
    while !words.is_empty() {
        let Some(word) = words.get(((index * 7 + k * 13) % words.len() as u64) as usize) else {
            break;
        };
        if line.len() + word.len() + 1 > usize::from(cols) {
            break;
        }
        line.push_str(word);
        line.push(' ');
        k += 1;
    }
    line.truncate(usize::from(cols));
    line
}

/// One full redraw of the TUI: the document from `top`, a status row last.
fn redraw(top: u64, len: u64, words: &[String], cols: u16, rows: u16) -> Vec<u8> {
    let mut out = String::from("\x1b[?1049h\x1b[?25l");
    for row in 0..rows.saturating_sub(1) {
        let index = top + u64::from(row);
        out.push_str(&format!("\x1b[{};1H", row + 1));
        if index < len {
            let line = doc_line(index, words, cols);
            let (number, rest) = line.split_at_checked(line.len().min(6)).unwrap_or((&line, ""));
            out.push_str(&format!("\x1b[38;5;{}m{number}\x1b[0m{rest}", 16 + index % 200));
        }
        out.push_str("\x1b[K");
    }
    let status = format!(" {top}/{len} ");
    out.push_str(&format!("\x1b[{rows};1H\x1b[7m{:<w$}\x1b[0m", status, w = usize::from(cols)));
    out.into_bytes()
}

/// One redraw of the TUI: when the Mac's terminal gets it, whether a scroll input caused it,
/// and its bytes.
struct Redraw {
    t: f64,
    from_input: bool,
    bytes: Vec<u8>,
}

/// What one write on the `terminal` TUI path is for: the TUI's own redraw, a scroll's redraw,
/// or a typed key's echo (`origin`: when the phone sent the key).
#[derive(Clone, Copy, PartialEq)]
enum Write {
    Tick,
    Scroll,
    Echo { origin: f64 },
}

/// The TUI's redraws, in time order: one per scroll input, and one per fps tick when the
/// document grew.
fn tui_redraws(scenario: &Scenario, inputs: &Inputs) -> Result<Vec<Redraw>, String> {
    let tui = scenario.tui.as_ref().ok_or("this path needs [tui]")?;
    let (cols, rows) = (scenario.cols, scenario.rows);
    let view = u64::from(rows.saturating_sub(1)).max(1);
    let length_ms = (tui.seconds * 1000) as f64;
    let words: Vec<String> = inputs::printable_words(&inputs.pty)
        .into_iter()
        .filter(|word| word.is_ascii() && word.len() < usize::from(cols) / 2)
        .collect();

    // Inputs: scroll steps; redraws: every input, and each fps tick when the document grew.
    let mut inputs_at: Vec<(f64, i64)> = Vec::new();
    for event in &scenario.events {
        if let Event::Scroll { every_ms, rows, steps_each_way, from_ms, until_ms } = event {
            let at = ticks(*every_ms, *from_ms, *until_ms, length_ms);
            let steps = scroll_steps(at.len(), *rows, *steps_each_way);
            inputs_at.extend(at.into_iter().zip(steps));
        }
    }
    inputs_at.sort_by(|a, b| a.0.total_cmp(&b.0));
    let tick_ms = 1000.0 / tui.redraw_fps.max(1) as f64;
    let len_at = |t: f64| tui.doc_lines + (t * tui.append_lines_per_s as f64 / 1000.0) as u64;

    let mut out = Vec::new();
    let (mut back, mut drawn_len) = (0u64, 0u64);
    let mut input = 0usize;
    let mut tick = 0.0f64;
    loop {
        // The next redraw: an input, else the next fps tick if the document grew.
        let (t, step) = match inputs_at.get(input) {
            Some(&(at, step)) if at <= tick => (at, Some(step)),
            _ if tick < length_ms => (tick, None),
            _ => break,
        };
        let from_input = step.is_some();
        if let Some(step) = step {
            input += 1;
            back = if step < 0 {
                back + step.unsigned_abs()
            } else {
                back.saturating_sub(step as u64)
            };
        } else {
            tick += tick_ms;
        }
        let len = len_at(t);
        back = back.min(len.saturating_sub(view));
        if !from_input && len == drawn_len {
            continue;
        }
        drawn_len = len;
        let top = len.saturating_sub(view + back);
        out.push(Redraw { t, from_input, bytes: redraw(top, len, &words, cols, rows) });
    }
    Ok(out)
}

/// When the phone sends a typed key, every `echo` event's tick.
fn tui_keys(scenario: &Scenario) -> Vec<f64> {
    let length_ms = scenario.tui.as_ref().map_or(0.0, |tui| (tui.seconds * 1000) as f64);
    let mut keys: Vec<f64> = scenario
        .events
        .iter()
        .filter_map(|event| match event {
            Event::Echo { every_ms, from_ms, until_ms } => {
                Some(ticks(*every_ms, *from_ms, *until_ms, length_ms))
            }
            _ => None,
        })
        .flatten()
        .collect();
    keys.sort_by(f64::total_cmp);
    keys
}

fn projection_run(
    scenario: &Scenario,
    inputs: &Inputs,
    metrics: &mut Metrics,
) -> Result<(), String> {
    let knobs = scenario.knobs()?;
    let link = scenario.link_profile(&knobs)?;
    let (cols, rows) = (scenario.cols, scenario.rows);

    let mut mac = terminal(cols, rows)?;
    let mut phone = terminal(cols, rows)?;
    let mut hybrid = HybridStream::new(cols, rows);
    let mut encoder = LeanEncoder::new();
    let mut decoder = LeanDecoder::new();
    let mut wire = Link::new(link, Rng::new(knobs.seed ^ SCENARIO_SALT).split(20));
    let mut phone_state = RenderState::new().map_err(vt_err)?;
    let mut mac_state = RenderState::new().map_err(vt_err)?;
    // Each side's CPU runs one frame at a time; the phone presents what it has at each vsync.
    let (mut mac_free, mut phone_free) = (0.0f64, 0.0f64);
    for Redraw { t, from_input, bytes } in tui_redraws(scenario, inputs)? {
        mac.vt_write(&bytes);

        let start = t.max(mac_free);
        let started = Instant::now();
        let (grid, cursor) = screen(&mut mac, &mut mac_state)?;
        let grid_ms = ms(started);
        let started = Instant::now();
        let frame = hybrid.update(&grid, t as u64);
        let diff_ms = ms(started);
        let started = Instant::now();
        let lean = frame.and_then(|frame| encoder.encode("tui", cols, rows, &frame, cursor));
        let encode_ms = ms(started);
        mac_free = start + grid_ms + diff_ms + encode_ms;
        let Some(lean) = lean else { continue };
        let sent = mac_free;
        let arrived = wire.deliver((sent * 1000.0) as u64, lean.len()) as f64 / 1000.0;
        let started = Instant::now();
        let decoded = decoder.decode(&lean).ok_or("a lean frame the decoder reads")?;
        let decode_ms = ms(started);
        let ready = arrived.max(phone_free) + decode_ms;
        let started = Instant::now();
        if let Some(bytes) = vt::frame_bytes(&decoded.frame, rows, decoded.cursor) {
            phone.vt_write(&bytes);
        }
        phone_state.update(&mut phone).map_err(vt_err)?;
        let _ = phone_state.build_frame().map_err(vt_err)?;
        let paint_ms = ms(started);
        phone_free = ready + paint_ms;
        let present = (phone_free / FRAME_MS).ceil() * FRAME_MS;

        metrics.push("mac_queue_ms", "ms", start - t);
        metrics.push("mac_grid_ms", "ms", grid_ms);
        metrics.push("mac_diff_ms", "ms", diff_ms);
        metrics.push("mac_encode_ms", "ms", encode_ms);
        metrics.push("wire_ms", "ms", arrived - sent);
        metrics.push("phone_decode_ms", "ms", decode_ms);
        metrics.push("vsync_wait_ms", "ms", present - phone_free);
        metrics.push("phone_paint_ms", "ms", paint_ms);
        metrics.push("wire_bytes", "bytes", lean.len() as f64);
        if from_input {
            metrics.push("scroll_to_paint_ms", "ms", present - t);
        }
        let mac_text = mac.viewport_text().map_err(vt_err)?;
        let phone_text = phone.viewport_text().map_err(vt_err)?;
        let trim = |text: &str| text.lines().map(str::trim_end).collect::<Vec<_>>().join("\n");
        metrics
            .count("paint_mismatch", if trim(&mac_text) == trim(&phone_text) { 0.0 } else { 1.0 });
    }
    metrics.declare("scroll_to_paint_ms", "ms");
    Ok(())
}

/// `terminal` with `[tui]`, Leo's default (Agent CLI Screen Changes off): no grid, diff or frame on the Mac. Each redraw's PTY bytes
/// go as `output` events (base64 in JSON, as `send_attach_frame_backpressured` writes them),
/// one per redraw, or held to one per `coalesce_ms` (`OutputCoalescer`: the first bytes after
/// an idle interval at once, the rest at the interval's end). The phone decodes each event,
/// writes its bytes into its terminal and builds its frame; it presents at the next vsync.
fn tui_bytes_run(
    scenario: &Scenario,
    inputs: &Inputs,
    metrics: &mut Metrics,
) -> Result<(), String> {
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    let knobs = scenario.knobs()?;
    let link = scenario.link_profile(&knobs)?;
    let (cols, rows) = (scenario.cols, scenario.rows);
    let interval = scenario.coalesce_ms.filter(|ms| *ms > 0).map(|ms| ms as f64);

    let mut mac = terminal(cols, rows)?;
    let mut phone = terminal(cols, rows)?;
    let mut wire = Link::new(link.clone(), Rng::new(knobs.seed ^ SCENARIO_SALT).split(20));
    let mut phone_state = RenderState::new().map_err(vt_err)?;
    let (mut mac_free, mut phone_free) = (0.0f64, 0.0f64);
    let (mut events, mut wire_total) = (0u64, 0u64);
    let trim = |text: &str| text.lines().map(str::trim_end).collect::<Vec<_>>().join("\n");

    // One `output` event leaving the Mac's attach worker at `due` (virtual ms): `held` are the
    // writes (when the Mac's terminal got each, and what it was for) the event carries.
    let mut send = |due: f64,
                    bytes: &[u8],
                    held: &[(f64, Write)],
                    mac: &mut Terminal,
                    metrics: &mut Metrics|
     -> Result<(), String> {
        let start = due.max(mac_free);
        let started = Instant::now();
        let event = serde_json::json!({
            "event": "output",
            "surface": 1,
            "data": STANDARD.encode(bytes),
        })
        .to_string();
        let encode_ms = ms(started);
        mac_free = start + encode_ms;
        let sent = mac_free;
        let arrived = wire.deliver((sent * 1000.0) as u64, event.len()) as f64 / 1000.0;
        let started = Instant::now();
        let value: serde_json::Value =
            serde_json::from_str(&event).map_err(|error| format!("output event: {error}"))?;
        let data = value
            .get("data")
            .and_then(serde_json::Value::as_str)
            .and_then(|data| STANDARD.decode(data).ok())
            .ok_or("an output event's data")?;
        let decode_ms = ms(started);
        let ready = arrived.max(phone_free) + decode_ms;
        let started = Instant::now();
        phone.vt_write(&data);
        let parse_ms = ms(started);
        let started = Instant::now();
        phone_state.update(&mut phone).map_err(vt_err)?;
        let _ = phone_state.build_frame().map_err(vt_err)?;
        let build_ms = ms(started);
        let paint_ms = parse_ms + build_ms;
        phone_free = ready + paint_ms;
        let present = (phone_free / FRAME_MS).ceil() * FRAME_MS;

        for (t, _) in held {
            metrics.push("mac_queue_ms", "ms", start - t);
        }
        metrics.push("mac_grid_ms", "ms", 0.0);
        metrics.push("mac_diff_ms", "ms", 0.0);
        metrics.push("mac_encode_ms", "ms", encode_ms);
        metrics.push("wire_ms", "ms", arrived - sent);
        metrics.push("phone_decode_ms", "ms", decode_ms);
        metrics.push("phone_parse_ms", "ms", parse_ms);
        metrics.push("phone_build_ms", "ms", build_ms);
        metrics.push("vsync_wait_ms", "ms", present - phone_free);
        metrics.push("phone_paint_ms", "ms", paint_ms);
        metrics.push("wire_bytes", "bytes", event.len() as f64);
        events += 1;
        wire_total += event.len() as u64;
        metrics.push("redraws_per_event", "redraws", held.len() as f64);
        for (t, write) in held {
            match write {
                Write::Scroll => metrics.push("scroll_to_paint_ms", "ms", present - t),
                Write::Echo { origin } => metrics.push("echo_to_paint_ms", "ms", present - origin),
                Write::Tick => {}
            }
            // The part that is not the link's: everything but the down link's delivery.
            if *write != Write::Tick {
                metrics.push("paint_over_link_ms", "ms", present - t - (arrived - sent));
            }
        }
        mac.vt_write(bytes);
        let mac_text = mac.viewport_text().map_err(vt_err)?;
        let phone_text = phone.viewport_text().map_err(vt_err)?;
        metrics
            .count("paint_mismatch", if trim(&mac_text) == trim(&phone_text) { 0.0 } else { 1.0 });
        Ok(())
    };

    // The TUI's redraws and the typed keys' echoes (a key goes up the link, the TUI echoes it
    // on its status row), in the order the Mac's terminal gets them.
    let mut writes: Vec<(f64, Write, Vec<u8>)> = tui_redraws(scenario, inputs)?
        .into_iter()
        .map(|Redraw { t, from_input, bytes }| {
            (t, if from_input { Write::Scroll } else { Write::Tick }, bytes)
        })
        .collect();
    let mut up = Link::new(link.clone(), Rng::new(knobs.seed ^ SCENARIO_SALT).split(21));
    for origin in tui_keys(scenario) {
        let at = up.deliver((origin * 1000.0) as u64, 1) as f64 / 1000.0;
        let echo = format!("\x1b[{rows};{}H\x1b[7mk\x1b[0m", cols.max(1));
        writes.push((at, Write::Echo { origin }, echo.into_bytes()));
    }
    writes.sort_by(|a, b| a.0.total_cmp(&b.0));
    metrics.declare("echo_to_paint_ms", "ms");

    let mut pending: Vec<u8> = Vec::new();
    let mut held: Vec<(f64, Write)> = Vec::new();
    let mut last_sent: Option<f64> = None;
    for (t, write, bytes) in writes {
        let Some(interval) = interval else {
            send(t, &bytes, &[(t, write)], &mut mac, metrics)?;
            continue;
        };
        // The held bytes went out at their interval's end, before this redraw.
        if let Some(due) = last_sent.map(|sent| sent + interval)
            && !pending.is_empty()
            && due <= t
        {
            send(due, &pending, &held, &mut mac, metrics)?;
            (last_sent, pending, held) = (Some(due), Vec::new(), Vec::new());
        }
        let idle = last_sent.is_none_or(|sent| t >= sent + interval);
        if pending.is_empty() && idle {
            send(t, &bytes, &[(t, write)], &mut mac, metrics)?;
            last_sent = Some(t);
        } else {
            pending.extend_from_slice(&bytes);
            held.push((t, write));
        }
    }
    if !pending.is_empty() {
        let due = last_sent.map_or(0.0, |sent| sent + interval.unwrap_or(0.0));
        send(due, &pending, &held, &mut mac, metrics)?;
    }
    drop(send);
    let seconds = scenario.tui.as_ref().map_or(1, |tui| tui.seconds.max(1)) as f64;
    metrics.push("events_per_s", "events/s", events as f64 / seconds);
    metrics.push("wire_bytes_per_s", "bytes/s", wire_total as f64 / seconds);
    metrics.declare("scroll_to_paint_ms", "ms");
    Ok(())
}

/// The terminal's screen as the hybrid stream sends it, and its cursor (`tests/parity.rs`
/// `live_screen` in cmux-agent-cli-render).
fn screen(term: &mut Terminal, state: &mut RenderState) -> Result<(Grid, vt::Cursor), String> {
    state.update(term).map_err(vt_err)?;
    let frame = state.build_frame().map_err(vt_err)?;
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
    Ok((grid, cursor))
}

/// Runs `scenario` and judges it: the JSON line and the text verdict.
pub fn run_and_report(
    scenario: &Scenario,
    inputs: &Inputs,
    commit: Option<&str>,
) -> Result<(serde_json::Value, String, bool), String> {
    let run = run(scenario, inputs)?;
    let judged = scenario::judge(&scenario.checks, &run.metrics);
    let pass = judged.iter().all(|judged| judged.pass);
    let json =
        scenario::report_json(scenario, run.seed, commit, &run.metrics, &judged, run.wall_ms);
    let text = scenario::report_text(scenario, &run.metrics, &judged);
    Ok((json, text, pass))
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    fn recordings() -> Inputs {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        Inputs::load_repo(&repo).expect("the PTY and chat fixtures (a full checkout)")
    }

    fn scenario(text: &str) -> Scenario {
        Scenario::parse(text).unwrap()
    }

    #[test]
    fn a_pause_is_caught_up_in_frames_of_frame_bytes() {
        // 512 kbit/s for 6 s, a 2 s pause: about 128 KB held, written 16 KB a frame.
        let s = scenario(
            r#"
name = "t"
summary = "t"
spec = "idle,stream_kbps=512,stream_seconds=6"
headless = true
frame_bytes = 16384
[[event]]
kind = "pause"
at_ms = 2000
ms = 2000
[[check]]
metric = "resume_catch_up_frames"
min = 4
[sim]
ui = ["X"]
"#,
        );
        let run = run(&s, &recordings()).unwrap();
        let frames = run.metrics.0["resume_catch_up_frames"].samples[0];
        assert!((4.0..=40.0).contains(&frames), "{frames}");
        assert!(run.metrics.0["resume_catch_up_ms"].samples[0] >= (frames - 1.0) * FRAME_MS);
        assert_eq!(run.metrics.0["unfinished_marks"].samples, vec![0.0]);
        let judged = scenario::judge(&s.checks, &run.metrics);
        assert!(judged[0].pass, "{judged:?}");
    }

    #[test]
    fn resizes_and_themes_land_in_the_frame() {
        let s = scenario(
            r##"
name = "t"
summary = "t"
spec = "idle,stream_kbps=128,stream_seconds=3"
headless = true
[[event]]
kind = "resize"
every_ms = 250
rows = [40, 22]
[[event]]
kind = "theme"
every_ms = 400
themes = [{ name = "dark", fg = "#ffffff", bg = "#000000" }, { name = "light", fg = "#111111", bg = "#fafafa" }]
[[check]]
metric = "resize_mismatch"
max = 0
[sim]
ui = ["X"]
"##,
        );
        let run = run(&s, &recordings()).unwrap();
        assert_eq!(run.metrics.0["resize_ms"].samples.len(), 11);
        assert_eq!(run.metrics.0["resize_mismatch"].samples, vec![0.0]);
        assert_eq!(run.metrics.0["theme_ms"].samples.len(), 7);
        assert_eq!(run.metrics.0["theme_mismatch"].samples, vec![0.0]);
    }

    #[test]
    fn projection_paints_what_the_mac_shows() {
        let s = scenario(
            r#"
name = "t"
summary = "t"
spec = "idle"
headless = true
path = "projection"
cols = 80
rows = 24
[tui]
doc_lines = 500
append_lines_per_s = 20
seconds = 2
[[event]]
kind = "scroll"
every_ms = 50
rows = -3
[[check]]
metric = "paint_mismatch"
max = 0
[sim]
ui = ["X"]
"#,
        );
        let run = run(&s, &recordings()).unwrap();
        assert_eq!(run.metrics.0["paint_mismatch"].samples, vec![0.0]);
        assert!(run.metrics.0["scroll_to_paint_ms"].samples.len() >= 30);
        for stage in [
            "mac_queue_ms",
            "mac_grid_ms",
            "mac_diff_ms",
            "mac_encode_ms",
            "wire_ms",
            "phone_decode_ms",
            "phone_paint_ms",
            "vsync_wait_ms",
        ] {
            assert!(!run.metrics.0[stage].samples.is_empty(), "{stage}");
        }
    }

    /// The default path: the same TUI as PTY bytes, one event per redraw, or coalesced.
    #[test]
    fn a_tui_on_the_terminal_path_paints_what_the_mac_shows() {
        let text = |coalesce: &str| {
            format!(
                r#"
name = "t"
summary = "t"
spec = "idle,link=lan"
headless = true
cols = 50
rows = 40
{coalesce}
[tui]
doc_lines = 500
append_lines_per_s = 62
redraw_fps = 62
seconds = 2
[[event]]
kind = "scroll"
every_ms = 50
rows = -3
[[event]]
kind = "echo"
every_ms = 250
[[check]]
metric = "paint_mismatch"
max = 0
[sim]
ui = ["X"]
"#
            )
        };
        let each = run(&scenario(&text("")), &recordings()).unwrap().metrics;
        let held = run(&scenario(&text("coalesce_ms = 17")), &recordings()).unwrap().metrics;
        for metrics in [&each, &held] {
            assert_eq!(metrics.0["paint_mismatch"].samples, vec![0.0]);
            assert!(metrics.0["scroll_to_paint_ms"].samples.len() >= 30);
            assert!(metrics.0["echo_to_paint_ms"].samples.len() >= 7);
            for stage in ["mac_queue_ms", "wire_ms", "phone_parse_ms", "phone_build_ms"] {
                assert!(!metrics.0[stage].samples.is_empty(), "{stage}");
            }
        }
        // Every redraw carried, in fewer events when held.
        let carried = |m: &Metrics| m.0["redraws_per_event"].samples.iter().sum::<f64>();
        assert_eq!(carried(&each), carried(&held));
        assert!(held.0["wire_bytes"].samples.len() < each.0["wire_bytes"].samples.len());
    }

    #[test]
    fn sim_only_scenarios_do_not_run() {
        let s = scenario(
            r#"
name = "t"
summary = "t"
spec = "duress"
headless = false
headless_reason = "SwiftUI only"
[sim]
ui = ["X"]
"#,
        );
        assert!(run(&s, &recordings()).err().unwrap().contains("sim-only"));
    }
}
