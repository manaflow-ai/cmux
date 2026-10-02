//! Drawing, in cmux's chrome: no boxes around panes, one vertical rule on
//! the sidebar, a status bar with an active chip, bordered dialogs with
//! `[ Cancel esc ]  [ OK ⏎ ]` buttons, and the shared scrollbar.

use super::dialog::{self, DialogRow, DialogSpec};
use super::scroll::draw_thumb;
use super::theme::Chrome;
use super::{App, ButtonAction, Focus, NewForm, Overlay, POLICIES, Picker, Toggle};
use crate::transcript::{Item, Transcript};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use serde_json::Value;
use unicode_width::UnicodeWidthStr;

mod cache;
mod composer;
mod dialogs;
mod sidebar;
mod status;
mod transcript;
mod transcript_rows;
pub(crate) use cache::TranscriptCache;
pub use transcript_rows::transcript_rows;
use transcript_rows::{transcript_rows_range, working_row};

use composer::draw_composer;
pub(crate) use composer::policy_label;
use dialogs::{
    draw_add_host, draw_confirm, draw_directory, draw_help, draw_new_session, draw_permission_card,
    draw_picker,
};
use sidebar::draw_sidebar;
use status::draw_status;
use transcript::draw_transcript;

pub const SIDEBAR_WIDTH: u16 = 32;
/// Columns before the composer text: the `❯ ` prompt, matching Claude Code.
pub const COMPOSER_INDENT: u16 = 2;
/// Columns always left for the transcript, as cmux leaves for panes.
pub const MIN_MAIN_WIDTH: u16 = 40;
/// Widest conversation column, in cells; a wider pane centers it, as the
/// Codex app does with its 860px column.
pub const COLUMN_WIDTH: u16 = 124;

/// One rendered transcript row with the absolute index it belongs to, so
/// selection and scrolling stay stable while text streams in.
#[derive(Clone)]
pub struct Row {
    pub line: Line<'static>,
    /// Plain text of the row, used for copy.
    pub text: String,
    /// Index of the transcript item this row belongs to.
    pub item: usize,
    /// The collapsible this row belongs to; a click on it toggles.
    pub toggle: Option<Toggle>,
}

pub fn truncate(s: &str, max: usize) -> String {
    if s.width() <= max {
        return s.to_owned();
    }
    let mut out = String::new();
    let mut w = 0;
    for ch in s.chars() {
        let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if w + cw + 1 > max {
            break;
        }
        out.push(ch);
        w += cw;
    }
    out.push('…');
    out
}

pub fn shorten_path(p: &str) -> String {
    if let Some(h) = dirs::home_dir()
        && let Ok(rest) = std::path::Path::new(p).strip_prefix(&h)
    {
        return format!("~/{}", rest.display());
    }
    p.to_owned()
}

pub fn fill(buf: &mut Buffer, area: Rect, style: Style) {
    for y in area.y..area.y + area.height {
        for x in area.x..area.x + area.width {
            if let Some(c) = buf.cell_mut((x, y)) {
                c.reset();
                c.set_symbol(" ").set_style(style);
            }
        }
    }
}

pub fn border(buf: &mut Buffer, r: Rect, style: Style) {
    if r.width < 2 || r.height < 2 {
        return;
    }
    let (x0, y0, x1, y1) = (r.x, r.y, r.x + r.width - 1, r.y + r.height - 1);
    let put = |buf: &mut Buffer, x: u16, y: u16, s: &str| {
        if let Some(c) = buf.cell_mut((x, y)) {
            c.set_symbol(s).set_style(style);
        }
    };
    for x in x0 + 1..x1 {
        put(buf, x, y0, "─");
        put(buf, x, y1, "─");
    }
    for y in y0 + 1..y1 {
        put(buf, x0, y, "│");
        put(buf, x1, y, "│");
    }
    put(buf, x0, y0, "╭");
    put(buf, x1, y0, "╮");
    put(buf, x0, y1, "╰");
    put(buf, x1, y1, "╯");
}

pub fn centered(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width.saturating_sub(2)).max(10);
    let h = h.min(area.height.saturating_sub(2)).max(3);
    Rect {
        x: area.x + (area.width - w) / 2,
        y: area.y + (area.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    }
}

// ------------------------------------------------------------ wrapping

