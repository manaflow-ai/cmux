//! The cell wires the bench measures.
//!
//! `render-delta` is the daemon's render attach message as cmux-tui-core sends it
//! today (`cmux-tui-core/src/server/render_messages.rs`: `styled_run_json`,
//! `render_rows_json`, `render_cursor_json`, `RenderDeltaMessage`): the dirty rows
//! ghostty-vt reports, each as styled runs with resolved colours. The bench builds
//! the same messages: `render-state` on attach, then `render-delta`s with the same
//! full-frame rule and optional fields (`RenderClientState::delta_message`); kitty
//! graphics are left out (no workload here draws images).
//!
//! `rowdiff` is a candidate: rows compared against what the viewer already holds,
//! and a scroll op when the screen moved up, so a flood sends only the new lines.

use flate2::{Compress, Compression, FlushCompress};
use ghostty_vt::{CursorShape, Dirty, RenderFrame, Rgb, StyledRun, UnderlineStyle};
use serde_json::{Value, json};

use crate::raster::Run;

fn rgb_hex(c: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

fn parse_hex(v: &Value) -> Option<Rgb> {
    let s = v.as_str()?.strip_prefix('#')?;
    let n = u32::from_str_radix(s, 16).ok()?;
    Some(Rgb { r: (n >> 16) as u8, g: (n >> 8) as u8, b: n as u8 })
}

/// `styled_run_json` (render_messages.rs).
fn run_json(run: &StyledRun) -> Value {
    let mut v = json!({
        "text": run.text,
        "fg": run.fg.map(rgb_hex),
        "bg": run.bg.map(rgb_hex),
        "attrs": run.attrs,
    });
    if let (Some(u), Some(o)) = (run.underline, v.as_object_mut()) {
        let name = match u {
            UnderlineStyle::Single => "single",
            UnderlineStyle::Double => "double",
            UnderlineStyle::Curly => "curly",
            UnderlineStyle::Dotted => "dotted",
            UnderlineStyle::Dashed => "dashed",
        };
        o.insert("underline".into(), json!(name));
    }
    if let (Some(w), Some(o)) = (run.width_hint, v.as_object_mut()) {
        o.insert("width_hint".into(), json!(w));
    }
    v
}

/// `render_cursor_json` (render_messages.rs).
fn cursor_json(frame: &RenderFrame) -> Value {
    let (style, blink) = frame.cursor_visual;
    let style = match style {
        CursorShape::Bar => "bar",
        CursorShape::Underline => "underline",
        CursorShape::Block | CursorShape::BlockHollow => "block",
    };
    let (x, y, visible) = frame.cursor.map(|c| (c.x, c.y, true)).unwrap_or((0, 0, false));
    json!({"x": x, "y": y, "style": style, "blink": blink, "visible": visible,
           "color": frame.cursor_color.map(rgb_hex)})
}

fn rows_json(frame: &RenderFrame, rows: &[u16]) -> Vec<Value> {
    rows.iter()
        .filter_map(|&row| {
            frame.row_runs(row).map(
                |runs| json!({"row": row, "runs": runs.iter().map(run_json).collect::<Vec<_>>()}),
            )
        })
        .collect()
}

fn line(m: &Value) -> Vec<u8> {
    let mut out = serde_json::to_vec(m).unwrap_or_default();
    out.push(b'\n');
    out
}

/// The terminal state a render frame goes with (`SurfaceRenderFrame`'s extra fields).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Meta {
    pub scrollback_rows: u32,
    pub history_epoch: u64,
}

/// `render-state` (`render_state_message`): the whole viewport and every field,
/// what a client gets when it attaches.
pub fn render_state(frame: &RenderFrame, meta: Meta) -> Vec<u8> {
    let all: Vec<u16> = (0..frame.size.1).collect();
    line(&json!({
        "event": "render-state", "surface": 1,
        "size": {"cols": frame.size.0, "rows": frame.size.1},
        "cursor": cursor_json(frame),
        "default_fg": rgb_hex(frame.default_colors.1),
        "default_bg": rgb_hex(frame.default_colors.0),
        "scrollback_rows": meta.scrollback_rows,
        "history_epoch": meta.history_epoch,
        "rows": rows_json(frame, &all),
    }))
}

