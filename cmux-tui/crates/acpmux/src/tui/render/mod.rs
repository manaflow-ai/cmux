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
use dialogs::{draw_add_host, draw_confirm, draw_directory, draw_help, draw_new_session, draw_permission_card, draw_picker};
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
    put(buf, x0, y0, "╭");
    put(buf, x1, y0, "╮");
    put(buf, x0, y1, "╰");
    put(buf, x1, y1, "╯");
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
/// up down the page. The transcript is a hierarchy of collapsibles: the
/// work of a turn (everything between your message and the turn's final
/// reply; the message and the reply themselves never hide), runs of
/// consecutive tool calls, and single tool calls or thoughts. `toggled`
/// holds the ones flipped from their default (work and groups open,
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
            if let Item::Permission { title, decided: Some(d), .. } = it {
                // "✓ Allowed  Write x" right under "✎ Write x" repeats the row.
                let echoes_tool = i > 0 && matches!(&t.items[i - 1], Item::Tool { title: tt, .. } if tt == title);
                if d.starts_with("allow") && echoes_tool {
                    return false;
                }
            }
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
    // One tool or permission row (plus open details) at `indent`.
    let tool_rows = |rows: &mut Vec<Row>, i: usize, indent: &str| {
        let iw = width.saturating_sub(indent.len());
        match &t.items[i] {
            Item::Tool { title, kind, status, detail, .. } => {
                // Codex app: one muted line per activity, an icon for the
                // kind, paths shortened, red only when it failed. Details
                // open on click.
                let glyph = match kind.as_str() {
                    "read" => "≡",
                    "edit" => "✎",
                    "execute" => "$",
                    "search" => "⌕",
                    "fetch" => "↓",
                    "think" => "…",
                    "delete" | "move" => "⇄",
                    _ => "•",
                };
                let (gstyle, tstyle) = match status.as_str() {
                    "failed" => (Style::default().fg(c.error_fg), Style::default().fg(c.error_fg)),
                    "in_progress" | "pending" => (c.muted(), c.muted()),
                    _ => (c.dim(), c.muted()),
                };
                let open = !detail.is_empty() && is_open(Toggle::Item(i), false);
                // A diff names its files better than the harness's generic
                // "Editing files": "Edited calc.py".
                let files: Vec<String> = detail.lines().filter_map(|l| l.strip_prefix("@@ ")).map(|p| p.rsplit('/').next().unwrap_or(p).to_owned()).collect();
                let shown = if !files.is_empty() && (kind == "edit" || title.to_lowercase().contains("edit")) {
                    format!("{} {}", if status == "completed" { "Edited" } else { "Editing" }, files.join(", "))
                } else {
                    shorten_tool_title(title)
                };
                let title_shown = truncate(&shown, iw.saturating_sub(4));
                let text = format!("{indent}{glyph} {title_shown}");
                let mut spans = vec![Span::raw(indent.to_owned()), Span::styled(format!("{glyph} "), gstyle), Span::styled(title_shown, tstyle)];
                let counts = crate::transcript::diff_counts(detail);
                if let Some((plus, minus)) = counts {
                    spans.push(Span::styled(format!("  +{plus}"), Style::default().fg(c.diff_add_fg)));
                    spans.push(Span::styled(format!(" -{minus}"), Style::default().fg(c.diff_del_fg)));
                }
                if !detail.is_empty() {
                    spans.push(Span::styled(if open { "  ▾" } else { "  ›" }, c.dim()));
                }
                rows.push(Row {
                    line: Line::from(spans),
                    text,
                    item: i,
                    toggle: if detail.is_empty() { None } else { Some(Toggle::Item(i)) },
                });
                if open && counts.is_some() {
                    // Diff lines keep their prefix colors and are not wrapped.
                    for l in detail.lines() {
                        let style = match l.chars().next() {
                            Some('+') => Style::default().fg(c.diff_add_fg),
                            Some('-') => Style::default().fg(c.diff_del_fg),
                            Some('@') => c.muted(),
                            _ => c.dim(),
                        };
                        let text = format!("{indent}  {}", truncate(l, iw.saturating_sub(3)));
                        rows.push(Row { line: Line::from(Span::styled(text.clone(), style)), text, item: i, toggle: None });
                    }
                } else if open {
                    wrap(detail, iw.saturating_sub(2), c.dim(), &format!("{indent}  "), i, rows);
                }
            }
            Item::Permission { title, decided, .. } => {
                // Codex app wording: the request while it waits, the answer after.
                let shown = shorten_tool_title(title);
                let (text, style) = match decided.as_deref() {
                    Some(d) if d.starts_with("allow") => (format!("{indent}✓ Allowed  {shown}"), c.dim()),
                    Some(d) if d.starts_with("reject") => (format!("{indent}✗ Rejected  {shown}"), c.dim()),
                    Some(_) => (format!("{indent}– Cancelled  {shown}"), c.dim()),
                    None => (format!("{indent}? Needs permission  {shown}"), Style::default().fg(c.attention_fg)),
                };
                plain(&text, style, i, rows);
            }
            _ => {}
        }
    };

    // Queued messages wait at the bottom, under the running turn, until
    // their own turn starts (Codex app).
    let queued: Vec<usize> = vis.iter().copied().filter(|&i| matches!(t.items[i], Item::User { queued: true, .. })).collect();
    let mut k = 0usize;
    let mut turn_open = true;
    // When a turn's work is collapsed, rendering resumes at this item (the
    // turn's final reply, or the next user message).
    let mut reopen_at: Option<usize> = None;
    while k < vis.len() {
        let i = vis[k];
        if reopen_at == Some(i) {
            turn_open = true;
            reopen_at = None;
        }
        let item = &t.items[i];
        if matches!(item, Item::User { queued: true, .. }) {
            k += 1;
            continue;
        }
        match item {
            Item::User { text, steer, queued } => {
                k += 1;
                turn_open = true;
                reopen_at = None;
                spacer(&mut rows, i, false);
                // Codex app: a centered muted timestamp before each message.
                if let Some(at) = t.user_at.get(&i) {
                    let label = when_label(*at);
                    let pad = width.saturating_sub(label.width()) / 2;
                    let text = format!("{}{label}", " ".repeat(pad));
                    rows.push(Row { line: Line::from(Span::styled(text.clone(), c.dim())), text, item: i, toggle: None });
                    plain("", Style::default(), i, &mut rows);
                }
                // Codex app: your message is a tinted bubble on the right,
                // at most seven tenths of the width, with a padded row above
                // and below. `❯` marks it; the foreground is explicit so a
                // light terminal reads it too.
                let bg = Style::default().bg(c.user_bg);
                let style = if *queued { c.dim().bg(c.user_bg) } else { bg.fg(c.status_fg) };
                let marker = if *steer { "» " } else if *queued { "⋯ " } else { "❯ " };
                let marker_style = bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD);
                let bubble_w = if width < 50 { width } else { (width * 7 / 10).max(40).min(width) };
                let inner_w = bubble_w.saturating_sub(4);
                let left = " ".repeat(width.saturating_sub(bubble_w));
                let mut body: Vec<Row> = Vec::new();
                wrap(text, inner_w, style, "", i, &mut body);
                if *queued {
                    plain("queued · sends when the running turn ends · Ctrl-x cancels it", c.dim().bg(c.user_bg), i, &mut body);
                }
                let bubble_row = |content: Vec<Span<'static>>, used: usize, text: String| -> Row {
                    let mut spans = vec![Span::raw(left.clone()), Span::styled(" ".to_owned(), bg)];
                    spans.extend(content);
                    spans.push(Span::styled(" ".repeat(bubble_w.saturating_sub(2 + used)), bg));
                    Row { line: Line::from(spans), text, item: i, toggle: None }
                };
                rows.push(bubble_row(vec![], 0, String::new()));
                for (n, r) in body.into_iter().enumerate() {
                    let m = if n == 0 { marker } else { "  " };
                    let content = r.text.clone();
                    let used = 2 + content.width();
                    let spans = vec![Span::styled(m.to_owned(), if n == 0 { marker_style } else { bg }), Span::styled(content.clone(), if r.line.spans.len() > 1 { r.line.spans[1].style.bg(c.user_bg) } else { style })];
                    rows.push(bubble_row(spans, used, format!("{left} {m}{content}")));
                }
                rows.push(bubble_row(vec![], 0, String::new()));
                let _ = after_user_block;
                // The turn's work: everything visible between this message
                // and the final reply. Two or more blocks get a handle row
                // that collapses them all; one block collapses on its own.
                let next_user = t.items[i + 1..].iter().position(|x| matches!(x, Item::User { queued: false, .. })).map(|p| i + 1 + p).unwrap_or(t.items.len());
                let turn_live = running && next_user == t.items.len();
                // While the turn runs there is no final reply yet: every block
                // is work and the handle reads "Working for …".
                let final_reply = if turn_live { None } else { (i + 1..next_user).rev().find(|&j| matches!(t.items[j], Item::Assistant { .. })) };
                let work_end = final_reply.unwrap_or(next_user);
                let work: Vec<usize> = vis.iter().copied().filter(|&j| j > i && j < work_end).collect();
                let mut blocks = 0usize;
                let mut tools = 0usize;
                let mut thoughts = 0usize;
                let mut replies = 0usize;
                let mut prev_group = false;
                for &j in &work {
                    match &t.items[j] {
                        Item::Tool { .. } => {
                            tools += 1;
                            if !prev_group {
                                blocks += 1;
                            }
                            prev_group = true;
                        }
                        Item::Permission { .. } => {
                            if !prev_group {
                                blocks += 1;
                            }
                            prev_group = true;
                        }
                        Item::Thought { .. } => { thoughts += 1; blocks += 1; prev_group = false; }
                        Item::Assistant { .. } => { replies += 1; blocks += 1; prev_group = false; }
                        _ => { blocks += 1; prev_group = false; }
                    }
                }
                if blocks >= 2 {
                    let open = is_open(Toggle::Turn(i), true);
                    let _ = (tools, thoughts, replies);
                    // Codex app: "Worked for 1m 7s ›" (collapsed) or "Worked for 1m 7s ▾".
                    let span = t.turn_span(i);
                    let label = match span {
                        Some((start, Some(end))) => format!("Worked for {}", duration_label(end.saturating_sub(start))),
                        Some((start, None)) if t.turn_times.last().map(|x| x.0 == i).unwrap_or(false) && t.status != "ready" && t.status != "idle" => format!("Working for {}", duration_label(now_ms().saturating_sub(start))),
                        _ => "Worked".to_owned(),
                    };
                    spacer(&mut rows, i, false);
                    let text = format!("{label}  {}", if open { "▾" } else { "›" });
                    rows.push(Row { line: Line::from(vec![Span::styled(label, c.muted()), Span::styled(format!("  {}", if open { "▾" } else { "›" }), c.dim())]), text, item: i, toggle: Some(Toggle::Turn(i)) });
                    // Codex app: a hairline under the handle.
                    rows.push(Row { line: Line::from(Span::styled("─".repeat(width), Style::default().fg(c.composer_border_fg))), text: String::new(), item: i, toggle: None });
                    // "Edited 2 files  +21 -2": the turn's file edits, summed, visible even when folded.
                    let mut files: Vec<String> = Vec::new();
                    let (mut plus, mut minus) = (0usize, 0usize);
                    for &j in &work {
                        if let Item::Tool { detail, .. } = &t.items[j] {
                            if let Some((p, m)) = crate::transcript::diff_counts(detail) {
                                plus += p;
                                minus += m;
                                for f in detail.lines().filter_map(|l| l.strip_prefix("@@ ")).map(|p| p.rsplit('/').next().unwrap_or(p).to_owned()) {
                                    if !files.contains(&f) {
                                        files.push(f);
                                    }
                                }
                            }
                        }
                    }
                    if !files.is_empty() {
                        let label = format!("{GUTTER}✎ Edited {} file{}  ", files.len(), if files.len() == 1 { "" } else { "s" });
                        let names = truncate(&files.join(", "), w.saturating_sub(label.width() + 14));
                        let text = format!("{label}{names}  +{plus} -{minus}");
                        rows.push(Row {
                            line: Line::from(vec![Span::styled(label, c.muted()), Span::styled(names, c.dim()), Span::styled(format!("  +{plus}"), Style::default().fg(c.diff_add_fg)), Span::styled(format!(" -{minus}"), Style::default().fg(c.diff_del_fg))]),
                            text,
                            item: i,
                            toggle: None,
                        });
                    }
                    if !open {
                        turn_open = false;
                        reopen_at = Some(work_end);
                    }
                }
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
                    let text = format!("{} steps · {}{state}  {}", tools.len(), names.join(", "), if open { "▾" } else { "›" });
                    rows.push(Row {
                        line: Line::from(vec![Span::styled(format!("{} steps", tools.len()), c.muted()), Span::styled(format!(" · {}{state}", names.join(", ")), c.dim()), Span::styled(format!("  {}", if open { "▾" } else { "›" }), c.dim())]),
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
                        super::markdown::render(text, width, GUTTER, Style::default(), c, i, &mut rows);
                    }
                    Item::Thought { text } => {
                        let live = running && i == last;
                        let open = live || is_open(Toggle::Item(i), show_thoughts);
                        let n = text.chars().count();
                        let first_line = text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
                        let _ = n;
                        let summary = first_line.trim_matches('*').trim();
                        if live {
                            // Codex app: one shimmering line with the latest
                            // sentence while it streams; a click opens the rest.
                            let latest = text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim().trim_matches('*').trim();
                            let mut spans = vec![Span::raw(GUTTER)];
                            spans.extend(super::shimmer::spans("Thinking", c.shimmer_base, c.shimmer_bright));
                            if !latest.is_empty() {
                                spans.push(Span::styled(format!("  {}", truncate(latest, w.saturating_sub(12))), c.dim().add_modifier(Modifier::ITALIC)));
                            }
                            rows.push(Row { line: Line::from(spans), text: format!("{GUTTER}Thinking  {latest}"), item: i, toggle: Some(Toggle::Item(i)) });
                            if is_open(Toggle::Item(i), false) {
                                wrap(text, w, c.dim().add_modifier(Modifier::ITALIC), GUTTER, i, &mut rows);
                            }
                        } else if open {
                            header_row(&format!("{GUTTER}Thought  ▾"), c.muted_fg, i, Toggle::Item(i), &mut rows);
                            wrap(text, w, c.dim().add_modifier(Modifier::ITALIC), GUTTER, i, &mut rows);
                        } else {
                            let shown = truncate(summary, w.saturating_sub(14));
                            let text_row = format!("{GUTTER}Thought  {shown}  ›");
                            rows.push(Row {
                                line: Line::from(vec![Span::raw(GUTTER), Span::styled("Thought  ", c.muted()), Span::styled(shown, c.dim().add_modifier(Modifier::ITALIC)), Span::styled("  ›", c.dim())]),
                                text: text_row,
                                item: i,
                                toggle: Some(Toggle::Item(i)),
                            });
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
                    Item::Error { text } => {
                        // Codex app: a rounded notice card with an icon.
                        let border = Style::default().fg(c.composer_border_fg);
                        let cw = width.max(12);
                        let inner = cw.saturating_sub(6);
                        let mut body: Vec<Row> = Vec::new();
                        wrap(text, inner, Style::default().fg(c.status_fg), "", i, &mut body);
                        rows.push(Row { line: Line::from(Span::styled(format!("╭{}╮", "─".repeat(cw - 2)), border)), text: String::new(), item: i, toggle: None });
                        for (n, r) in body.into_iter().enumerate() {
                            let content = r.text.clone();
                            let icon = if n == 0 { "✗ " } else { "  " };
                            let pad = inner.saturating_sub(content.width());
                            rows.push(Row {
                                line: Line::from(vec![Span::styled("│ ".to_owned(), border), Span::styled(icon.to_owned(), Style::default().fg(c.error_fg).add_modifier(Modifier::BOLD)), Span::styled(content.clone(), Style::default().fg(c.status_fg)), Span::raw(" ".repeat(pad)), Span::styled(" │".to_owned(), border)]),
                                text: format!("  {icon}{content}"),
                                item: i,
                                toggle: None,
                            });
                        }
                        rows.push(Row { line: Line::from(Span::styled(format!("╰{}╯", "─".repeat(cw - 2)), border)), text: String::new(), item: i, toggle: None });
                    }
                    Item::Stderr { text } => plain(&format!("{GUTTER}stderr: {}", truncate(text, w.saturating_sub(8))), c.dim(), i, &mut rows),
                    _ => {}
                }
            }
        }
    }
    for &i in &queued {
        if let Item::User { text, .. } = &t.items[i] {
            spacer(&mut rows, i, false);
            let bg = Style::default().bg(c.user_bg);
            let style = c.dim().bg(c.user_bg);
            let bubble_w = if width < 50 { width } else { (width * 7 / 10).max(40).min(width) };
            let inner_w = bubble_w.saturating_sub(4);
            let left = " ".repeat(width.saturating_sub(bubble_w));
            let mut body: Vec<Row> = Vec::new();
            wrap(text, inner_w, style, "", i, &mut body);
            plain("queued · sends when the running turn ends · Ctrl-x cancels it", c.dim().bg(c.user_bg), i, &mut body);
            let bubble_row = |content: Vec<Span<'static>>, used: usize, text: String| -> Row {
                let mut spans = vec![Span::raw(left.clone()), Span::styled(" ".to_owned(), bg)];
                spans.extend(content);
                spans.push(Span::styled(" ".repeat(bubble_w.saturating_sub(2 + used)), bg));
                Row { line: Line::from(spans), text, item: i, toggle: None }
            };
            rows.push(bubble_row(vec![], 0, String::new()));
            for (n, r) in body.into_iter().enumerate() {
                let m = if n == 0 { "⋯ " } else { "  " };
                let content = r.text.clone();
                let used = 2 + content.width();
                rows.push(bubble_row(vec![Span::styled(m.to_owned(), bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD)), Span::styled(content.clone(), style)], used, format!("{left} {m}{content}")));
            }
            rows.push(bubble_row(vec![], 0, String::new()));
        }
    }
    if running {
        let streaming = matches!(t.items.last(), Some(Item::Assistant { .. }) | Some(Item::Tool { .. }) | Some(Item::Thought { .. }));
        if !streaming {
            plain("", Style::default(), usize::MAX, &mut rows);
            // Codex app: "Working for 4s" that keeps counting.
            let label = match t.turn_times.last() {
                Some((_, start, None)) => format!("Working for {}", duration_label(now_ms().saturating_sub(*start))),
                _ => "Working…".to_owned(),
            };
            let mut spans = vec![Span::raw(GUTTER)];
            spans.extend(super::shimmer::spans(&label, c.shimmer_base, c.shimmer_bright));
            let note = t.note.as_deref().map(|n| format!("  {n}")).unwrap_or_default();
            if !note.is_empty() {
                spans.push(Span::styled(note.clone(), c.dim()));
            }
            rows.push(Row { line: Line::from(spans), text: format!("{GUTTER}{label}{note}"), item: usize::MAX, toggle: None });
        }
    }
    rows
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
    std::path::Path::new(trimmed).file_name().map(|f| f.to_string_lossy().into_owned()).filter(|p| !p.is_empty()).unwrap_or_else(|| shorten_path(cwd))
}