fn wrap(text: &str, width: usize, style: Style, prefix: &str, item: usize, out: &mut Vec<Row>) {
    let width = width.max(8);
    let pad = " ".repeat(prefix.width());
    for raw in text.split('\n') {
        let mut line = String::new();
        let mut first = true;
        let flush = |line: &mut String, first: &mut bool, out: &mut Vec<Row>| {
            let p = if *first { prefix.to_owned() } else { pad.clone() };
            let text = format!("{p}{line}");
            out.push(Row {
                line: Line::from(vec![Span::raw(p), Span::styled(std::mem::take(line), style)]),
                text,
                item,
                toggle: None,
            });
            *first = false;
        };
        for word in raw.split(' ') {
            let candidate =
                if line.is_empty() { word.width() } else { line.width() + 1 + word.width() };
            if candidate > width && !line.is_empty() {
                flush(&mut line, &mut first, out);
            }
            let mut word = word.to_owned();
            while word.width() > width {
                let mut head = String::new();
                let mut w = 0;
                let mut rest = String::new();
                for ch in word.chars() {
                    let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
                    if w + cw > width || !rest.is_empty() {
                        rest.push(ch);
                    } else {
                        head.push(ch);
                        w += cw;
                    }
                }
                let mut h = head;
                flush(&mut h, &mut first, out);
                word = rest;
            }
            if !line.is_empty() {
                line.push(' ');
            }
            line.push_str(&word);
        }
        flush(&mut line, &mut first, out);
    }
}

fn plain(text: &str, style: Style, item: usize, out: &mut Vec<Row>) {
    out.push(Row {
        line: Line::from(Span::styled(text.to_owned(), style)),
        text: text.to_owned(),
        item,
        toggle: None,
    });
}

/// Lifecycle chatter (process stopped, resumed, renamed, model set…) is
/// hidden unless `show_system`; real failures always show.
pub fn is_system_noise(item: &Item) -> bool {
    match item {
        Item::Status { text } => {
            !(text.starts_with("agent exited unexpectedly") || text.starts_with("resume failed"))
        }
        Item::Stderr { .. } => true,
        Item::Error { text } => text == "agent process closed",
        _ => false,
    }
}

/// The project label for a directory: its last segment, or `~` for a home
/// directory (local or a peer's), so a session started in $HOME does not
/// read as a project named after the user.
pub fn project_label(cwd: &str) -> String {
    let home = dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default();
    let trimmed = cwd.trim_end_matches('/');
    if !home.is_empty() && trimmed == home.trim_end_matches('/') {
        return "~".into();
    }
    let parts: Vec<&str> = trimmed.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() == 2 && matches!(parts[0], "Users" | "home") {
        return "~".into();
    }
    std::path::Path::new(trimmed)
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| shorten_path(cwd))
}