/// One attach client's render stream (`RenderClientState`): a `render-state`
/// first, then `render-delta`s that are full on a size or default-colour change
/// or a full repaint, and carry the optional fields only when they changed.
#[derive(Default)]
pub struct RenderStream {
    /// Size, default colours and meta of the last message.
    last: Option<Sent>,
}

type Sent = ((u16, u16), (Rgb, Rgb), Meta);

impl RenderStream {
    /// The message for `frame` and the rows it carries.
    pub fn message(&mut self, frame: &RenderFrame, meta: Meta) -> (Vec<u8>, Vec<u16>) {
        let now = (frame.size, frame.default_colors, meta);
        let Some((size, colors, last_meta)) = self.last.replace(now) else {
            return (render_state(frame, meta), (0..frame.size.1).collect());
        };
        let size_changed = size != frame.size;
        let fg_changed = colors.1 != frame.default_colors.1;
        let bg_changed = colors.0 != frame.default_colors.0;
        let full = size_changed || fg_changed || bg_changed || frame.dirty == Dirty::Full;
        let rows: Vec<u16> =
            if full { (0..frame.size.1).collect() } else { frame.dirty_rows.clone() };
        let mut m = json!({"event": "render-delta", "surface": 1, "cursor": cursor_json(frame),
                           "full": full, "rows": rows_json(frame, &rows)});
        if let Some(o) = m.as_object_mut() {
            if size_changed {
                o.insert("size".into(), json!({"cols": frame.size.0, "rows": frame.size.1}));
            }
            if fg_changed {
                o.insert("default_fg".into(), json!(rgb_hex(frame.default_colors.1)));
            }
            if bg_changed {
                o.insert("default_bg".into(), json!(rgb_hex(frame.default_colors.0)));
            }
            if meta.scrollback_rows != last_meta.scrollback_rows {
                o.insert("scrollback_rows".into(), json!(meta.scrollback_rows));
            }
            if meta.history_epoch != last_meta.history_epoch {
                o.insert("history_epoch".into(), json!(meta.history_epoch));
            }
        }
        (line(&m), rows)
    }
}

/// What a viewer holds after applying cell messages.
pub struct CellViewer {
    pub rows: Vec<Vec<Run>>,
    pub cursor: Option<(usize, usize)>,
    pub defaults: Option<(Rgb, Rgb)>,
}

impl CellViewer {
    pub fn new(rows: usize) -> Self {
        CellViewer { rows: vec![Vec::new(); rows], cursor: None, defaults: None }
    }

