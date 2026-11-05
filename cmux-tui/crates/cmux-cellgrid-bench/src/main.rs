//! cmux-cellgrid-bench: one recorded terminal workload, streamed three ways.
//!
//! - `vt`: the PTY bytes as they arrive (the `terminal_bytes` channel's live frames).
//! - `render-delta`: the daemon render attach's JSON (8 ms frame cadence, dirty rows).
//! - `rowdiff`: a candidate cell wire, rows diffed against the viewer plus a scroll op.
//! - `h264-*`: the pane's pixels through OpenH264 at a target bitrate, captured at 60 Hz.
//!
//! For each it prints bytes per second (raw and through a deflate stream),
//! keystroke-to-render p50/p95 from the program's echo to the viewer holding it,
//! and, against the host's own pixels, exact text cells, PSNR and CIEDE2000 of
//! text colour. Usage: [`USAGE`].

mod color;
mod raster;
mod trace;
mod video;
mod wire;

use std::time::Instant;

use ghostty_vt::{Callbacks, Dirty, RenderState, Terminal};
use serde_json::{Value, json};

use raster::{Raster, Run};
use video::{Quality, Video};
use wire::{CellViewer, Deflater, RowDiff};

const CELL_CADENCE_NS: u64 = 8_000_000; // cmux-tui-core frame_producer RENDER_FRAME_CADENCE
const CAPTURE_PERIOD_NS: u64 = 1_000_000_000 / 60;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

const USAGE: &str =
    "usage: cmux-cellgrid-bench TRACE.cgt [--video KBPS[:REFRESH_MS],...] [--link-mbps 20]
       [--window START_S:END_S] [--quality-every N] [--px 26] [--font REGULAR.ttf --bold BOLD.ttf]
       [--attach-at S] [--json OUT.json]
TRACE comes from scripts/record.py.";

/// Parses one option value, or fails with the usage text.
fn num<T: std::str::FromStr>(s: &str) -> Res<T> {
    s.parse().map_err(|_| format!("bad value {s:?}\n{USAGE}").into())
}

struct Opts {
    trace: String,
    videos: Vec<(u32, u64)>,
    link_bps: f64,
    window: Option<(f64, f64)>,
    quality_every: u64,
    px: f32,
    font: String,
    bold: String,
    json: Option<String>,
    attach_at: Option<f64>,
}

fn opts() -> Res<Opts> {
    let mut a = std::env::args().skip(1);
    let mut o = Opts {
        trace: String::new(),
        videos: vec![(2000, 0), (6000, 0), (12000, 0), (12000, 500)],
        link_bps: 20e6,
        window: None,
        quality_every: 15,
        px: 26.0,
        font: "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf".into(),
        bold: "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf".into(),
        json: None,
        attach_at: None,
    };
    while let Some(arg) = a.next() {
        let mut val = || a.next().ok_or_else(|| format!("{arg} needs a value\n{USAGE}"));
        match arg.as_str() {
            "--video" => {
                o.videos = val()?
                    .split(',')
                    .map(|v| {
                        let (k, r) = v.split_once(':').unwrap_or((v, "0"));
                        Ok((num(k)?, num(r)?))
                    })
                    .collect::<Res<_>>()?;
            }
            "--link-mbps" => o.link_bps = num::<f64>(&val()?)? * 1e6,
            "--window" => {
                let v = val()?;
                let (s, e) =
                    v.split_once(':').ok_or_else(|| format!("--window is START:END\n{USAGE}"))?;
                o.window = Some((num(s)?, num(e)?));
            }
            "--quality-every" => o.quality_every = num(&val()?)?,
            "--px" => o.px = num(&val()?)?,
            "--font" => o.font = val()?,
            "--bold" => o.bold = val()?,
            "--json" => o.json = Some(val()?),
            "--attach-at" => o.attach_at = Some(num(&val()?)?),
            _ if o.trace.is_empty() && !arg.starts_with('-') => o.trace = arg,
            _ => return Err(USAGE.into()),
        }
    }
    if o.trace.is_empty() {
        return Err(USAGE.into());
    }
    Ok(o)
}

