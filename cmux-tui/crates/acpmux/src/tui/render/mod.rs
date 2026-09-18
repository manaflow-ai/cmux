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

mod composer;
mod dialogs;
mod sidebar;
mod status;
mod transcript;

use composer::draw_composer;
use dialogs::{draw_add_host, draw_confirm, draw_directory, draw_help, draw_new_session, draw_permission, draw_picker};
use sidebar::draw_sidebar;
use status::draw_status;
use transcript::draw_transcript;

pub const SIDEBAR_WIDTH: u16 = 32;
/// Columns before the composer text: the `❯ ` prompt, matching Claude Code.
pub const COMPOSER_INDENT: u16 = 2;
/// Columns always left for the transcript, as cmux leaves for panes.
pub const MIN_MAIN_WIDTH: u16 = 40;

/// One rendered transcript row with the absolute index it belongs to, so
/// selection and scrolling stay stable while text streams in.
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
    if let Some(h) = dirs::home_dir() {
        if let Ok(rest) = std::path::Path::new(p).strip_prefix(&h) {
            return format!("~/{}", rest.display());
        }
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
    put(buf, x0, y0, "┌");
    put(buf, x1, y0, "┐");
    put(buf, x0, y1, "└");
    put(buf, x1, y1, "┘");
}

pub fn centered(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width.saturating_sub(2)).max(10);
    let h = h.min(area.height.saturating_sub(2)).max(3);
    Rect { x: area.x + (area.width - w) / 2, y: area.y + (area.height.saturating_sub(h)) / 3, width: w, height: h }
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
            out.push(Row { line: Line::from(vec![Span::raw(p), Span::styled(std::mem::take(line), style)]), text, item, toggle: None });
            *first = false;
        };
        for word in raw.split(' ') {
            let candidate = if line.is_empty() { word.width() } else { line.width() + 1 + word.width() };
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
    out.push(Row { line: Line::from(Span::styled(text.to_owned(), style)), text: text.to_owned(), item, toggle: None });
}

/// Lifecycle chatter (process stopped, resumed, renamed, model set…) is
/// hidden unless `show_system`; real failures always show.
pub fn is_system_noise(item: &Item) -> bool {
    match item {
        Item::Status { text } => !(text.starts_with("agent exited unexpectedly") || text.starts_with("resume failed")),
        Item::Stderr { .. } => true,
        Item::Error { text } => text == "agent process closed",
        _ => false,
    }
}

