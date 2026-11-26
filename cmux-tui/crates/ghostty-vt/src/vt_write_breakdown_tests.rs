//! What [`Terminal::vt_write`] spends besides libghostty-vt's own parse, one
//! step at a time, on the cmux-tui host-stage payload.

use std::time::Instant;

use super::*;

/// The cmux-tui host-stage payload: compiler-style lines, a quarter of the
/// words colored with SGR, a tenth UTF-8. `CMUX_VT_PAYLOAD=utf8` makes every
/// word non-ASCII (box drawing, CJK, emoji: a TUI or a CJK log).
fn payload(bytes: usize) -> Vec<u8> {
    let all_utf8 = std::env::var("CMUX_VT_PAYLOAD").is_ok_and(|value| value == "utf8");
    let words =
        ["cargo", "build", "warning:", "error[E0308]:", "src/main.rs:42:7", "Compiling", "ok"];
    let utf8 = ["é", "→", "✓", "日本語", "│", "🙂"];
    let mut state: u64 = 571;
    let mut next = move |n: usize| {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        usize::try_from(state >> 33).unwrap_or(0) % n
    };
    let mut out = Vec::with_capacity(bytes + 512);
    while out.len() < bytes {
        let kind = next(100);
        let count = 6 + next(24);
        for i in 0..count {
            if i > 0 {
                out.push(b' ');
            }
            if all_utf8 {
                out.extend_from_slice(utf8[next(utf8.len())].as_bytes());
            } else if kind < 25 {
                out.extend_from_slice(
                    format!("\x1b[38;5;{}m{}\x1b[0m", next(256), words[next(words.len())])
                        .as_bytes(),
                );
            } else if kind < 35 {
                out.extend_from_slice(utf8[next(utf8.len())].as_bytes());
            } else {
                out.extend_from_slice(words[next(words.len())].as_bytes());
            }
        }
        out.extend_from_slice(b"\r\n");
    }
    out.truncate(bytes);
    out
}

fn terminal() -> Terminal {
    Terminal::new(120, 40, 10_000_000, Callbacks::default()).unwrap()
}

#[test]
#[ignore = "a throughput bench; run with --ignored --nocapture"]
fn vt_write_step_breakdown_bench() {
    let mb: usize = std::env::var("CMUX_HOST_STAGE_MB")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(200);
    let payload = payload(mb * 1_000_000);
    let steps: Vec<String> = std::env::var("CMUX_VT_STEPS")
        .map(|value| value.split(',').map(str::to_owned).collect())
        .unwrap_or_default();
    let wanted = |step: &str| steps.is_empty() || steps.iter().any(|s| s == step);
    for frame_bytes in [4 * 1024, 16 * 1024, 64 * 1024, 256 * 1024] {
        let frames: Vec<&[u8]> = payload.chunks(frame_bytes).collect();
        let report = |step: &str, seconds: f64| {
            let mb_s = payload.len() as f64 / 1_000_000.0 / seconds;
            let ns_frame = seconds * 1e9 / frames.len() as f64;
            println!(
                "VT-STEP {{\"step\":\"{step}\",\"frame_bytes\":{frame_bytes},\"seconds\":{seconds:.4},\"mb_s\":{mb_s:.1},\"ns_per_frame\":{ns_frame:.0}}}"
            );
        };
        if wanted("vt_write") {
            let mut term = terminal();
            let started = Instant::now();
            for frame in &frames {
                term.vt_write(frame);
            }
            report("vt_write", started.elapsed().as_secs_f64());
        }
        if wanted("raw_parse") {
            let term = terminal();
            let started = Instant::now();
            for frame in &frames {
                unsafe { sys::ghostty_terminal_vt_write(term.raw, frame.as_ptr(), frame.len()) };
            }
            report("raw_parse", started.elapsed().as_secs_f64());
        }
        if wanted("raw_parse_small_history") {
            let term = Terminal::new(120, 40, 0, Callbacks::default()).unwrap();
            let started = Instant::now();
            for frame in &frames {
                unsafe { sys::ghostty_terminal_vt_write(term.raw, frame.as_ptr(), frame.len()) };
            }
            report("raw_parse_small_history", started.elapsed().as_secs_f64());
        }
        if wanted("normalize") {
            let mut normalizer = C1Normalizer::default();
            let started = Instant::now();
            for frame in &frames {
                std::hint::black_box(normalizer.normalize(frame));
            }
            report("normalize", started.elapsed().as_secs_f64());
        }
        if wanted("kitty_filter") {
            let mut filter = EmptyKittyProbeFilter;
            let started = Instant::now();
            for frame in &frames {
                std::hint::black_box(filter.write(Cow::Borrowed(frame)));
            }
            report("kitty_filter", started.elapsed().as_secs_f64());
        }
        if wanted("trackers") {
            let mut term = terminal();
            let started = Instant::now();
            for frame in &frames {
                std::hint::black_box(term.feed_trackers(frame));
            }
            report("trackers", started.elapsed().as_secs_f64());
        }
        if wanted("prepare_write") {
            // Everything vt_write does to the bytes before the parse, as it runs
            // there: one neutral scan, then C1, Kitty filter and trackers on the rest.
            let mut term = terminal();
            let started = Instant::now();
            for frame in &frames {
                std::hint::black_box(term.prepare_write(frame));
            }
            report("prepare_write", started.elapsed().as_secs_f64());
        }
        if wanted("neutral_scan") {
            let started = Instant::now();
            for frame in &frames {
                std::hint::black_box(byte_scan::neutral_run_end(frame, 0, true));
            }
            report("neutral_scan", started.elapsed().as_secs_f64());
        }
        if wanted("history_bookkeeping") {
            // Everything vt_write does around the parse, on a terminal whose
            // history is already full (the steady state of a flood).
            let mut term = terminal();
            for frame in frames.iter().take(2_000_000 / frame_bytes + 1) {
                term.vt_write(frame);
            }
            let started = Instant::now();
            for _ in &frames {
                term.ensure_history_anchor();
                let previous = term.scrollback_rows();
                term.history_markers_before_write();
                term.history_markers_after_write();
                let rows = term.scrollback_rows();
                let evicted = !term.history_anchor.is_null()
                    && !unsafe { sys::ghostty_tracked_grid_ref_has_value(term.history_anchor) };
                std::hint::black_box((previous, rows, evicted));
            }
            report("history_bookkeeping", started.elapsed().as_secs_f64());
        }
    }
}