    fn runs(v: &Value) -> Vec<Run> {
        v.as_array()
            .map(|runs| {
                runs.iter()
                    .map(|r| Run {
                        text: r["text"].as_str().unwrap_or_default().to_string(),
                        fg: parse_hex(&r["fg"]),
                        bg: parse_hex(&r["bg"]),
                        attrs: r["attrs"].as_u64().unwrap_or(0) as u16,
                        underline: !r["underline"].is_null(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Applies one message (`render-delta` or `rowdiff`); returns the rows it changed.
    pub fn apply(&mut self, msg: &[u8]) -> Vec<usize> {
        let Ok(m) = serde_json::from_slice::<Value>(msg) else { return Vec::new() };
        let mut touched = Vec::new();
        let (fg, bg) = (parse_hex(&m["default_fg"]), parse_hex(&m["default_bg"]));
        match (self.defaults, fg, bg) {
            (_, Some(fg), Some(bg)) => self.defaults = Some((fg, bg)),
            (Some((_, b)), Some(fg), None) => self.defaults = Some((fg, b)),
            (Some((f, _)), None, Some(bg)) => self.defaults = Some((f, bg)),
            _ => {}
        }
        let n = self.rows.len();
        if let Some(k) = m["scroll"].as_u64().map(|k| k as usize).filter(|&k| k > 0 && k < n) {
            self.rows.drain(0..k);
            self.rows.extend(std::iter::repeat_n(Vec::new(), k));
            touched.extend(0..n);
        }
        for r in m["rows"].as_array().into_iter().flatten() {
            let Some(row) = r["row"].as_u64().map(|x| x as usize).filter(|&x| x < n) else {
                continue;
            };
            self.rows[row] = Self::runs(&r["runs"]);
            touched.push(row);
        }
        let c = &m["cursor"];
        if !c.is_null() {
            let old = self.cursor;
            self.cursor = c["visible"].as_bool().filter(|&v| v).map(|_| {
                (c["x"].as_u64().unwrap_or(0) as usize, c["y"].as_u64().unwrap_or(0) as usize)
            });
            if old != self.cursor {
                touched.extend(old.map(|o| o.1));
                touched.extend(self.cursor.map(|o| o.1));
            }
        }
        touched.sort_unstable();
        touched.dedup();
        touched
    }
}

/// The row-diff candidate's sender: the rows its viewer holds.
pub struct RowDiff {
    sent: Vec<Vec<StyledRun>>,
    cursor: Option<(u16, u16)>,
}

impl RowDiff {
    pub fn new(rows: usize) -> Self {
        RowDiff { sent: vec![Vec::new(); rows], cursor: None }
    }

    /// A message bringing the viewer to `frame`'s grid, or None when it already shows it.
    pub fn message(&mut self, frame: &RenderFrame) -> Option<Vec<u8>> {
        let cur: Vec<Vec<StyledRun>> = frame.runs();
        let n = cur.len().min(self.sent.len());
        // The upward shift that lines up the most rows, if it beats no shift.
        let same_at = |k: usize| (0..n - k).filter(|&i| cur[i] == self.sent[i + k]).count();
        let base = (0..n).filter(|&i| cur[i] == self.sent[i]).count();
        let (mut scroll, mut best) = (0usize, base);
        for k in 1..n {
            let s = same_at(k);
            if s > best + 1 {
                (scroll, best) = (k, s);
            }
        }
        if scroll > 0 {
            self.sent.drain(0..scroll);
            self.sent.extend(std::iter::repeat_n(Vec::new(), scroll));
        }
        let changed: Vec<usize> = (0..n).filter(|&i| cur[i] != self.sent[i]).collect();
        let cursor = frame.cursor.map(|c| (c.x, c.y));
        if scroll == 0 && changed.is_empty() && cursor == self.cursor {
            return None;
        }
        let rows: Vec<Value> = changed
            .iter()
            .map(|&i| json!({"row": i, "runs": cur[i].iter().map(run_json).collect::<Vec<_>>()}))
            .collect();
        let mut m = json!({"event": "rowdiff", "rows": rows});
        if let Some(o) = m.as_object_mut() {
            if scroll > 0 {
                o.insert("scroll".into(), json!(scroll));
            }
            if cursor != self.cursor {
                o.insert("cursor".into(), cursor_json(frame));
            }
        }
        for &i in &changed {
            self.sent[i] = cur[i].clone();
        }
        self.cursor = cursor;
        let mut out = serde_json::to_vec(&m).unwrap_or_default();
        out.push(b'\n');
        Some(out)
    }
}

/// A transport-level deflate stream (sync flush per message): the bytes a
/// compressed channel would carry for the same messages.
pub struct Deflater {
    c: Compress,
    buf: Vec<u8>,
}

impl Deflater {
    pub fn new() -> Self {
        Deflater { c: Compress::new(Compression::fast(), false), buf: vec![0; 1 << 20] }
    }

    pub fn bytes(&mut self, mut data: &[u8]) -> usize {
        let mut total = 0usize;
        loop {
            let (i0, o0) = (self.c.total_in(), self.c.total_out());
            if self.c.compress(data, &mut self.buf, FlushCompress::Sync).is_err() {
                return total;
            }
            let used = (self.c.total_in() - i0) as usize;
            let made = (self.c.total_out() - o0) as usize;
            total += made;
            data = &data[used..];
            if data.is_empty() && made < self.buf.len() {
                return total;
            }
        }
    }
}
