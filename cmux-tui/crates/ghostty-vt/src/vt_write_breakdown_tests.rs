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

/// G8 probe (temporary, not for merge): where prepare_write's bytes go.
#[test]
#[ignore = "probe"]
fn g8_prepare_write_probe() {
    use std::collections::BTreeMap;
    let mb: usize =
        std::env::var("CMUX_HOST_STAGE_MB").ok().and_then(|v| v.parse().ok()).unwrap_or(200);
    let payload = payload(mb * 1_000_000);
    for frame_bytes in [4 * 1024, 16 * 1024, 64 * 1024, 256 * 1024] {
        let mut term = terminal();
        let (mut head, mut rest_b, mut skipped, mut stepped) = (0usize, 0usize, 0usize, 0usize);
        let (mut c1_owned, mut kitty_owned, mut frames_n, mut idle_frames) =
            (0usize, 0usize, 0usize, 0usize);
        let mut enders: BTreeMap<String, usize> = BTreeMap::new();
        let mut stepped_by: BTreeMap<String, usize> = BTreeMap::new();
        for frame in payload.chunks(frame_bytes) {
            frames_n += 1;
            let idle = term.c1_normalizer.utf8_remaining == 0 && term.trackers_idle();
            if idle {
                idle_frames += 1;
            }
            let neutral = if idle {
                byte_scan::neutral_run_end(frame, 0, !term.prompt_semantic.waits_for_line_end())
            } else {
                0
            };
            head += neutral;
            rest_b += frame.len() - neutral;
            let rest = &frame[neutral..];
            let r = term.c1_normalizer.normalize(rest);
            if matches!(r, Cow::Owned(_)) {
                c1_owned += 1;
            }
            let r = term.empty_kitty_probe_filter.write(r);
            if matches!(r, Cow::Owned(_)) {
                kitty_owned += 1;
            }
            let data: &[u8] = &r;
            let mut at = 0;
            let mut cause = String::from("not-idle-at-frame-start");
            while at < data.len() {
                if term.trackers_idle() {
                    let lw = !term.prompt_semantic.waits_for_line_end();
                    let end = byte_scan::neutral_run_end(data, at, lw);
                    if end > at {
                        skipped += end - at;
                        term.vt_boundary.clear_pending();
                        at = end;
                        continue;
                    }
                    let b = data[at];
                    cause = match b {
                        0x1b => match data.get(at + 1) {
                            Some(b'[') => {
                                let mut e = at + 2;
                                while e < data.len() && matches!(data[e], b'0'..=b'9' | b';' | b':')
                                {
                                    e += 1;
                                }
                                match data.get(e) {
                                    None => "CSI cut at frame end".into(),
                                    Some(f) => format!("CSI final {:?}", *f as char),
                                }
                            }
                            Some(b']') => "OSC".into(),
                            Some(b'P') => "DCS".into(),
                            Some(b'_') => "APC".into(),
                            None => "ESC cut at frame end".into(),
                            Some(o) => format!("ESC {:?}", *o as char),
                        },
                        0x80..=0xff => {
                            if data.len() - at < 4 {
                                "UTF-8 cut at frame end".into()
                            } else {
                                "invalid UTF-8".into()
                            }
                        }
                        b'\n' | 0x0b | 0x0c => "line end (prompt waits)".into(),
                        _ => format!("ctl {b:#x}"),
                    };
                    *enders.entry(cause.clone()).or_default() += 1;
                }
                let byte = data[at];
                term.kitty_inflight.step(byte);
                term.vt_boundary.step(byte);
                term.prompt_semantic.step(byte);
                term.cursor_override.step(byte);
                term.palette_override.step(byte);
                term.color_overrides.step(byte);
                term.mouse_mode_change_detector.step(byte);
                stepped += 1;
                *stepped_by.entry(cause.clone()).or_default() += 1;
                at += 1;
            }
            // keep the real parser state in sync isn't needed for trackers; feed raw for realism skipped
        }
        let total = payload.len() as f64;
        println!(
            "G8 frame={frame_bytes} frames={frames_n} idle_frames={idle_frames} head={:.4}% rest={:.4}% skipped_in_feed={:.4}% stepped={:.5}% c1_owned={c1_owned} kitty_owned={kitty_owned}",
            head as f64 * 100.0 / total,
            rest_b as f64 * 100.0 / total,
            skipped as f64 * 100.0 / total,
            stepped as f64 * 100.0 / total
        );
        let mut v: Vec<_> = stepped_by.iter().collect();
        v.sort_by(|a, b| b.1.cmp(a.1));
        for (k, n) in v.iter().take(10) {
            println!(
                "G8   stepped {n:>8} bytes, ended-by {k} x{}",
                enders.get(*k).copied().unwrap_or(0)
            );
        }
    }
    // where neutral_run_end_by_escape's bytes go (replicated loop with counters)
    for frame_bytes in [4 * 1024, 64 * 1024] {
        let (
            mut by_block,
            mut by_find,
            mut by_csi_walk,
            mut by_utf8,
            mut iters,
            mut csi_walks,
            mut utf8_calls,
        ) = (0usize, 0usize, 0usize, 0usize, 0usize, 0usize, 0usize);
        for data in payload.chunks(frame_bytes) {
            let mut at = 0;
            loop {
                iters += 1;
                let b = byte_scan::block::skip(data, at);
                by_block += b - at;
                at = b;
                let f = byte_scan::find_esc_or_high(data, at);
                by_find += f - at;
                at = f;
                let Some(&byte) = data.get(at) else { break };
                if byte == 0x1b {
                    let mut e = at + 2;
                    if data.get(at + 1) != Some(&b'[') {
                        break;
                    }
                    while e < data.len() && matches!(data[e], b'0'..=b'9' | b';' | b':') {
                        e += 1;
                    }
                    match data.get(e) {
                        Some(&f) if matches!(f, b'@'..=b'M' | b'P' | b'S' | b'T' | b'X' | b'Z' | b'`' | b'a' | b'b' | b'd'..=b'g' | b'm') =>
                        {
                            csi_walks += 1;
                            by_csi_walk += e + 1 - at;
                            at = e + 1;
                            continue;
                        }
                        _ => break,
                    }
                }
                utf8_calls += 1;
                let esc = memchr::memchr(0x1b, &data[at..]).map_or(data.len(), |o| at + o);
                match simdutf8::compat::from_utf8(&data[at..esc]) {
                    Err(e) => {
                        by_utf8 += e.valid_up_to();
                        break;
                    }
                    Ok(_) => {
                        by_utf8 += esc - at;
                        at = esc
                    }
                }
            }
        }
        let t = payload.len() as f64 / 100.0;
        println!(
            "G8 scan frame={frame_bytes} block={:.2}% find={:.2}% csi_walk={:.2}% ({csi_walks} walks) utf8={:.2}% ({utf8_calls} calls) iters={iters} bytes/iter={:.1}",
            by_block as f64 / t,
            by_find as f64 / t,
            by_csi_walk as f64 / t,
            by_utf8 as f64 / t,
            payload.len() as f64 / iters as f64
        );
    }
    // time split of prepare_write: neutral scan alone vs full, 64K frames
    for frame_bytes in [4 * 1024, 64 * 1024] {
        let frames: Vec<&[u8]> = payload.chunks(frame_bytes).collect();
        let mut best = [f64::MAX; 4];
        for _ in 0..3 {
            let mut term = terminal();
            let t = Instant::now();
            for f in &frames {
                std::hint::black_box(term.prepare_write(f));
            }
            best[0] = best[0].min(t.elapsed().as_secs_f64());
            let t = Instant::now();
            for f in &frames {
                std::hint::black_box(byte_scan::neutral_run_end(f, 0, true));
            }
            best[1] = best[1].min(t.elapsed().as_secs_f64());
            let t = Instant::now();
            for f in &frames {
                std::hint::black_box(byte_scan::block::skip(f, 0));
            }
            best[2] = best[2].min(t.elapsed().as_secs_f64());
            let t = Instant::now();
            for f in &frames {
                std::hint::black_box(simdutf8::basic::from_utf8(f).is_ok());
            }
            best[3] = best[3].min(t.elapsed().as_secs_f64());
        }
        let mbs = |s: f64| payload.len() as f64 / 1e6 / s;
        println!(
            "G8 time frame={frame_bytes} prepare_write={:.1}MB/s neutral_scan={:.1}MB/s block_skip_first_stop={:.1}MB/s simdutf8_whole={:.1}MB/s",
            mbs(best[0]),
            mbs(best[1]),
            mbs(best[2]),
            mbs(best[3])
        );
    }
}