/// Render a transcript into rows at `width`. Every row starts after a
/// two-column gutter that holds the role or state marker, so text lines
/// up down the page. The transcript is a hierarchy of collapsibles: a
/// turn (your message plus the agent's work until your next one), runs of
/// consecutive tool calls, and single tool calls or thoughts. `toggled`
/// holds the ones flipped from their default (turns and groups open,
/// details closed); the thought being streamed is always open.
pub fn transcript_rows(t: &Transcript, width: usize, show_thoughts: bool, show_system: bool, toggled: &std::collections::HashSet<Toggle>, c: &Chrome) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    let w = width.saturating_sub(GUTTER.len());
    let running = t.status == "running";
    let last = t.items.len().saturating_sub(1);
    let is_open = |tg: Toggle, default_open: bool| default_open ^ toggled.contains(&tg);
    let group = |it: &Item| matches!(it, Item::Tool { .. } | Item::Permission { .. });
    // Visible items: lifecycle noise and silent turn ends never draw.
    let vis: Vec<usize> = (0..t.items.len())
        .filter(|&i| {
            let it = &t.items[i];
            (show_system || !is_system_noise(it)) && !matches!(it, Item::TurnEnd { stop } if stop == "end_turn")
        })
        .collect();
    // Codex spacing: one plain blank row before every block. The user block
    // also carries a tinted blank row inside its band above and below.
    let after_user_block = false;
    let spacer = |rows: &mut Vec<Row>, i: usize, _after_user_block: bool| {
        if !rows.is_empty() {
            plain("", Style::default(), i, rows);
        }
    };
    // A turn's final reply after tool calls or thinking gets a dim rule
    // above it, like Codex's "worked for" separator.
    let is_final_reply = |i: usize| -> bool {
        let mut worked = false;
        let mut j = i;
        while j > 0 {
            j -= 1;
            match &t.items[j] {
                Item::User { .. } => break,
                Item::Tool { .. } | Item::Thought { .. } | Item::Plan { .. } => worked = true,
                _ => {}
            }
        }
        if !worked {
            return false;
        }
        t.items[i + 1..].iter().take_while(|x| !matches!(x, Item::User { .. })).all(|x| !matches!(x, Item::Tool { .. } | Item::Thought { .. } | Item::Plan { .. } | Item::Assistant { .. }))
    };
    // One tool or permission row (plus open details) at `indent`.
    let tool_rows = |rows: &mut Vec<Row>, i: usize, indent: &str| {
        let iw = width.saturating_sub(indent.len());
        match &t.items[i] {
            Item::Tool { title, kind, status, detail, .. } => {
                let (glyph, color) = match status.as_str() {
                    "completed" => ("✓", c.ok_fg),
                    "failed" => ("✗", c.error_fg),
                    "in_progress" => ("…", c.warn_fg),
                    _ => ("·", c.warn_fg),
                };
                let open = !detail.is_empty() && is_open(Toggle::Item(i), false);
                let arrow = if detail.is_empty() { " " } else if open { "▾" } else { "▸" };
                let title_shown = truncate(title, iw.saturating_sub(kind.len() + 8));
                let snippet = if !open && !detail.is_empty() { format!("  {}", truncate(detail.lines().next().unwrap_or("").trim(), iw.saturating_sub(title_shown.width() + kind.len() + 12))) } else { String::new() };
                let text = format!("{}{arrow} {glyph} {title_shown}  {kind}{snippet}", &indent[GUTTER.len().min(indent.len())..]);
                rows.push(Row {
                    line: Line::from(vec![
                        Span::raw(indent[GUTTER.len().min(indent.len())..].to_owned()),
                        Span::styled(format!("{arrow} "), c.dim()),
                        Span::styled(format!("{glyph} "), Style::default().fg(color)),
                        Span::styled(title_shown, Style::default().fg(c.tool_fg)),
                        Span::styled(format!("  {kind}"), c.dim()),
                        Span::styled(snippet, c.dim()),
                    ]),
                    text,
                    item: i,
                    toggle: if detail.is_empty() { None } else { Some(Toggle::Item(i)) },
                });
                if open {
                    wrap(detail, iw, c.dim(), indent, i, rows);
                }
            }
            Item::Permission { title, decided, .. } => {
                let text = match decided {
                    Some(d) => format!("{indent}permission: {title} → {d}"),
                    None => format!("{indent}permission needed: {title}"),
                };
                plain(&text, Style::default().fg(c.attention_fg), i, rows);
            }
            _ => {}
        }
    };

    let mut k = 0usize;
    let mut turn_open = true;
    while k < vis.len() {
        let i = vis[k];
        let item = &t.items[i];
        match item {
            Item::User { text, steer, queued } => {
                k += 1;
                let open = is_open(Toggle::Turn(i), true);
                turn_open = open;
                spacer(&mut rows, i, false);
                // Codex's user block: a tinted band with a blank row above and
                // below and `› ` before the text.
                let bg = Style::default().bg(c.user_bg);
                let style = if *queued { c.dim().bg(c.user_bg) } else { bg.fg(c.user_fg) };
                let marker = if !open { "▸ " } else if *steer { "» " } else if *queued { "⏳" } else { "› " };
                let start = rows.len();
                plain("", bg, i, &mut rows);
                if open {
                    wrap_marked(text, w, style, marker, bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD), i, &mut rows);
                    if *queued {
                        plain(&format!("{GUTTER}queued · sends when the running turn ends · Ctrl-x cancels it"), c.dim().bg(c.user_bg), i, &mut rows);
                    }
                } else {
                    // Collapsed: first line plus what the turn holds.
                    let next_user = t.items[i + 1..].iter().position(|x| matches!(x, Item::User { .. })).map(|p| i + 1 + p).unwrap_or(t.items.len());
                    let tools = t.items[i + 1..next_user].iter().filter(|x| matches!(x, Item::Tool { .. })).count();
                    let replies = t.items[i + 1..next_user].iter().filter(|x| matches!(x, Item::Assistant { .. })).count();
                    let mut parts = Vec::new();
                    if tools > 0 {
                        parts.push(format!("{tools} tool call{}", if tools == 1 { "" } else { "s" }));
                    }
                    if replies > 0 {
                        parts.push(format!("{replies} repl{}", if replies == 1 { "y" } else { "ies" }));
                    }
                    let summary = if parts.is_empty() { String::new() } else { format!("  · {}", parts.join(" · ")) };
                    let first = text.lines().next().unwrap_or("").trim();
                    let shown = truncate(first, w.saturating_sub(summary.width() + 4));
                    let row_text = format!("{marker}{shown}{summary}");
                    rows.push(Row {
                        line: Line::from(vec![Span::styled(marker.to_owned(), bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD)), Span::styled(shown, style), Span::styled(summary, c.dim().bg(c.user_bg))]),
                        text: row_text,
                        item: i,
                        toggle: None,
                    });
                }
                plain("", bg, i, &mut rows);
                tint_rows(&mut rows[start..], width, c.user_bg, Some(Toggle::Turn(i)));
                let _ = after_user_block;
                continue;
            }
            it if group(it) => {
                let start_k = k;
                while k < vis.len() && group(&t.items[vis[k]]) {
                    k += 1;
                }
                if !turn_open {
                    continue;
                }
                let members = &vis[start_k..k];
                spacer(&mut rows, i, after_user_block);
                let tools: Vec<usize> = members.iter().copied().filter(|&m| matches!(t.items[m], Item::Tool { .. })).collect();
                if tools.len() >= 2 {
                    let g = Toggle::Group(tools[0]);
                    let open = is_open(g, true);
                    let names: Vec<String> = tools.iter().take(6).map(|&m| match &t.items[m] { Item::Tool { title, .. } => title.split_whitespace().next().unwrap_or("tool").to_owned(), _ => String::new() }).collect();
                    let done = tools.iter().filter(|&&m| matches!(&t.items[m], Item::Tool { status, .. } if status == "completed")).count();
                    let failed = tools.iter().filter(|&&m| matches!(&t.items[m], Item::Tool { status, .. } if status == "failed")).count();
                    let state = if failed > 0 { format!(" · {failed} failed") } else if done < tools.len() { format!(" · {done}/{} done", tools.len()) } else { String::new() };
                    let text = format!("{} {} tool calls · {}{state}", if open { "▾" } else { "▸" }, tools.len(), names.join(", "));
                    rows.push(Row {
                        line: Line::from(vec![Span::styled(format!("{} ", if open { "▾" } else { "▸" }), c.dim()), Span::styled(format!("{} tool calls", tools.len()), Style::default().fg(c.tool_fg)), Span::styled(format!(" · {}{state}", names.join(", ")), c.dim())]),
                        text,
                        item: tools[0],
                        toggle: Some(g),
                    });
                    if open {
                        for &m in members {
                            tool_rows(&mut rows, m, "    ");
                        }
                    }
                } else {
                    for &m in members {
                        tool_rows(&mut rows, m, GUTTER);
                    }
                }
            }
            _ => {
                k += 1;
                if !turn_open {
                    continue;
                }
                spacer(&mut rows, i, after_user_block);
                match item {
                    Item::Assistant { text } => {
                        if is_final_reply(i) {
                            let rule = "─".repeat(width.saturating_sub(GUTTER.len()));
                            rows.push(Row { line: Line::from(vec![Span::raw(GUTTER), Span::styled(rule.clone(), c.dim())]), text: format!("{GUTTER}{rule}"), item: i, toggle: None });
                            plain("", Style::default(), i, &mut rows);
                        }
                        let start = rows.len();
                        super::markdown::render(text, width, GUTTER, Style::default(), c, i, &mut rows);
                        // Codex's `• ` bullet on the first line of an agent message.
                        if let Some(first) = rows.get_mut(start) {
                            let mut spans: Vec<Span<'static>> = first.line.spans.clone();
                            if spans.first().map(|s| s.content.as_ref() == GUTTER).unwrap_or(false) {
                                spans[0] = Span::styled("• ".to_owned(), c.dim());
                                first.line = Line::from(spans);
                                first.text = format!("• {}", &first.text[GUTTER.len().min(first.text.len())..]);
                            }
                        }
                    }
                    Item::Thought { text } => {
                        let live = running && i == last;
                        let open = live || is_open(Toggle::Item(i), show_thoughts);
                        let n = text.chars().count();
                        let first_line = text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
                        if open {
                            header_row(&format!("▾ thinking · {n} chars"), c.thought_fg, i, Toggle::Item(i), &mut rows);
                            wrap(text, w, Style::default().fg(c.thought_fg).add_modifier(Modifier::ITALIC), GUTTER, i, &mut rows);
                        } else {
                            let summary = truncate(first_line, w.saturating_sub(24));
                            header_row(&format!("▸ thinking · {n} chars  {summary}"), c.thought_fg, i, Toggle::Item(i), &mut rows);
                        }
                    }
                    Item::Plan { entries } => {
                        plain(&format!("{GUTTER}plan"), Style::default().fg(c.attention_fg), i, &mut rows);
                        for (s, content) in entries {
                            let glyph = match s.as_str() {
                                "completed" => "✓",
                                "in_progress" => "▶",
                                _ => "○",
                            };
                            wrap(content, w.saturating_sub(2), Style::default().fg(c.attention_fg), &format!("{GUTTER}{glyph} "), i, &mut rows);
                        }
                    }
                    Item::Status { text } => plain(&format!("{GUTTER}-- {text}"), c.dim(), i, &mut rows),
                    Item::TurnEnd { stop } => plain(&format!("{GUTTER}-- {stop}"), c.dim(), i, &mut rows),
                    Item::Error { text } => wrap_marked(text, w, Style::default().fg(c.error_fg).add_modifier(Modifier::BOLD), "✗ ", Style::default().fg(c.error_fg), i, &mut rows),
                    Item::Stderr { text } => plain(&format!("{GUTTER}stderr: {}", truncate(text, w.saturating_sub(8))), c.dim(), i, &mut rows),
                    _ => {}
                }
            }
        }
    }
    if running {
        let streaming = matches!(t.items.last(), Some(Item::Assistant { .. }) | Some(Item::Tool { .. }) | Some(Item::Thought { .. }));
        if !streaming {
            plain("", Style::default(), usize::MAX, &mut rows);
            let mut spans = vec![Span::raw(GUTTER)];
            spans.extend(super::shimmer::spans("Working…", c.shimmer_base, c.shimmer_bright));
            let note = t.note.as_deref().map(|n| format!("  {n}")).unwrap_or_default();
            if !note.is_empty() {
                spans.push(Span::styled(note.clone(), c.dim()));
            }
            rows.push(Row { line: Line::from(spans), text: format!("{GUTTER}Working…{note}"), item: usize::MAX, toggle: None });
        }
    }
    rows
}