/// One path's sends and timings.
#[derive(Default)]
struct PathStats {
    sends: Vec<(u64, usize, usize)>,
    host_ns: u64,
    viewer_ns: u64,
    latency_ns: Vec<u64>,
    /// Per key: [pacing wait, host work, network at the link rate, viewer work].
    stages_ns: Vec<[u64; 4]>,
    mismatched_rows: u64,
    quality: Option<Quality>,
}

impl PathStats {
    fn key(&mut self, stages: [u64; 4]) {
        self.latency_ns.push(stages.iter().sum());
        self.stages_ns.push(stages);
    }

    fn send(&mut self, t: u64, raw: usize, deflated: usize) {
        self.sends.push((t, raw, deflated));
    }

    fn json(&mut self, win: (u64, u64), span_s: f64) -> Value {
        let secs = (win.1.saturating_sub(win.0)) as f64 / 1e9;
        let (mut raw, mut def, mut n) = (0usize, 0usize, 0usize);
        for &(t, r, d) in &self.sends {
            if t >= win.0 && t <= win.1 {
                raw += r;
                def += d;
                n += usize::from(r > 0);
            }
        }
        self.latency_ns.sort_unstable();
        let q = |f: f64| {
            self.latency_ns
                .get(((self.latency_ns.len() as f64 - 1.0) * f).round() as usize)
                .map(|&ns| ns as f64 / 1e6)
        };
        let stage = |i: usize| {
            let mut v: Vec<u64> = self.stages_ns.iter().map(|s| s[i]).collect();
            v.sort_unstable();
            v.get(v.len().saturating_sub(1) / 2).map(|&ns| ns as f64 / 1e6)
        };
        json!({
            "kbps": raw as f64 * 8.0 / 1000.0 / secs,
            "kbps_deflate": if def > 0 { json!(def as f64 * 8.0 / 1000.0 / secs) } else { Value::Null },
            "sends_per_s": n as f64 / secs,
            "key_to_view_ms": {"n": self.latency_ns.len(), "p50": q(0.5), "p95": q(0.95), "max": q(1.0)},
            "key_stages_p50_ms": {"wait": stage(0), "host": stage(1), "network": stage(2), "viewer": stage(3)},
            "host_cpu_ms_per_s": self.host_ns as f64 / 1e6 / span_s,
            "viewer_cpu_ms_per_s": self.viewer_ns as f64 / 1e6 / span_s,
            "mismatched_rows": self.mismatched_rows,
            "quality": self.quality.as_mut().map(Quality::json),
        })
    }
}

/// A key the recorder typed, and when each path showed its echo.
struct Key {
    t: u64,
    echo: Option<u64>,
    drawn: Option<u64>,
    done: Vec<bool>,
}

fn host_runs(frame: &ghostty_vt::RenderFrame, row: u16) -> Vec<Run> {
    frame.row_runs(row).unwrap_or_default().iter().map(Run::from).collect()
}

/// What a viewer joining now needs before live frames, all of the same screen:
/// the GHOSTSNP READY the terminal_bytes channel sends, a full render-delta,
/// and an H.264 IDR of the pane's pixels.
fn attach_cost(
    host: &Terminal,
    frame: &ghostty_vt::RenderFrame,
    surf: &raster::Surface,
    rows: u16,
    w: usize,
    h: usize,
) -> Res<Value> {
    // `frame` is the host RenderState's own latest frame: a second RenderState
    // updating the terminal would clear the dirty rows the host's needs.
    let ready = host.encode_snapshot(ghostty_vt::SnapshotPhase::Ready)?;
    let full = wire::render_delta(frame, &(0..rows).collect::<Vec<_>>(), true);
    let mut idr = Video::new(w, h, 60, 12000, 0)?;
    let idr_bytes = idr.frame(&surf.bgrx, 0)?.bytes;
    Ok(json!({
        "ghostsnp_ready_bytes": ready.len(),
        "ghostsnp_ready_deflate_bytes": Deflater::new().bytes(&ready),
        "render_delta_full_bytes": full.len(),
        "render_delta_full_deflate_bytes": Deflater::new().bytes(&full),
        "h264_idr_12000k_bytes": idr_bytes,
    }))
}