/// What a session is called in the sidebar and header: its title (the
/// first prompt) when its name was generated (`codex`, `codex-3`), else
/// the name the user gave it.
pub fn session_title(s: &Value) -> String {
    let name = s.get("name").and_then(Value::as_str).unwrap_or("?");
    let harness = s.get("harness").and_then(Value::as_str).unwrap_or("");
    let bare = name.rsplit('/').next().unwrap_or(name);
    let auto = !harness.is_empty()
        && (bare == harness
            || bare
                .strip_prefix(harness)
                .and_then(|r| r.strip_prefix('-'))
                .map(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
                .unwrap_or(false));
    match s.get("title").and_then(Value::as_str).filter(|t| !t.trim().is_empty()) {
        Some(t) if auto => t.to_owned(),
        _ => name.to_owned(),
    }
}

/// Tool titles as the Codex app shows them: verbs kept, absolute paths cut
/// to their last two segments, shell commands left alone.
pub fn shorten_tool_title(title: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    for word in title.split(' ') {
        let w = word.trim_matches(|ch: char| ch == '\'' || ch == '"' || ch == '`' || ch == ',');
        let is_path = w.starts_with('/') || w.starts_with("~/") || w.starts_with("./");
        if is_path && w.matches('/').count() >= 2 {
            let base = w.rsplit('/').next().unwrap_or(w);
            out.push(if base.is_empty() { w.to_owned() } else { base.to_owned() });
        } else {
            out.push(w.to_owned());
        }
    }
    let joined = out.join(" ");
    // "Read file X" reads better as "Read X".
    joined.replacen("Read file ", "Read ", 1).replacen("Write file ", "Write ", 1).replacen(
        "Edit file ",
        "Edit ",
        1,
    )
}

/// "just now", "5m ago", "3h ago", "2d ago".
pub fn age_label(ms: u64) -> String {
    let s = ms / 1000;
    if s < 60 {
        "just now".into()
    } else if s < 3600 {
        format!("{}m ago", s / 60)
    } else if s < 86_400 {
        format!("{}h ago", s / 3600)
    } else {
        format!("{}d ago", s / 86_400)
    }
}

/// "1m 7s", "12s", "1h 2m".
/// A model id as the chip shows it: a trailing date stamp (`-20251001`)
/// is dropped, as the Codex app shows "6 Astra", not the full id.
pub fn model_label(model: &str) -> String {
    match model.rsplit_once('-') {
        Some((head, tail))
            if tail.len() == 8 && tail.chars().all(|c| c.is_ascii_digit()) && !head.is_empty() =>
        {
            head.to_owned()
        }
        _ => model.to_owned(),
    }
}

/// An effort level as the chip shows it, Codex-app style: `xhigh` reads
/// "Extra high", the rest are capitalized; unknown values pass through.
pub fn effort_label(effort: &str) -> String {
    match effort {
        "xhigh" | "x-high" | "extra_high" | "extra-high" => "Extra high".to_owned(),
        "ultra" => "Ultra".to_owned(),
        "max" => "Max".to_owned(),
        "high" => "High".to_owned(),
        "medium" => "Medium".to_owned(),
        "low" => "Low".to_owned(),
        "minimal" => "Minimal".to_owned(),
        "none" => "None".to_owned(),
        other => other.to_owned(),
    }
}

pub fn duration_label(ms: u64) -> String {
    let s = ms / 1000;
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m {}s", s / 60, s % 60)
    } else {
        format!("{}h {}m", s / 3600, (s % 3600) / 60)
    }
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// "Today 10:13 PM", "Yesterday 9:02 AM", or "Sep 12, 9:02 AM", in local time.
pub fn when_label(ms: u64) -> String {
    #[cfg(unix)]
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        let mut now_tm: libc::tm = std::mem::zeroed();
        let t = (ms / 1000) as libc::time_t;
        let n = (now_ms() / 1000) as libc::time_t;
        libc::localtime_r(&t, &mut tm);
        libc::localtime_r(&n, &mut now_tm);
        let (h24, m) = (tm.tm_hour, tm.tm_min);
        let ampm = if h24 >= 12 { "PM" } else { "AM" };
        let h12 = match h24 % 12 {
            0 => 12,
            h => h,
        };
        let clock = format!("{h12}:{m:02} {ampm}");
        let same_year = tm.tm_year == now_tm.tm_year;
        if same_year && tm.tm_yday == now_tm.tm_yday {
            return format!("Today {clock}");
        }
        if same_year && tm.tm_yday + 1 == now_tm.tm_yday {
            return format!("Yesterday {clock}");
        }
        let months =
            ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        let mon = months.get(tm.tm_mon as usize).copied().unwrap_or("?");
        format!("{mon} {}, {clock}", tm.tm_mday)
    }
    #[cfg(not(unix))]
    {
        let _ = ms;
        String::new()
    }
}

/// The left gutter every transcript row shares.
pub const GUTTER: &str = "  ";

/// A one-line collapsible header in the gutter style.
fn header_row(
    text: &str,
    color: ratatui::style::Color,
    item: usize,
    toggle: Toggle,
    out: &mut Vec<Row>,
) {
    let text = text.to_owned();
    out.push(Row {
        line: Line::from(Span::styled(text.clone(), Style::default().fg(color))),
        text,
        item,
        toggle: Some(toggle),
    });
}

// ------------------------------------------------------------- frames