/// Give rows a full-width background and a shared toggle (the user block).
fn tint_rows(rows: &mut [Row], width: usize, bg: ratatui::style::Color, toggle: Option<Toggle>) {
    for r in rows {
        let mut spans: Vec<Span<'static>> = r.line.spans.iter().map(|s| Span::styled(s.content.to_string(), s.style.bg(bg))).collect();
        let used: usize = spans.iter().map(|s| s.content.width()).sum();
        if used < width {
            spans.push(Span::styled(" ".repeat(width - used), Style::default().bg(bg)));
        }
        r.line = Line::from(spans);
        r.toggle = toggle;
    }
}

/// The left gutter every transcript row shares.
pub const GUTTER: &str = "  ";

/// A one-line collapsible header in the gutter style.
fn header_row(text: &str, color: ratatui::style::Color, item: usize, toggle: Toggle, out: &mut Vec<Row>) {
    let text = text.to_owned();
    out.push(Row { line: Line::from(Span::styled(text.clone(), Style::default().fg(color))), text, item, toggle: Some(toggle) });
}

/// Wrap with a two-column marker in the gutter on the first row.
fn wrap_marked(text: &str, width: usize, style: Style, marker: &str, marker_style: Style, item: usize, out: &mut Vec<Row>) {
    let start = out.len();
    wrap(text, width, style, GUTTER, item, out);
    if let Some(first) = out.get_mut(start) {
        let mut spans: Vec<Span<'static>> = first.line.spans.clone();
        if let Some(s) = spans.first_mut() {
            *s = Span::styled(format!("{marker:<2}"), marker_style);
        }
        first.line = Line::from(spans);
        first.text = format!("{marker:<2}{}", &first.text[GUTTER.len().min(first.text.len())..]);
    }
}