fn main() -> Res<()> {
    let o = match opts() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("{e}");
            return Err("bad arguments".into());
        }
    };
    let tr = trace::load(&o.trace)?;
    let (cols, rows) = (tr.cols, tr.rows);
    let ser_ns = |bytes: usize| (bytes as f64 * 8.0 / o.link_bps * 1e9) as u64;

    let mut host = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
    let mut host_rs = RenderState::new()?;
    let mut vt_view = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
    let mut vt_rs = RenderState::new()?;

    let mut raster = Raster::new(
        &std::fs::read(&o.font)?,
        &std::fs::read(&o.bold)?,
        o.px,
        cols.into(),
        rows.into(),
    )?;
    let (w, h) = (raster.w, raster.h);
    let mut host_surf = raster.surface();
    let mut cell_surf = raster.surface();
    let mut cell_view = CellViewer::new(rows.into());
    let mut rowdiff = RowDiff::new(rows.into());
    let mut rowdiff_view = CellViewer::new(rows.into());
    let (mut d_vt, mut d_cells, mut d_rowdiff) =
        (Deflater::new(), Deflater::new(), Deflater::new());

    let mut videos =
        o.videos.iter().map(|&(k, r)| Video::new(w, h, 60, k, r)).collect::<Result<Vec<_>, _>>()?;
    let mut damaged = vec![true; videos.len()];
    let (mut s_vt, mut s_cells, mut s_rowdiff) =
        (PathStats::default(), PathStats::default(), PathStats::default());
    s_cells.quality = Some(Quality::default());
    let mut s_video: Vec<PathStats> = videos
        .iter()
        .map(|_| PathStats { quality: Some(Quality::default()), ..Default::default() })
        .collect();
    let mut floor = Quality::default();

    let mut keys: Vec<Key> = Vec::new();
    let mut attach: Option<Value> = None;
    let mut host_cursor: Option<(usize, usize)> = None;
    let mut last_cell_emit: Option<u64> = None;
    let mut cell_due: Option<u64> = None;
    let mut next_tick = CAPTURE_PERIOD_NS;
    let mut ticks = 0u64;
    let end = tr.records.last().map_or(0, |r| r.t_ns) + 500_000_000;

    let started = Instant::now();
    let mut idx = 0usize;
    loop {
        let rec_t = tr.records.get(idx).map_or(end, |r| r.t_ns);
        // Everything scheduled before the next record happens first.
        loop {
            let due = cell_due.unwrap_or(u64::MAX).min(next_tick);
            if due > rec_t || due > end {
                break;
            }
            if cell_due == Some(due) {
                cell_due = None;
                last_cell_emit = Some(due);
                // render-delta: the dirty rows of this frame.
                let t0 = Instant::now();
                host_rs.update(&mut host)?;
                let first = s_cells.sends.is_empty();
                let frame = host_rs.build_frame()?;
                let frame_ns = t0.elapsed().as_nanos() as u64;
                let full = first || frame.dirty == Dirty::Full;
                let dirty: Vec<u16> =
                    if full { (0..rows).collect() } else { frame.dirty_rows.clone() };
                let msg = wire::render_delta(&frame, &dirty, full);
                let host_ns = t0.elapsed().as_nanos() as u64;
                s_cells.host_ns += host_ns;
                s_cells.send(due, msg.len(), d_cells.bytes(&msg));
                let t1 = Instant::now();
                let touched = cell_view.apply(&msg);
                let viewer_ns = t1.elapsed().as_nanos() as u64;
                s_cells.viewer_ns += viewer_ns;

                let t2 = Instant::now();
                let rd = rowdiff.message(&frame);
                let rd_host_ns = frame_ns + t2.elapsed().as_nanos() as u64;
                s_rowdiff.host_ns += rd_host_ns;
                let mut rd_view_ns = 0;
                if let Some(rd) = &rd {
                    s_rowdiff.send(due, rd.len(), d_rowdiff.bytes(rd));
                    let t3 = Instant::now();
                    rowdiff_view.apply(rd);
                    rd_view_ns = t3.elapsed().as_nanos() as u64;
                    s_rowdiff.viewer_ns += rd_view_ns;
                }

                // Both viewers hold exactly the host's rows?
                for r in 0..rows {
                    let want = host_runs(&frame, r);
                    s_cells.mismatched_rows += u64::from(cell_view.rows[r as usize] != want);
                    s_rowdiff.mismatched_rows += u64::from(rowdiff_view.rows[r as usize] != want);
                }

                // The host's pixels (what video captures) and the cell viewer's.
                let defaults = (frame.default_colors.1, frame.default_colors.0);
                let cursor = frame.cursor.map(|c| (c.x as usize, c.y as usize));
                let mut redraw: Vec<usize> = dirty.iter().map(|&r| r as usize).collect();
                if cursor != host_cursor {
                    redraw.extend(host_cursor.map(|c| c.1));
                    redraw.extend(cursor.map(|c| c.1));
                    host_cursor = cursor;
                }
                for &r in &redraw {
                    let col = cursor.filter(|c| c.1 == r).map(|c| c.0);
                    raster.draw_row(&mut host_surf, r, &host_runs(&frame, r as u16), defaults, col);
                }
                if let Some(vd) = cell_view.defaults {
                    for r in touched {
                        let col = cell_view.cursor.filter(|c| c.1 == r).map(|c| c.0);
                        raster.draw_row(&mut cell_surf, r, &cell_view.rows[r], vd, col);
                    }
                }
                if attach.is_none() && o.attach_at.is_some_and(|a| due >= (a * 1e9) as u64) {
                    attach = Some(attach_cost(&host, &frame, &host_surf, rows, w, h)?);
                }
                if !redraw.is_empty() {
                    damaged.iter_mut().for_each(|d| *d = true);
                }
                for k in keys
                    .iter_mut()
                    .filter(|k| k.echo.is_some_and(|e| e <= due) && k.drawn.is_none())
                {
                    let e = k.echo.unwrap_or(due);
                    k.drawn = Some(due);
                    s_cells.key([due - e, host_ns, ser_ns(msg.len()), viewer_ns]);
                    // No rowdiff message: its viewer already showed this grid.
                    let rd_len = rd.as_ref().map_or(0, Vec::len);
                    s_rowdiff.key([due - e, rd_host_ns, ser_ns(rd_len), rd_view_ns]);
                }
            } else {
                for (i, v) in videos.iter_mut().enumerate() {
                    let refresh = v.refresh_ms > 0
                        && due.saturating_sub(v.last_encode_ns) >= v.refresh_ms * 1_000_000;
                    if !damaged[i] && !refresh {
                        continue;
                    }
                    let enc = v.frame(&host_surf.bgrx, (due / 1_000_000) as i64)?;
                    v.last_encode_ns = due;
                    s_video[i].host_ns += enc.encode_ns;
                    s_video[i].viewer_ns += enc.decode_ns;
                    s_video[i].send(due, enc.bytes, 0);
                    // A frame the rate control skipped sends nothing: try again next capture.
                    damaged[i] = enc.bytes == 0;
                    if enc.bytes > 0 {
                        for k in keys
                            .iter_mut()
                            .filter(|k| k.drawn.is_some_and(|d| d <= due) && !k.done[i])
                        {
                            k.done[i] = true;
                            let e = k.echo.unwrap_or(due);
                            s_video[i].key([
                                due - e,
                                enc.encode_ns,
                                ser_ns(enc.bytes),
                                enc.decode_ns,
                            ]);
                        }
                    }
                }
                ticks += 1;
                if ticks.is_multiple_of(o.quality_every) {
                    for (i, v) in videos.iter().enumerate() {
                        if let Some(q) = s_video[i].quality.as_mut() {
                            q.add(&host_surf, &v.decoded, w, h, raster.cw, raster.ch);
                        }
                    }
                    if let Some(q) = s_cells.quality.as_mut() {
                        q.add(&host_surf, &cell_surf.bgrx, w, h, raster.cw, raster.ch);
                    }
                    floor.add(
                        &host_surf,
                        &video::chroma_floor(&host_surf.bgrx, w, h),
                        w,
                        h,
                        raster.cw,
                        raster.ch,
                    );
                }
                next_tick += CAPTURE_PERIOD_NS;
            }
        }
        let Some(rec) = tr.records.get(idx) else { break };
        idx += 1;
        if rec.key {
            keys.push(Key {
                t: rec.t_ns,
                echo: None,
                drawn: None,
                done: vec![false; videos.len()],
            });
            continue;
        }
        host.vt_write(&rec.data);
        s_vt.send(rec.t_ns, rec.data.len(), d_vt.bytes(&rec.data));
        let t0 = Instant::now();
        vt_view.vt_write(&rec.data);
        let echoes = keys.iter().any(|k| k.echo.is_none() && k.t <= rec.t_ns);
        if echoes {
            // The VT viewer has the echo once it parsed it and read its grid.
            vt_rs.update(&mut vt_view)?;
            let _ = vt_rs.build_frame()?;
        }
        let viewer_ns = t0.elapsed().as_nanos() as u64;
        s_vt.viewer_ns += viewer_ns;
        for k in keys.iter_mut().filter(|k| k.echo.is_none() && k.t <= rec.t_ns) {
            k.echo = Some(rec.t_ns);
            s_vt.key([0, 0, ser_ns(rec.data.len()), viewer_ns]);
        }
        if cell_due.is_none() {
            cell_due =
                Some(last_cell_emit.map_or(rec.t_ns, |l| (l + CELL_CADENCE_NS).max(rec.t_ns)));
        }
    }

    // The VT viewer's final grid against the host's.
    host_rs.update(&mut host)?;
    vt_rs.update(&mut vt_view)?;
    let (hf, vf) = (host_rs.build_frame()?, vt_rs.build_frame()?);
    s_vt.mismatched_rows = (0..rows).filter(|&r| hf.row_runs(r) != vf.row_runs(r)).count() as u64;
    if attach.is_none() {
        attach = Some(attach_cost(&host, &hf, &host_surf, rows, w, h)?);
    }

    let span = tr.records.last().map_or(1, |r| r.t_ns).max(1);
    let win = o.window.map_or((0, span), |(a, b)| ((a * 1e9) as u64, (b * 1e9) as u64));
    let span_s = span as f64 / 1e9;
    let mut paths = serde_json::Map::new();
    paths.insert("vt".into(), s_vt.json(win, span_s));
    paths.insert("render-delta".into(), s_cells.json(win, span_s));
    paths.insert("rowdiff".into(), s_rowdiff.json(win, span_s));
    for (i, v) in videos.iter().enumerate() {
        paths.insert(v.name(), s_video[i].json(win, span_s));
    }
    let out = json!({
        "schema": "cmux.cellgrid-bench/1",
        "trace": o.trace,
        "grid": {"cols": cols, "rows": rows, "pixels": [w, h], "cell_px": [raster.cw, raster.ch], "font_px": o.px},
        "trace_s": span_s,
        "window_s": [win.0 as f64 / 1e9, win.1 as f64 / 1e9],
        "vt_bytes": tr.records.iter().filter(|r| !r.key).map(|r| r.data.len()).sum::<usize>(),
        "keys": keys.len(),
        "link_mbps": o.link_bps / 1e6,
        "chroma_420_floor": floor.json(),
        "attach": attach,
        "paths": paths,
        "bench_wall_s": started.elapsed().as_secs_f64(),
    });
    let text = serde_json::to_string_pretty(&out)?;
    if let Some(p) = &o.json {
        std::fs::write(p, &text)?;
    }
    println!("{text}");
    Ok(())
}