/// What a session is called in the sidebar and header: its title (the
/// first prompt) when its name was generated (`codex`, `codex-3`), else
/// the name the user gave it.
pub fn session_title(s: &Value) -> String {
    let name = s.get("name").and_then(Value::as_str).unwrap_or("?");
    let harness = s.get("harness").and_then(Value::as_str).unwrap_or("");
    let bare = name.rsplit('/').next().unwrap_or(name);
    let auto = !harness.is_empty()
        && (bare == harness || bare.strip_prefix(harness).and_then(|r| r.strip_prefix('-')).map(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit())).unwrap_or(false));
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
    joined.replacen("Read file ", "Read ", 1).replacen("Write file ", "Write ", 1).replacen("Edit file ", "Edit ", 1)
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
        Some((head, tail)) if tail.len() == 8 && tail.chars().all(|c| c.is_ascii_digit()) && !head.is_empty() => head.to_owned(),
        _ => model.to_owned(),
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
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
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
        let h12 = match h24 % 12 { 0 => 12, h => h };
        let clock = format!("{h12}:{m:02} {ampm}");
        let same_year = tm.tm_year == now_tm.tm_year;
        if same_year && tm.tm_yday == now_tm.tm_yday {
            return format!("Today {clock}");
        }
        if same_year && tm.tm_yday + 1 == now_tm.tm_yday {
            return format!("Yesterday {clock}");
        }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        let mon = months.get(tm.tm_mon as usize).copied().unwrap_or("?");
        return format!("{mon} {}, {clock}", tm.tm_mday);
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
fn header_row(text: &str, color: ratatui::style::Color, item: usize, toggle: Toggle, out: &mut Vec<Row>) {
    let text = text.to_owned();
    out.push(Row { line: Line::from(Span::styled(text.clone(), Style::default().fg(color))), text, item, toggle: Some(toggle) });
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
    let col_w = main.width.min(COLUMN_WIDTH);
    let col_x = main.x + (main.width - col_w) / 2;
    // The composer box: one column of margin, a border and a space each side.
    let editor_w = col_w.saturating_sub(6) as usize;
    // Top rule, the text (1-6 rows), bottom rule, controls row.
    let max_rows = app.composer_max_rows.min(main.height / 2).max(1);
    // Top rule, the text, bottom rule, controls row.
    let input_h = (app.editor().rows_at(editor_w).max(1) as u16).min(max_rows) + 3;
    let composer = Rect { x: col_x, y: main.y + main.height - input_h, width: col_w, height: input_h };
    // A pending permission docks as a card above the composer, Codex-app
    // style, instead of covering the conversation.
    let pending = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .and_then(|t| match t.pending_permission() {
            Some(Item::Permission { title, options, .. }) => Some((title.clone(), options.clone())),
            _ => None,
        });
    let card_h: u16 = if pending.is_some() && main.height > input_h + 8 { 4 } else { 0 };
    let card = Rect { x: col_x + 1, y: composer.y.saturating_sub(card_h), width: col_w.saturating_sub(2), height: card_h };
    let transcript = Rect { x: main.x, y: main.y, width: main.width, height: main.height - input_h - card_h };
    app.areas.column = Rect { x: col_x, y: transcript.y, width: col_w, height: transcript.height };
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
    if let (Some((title, options)), true) = (pending, card_h > 0) {
        draw_permission_card(f, card, &title, &options, app);
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
    // Codex app: hovering a sidebar row shows a card with the full title,
    // the directory, the harness and model, and how long ago it moved.
    if matches!(app.overlay, Overlay::None) && app.sidebar_drag.is_none() {
        if let Some((row, idx)) = app.hover.and_then(|(hx, hy)| app.sidebar_rows.iter().find(|(r, _)| hx >= r.x && hx < r.x + r.width && hy >= r.y && hy < r.y + r.height).cloned()) {
            let ndrafts = app.drafts.len();
            if idx >= ndrafts {
                if let Some(s) = app.sessions.get(idx - ndrafts).cloned() {
                    let title = session_title(&s);
                    let name = s.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
                    let cwd = s.get("cwd").and_then(Value::as_str).unwrap_or("").to_owned();
                    let harness = s.get("harness").and_then(Value::as_str).unwrap_or("").to_owned();
                    let model = s.get("model").and_then(Value::as_str).unwrap_or("").to_owned();
                    let age = s.get("updatedAt").and_then(Value::as_u64).map(|t| age_label(now_ms().saturating_sub(t))).unwrap_or_default();
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
                    let w = (line1.width().max(line2.width()) as u16 + 4).min(main.width.saturating_sub(4)).min(72).max(12);
                    let x = sidebar.x + sidebar.width + 1;
                    let y = row.y.min(area.y + area.height.saturating_sub(5));
                    let r = Rect { x, y, width: w, height: 4 };
                    let buf = f.buffer_mut();
                    fill(buf, r, c.prompt());
                    composer::rounded_border(buf, r, c.prompt_border());
                    buf.set_stringn(r.x + 2, r.y + 1, &truncate(&line1, w as usize - 4), w as usize - 4, c.prompt().add_modifier(Modifier::BOLD));
                    buf.set_stringn(r.x + 2, r.y + 2, &truncate(&line2, w as usize - 4), w as usize - 4, c.prompt().fg(c.status_dim_fg));
                    app.link_cells.retain(|l| !(l.y >= r.y && l.y < r.y + r.height && l.x < r.x + r.width && l.x + l.text.width() as u16 > r.x));
                }
            }
        }
    }
    // Link runs are re-printed after the frame; drop any that a dialog,
    // menu or toast now covers, or their text would show through it.
    if !matches!(app.overlay, Overlay::None) {
        let d = app.dialog_rect;
        let covered = |x: u16, y: u16, w: u16| y >= d.y && y < d.y + d.height && x < d.x + d.width && x + w > d.x;
        app.link_cells.retain(|l| !covered(l.x, l.y, l.text.width() as u16));
    }
    if let Some((text, _)) = &app.toast {
        let label = format!(" {text} ");
        let w = (label.width() as u16).min(transcript.width);
        let r = Rect { x: transcript.x + transcript.width.saturating_sub(w + 1), y: transcript.y + transcript.height.saturating_sub(2), width: w, height: 1 };
        f.buffer_mut().set_stringn(r.x, r.y, &label, w as usize, c.toast());
        app.link_cells.retain(|l| !(l.y == r.y && l.x < r.x + r.width && l.x + l.text.width() as u16 > r.x));
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
        if end > start { Some((start, end)) } else if row != r0 && row != r1 { Some((0, 0)) } else { None }
    }
    pub fn text(&self, rows: &[String]) -> String {
        let ((r0, _), (r1, _)) = self.range();
        let mut out = Vec::new();
        for r in r0..=r1.min(rows.len().saturating_sub(1)) {
            let line = &rows[r];
            let chars: Vec<char> = line.chars().collect();
            let piece = match self.cols_on_row(r, line) {
                Some((s, e)) if e > s => chars[s.min(chars.len())..e.min(chars.len())].iter().collect::<String>(),
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
    if lo < chars.len() && matches!(chars[lo], '›' | '•' | '»' | '▸' | '▾' | '⏳' | '❯' | '≡' | '✎' | '$' | '⌕' | '↓' | '…' | '⇄' | '?' | '✓' | '✗' | '–') {
        lo += 1;
        while lo < chars.len() && chars[lo] == ' ' {
            lo += 1;
        }
        // A second marker, e.g. the outcome bullet after the collapse arrow.
        if lo < chars.len() && matches!(chars[lo], '•' | '✓' | '✗') && chars.get(lo + 1) == Some(&' ') {
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
    fn errors_render_as_a_notice_card() {
        let c = Chrome::dark();
        let mut t = Transcript::default();
        t.items.push(Item::User { text: "go".into(), steer: false, queued: false });
        t.items.push(Item::Error { text: "API error: model not found".into() });
        let rows = transcript_rows(&t, 60, false, false, &std::collections::HashSet::new(), &c);
        let lines: Vec<String> = rows.iter().map(|r| r.line.spans.iter().map(|s| s.content.to_string()).collect::<String>()).collect();
        assert!(lines.iter().any(|l| l.starts_with("╭") && l.ends_with("╮")), "{lines:?}");
        assert!(lines.iter().any(|l| l.contains("✗ API error: model not found")), "{lines:?}");
        assert!(lines.iter().any(|l| l.starts_with("╰") && l.ends_with("╯")), "{lines:?}");
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.contains("✗ API error")), "{text:?}");
    }

    #[test]
    fn hierarchy_renders_and_collapses() {
        let c = Chrome::dark();
        let t = sample();
        let none = std::collections::HashSet::new();
        let rows = transcript_rows(&t, 80, false, false, &none, &c);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.trim_start().starts_with("❯ Use your Bash")), "{text:?}");
        assert!(text.iter().any(|l| l.starts_with("2 steps") && l.ends_with("▾")), "{text:?}");
        assert!(text.iter().any(|l| l.contains("Allowed  date")), "{text:?}");
        // Collapse the group and the first turn.
        let mut flipped = std::collections::HashSet::new();
        flipped.insert(Toggle::Group(2));
        let rows = transcript_rows(&t, 80, false, false, &flipped, &c);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.starts_with("2 steps") && l.ends_with("›")), "{text:?}");
        assert!(!text.iter().any(|l| l.contains("permission: date")), "{text:?}");
        // The first turn's work (a thought and a tool group) has a handle.
        let rows = transcript_rows(&t, 80, false, false, &none, &c);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.starts_with("Worked") && l.ends_with("▾")), "{text:?}");
        assert!(text.iter().any(|l| l.trim_start().starts_with("❯ Use your Bash")), "{text:?}");
        assert!(!rows.iter().any(|r| r.text.trim_start().starts_with("❯") && r.toggle.is_some()), "user rows never toggle");
        // Collapsing the work keeps the message and the final reply.
        flipped.insert(Toggle::Turn(0));
        let rows = transcript_rows(&t, 80, false, false, &flipped, &c);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        assert!(text.iter().any(|l| l.starts_with("Worked") && l.ends_with("›")), "{text:?}");
        assert!(text.iter().any(|l| l.trim_start().starts_with("❯ Use your Bash tool twice")), "{text:?}");
        assert!(text.iter().any(|l| l == &"  done"), "{text:?}");
        assert!(!text.iter().any(|l| l.contains("thinking") || l.contains("hostname")), "{text:?}");
        assert!(text.iter().any(|l| l.trim_start().starts_with("❯ again")), "{text:?}");
        // The second turn has one block only: no handle.
        assert_eq!(text.iter().filter(|l| l.starts_with("Worked")).count(), 1, "{text:?}");
    }
}