pub fn draw(f: &mut ratatui::Frame, app: &mut App) {
    let area = f.area();
    let c = app.chrome;
    app.buttons.clear();
    app.perm_rows.clear();
    app.link_cells.clear();
    app.cursor_pos = None;
    app.dialog_rect = Rect::default();
    if area.height < 6 || area.width < 20 {
        app.areas = super::Areas::default();
        return;
    }
    let status_y = area.y + area.height - 1;
    let body = Rect { x: area.x, y: area.y, width: area.width, height: area.height - 1 };
    let sidebar_w = if app.sidebar_hidden {
        0
    } else {
        app.sidebar_width
            .unwrap_or(SIDEBAR_WIDTH)
            .min(body.width.saturating_sub(MIN_MAIN_WIDTH))
            .max(16)
    };
    let sidebar = Rect { x: body.x, y: body.y, width: sidebar_w, height: body.height };
    let main = Rect {
        x: body.x + sidebar_w,
        y: body.y,
        width: body.width - sidebar_w,
        height: body.height,
    };
    let col_w = main.width.min(COLUMN_WIDTH);
    let col_x = main.x + (main.width - col_w) / 2;
    // The composer box: one column of margin, a border and a space each side.
    let editor_w = col_w.saturating_sub(6) as usize;
    // Top rule, the text (1-6 rows), bottom rule, controls row.
    let max_rows = app.composer_max_rows.min(main.height / 2).max(1);
    // Top rule, the text, bottom rule, controls row.
    let input_h = (app.editor().rows_at(editor_w).max(1) as u16).min(max_rows)
        + 3
        + u16::from(!app.prompt_images().is_empty());
    let composer =
        Rect { x: col_x, y: main.y + main.height - input_h, width: col_w, height: input_h };
    // A pending permission docks as a card above the composer, Codex-app
    // style, instead of covering the conversation.
    let pending = app.selected_id().and_then(|id| app.transcripts.get(&id)).and_then(|t| {
        match t.pending_permission() {
            Some(Item::Permission { title, options, .. }) => Some((title.clone(), options.clone())),
            _ => None,
        }
    });
    let card_h: u16 = if pending.is_some() && main.height > input_h + 8 { 4 } else { 0 };
    let card = Rect {
        x: col_x + 1,
        y: composer.y.saturating_sub(card_h),
        width: col_w.saturating_sub(2),
        height: card_h,
    };
    let transcript =
        Rect { x: main.x, y: main.y, width: main.width, height: main.height - input_h - card_h };
    app.areas.column = Rect { x: col_x, y: transcript.y, width: col_w, height: transcript.height };
    app.areas.sidebar = sidebar;
    app.areas.sidebar_rule = if sidebar_w == 0 {
        Rect::default()
    } else {
        Rect { x: sidebar.x + sidebar.width - 1, y: sidebar.y, width: 1, height: sidebar.height }
    };
    app.areas.transcript = transcript;
    app.areas.composer = composer;
    app.areas.status = Rect { x: area.x, y: status_y, width: area.width, height: 1 };

    if sidebar_w > 0 {
        draw_sidebar(f, sidebar, app);
    } else {
        app.sidebar_rows.clear();
    }
    draw_transcript(f, transcript, app);
    draw_composer(f, composer, app);
    draw_status(f, app.areas.status, app);
    let chips = std::mem::take(&mut app.host_chips);
    for (r, key) in chips {
        let action = match key.as_deref() {
            Some("+") => ButtonAction::AddHost,
            other => ButtonAction::HostFilter(other.map(str::to_owned)),
        };
        app.buttons.push((r, action));
    }
    if let (Some((title, options)), true) = (pending, card_h > 0) {
        draw_permission_card(f, card, &title, &options, app);
    }
    let hover = app.hover;
    let kind: u8 = match &app.overlay {
        Overlay::None => 0,
        Overlay::Help => 1,
        Overlay::NewSession(_) => 2,
        Overlay::Picker(_) => 3,
        Overlay::Confirm { .. } => 4,
        Overlay::AddHost { .. } => 5,
        Overlay::Directory { .. } => 6,
        Overlay::Menu(_) => 7,
    };
    if kind != app.last_overlay {
        app.dialog = dialog::DialogState::default();
        app.last_overlay = kind;
    }
    // Modal hit targets replace the background; clicks cannot activate covered chips.
    if !matches!(app.overlay, Overlay::None) {
        app.buttons.clear();
        app.perm_rows.clear();
    }
    match std::mem::replace(&mut app.overlay, Overlay::None) {
        Overlay::None => {}
        Overlay::Menu(mut m) => {
            super::menu::draw(f.buffer_mut(), area, &c, hover, &mut m);
            app.dialog_rect = m.rect;
            app.overlay = Overlay::Menu(m);
        }
        Overlay::Help => {
            draw_help(f, area, app);
            app.overlay = Overlay::Help;
        }
        Overlay::NewSession(form) => {
            draw_new_session(f, area, &form, app, hover);
            app.overlay = Overlay::NewSession(form);
        }
        Overlay::Picker(mut p) => {
            draw_picker(f, area, &mut p, app);
            app.overlay = Overlay::Picker(p);
        }
        Overlay::Confirm { title, action } => {
            draw_confirm(f, area, &title, app, hover);
            app.overlay = Overlay::Confirm { title, action };
        }
        Overlay::AddHost { text } => {
            draw_add_host(f, area, &text, app, hover);
            app.overlay = Overlay::AddHost { text };
        }
        Overlay::Directory { text } => {
            draw_directory(f, area, &text, app, hover);
            app.overlay = Overlay::Directory { text };
        }
    }
    // Codex app: hovering a sidebar row shows a card with the full title,
    // the directory, the harness and model, and how long ago it moved.
    if matches!(app.overlay, Overlay::None)
        && app.sidebar_drag.is_none()
        && let Some((row, idx)) = app.hover.and_then(|(hx, hy)| {
            app.sidebar_rows
                .iter()
                .find(|(r, _)| hx >= r.x && hx < r.x + r.width && hy >= r.y && hy < r.y + r.height)
                .cloned()
        })
    {
        let ndrafts = app.drafts.len();
        if idx >= ndrafts
            && let Some(s) = app.sessions.get(idx - ndrafts).cloned()
        {
            let title = session_title(&s);
            let name = s.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
            let cwd = s.get("cwd").and_then(Value::as_str).unwrap_or("").to_owned();
            let harness = s.get("harness").and_then(Value::as_str).unwrap_or("").to_owned();
            let model = s.get("model").and_then(Value::as_str).unwrap_or("").to_owned();
            let age = s
                .get("updatedAt")
                .and_then(Value::as_u64)
                .map(|t| age_label(now_ms().saturating_sub(t)))
                .unwrap_or_default();
            let line1 = if title == name { title.clone() } else { format!("{title}  ·  {name}") };
            // The project, then the path only when it is short enough to help.
            let short = shorten_path(&cwd);
            let mut line2 = format!("▢ {}", project_label(&cwd));
            if short.width() <= 40 && short != project_label(&cwd) {
                line2.push_str(&format!("  {short}"));
            }
            if !harness.is_empty() {
                line2.push_str(&format!("  ·  {harness}"));
            }
            if !model.is_empty() && model != "default" {
                line2.push_str(&format!(" · {model}"));
            }
            if !age.is_empty() {
                line2.push_str(&format!("  ·  {age}"));
            }
            let w = (line1.width().max(line2.width()) as u16 + 4)
                .min(main.width.saturating_sub(4))
                .clamp(12, 72);
            let x = sidebar.x + sidebar.width + 1;
            let y = row.y.min(area.y + area.height.saturating_sub(5));
            let r = Rect { x, y, width: w, height: 4 };
            let buf = f.buffer_mut();
            fill(buf, r, c.prompt());
            composer::rounded_border(buf, r, c.prompt_border());
            buf.set_stringn(
                r.x + 2,
                r.y + 1,
                truncate(&line1, w as usize - 4),
                w as usize - 4,
                c.prompt().add_modifier(Modifier::BOLD),
            );
            buf.set_stringn(
                r.x + 2,
                r.y + 2,
                truncate(&line2, w as usize - 4),
                w as usize - 4,
                c.prompt().fg(c.status_dim_fg),
            );
            app.link_cells.retain(|l| {
                !(l.y >= r.y
                    && l.y < r.y + r.height
                    && l.x < r.x + r.width
                    && l.x + l.text.width() as u16 > r.x)
            });
        }
    }
    // Hyperlink metadata belongs only to visible transcript cells. Drop
    // links covered by a dialog, menu or toast before the backend diffs them.
    if !matches!(app.overlay, Overlay::None) {
        let d = app.dialog_rect;
        let covered = |x: u16, y: u16, w: u16| {
            y >= d.y && y < d.y + d.height && x < d.x + d.width && x + w > d.x
        };
        app.link_cells.retain(|l| !covered(l.x, l.y, l.text.width() as u16));
    }
    if let Some((text, _)) = &app.toast {
        let label = format!(" {text} ");
        let w = (label.width() as u16).min(transcript.width);
        let r = Rect {
            x: transcript.x + transcript.width.saturating_sub(w + 1),
            y: transcript.y + transcript.height.saturating_sub(2),
            width: w,
            height: 1,
        };
        f.buffer_mut().set_stringn(r.x, r.y, &label, w as usize, c.toast());
        app.link_cells
            .retain(|l| !(l.y == r.y && l.x < r.x + r.width && l.x + l.text.width() as u16 > r.x));
    }
}