// ------------------------------------------------------------- frames

pub fn draw(f: &mut ratatui::Frame, app: &mut App) {
    let area = f.area();
    let c = app.chrome;
    if area.height < 4 || area.width < 20 {
        return;
    }
    let status_y = area.y + area.height - 1;
    let body = Rect { x: area.x, y: area.y, width: area.width, height: area.height - 1 };
    let sidebar_w = if app.sidebar_hidden { 0 } else { app.sidebar_width.unwrap_or(SIDEBAR_WIDTH).min(body.width.saturating_sub(MIN_MAIN_WIDTH)).max(16) };
    let sidebar = Rect { x: body.x, y: body.y, width: sidebar_w, height: body.height };
    let main = Rect { x: body.x + sidebar_w, y: body.y, width: body.width - sidebar_w, height: body.height };
    let editor_w = main.width.saturating_sub(COMPOSER_INDENT + 1) as usize;
    // Top rule, the text (1-6 rows), bottom rule, controls row.
    let max_rows = app.composer_max_rows.min(main.height / 2).max(1);
    let input_h = (app.editor().rows_at(editor_w).max(1) as u16).min(max_rows) + 3;
    let composer = Rect { x: main.x, y: main.y + main.height - input_h, width: main.width, height: input_h };
    let transcript = Rect { x: main.x, y: main.y, width: main.width, height: main.height - input_h };
    app.areas.sidebar = sidebar;
    app.areas.sidebar_rule = if sidebar_w == 0 { Rect::default() } else { Rect { x: sidebar.x + sidebar.width - 1, y: sidebar.y, width: 1, height: sidebar.height } };
    app.areas.transcript = transcript;
    app.areas.composer = composer;
    app.areas.status = Rect { x: area.x, y: status_y, width: area.width, height: 1 };

    app.buttons.clear();
    app.perm_rows.clear();
    app.link_cells.clear();
    app.cursor_pos = None;
    app.dialog_rect = Rect::default();
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
    if matches!(app.overlay, Overlay::None) {
        let pending = app
            .selected_id()
            .and_then(|id| app.transcripts.get(&id))
            .and_then(|t| match t.pending_permission() {
                Some(Item::Permission { title, options, .. }) => Some((title.clone(), options.clone())),
                _ => None,
            });
        if let Some((title, options)) = pending {
            draw_permission(f, area, &title, &options, app);
        }
    }
    let hover = app.hover;
    let kind: u8 = match &app.overlay { Overlay::None => 0, Overlay::Help => 1, Overlay::NewSession(_) => 2, Overlay::Picker(_) => 3, Overlay::Confirm { .. } => 4, Overlay::AddHost { .. } => 5, Overlay::Directory { .. } => 6, Overlay::Menu(_) => 7 };
    if kind != app.last_overlay {
        app.dialog = dialog::DialogState::default();
        app.last_overlay = kind;
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
    if let Some((text, _)) = &app.toast {
        let label = format!(" {text} ");
        let w = (label.width() as u16).min(transcript.width);
        let r = Rect { x: transcript.x + transcript.width.saturating_sub(w + 1), y: transcript.y + transcript.height.saturating_sub(2), width: w, height: 1 };
        f.buffer_mut().set_stringn(r.x, r.y, &label, w as usize, c.toast());
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
    /// Columns [c0, c1) selected on row `row`, or None.
    pub fn cols_on_row(&self, row: usize, row_width: usize) -> Option<(usize, usize)> {
        let ((r0, c0), (r1, c1)) = self.range();
        if row < r0 || row > r1 {
            return None;
        }
        let start = if row == r0 { c0 } else { 0 };
        let end = if row == r1 { c1.min(row_width) } else { row_width };
        if end > start { Some((start, end)) } else if row != r0 && row != r1 { Some((0, 0)) } else { None }
    }
    pub fn text(&self, rows: &[String]) -> String {
        let ((r0, c0), (r1, c1)) = self.range();
        let mut out = Vec::new();
        for r in r0..=r1.min(rows.len().saturating_sub(1)) {
            let line = &rows[r];
            let chars: Vec<char> = line.chars().collect();
            let s = if r == r0 { c0.min(chars.len()) } else { 0 };
            let e = if r == r1 { c1.min(chars.len()) } else { chars.len() };
            out.push(chars[s..e].iter().collect::<String>().trim_end().to_owned());
        }
        out.join("\n")
    }
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
mod tests {
    use super::*;

    #[test]
    fn selection_text_spans_rows() {
        let rows = vec!["hello world".to_owned(), "second line".to_owned(), "third".to_owned()];
        let s = Selection { session: "x".into(), anchor: (0, 6), head: (2, 3), mode: SelectMode::Cell };
        assert_eq!(s.text(&rows), "world\nsecond line\nthi");
        let back = Selection { session: "x".into(), anchor: (2, 3), head: (0, 6), mode: SelectMode::Cell };
        assert_eq!(back.text(&rows), s.text(&rows));
    }

    #[test]
    fn word_bounds_pick_a_token() {
        assert_eq!(word_bounds("run cargo-build now", 6), (4, 15));
        assert_eq!(word_bounds("a  b", 1), (1, 3));
    }

    #[test]
    fn wrap_keeps_prefix_on_first_row_only() {
        let mut rows = Vec::new();
        wrap("one two three four", 9, Style::default(), "> ", 0, &mut rows);
        assert_eq!(rows.len(), 3);
        assert!(rows[0].text.starts_with("> one"));
        assert!(rows[1].text.starts_with("  "));
    }
}

#[cfg(test)]
mod hierarchy_tests {
    use super::*;
    use crate::transcript::Item;

    fn sample() -> Transcript {
        let mut t = Transcript::default();
        t.items = vec![
            Item::User { text: "Use your Bash tool twice".into(), steer: false, queued: false },
            Item::Thought { text: "I will run hostname then date.".into() },
            Item::Tool { id: "1".into(), title: "hostname".into(), kind: "execute".into(), status: "completed".into(), detail: "mac.local".into() },
            Item::Permission { id: "p".into(), title: "date".into(), options: vec![], decided: Some("allow_once".into()) },
            Item::Tool { id: "2".into(), title: "date".into(), kind: "execute".into(), status: "completed".into(), detail: "Thu Sep 17".into() },
            Item::Assistant { text: "done".into() },
            Item::TurnEnd { stop: "end_turn".into() },
            Item::User { text: "again".into(), steer: false, queued: false },
            Item::Assistant { text: "ok".into() },
        ];
        t.status = "ready".into();
        t
    }

    #[test]
    fn hierarchy_renders_and_collapses() {
        let c = Chrome::dark();
        let t = sample();
        let none = std::collections::HashSet::new();
        let rows = transcript_rows(&t, 80, false, false, &none, &c);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.starts_with("› Use your Bash")), "{text:?}");
        assert!(text.iter().any(|l| l.starts_with("▾ 2 tool calls")), "{text:?}");
        assert!(text.iter().any(|l| l.contains("permission: date")), "{text:?}");
        // Collapse the group and the first turn.
        let mut flipped = std::collections::HashSet::new();
        flipped.insert(Toggle::Group(2));
        let rows = transcript_rows(&t, 80, false, false, &flipped, &c);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.starts_with("▸ 2 tool calls")), "{text:?}");
        assert!(!text.iter().any(|l| l.contains("permission: date")), "{text:?}");
        flipped.insert(Toggle::Turn(0));
        let rows = transcript_rows(&t, 80, false, false, &flipped, &c);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.starts_with("▸ Use your Bash tool twice") && l.contains("2 tool calls")), "{text:?}");
        assert!(!text.iter().any(|l| l == &"  done"), "{text:?}");
        assert!(text.iter().any(|l| l.starts_with("› again")), "{text:?}");
    }
}