#[cfg(test)]
mod selection_tests {
    use super::*;

    /// A user bubble's row text lines up with its display cells, so a
    /// drag inside the bubble copies the words under the pointer.
    #[test]
    fn bubble_rows_align_text_with_cells() {
        let c = Chrome::dark();
        let mut t = Transcript::default();
        t.items.push(Item::User { text: "copy these words".into(), steer: false, queued: false });
        let rows = transcript_rows(&t, 80, false, false, &std::collections::HashSet::new(), &c);
        let row = rows.iter().find(|r| r.text.contains("❯")).expect("bubble row");
        let shown: String = row.line.spans.iter().map(|s| s.content.to_string()).collect();
        let cell_col = shown.chars().position(|ch| ch == '❯').unwrap();
        let text_col = row.text.chars().position(|ch| ch == '❯').unwrap();
        assert_eq!(cell_col, text_col, "shown={shown:?} text={:?}", row.text);
        let (lo, hi) = content_bounds(&row.text);
        assert_eq!(row.text.chars().skip(lo).take(hi - lo).collect::<String>(), "copy these words");
        let i = rows.iter().position(|r| std::ptr::eq(r, row)).unwrap();
        let sel = Selection { session: "s".into(), anchor: (i, lo + 5), head: (i, lo + 10), mode: SelectMode::Cell };
        assert_eq!(sel.text(&rows.iter().map(|r| r.text.clone()).collect::<Vec<_>>()), "these");
    }

    #[test]
    fn model_label_drops_date_stamps() {
        assert_eq!(model_label("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
        assert_eq!(model_label("gpt-6-astra"), "gpt-6-astra");
        assert_eq!(model_label("subrouter/gpt-6-astra"), "subrouter/gpt-6-astra");
        assert_eq!(model_label("20251001"), "20251001");
    }

    #[test]
    fn selection_skips_gutter_markers_and_padding() {
        assert_eq!(content_bounds("  › hello   "), (4, 9));
        assert_eq!(content_bounds("  ▸ • hostname  execute"), (6, 23));
        assert_eq!(content_bounds("• reply"), (2, 7));
        assert_eq!(content_bounds("    - item"), (4, 10));
        let rows = vec!["  › first line   ".to_owned(), "  • second".to_owned(), "".to_owned()];
        let sel = Selection { session: "s".into(), anchor: (0, 0), head: (1, 100), mode: SelectMode::Cell };
        assert_eq!(sel.text(&rows), "first line\nsecond");
        assert_eq!(sel.cols_on_row(0, &rows[0]), Some((4, 14)));
    }
}