fn status_fg(c: &Chrome, status: &str) -> Style {
    match status {
        "running" => Style::default().fg(c.warn_fg),
        "waiting" => Style::default().fg(c.attention_fg).add_modifier(Modifier::BOLD),
        "ready" => Style::default().fg(c.ok_fg),
        "disconnected" | "closed" | "unreachable" => Style::default().fg(c.error_fg),
        _ => c.dim(),
    }
}

/// Selection over transcript rows, stored by absolute row index so it
/// survives streaming and scrolling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    pub session: String,
    pub anchor: (usize, usize),
    pub head: (usize, usize),
    pub mode: SelectMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectMode {
    Cell,
    Word,
    Line,
}

impl Selection {
    pub fn range(&self) -> ((usize, usize), (usize, usize)) {
        if self.anchor <= self.head { (self.anchor, self.head) } else { (self.head, self.anchor) }
    }
    /// Columns [c0, c1) selected on row `row`, or None. Only the useful
    /// part of a row is ever selected: the gutter, role markers and
    /// trailing padding are left out (see `content_bounds`).
    pub fn cols_on_row(&self, row: usize, line: &str) -> Option<(usize, usize)> {
        let ((r0, c0), (r1, c1)) = self.range();
        if row < r0 || row > r1 {
            return None;
        }
        let (lo, hi) = content_bounds(line);
        let start = if row == r0 { c0.max(lo) } else { lo };
        let end = if row == r1 { c1.min(hi) } else { hi };
        if end > start {
            Some((start, end))
        } else if row != r0 && row != r1 {
            Some((0, 0))
        } else {
            None
        }
    }
    pub fn text(&self, rows: &[String]) -> String {
        let ((r0, _), (r1, _)) = self.range();
        let mut out = Vec::new();
        for (r, line) in rows.iter().enumerate().take(r1 + 1).skip(r0) {
            let chars: Vec<char> = line.chars().collect();
            let piece = match self.cols_on_row(r, line) {
                Some((s, e)) if e > s => {
                    chars[s.min(chars.len())..e.min(chars.len())].iter().collect::<String>()
                }
                _ => String::new(),
            };
            out.push(piece.trim_end().to_owned());
        }
        out.join("\n")
    }
}

