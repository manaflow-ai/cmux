//! A live check of `agent-cli-phone-grid-v1` against a running daemon: the Mac's pane of a
//! Claude Code terminal, and the same terminal as a phone at its own grid sees it.
//!
//!     cargo run -p cmux-agent-cli-render --example phone_grid_proof -- SOCKET SURFACE COLS ROWS OUT_DIR
//!
//! It attaches twice to the daemon at SOCKET: once as a plain byte viewer (the Mac pane: the
//! `vt-state` replay drawn into ghostty-vt), once as a phone that declared the hybrid stream and
//! the phone grid with `view_cols`/`view_rows` (its `output` bytes and `agent-cli-frame`s drawn
//! into a ghostty-vt of COLS x ROWS, as the phone's terminal draws them). It writes
//! `mac.txt`, `phone.txt` (the phone's scrollback, then its screen) and `side-by-side.html`.

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_agent_cli_render::stream::Frame;
use cmux_agent_cli_render::{Cell, Color, Grid, Style, vt, xterm_palette};
use serde_json::{Value, json};

fn b64(text: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(text).unwrap_or_default()
}

fn connect(socket: &str) -> (UnixStream, BufReader<UnixStream>) {
    let stream = UnixStream::connect(socket).expect("daemon socket");
    stream.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
    let reader = BufReader::new(stream.try_clone().unwrap());
    (stream, reader)
}

fn send(stream: &mut UnixStream, request: Value) {
    writeln!(stream, "{request}").unwrap();
}

/// Every line the daemon sends for `secs` seconds.
fn read_for(reader: &mut BufReader<UnixStream>, secs: u64) -> Vec<Value> {
    let end = Instant::now() + Duration::from_secs(secs);
    let mut out = Vec::new();
    let mut line = String::new();
    while Instant::now() < end {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    out.push(v);
                }
            }
            Err(_) => continue,
        }
    }
    out
}

fn color(spec: ghostty_vt::ColorSpec) -> Color {
    match spec {
        ghostty_vt::ColorSpec::Default => Color::Default,
        ghostty_vt::ColorSpec::Palette(i) => Color::Palette(i),
        ghostty_vt::ColorSpec::Rgb(rgb) => Color::Rgb(rgb.r, rgb.g, rgb.b),
    }
}

fn snapshot(term: &mut ghostty_vt::Terminal, cols: u16, rows: u16) -> Grid {
    let mut render = ghostty_vt::RenderState::new().unwrap();
    render.update(term).unwrap();
    let frame = render.build_frame().unwrap();
    let mut grid = Grid::blank(cols, rows);
    for (slot, row) in grid.cells.iter_mut().zip(frame.styled_rows()) {
        *slot = row
            .iter()
            .map(|c| Cell {
                text: c.text.clone(),
                style: Style { fg: color(c.fg), bg: color(c.bg), attrs: c.attrs() },
            })
            .collect();
        slot.resize(usize::from(cols), Cell::default());
    }
    grid
}

fn text(grid: &Grid) -> String {
    (0..grid.cells.len()).map(|y| grid.row_text(y) + "\n").collect()
}