/// The useful span of a transcript row, in char columns: after the gutter
/// and any role or structure marker (`›`, `•`, `»`, `▸`, `▾`, `⏳`), and
/// before trailing padding.
pub fn content_bounds(line: &str) -> (usize, usize) {
    let chars: Vec<char> = line.chars().collect();
    let mut lo = 0;
    while lo < chars.len() && chars[lo] == ' ' {
        lo += 1;
    }
    if lo < chars.len()
        && matches!(
            chars[lo],
            '›' | '•'
                | '»'
                | '▸'
                | '▾'
                | '⏳'
                | '❯'
                | '≡'
                | '✎'
                | '$'
                | '⌕'
                | '↓'
                | '…'
                | '⇄'
                | '?'
                | '✓'
                | '✗'
                | '–'
        )
    {
        lo += 1;
        while lo < chars.len() && chars[lo] == ' ' {
            lo += 1;
        }
        // A second marker, e.g. the outcome bullet after the collapse arrow.
        if lo < chars.len()
            && matches!(chars[lo], '•' | '✓' | '✗')
            && chars.get(lo + 1) == Some(&' ')
        {
            lo += 2;
        }
    }
    let mut hi = chars.len();
    while hi > lo && chars[hi - 1] == ' ' {
        hi -= 1;
    }
    // A trailing toggle glyph ("  ›", "  ▾") is chrome, not content.
    if hi >= lo + 3 && matches!(chars[hi - 1], '›' | '▾') && chars[hi - 2] == ' ' {
        hi -= 1;
        while hi > lo && chars[hi - 1] == ' ' {
            hi -= 1;
        }
    }
    (lo, hi)
}

pub fn word_bounds(line: &str, col: usize) -> (usize, usize) {
    let chars: Vec<char> = line.chars().collect();
    if chars.is_empty() {
        return (0, 0);
    }
    let col = col.min(chars.len() - 1);
    let is_word = |c: char| c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | '/' | ':' | '~');
    let target = is_word(chars[col]);
    let mut s = col;
    while s > 0 && is_word(chars[s - 1]) == target {
        s -= 1;
    }
    let mut e = col + 1;
    while e < chars.len() && is_word(chars[e]) == target {
        e += 1;
    }
    (s, e)
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod hierarchy_tests;

#[cfg(test)]
mod selection_tests;