fn html(grid: &Grid, title: &str) -> String {
    let palette = xterm_palette();
    let hex = |c: Option<(u8, u8, u8)>, default: &str| {
        c.map_or(default.to_owned(), |(r, g, b)| format!("#{r:02x}{g:02x}{b:02x}"))
    };
    let mut out = format!("<div class=pane><h3>{title} ({}x{})</h3><pre>", grid.cols, grid.rows);
    for row in grid.runs(&palette) {
        for run in row {
            let mut style =
                format!("color:{};background:{}", hex(run.fg, "#ddd"), hex(run.bg, "transparent"));
            if run.attrs & cmux_agent_cli_render::BOLD != 0 {
                style.push_str(";font-weight:bold");
            }
            if run.attrs & cmux_agent_cli_render::FAINT != 0 {
                style.push_str(";opacity:.6");
            }
            let escaped = run.text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
            out.push_str(&format!("<span style=\"{style}\">{escaped}</span>"));
        }
        out.push('\n');
    }
    out.push_str("</pre></div>");
    out
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let [_, socket, surface, cols, rows, out_dir] = &args[..] else {
        panic!("usage: phone_grid_proof SOCKET SURFACE COLS ROWS OUT_DIR");
    };
    let surface: u64 = surface.parse().unwrap();
    let (cols, rows): (u16, u16) = (cols.parse().unwrap(), rows.parse().unwrap());
    std::fs::create_dir_all(out_dir).unwrap();

    // The Mac pane: a plain byte attach's replay.
    let (mut mac, mut mac_reader) = connect(socket);
    send(
        &mut mac,
        json!({"id": 1, "cmd": "set-client-info", "name": "phone-grid-proof-mac", "kind": "cli"}),
    );
    send(&mut mac, json!({"id": 2, "cmd": "attach-surface", "surface": surface}));
    let lines = read_for(&mut mac_reader, 2);
    let state = lines.iter().find(|v| v["event"] == "vt-state").expect("vt-state");
    let (mc, mr) = (state["cols"].as_u64().unwrap() as u16, state["rows"].as_u64().unwrap() as u16);
    let mut mac_term =
        ghostty_vt::Terminal::new(mc, mr, 1 << 20, ghostty_vt::Callbacks::default()).unwrap();
    mac_term
        .vt_write(&b64(state["data"].as_str().or(state["replay"].as_str()).unwrap_or_default()));
    for v in &lines {
        if v["event"] == "output" {
            mac_term.vt_write(&b64(v["data"].as_str().unwrap_or_default()));
        }
    }
    let mac_grid = snapshot(&mut mac_term, mc, mr);

    // The phone: the hybrid stream at its own grid.
    let (mut phone, mut phone_reader) = connect(socket);
    send(
        &mut phone,
        json!({"id": 1, "cmd": "set-client-info", "name": "phone-grid-proof-phone", "kind": "cli",
               "capabilities": ["agent-cli-hybrid-v1", "agent-cli-phone-grid-v1"]}),
    );
    send(
        &mut phone,
        json!({"id": 2, "cmd": "attach-surface", "surface": surface, "view_cols": cols, "view_rows": rows}),
    );
    let lines = read_for(&mut phone_reader, 3);
    let mut term =
        ghostty_vt::Terminal::new(cols, rows, 1 << 20, ghostty_vt::Callbacks::default()).unwrap();
    let (mut frames, mut size) = (0, None);
    for v in &lines {
        match v["event"].as_str() {
            Some("output") => term.vt_write(&b64(v["data"].as_str().unwrap_or_default())),
            Some("agent-cli-frame") => {
                frames += 1;
                let frame = Frame {
                    frame: v["frame"].as_u64().unwrap_or(0),
                    base: v["base"].as_u64(),
                    data: b64(v["data"].as_str().unwrap_or_default()),
                };
                let fr = v["rows"].as_u64().unwrap_or(0) as u16;
                size = Some((v["cols"].as_u64().unwrap_or(0), fr));
                let cursor = vt::Cursor { x: 0, y: 0, visible: false };
                if let Some(bytes) = vt::frame_bytes(&frame, fr, cursor) {
                    term.vt_write(&bytes);
                }
            }
            _ => {}
        }
    }
    let phone_grid = snapshot(&mut term, cols, rows);
    // The phone's scrollback (what a swipe up shows), then its screen.
    let kept = term.history_rows();
    let history: Vec<Vec<Cell>> = term
        .styled_history_rows(0, u16::try_from(kept).unwrap_or(u16::MAX))
        .unwrap_or_default()
        .into_iter()
        .map(|row| {
            let mut row: Vec<Cell> = row
                .iter()
                .map(|c| Cell {
                    text: c.text.clone(),
                    style: Style { fg: color(c.fg), bg: color(c.bg), attrs: c.attrs() },
                })
                .collect();
            row.resize(usize::from(cols), Cell::default());
            row
        })
        .collect();
    let history = Grid { cols, rows: u16::try_from(history.len()).unwrap_or(0), cells: history };
    std::fs::write(format!("{out_dir}/mac.txt"), text(&mac_grid)).unwrap();
    std::fs::write(
        format!("{out_dir}/phone.txt"),
        format!("{}--- screen ---\n{}", text(&history), text(&phone_grid)),
    )
    .unwrap();
    let page = format!(
        "<!doctype html><meta charset=utf-8><style>body{{background:#111;color:#ddd;font:12px Menlo,monospace;display:flex;gap:24px;align-items:flex-start}} pre{{margin:0;line-height:1.25;background:#000;padding:8px}} h3{{font:13px -apple-system,sans-serif}}</style>{}{}",
        html(&mac_grid, "Mac pane"),
        html(&phone_grid, "Phone, drawn at its own grid"),
    ) + &html(&history, "Phone scrollback (swipe up)");
    std::fs::write(format!("{out_dir}/side-by-side.html"), page).unwrap();
    println!(
        "{}",
        json!({"mac": [mc, mr], "phone_frames": frames, "phone_frame_size": size,
               "phone_history_rows": history.cells.len(), "out": out_dir})
    );
}
