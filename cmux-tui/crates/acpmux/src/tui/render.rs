//! Drawing, in cmux's chrome: no boxes around panes, one vertical rule on
//! the sidebar, a status bar with an active chip, bordered dialogs with
//! `[ Cancel esc ]  [ OK ⏎ ]` buttons, and the shared scrollbar.

use super::dialog::{self, DialogRow, DialogSpec};
use super::scroll::draw_thumb;
use super::theme::Chrome;
use super::{App, ButtonAction, Focus, NewForm, Overlay, POLICIES, Picker};
use crate::transcript::{Item, Transcript};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use serde_json::Value;
use unicode_width::UnicodeWidthStr;

pub const SIDEBAR_WIDTH: u16 = 32;
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
            out.push(Row { line: Line::from(vec![Span::raw(p), Span::styled(std::mem::take(line), style)]), text, item });
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
    out.push(Row { line: Line::from(Span::styled(text.to_owned(), style)), text: text.to_owned(), item });
}

/// Render a transcript into rows at `width`.
pub fn transcript_rows(t: &Transcript, width: usize, show_thoughts: bool, tick: u64, c: &Chrome) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    let w = width.saturating_sub(2);
    for (i, item) in t.items.iter().enumerate() {
        match item {
            Item::User { text, steer, queued } => {
                plain("", Style::default(), i, &mut rows);
                let style = if *queued { c.dim() } else { Style::default().fg(c.user_fg).add_modifier(Modifier::BOLD) };
                let prefix = if *steer { "» " } else if *queued { "⏳ " } else { "> " };
                wrap(text, w.saturating_sub(2), style, prefix, i, &mut rows);
                if *queued {
                    plain("   queued · sends when the running turn ends · Ctrl-x cancels it", c.dim(), i, &mut rows);
                }
            }
            Item::Assistant { text } => {
                plain("", Style::default(), i, &mut rows);
                wrap(text, w, Style::default(), "", i, &mut rows);
            }
            Item::Thought { text } => {
                if show_thoughts {
                    wrap(text, w.saturating_sub(2), Style::default().fg(c.thought_fg).add_modifier(Modifier::ITALIC), "  ", i, &mut rows);
                } else {
                    plain(&format!("  ~ thinking ({} chars, :thoughts to show)", text.chars().count()), c.dim(), i, &mut rows);
                }
            }
            Item::Tool { title, kind, status, detail, .. } => {
                let (glyph, color) = match status.as_str() {
                    "completed" => ("✓", c.ok_fg),
                    "failed" => ("✗", c.error_fg),
                    "in_progress" => ("…", c.warn_fg),
                    _ => ("·", c.warn_fg),
                };
                let text = format!("  {glyph} {}  {kind}", truncate(title, w.saturating_sub(12)));
                rows.push(Row {
                    line: Line::from(vec![
                        Span::styled(format!("  {glyph} "), Style::default().fg(color)),
                        Span::styled(truncate(title, w.saturating_sub(12)), Style::default().fg(c.tool_fg)),
                        Span::styled(format!("  {kind}"), c.dim()),
                    ]),
                    text,
                    item: i,
                });
                if !detail.is_empty() && status != "in_progress" {
                    let shown: String = detail.lines().take(8).collect::<Vec<_>>().join("\n");
                    wrap(&shown, w.saturating_sub(4), c.dim(), "    ", i, &mut rows);
                    if detail.lines().count() > 8 {
                        plain("    …", c.dim(), i, &mut rows);
                    }
                }
            }
            Item::Plan { entries } => {
                plain("  plan", Style::default().fg(c.attention_fg), i, &mut rows);
                for (s, content) in entries {
                    let glyph = match s.as_str() {
                        "completed" => "✓",
                        "in_progress" => "▶",
                        _ => "○",
                    };
                    wrap(content, w.saturating_sub(6), Style::default().fg(c.attention_fg), &format!("    {glyph} "), i, &mut rows);
                }
            }
            Item::Permission { title, decided, .. } => {
                let text = match decided {
                    Some(d) => format!("  permission: {title} → {d}"),
                    None => format!("  permission needed: {title}"),
                };
                plain(&text, Style::default().fg(c.attention_fg), i, &mut rows);
            }
            Item::Status { text } => plain(&format!("  -- {text}"), c.dim(), i, &mut rows),
            Item::TurnEnd { stop } => {
                if stop != "end_turn" {
                    plain(&format!("  -- {stop}"), c.dim(), i, &mut rows);
                }
            }
            Item::Error { text } => wrap(text, w, Style::default().fg(c.error_fg).add_modifier(Modifier::BOLD), "  ✗ error: ", i, &mut rows),
            Item::Stderr { text } => plain(&format!("  stderr: {}", truncate(text, w.saturating_sub(10))), c.dim(), i, &mut rows),
        }
    }
    if t.status == "running" {
        let streaming = matches!(t.items.last(), Some(Item::Assistant { .. }) | Some(Item::Tool { .. }));
        if !streaming {
            let thought = match t.items.last() {
                Some(Item::Thought { text }) => format!(" · thinking {} chars", text.chars().count()),
                _ => String::new(),
            };
            let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
            plain("", Style::default(), usize::MAX, &mut rows);
            plain(&format!("  {} working{thought}", frames[(tick % 10) as usize]), Style::default().fg(c.warn_fg), usize::MAX, &mut rows);
        }
    }
    rows
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
    let editor_w = main.width.saturating_sub(2) as usize;
    let input_h = (app.editor().rows_at(editor_w).max(1) as u16 + 1).min(8);
    let composer = Rect { x: main.x, y: main.y + main.height - input_h, width: main.width, height: input_h };
    let transcript = Rect { x: main.x, y: main.y, width: main.width, height: main.height - input_h };
    app.areas.sidebar = sidebar;
    app.areas.sidebar_rule = if sidebar_w == 0 { Rect::default() } else { Rect { x: sidebar.x + sidebar.width - 1, y: sidebar.y, width: 1, height: sidebar.height } };
    app.areas.transcript = transcript;
    app.areas.composer = composer;
    app.areas.status = Rect { x: area.x, y: status_y, width: area.width, height: 1 };

    app.buttons.clear();
    app.perm_rows.clear();
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
    let kind: u8 = match &app.overlay { Overlay::None => 0, Overlay::Help => 1, Overlay::NewSession(_) => 2, Overlay::Picker(_) => 3, Overlay::Confirm { .. } => 4, Overlay::AddHost { .. } => 5, Overlay::Directory { .. } => 6 };
    if kind != app.last_overlay {
        app.dialog = dialog::DialogState::default();
        app.last_overlay = kind;
    }
    match std::mem::replace(&mut app.overlay, Overlay::None) {
        Overlay::None => {}
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

fn draw_sidebar(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let buf = f.buffer_mut();
    fill(buf, area, Style::default());
    let focused = app.focus == Focus::Sidebar;
    let rule_x = area.x + area.width - 1;
    let rule_hot = app.sidebar_drag.is_some() || app.hover.map(|(hx, _)| hx == rule_x).unwrap_or(false);
    let (rule, rule_style) = c.rule(focused || rule_hot);
    for y in area.y..area.y + area.height {
        if let Some(cell) = buf.cell_mut((rule_x, y)) {
            cell.set_symbol(rule).set_style(rule_style);
        }
    }
    let content_w = (area.width - 1) as usize;
    // Header row: count and the new-session hint.
    let header = match app.host_filter.as_deref() {
        Some("local") => format!(" mac · {}", app.sessions.iter().filter(|s| s.get("peer").is_none()).count()),
        Some(h) => format!(" {h} · {}", app.sessions.iter().filter(|s| s.get("peer").and_then(Value::as_str) == Some(h)).count()),
        None => format!(" sessions {}", app.sessions.len()),
    };
    let header_style = if focused { Style::default().bg(c.status_active_bg).fg(c.border_active_fg).add_modifier(Modifier::BOLD) } else { c.dim() };
    if focused {
        for x in area.x..rule_x {
            if let Some(cell) = buf.cell_mut((x, area.y)) {
                cell.set_style(header_style);
            }
        }
    }
    buf.set_stringn(area.x, area.y, &header, content_w, header_style);
    // Footer actions pinned to the bottom, like a cmux rail: they keep
    // their rows even on a short terminal so they stay reachable.
    let footer: [(&str, ButtonAction); 2] = [("+ new session", ButtonAction::NewDraft), ("+ add host", ButtonAction::AddHost)];
    let footer_h = if area.height > 6 { footer.len() as u16 + 1 } else { 0 };
    if footer_h > 0 {
        let fy = area.y + area.height - footer.len() as u16;
        for (i, (label, action)) in footer.iter().enumerate() {
            let y = fy + i as u16;
            let rect = Rect { x: area.x, y, width: area.width - 1, height: 1 };
            let hovered = app.hover.map(|(hx, hy)| hy == y && hx >= rect.x && hx < rect.x + rect.width).unwrap_or(false);
            let style = if hovered {
                Style::default().bg(c.prompt_button_hover_bg).fg(c.prompt_button_accent_fg).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(c.prompt_button_accent_fg)
            };
            if hovered {
                for x in rect.x..rect.x + rect.width {
                    if let Some(cell) = buf.cell_mut((x, y)) {
                        cell.set_style(style);
                    }
                }
            }
            buf.set_stringn(area.x + 1, y, label, content_w.saturating_sub(1), style);
            app.buttons.push((rect, action.clone()));
        }
    }
    // Two rows per session.
    let body_y = area.y + 1;
    let body_h = area.height.saturating_sub(1 + footer_h) as usize;
    let rows_per = 2usize;
    let visible_sessions = body_h / rows_per;
    let selected = app.selected;
    // Rows: an optional draft first, then sessions.
    let mut rows: Vec<Value> = Vec::with_capacity(app.sessions.len() + app.drafts.len());
    for d in &app.drafts {
        let preview = d.text.text();
        let sub = if preview.trim().is_empty() { shorten_path(&d.cwd) } else { preview.lines().next().unwrap_or("").to_owned() };
        let agent_label = match &d.peer { Some(p) => format!("{p}/{}", d.agent), None => d.agent.clone() };
        rows.push(serde_json::json!({"name": "new session", "status": if d.creating { "running" } else { "draft" }, "agent": agent_label, "lastPrompt": sub, "draft": true}));
    }
    rows.extend(app.sessions.iter().cloned());
    // Apply the host filter: keep (absolute index, row) pairs that match.
    let filtered: Vec<(usize, &Value)> = rows.iter().enumerate().filter(|(i, _)| app.row_visible(*i)).collect();
    let sel_pos = filtered.iter().position(|(i, _)| *i == selected).unwrap_or(0);
    let offset = if visible_sessions == 0 { 0 } else { sel_pos.saturating_sub(visible_sessions.saturating_sub(1)).min(filtered.len().saturating_sub(visible_sessions)) };
    app.sidebar_offset = offset;
    app.sidebar_rows.clear();
    for (line, (idx, s)) in filtered.iter().skip(offset).take(visible_sessions).enumerate() {
        let (idx, s) = (*idx, *s);
        let y = body_y + (line * rows_per) as u16;
        let name = s.get("name").and_then(Value::as_str).unwrap_or("?");
        let status = s.get("status").and_then(Value::as_str).unwrap_or("");
        let pending = s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
        let agent = s.get("agent").and_then(Value::as_str).unwrap_or("");
        let is_sel = idx == selected;
        let row_style = if is_sel { c.selected_row() } else { Style::default() };
        if is_sel {
            for yy in y..y + 2 {
                for x in area.x..rule_x {
                    if let Some(cell) = buf.cell_mut((x, yy)) {
                        cell.set_style(row_style);
                    }
                }
            }
        }
        let is_draft = s.get("draft").and_then(Value::as_bool).unwrap_or(false);
        let name = if is_draft { "new session" } else { name };
        let (glyph, gstyle) = if is_draft {
            ("+", Style::default().fg(c.border_active_fg).add_modifier(Modifier::BOLD))
        } else if pending {
            ("?", Style::default().fg(c.attention_fg).add_modifier(Modifier::BOLD))
        } else {
            match status {
                "running" => ("●", Style::default().fg(c.warn_fg)),
                "ready" => ("●", Style::default().fg(c.ok_fg)),
                "waiting" => ("?", Style::default().fg(c.attention_fg)),
                "disconnected" | "unreachable" => ("!", Style::default().fg(c.error_fg)),
                "closed" => ("×", c.dim()),
                _ => ("·", c.dim()),
            }
        };
        let gstyle = if is_sel { gstyle.bg(c.sidebar_selected_bg) } else { gstyle };
        if is_sel {
            // cmux's rail glyph marks the current entry in column 0.
            buf.set_stringn(area.x, y, "▎", 1, row_style.fg(c.border_active_fg));
            buf.set_stringn(area.x, y + 1, "▎", 1, row_style.fg(c.border_active_fg));
        }
        buf.set_stringn(area.x + 1, y, glyph, 1, gstyle);
        let sid = s.get("sessionId").and_then(Value::as_str).unwrap_or("");
        let dot = app.attention.get(sid).copied().unwrap_or(0);
        let mut name_x = area.x + 3;
        if dot > 0 && !is_sel {
            let color = match dot { 3 => c.error_fg, 2 => c.attention_fg, _ => c.ok_fg };
            buf.set_stringn(name_x, y, "•", 1, Style::default().fg(color).add_modifier(Modifier::BOLD));
            name_x += 2;
        }
        let name_w = content_w.saturating_sub((name_x - area.x) as usize + 1);
        buf.set_stringn(name_x, y, &truncate(name, name_w), name_w, row_style);
        let sub_text = s
            .get("lastPrompt")
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
            .map(|t| format!("{agent} · {t}"))
            .unwrap_or_else(|| format!("{agent} · {status}"));

        let sub_style = if is_sel { Style::default().bg(c.sidebar_selected_bg).fg(c.sidebar_dim_fg) } else { c.dim() };
        buf.set_stringn(area.x + 3, y + 1, &truncate(&sub_text, content_w.saturating_sub(4)), content_w.saturating_sub(4), sub_style);
        if is_sel {
            // Re-fill any cell the strings did not cover so the row reads as one block.
            for yy in y..y + 2 {
                for x in area.x..rule_x {
                    if let Some(cell) = buf.cell_mut((x, yy)) {
                        if cell.symbol() == " " {
                            cell.set_style(row_style);
                        }
                    }
                }
            }
        }
        app.sidebar_rows.push((Rect { x: area.x, y, width: area.width - 1, height: 2 }, idx));
    }
    if filtered.is_empty() && body_h > 1 {
        let what = match app.host_filter.as_deref() { Some("local") => "No sessions on this Mac".to_owned(), Some(h) => format!("No sessions on {h}"), None => "No sessions".to_owned() };
        buf.set_stringn(area.x + 1, body_y, &what, content_w, c.dim());
        buf.set_stringn(area.x + 1, body_y + 1, "Ctrl-t creates one", content_w, c.dim());
    }
    // Scrollbar one column inside the rule when sessions overflow.
    let total = filtered.len() * rows_per;
    let visible = visible_sessions * rows_per;
    if total > visible && visible > 0 {
        let track = Rect { x: rule_x - 1, y: body_y, width: 1, height: visible as u16 };
        let thumb = super::scroll::thumb_geometry(total, visible, offset * rows_per, track.height);
        draw_thumb(buf, track, thumb, c.scrollbar_thumb_fg, c.scrollbar_thumb_active_fg, super::scroll::ThumbState::Idle);
    }
}

fn draw_transcript(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let buf = f.buffer_mut();
    fill(buf, area, Style::default());
    // Title row: name, status, then clickable chips for harness/model, mode,
    // permissions, thinking, directory. Each chip opens its picker.
    let title_y = area.y;
    let name = app.selected_name();
    let (status, mode, model) = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .map(|t| (t.status.clone(), t.mode.clone().unwrap_or_default(), t.model.clone().unwrap_or_default()))
        .unwrap_or_default();
    let on_draft = app.on_draft();
    let (agent, cwd, policy, model_shown, thinking) = if let Some(d) = app.draft() {
        let a = match &d.peer { Some(p) => format!("{p}/{}", d.agent), None => d.agent.clone() };
        (a, d.cwd.clone(), d.policy.clone(), d.model.clone().unwrap_or_else(|| "default".into()), String::new())
    } else {
        let s = app.selected_session();
        let a = s.and_then(|s| s.get("agent").and_then(Value::as_str)).unwrap_or("").to_owned();
        let a = match s.and_then(|s| s.get("peer").and_then(Value::as_str)) { Some(p) => format!("{p}/{a}"), None => a };
        let cwd = s.and_then(|s| s.get("cwd").and_then(Value::as_str)).unwrap_or("").to_owned();
        let policy = s.and_then(|s| s.get("policy").and_then(Value::as_str)).unwrap_or("ask").to_owned();
        let thinking = app
            .selected_id()
            .and_then(|id| app.details.get(&id))
            .and_then(|d| d.get("configOptions").and_then(Value::as_array).cloned())
            .and_then(|opts| {
                ["reasoning_effort", "effort", "thinking", "reasoning"].iter().find_map(|k| {
                    opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some(k)).and_then(|o| o.get("currentValue").and_then(Value::as_str).map(str::to_owned))
                })
            })
            .unwrap_or_default();
        (a, cwd, policy, model, thinking)
    };
    let mut x = area.x + 1;
    let hover = app.hover;
    let mut chips: Vec<(Rect, ButtonAction)> = Vec::new();
    {
        let buf = f.buffer_mut();
        let w = (name.width() as u16).min((area.x + area.width).saturating_sub(x));
        let name_style = if app.focus == Focus::Transcript && matches!(app.overlay, Overlay::None) {
            Style::default().fg(c.border_active_fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().add_modifier(Modifier::BOLD)
        };
        buf.set_stringn(x, title_y, &name, w as usize, name_style);
        x += w;
        if !status.is_empty() {
            let t = format!("  {status}");
            let w = (t.width() as u16).min((area.x + area.width).saturating_sub(x));
            buf.set_stringn(x, title_y, &t, w as usize, status_fg(&c, &status));
            x += w;
        }
        x += 1;
        let mut chip = |buf: &mut Buffer, label: &str, value: &str, action: ButtonAction| {
            if value.is_empty() {
                return;
            }
            let t = format!(" {label} {value} ");
            let w = (t.width() as u16).min((area.x + area.width).saturating_sub(x));
            if w == 0 {
                return;
            }
            let r = Rect { x, y: title_y, width: w, height: 1 };
            let hovered = hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
            let style = if hovered { Style::default().bg(c.status_active_bg).fg(c.status_active_fg) } else { Style::default().bg(c.status_bg).fg(c.status_fg) };
            for cx in r.x..r.x + r.width {
                if let Some(cell) = buf.cell_mut((cx, title_y)) {
                    cell.set_style(style);
                }
            }
            buf.set_stringn(x, title_y, &format!(" {label} "), (label.width() + 2).min(w as usize), style.fg(if hovered { c.status_active_fg } else { c.status_dim_fg }));
            buf.set_stringn(x + label.width() as u16 + 2, title_y, &format!("{value} "), w.saturating_sub(label.width() as u16 + 2) as usize, style);
            chips.push((r, action));
            x += w + 1;
        };
        // Harness only when it differs from what the session name already says.
        let model_value = if on_draft { format!("{agent} · {}", if model_shown.is_empty() { "default" } else { &model_shown }) } else if model_shown.is_empty() { "default".into() } else { model_shown.clone() };
        chip(buf, "model", &model_value, ButtonAction::PickModel);
        if !on_draft {
            chip(buf, "mode", &mode, ButtonAction::PickMode);
        }
        chip(buf, "perms", &policy, ButtonAction::PickPolicy);
        if !on_draft && !thinking.is_empty() {
            chip(buf, "thinking", &thinking, ButtonAction::PickThinking);
        }
        chip(buf, "dir", &shorten_path(&cwd), ButtonAction::EditDirectory);
    }
    app.buttons.extend(chips);
    let buf = f.buffer_mut();
    let inner = Rect { x: area.x + 1, y: area.y + 1, width: area.width.saturating_sub(3), height: area.height.saturating_sub(1) };
    if let Some(d) = app.draft() {
        let lines = [
            String::new(),
            format!("  {}{}  ·  {}  ·  {}  ·  {}", d.peer.as_deref().map(|p| format!("{p}/")).unwrap_or_default(), d.agent, d.model.as_deref().unwrap_or("default model"), shorten_path(&d.cwd), d.policy),
            String::new(),
            "  Type a message below and press Enter to start this session.".into(),
            "  Ctrl-l harness and model   :cwd PATH   :policy ask|approve-reads|approve-all   Esc discards".into(),
        ];
        for (i, l) in lines.iter().enumerate() {
            if (i as u16) < inner.height {
                buf.set_stringn(inner.x, inner.y + i as u16, l, inner.width as usize, if i == 1 { Style::default() } else { c.dim() });
            }
        }
        let mut y = inner.y + 6;
        if d.creating {
            buf.set_stringn(inner.x, y, &format!("  ⠋ starting {}…", d.agent), inner.width as usize, Style::default().fg(c.warn_fg));
            y += 1;
        }
        for e in &d.errors {
            if y >= inner.y + inner.height {
                break;
            }
            buf.set_stringn(inner.x, y, &format!("  ✗ {e}"), inner.width as usize, Style::default().fg(c.error_fg));
            y += 1;
        }
        return;
    }
    let Some(id) = app.selected_id() else {
        let lines = [
            "",
            "  No sessions yet.",
            "",
            "  Ctrl-t   create a session: pick an agent, name it, choose a directory",
            "  ?        all keys",
            "",
            "  From a shell:  acpmux new -a claude -n my-task",
        ];
        for (i, l) in lines.iter().enumerate() {
            if (i as u16) < inner.height {
                buf.set_stringn(inner.x, inner.y + i as u16, l, inner.width as usize, if i == 3 || i == 4 { Style::default().fg(c.ok_fg) } else { c.dim() });
            }
        }
        return;
    };
    let Some(t) = app.transcripts.get(&id) else {
        buf.set_stringn(inner.x, inner.y, "loading…", inner.width as usize, c.dim());
        return;
    };
    let rows = transcript_rows(t, inner.width as usize, app.show_thoughts, app.tick, &c);
    let track = Rect { x: area.x + area.width - 1, y: inner.y, width: 1, height: inner.height };
    let vp = app.viewport.entry(id.clone()).or_default();
    vp.layout(rows.len(), inner.height as usize, track);
    vp.hover = hover.map(|(hx, hy)| vp.track_contains(hx, hy)).unwrap_or(false);
    let offset = vp.offset;
    let sel = app.selection.as_ref().filter(|s| s.session == id).cloned();
    for (i, row) in rows.iter().enumerate().skip(offset).take(inner.height as usize) {
        let y = inner.y + (i - offset) as u16;
        let p = Paragraph::new(row.line.clone());
        f_render(buf, p, Rect { x: inner.x, y, width: inner.width, height: 1 });
        if let Some(s) = &sel {
            if let Some((c0, c1)) = s.cols_on_row(i, row.text.width()) {
                for x in c0..c1.min(inner.width as usize) {
                    if let Some(cell) = buf.cell_mut((inner.x + x as u16, y)) {
                        cell.set_style(cell.style().patch(c.selection()));
                    }
                }
            }
        }
    }
    app.rows_cache = rows.into_iter().map(|r| r.text).collect();
    if vp.has_scrollbar() {
        draw_thumb(buf, track, vp.thumb(), c.scrollbar_thumb_fg, c.scrollbar_thumb_active_fg, vp.thumb_state());
    }
    let below = vp.rows_below();
    if below > 0 {
        let tag = format!(" ↓ {below} more · End ");
        let w = tag.width() as u16;
        buf.set_stringn(inner.x + inner.width.saturating_sub(w), inner.y + inner.height.saturating_sub(1), &tag, w as usize, c.status_active());
    }
}

fn f_render(buf: &mut Buffer, p: Paragraph, area: Rect) {
    use ratatui::widgets::Widget;
    p.render(area, buf);
}

fn draw_composer(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let focused = matches!(app.focus, Focus::Input | Focus::Command) && matches!(app.overlay, Overlay::None);
    let buf = f.buffer_mut();
    // Top rule with a label, like a pane tab bar.
    let rule_style = if focused { Style::default().fg(c.border_active_fg) } else { Style::default().fg(c.border_fg) };
    for x in area.x..area.x + area.width {
        if let Some(cell) = buf.cell_mut((x, area.y)) {
            cell.set_symbol("─").set_style(rule_style);
        }
    }
    let label = match app.focus {
        Focus::Command => " : command ".to_owned(),
        _ => {
            let steer = if app.selected_supports_steer() { "Ctrl-s steer" } else { "Ctrl-s queue" };
            format!(" message · Enter send · Ctrl-j newline · {steer} ")
        }
    };
    buf.set_stringn(area.x + 1, area.y, &label, area.width.saturating_sub(2) as usize, if focused { Style::default().fg(c.border_active_fg) } else { c.dim() });
    let text_area = Rect { x: area.x + 1, y: area.y + 1, width: area.width.saturating_sub(2), height: area.height - 1 };
    if app.focus == Focus::Command {
        let content = format!(":{}", app.command);
        buf.set_stringn(text_area.x, text_area.y, &content, text_area.width as usize, Style::default().fg(c.warn_fg));
        if focused {
            f.set_cursor_position((text_area.x + (content.width() as u16).min(text_area.width), text_area.y));
        }
        return;
    }
    let width = text_area.width.max(1) as usize;
    let on_draft = app.on_draft();
    let (rows, (cur_row, cur_col)) = app.editor().layout(width);
    let visible = text_area.height.max(1) as usize;
    // Keep the cursor row inside the visible window.
    let mut scroll = app.editor().scroll.min(rows.len().saturating_sub(1));
    if cur_row < scroll {
        scroll = cur_row;
    } else if cur_row >= scroll + visible {
        scroll = cur_row + 1 - visible;
    }
    app.editor_mut().scroll = scroll;
    if app.editor().is_empty() && on_draft {
        buf.set_stringn(text_area.x, text_area.y, "Ask anything…", width, c.dim());
    }
    for (i, row) in rows.iter().enumerate().skip(scroll).take(visible) {
        let y = text_area.y + (i - scroll) as u16;
        buf.set_stringn(text_area.x, y, &app.editor().row_text(*row), width, Style::default());
    }
    if rows.len() > visible {
        let track = Rect { x: area.x + area.width - 1, y: text_area.y, width: 1, height: text_area.height };
        let thumb = super::scroll::thumb_geometry(rows.len(), visible, scroll, track.height);
        draw_thumb(buf, track, thumb, c.scrollbar_thumb_fg, c.scrollbar_thumb_active_fg, super::scroll::ThumbState::Idle);
    }
    if focused {
        f.set_cursor_position((text_area.x + (cur_col as u16).min(text_area.width), text_area.y + (cur_row - scroll) as u16));
    }
}

fn draw_status(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let buf = f.buffer_mut();
    fill(buf, area, c.status());
    let mut x = area.x;
    fn put_at(buf: &mut Buffer, area: Rect, x: &mut u16, text: &str, style: Style) {
        let w = (text.width() as u16).min((area.x + area.width).saturating_sub(*x));
        if w > 0 {
            buf.set_stringn(*x, area.y, text, w as usize, style);
            *x += w;
        }
    }
    // Host chips: local first, then every peer, then [+ host]. Click filters.
    let mut chips: Vec<(Rect, Option<String>)> = Vec::new();
    let mut hosts: Vec<(Option<String>, String, bool)> = vec![(Some("local".into()), "mac".into(), true)];
    for (name, connected, _) in &app.hosts {
        hosts.push((Some(name.clone()), name.clone(), *connected));
    }
    for (key, label, connected) in hosts {
        let active = app.host_filter == key;
        let dot = if connected { "●" } else { "○" };
        let text = format!(" {dot} {label} ");
        let start = x;
        let hovered = app.hover.map(|(hx, hy)| hy == area.y && hx >= start && hx < start + text.width() as u16).unwrap_or(false);
        let style = if active { c.status_active() } else if hovered { c.status().bg(c.status_active_bg) } else { c.status() };
        let dot_style = style.fg(if connected { c.ok_fg } else { c.error_fg });
        put_at(buf, area, &mut x, " ", style);
        put_at(buf, area, &mut x, dot, dot_style);
        put_at(buf, area, &mut x, &format!(" {label} "), style);
        chips.push((Rect { x: start, y: area.y, width: x - start, height: 1 }, key));
    }
    {
        let text = "[+ host] ";
        let start = x;
        let hovered = app.hover.map(|(hx, hy)| hy == area.y && hx >= start && hx < start + text.width() as u16).unwrap_or(false);
        put_at(buf, area, &mut x, text, if hovered { c.status().bg(c.status_active_bg).fg(c.prompt_button_accent_fg) } else { c.status_dim() });
        chips.push((Rect { x: start, y: area.y, width: x - start, height: 1 }, Some("+".into())));
    }
    put_at(buf, area, &mut x, "│ ", c.status_dim());
    let is_error = app.status.starts_with("error: ");
    let status_style = if is_error { c.status().fg(c.error_fg).add_modifier(Modifier::BOLD) } else { c.status() };
    put_at(buf, area, &mut x, &app.status, status_style);
    if is_error {
        let label = " [copy] ";
        let lw = label.width() as u16;
        if x + lw < area.x + area.width {
            let r = Rect { x, y: area.y, width: lw, height: 1 };
            let hovered = app.hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
            put_at(buf, area, &mut x, label, if hovered { c.status().bg(c.status_active_bg).fg(c.prompt_button_accent_fg) } else { c.status_dim() });
            app.buttons.push((r, ButtonAction::CopyStatus));
        }
    }
    // Right side: usage, web link, and the [acpmux] label.
    let usage = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .and_then(|t| t.usage)
        .map(|(u, s)| if s > 0 { format!("ctx {}k/{}k ", u / 1000, s / 1000) } else { format!("{}k tokens ", u / 1000) })
        .unwrap_or_default();
    let web = app.web_url.as_deref().map(|u| format!("{u} ")).unwrap_or_default();
    let right = format!("{usage}{web}[acpmux] ");
    let rw = right.width() as u16;
    if x + rw < area.x + area.width {
        let rx = area.x + area.width - rw;
        buf.set_stringn(rx, area.y, &right, rw as usize, c.status_dim());
    }
    app.host_chips = chips;
}

// ------------------------------------------------------------ dialogs

/// Right-aligned `[ label ]` buttons on one row. Returns the rects in order.
pub const HELP_ROWS: &[(&str, &str)] = &[
    ("", "sessions"),
    ("Ctrl-t  n", "new session tab"),
    ("Cmd-Ctrl-h/j/k/l", "move focus: h sidebar, l content, k transcript, j composer (Alt-h/j/k/l too)"),
    ("Alt-s  :sidebar", "hide / show the sidebar"),
    ("Tab", "focus the sidebar: j/k move, Enter select, Esc back"),
    ("Ctrl-n / Ctrl-p", "in the sidebar: next / previous session; in the composer: next / previous line"),
    ("Alt-Left / Alt-Right", "narrow / widen the sidebar (drag its rule with the mouse)"),
    ("x / X", "stop / delete the selected session (asks first)"),
    ("f  r", "fork / rename"),
    ("", ""),
    ("", "talking"),
    ("Enter", "send the message"),
    ("Ctrl-j", "newline (also Shift-Enter, or a trailing \\ then Enter)"),
    ("Ctrl-s", "steer the running turn, or queue when the agent cannot steer"),
    ("Ctrl-x", "cancel the running turn"),
    ("y / n / 1-9", "answer a permission request"),
    ("", ""),
    ("", "editing"),
    ("Ctrl-a / Ctrl-e", "start / end of line"),
    ("Alt-b / Alt-f", "word left / right"),
    ("Ctrl-w  Alt-d", "delete word back / forward"),
    ("Ctrl-k / Ctrl-u", "kill to end / start of line"),
    ("Ctrl-z", "undo"),
    ("Up / Down", "move between lines; at the ends, recall sent messages"),
    ("", ""),
    ("", "reading"),
    ("wheel  PgUp/PgDn", "scroll the transcript"),
    ("Home / End", "top / follow the bottom"),
    ("drag", "select text; release copies it"),
    ("double / triple click", "select a word / a line"),
    (":thoughts", "show or hide the agent's thinking"),
    ("", ""),
    ("", "settings (all clickable in the title row)"),
    ("Ctrl-l  Ctrl-o", "pick model / mode"),
    (":set KEY", "pick any agent option, e.g. :set reasoning_effort"),
    (":policy P", "ask · approve-reads · approve-all · deny-all"),
    (":cwd PATH", "change directory: a draft moves, a live session forks"),
    (":peer add", "mirror another machine: :peer add NAME ssh://host"),
    (":web", "open the web dashboard"),
    ("", ""),
    ("Ctrl-q", "leave; every agent keeps running"),
];

fn spans(parts: &[(&str, Style)]) -> Vec<(String, Style)> {
    parts.iter().map(|(s, st)| (s.to_string(), *st)).collect()
}

fn draw_permission(f: &mut ratatui::Frame, area: Rect, title: &str, options: &[(String, String, String)], app: &mut App) {
    let c = app.chrome;
    let hover = app.hover;
    let rows: Vec<DialogRow> = options
        .iter()
        .enumerate()
        .map(|(i, (_, name, kind))| {
            let color = if kind.starts_with("allow") { c.prompt_button_accent_fg } else { c.error_fg };
            DialogRow {
                spans: vec![(format!("{}  ", i + 1), Style::default().fg(c.warn_fg)), (name.clone(), Style::default().fg(color))],
                selectable: true,
                note: Some(format!("({kind})")),
            }
        })
        .collect();
    let spec = DialogSpec {
        title: "Permission",
        header: vec![spans(&[(&truncate(title, 100), Style::default())]), vec![]],
        rows,
        selected: None,
        reveal: false,
        hint: "y allow · n reject · digit or click picks",
        buttons: vec![("[ Reject n ]", false, ButtonAction::PermissionDeny), ("[ Allow y ]", true, ButtonAction::PermissionAllow)],
        close_button: false,
        min_width: 40,
        max_width: 96,
    };
    let mut state = std::mem::take(&mut app.dialog);
    let mut btns = Vec::new();
    dialog::draw(f.buffer_mut(), area, &c, hover, spec, &mut state, &mut btns);
    app.perm_rows = state.row_rects.iter().map(|(r, i)| (*r, ButtonAction::PermissionOption(*i))).collect();
    app.dialog_rect = state.rect;
    app.buttons.extend(btns);
    app.dialog = state;
}

fn draw_new_session(f: &mut ratatui::Frame, area: Rect, form: &NewForm, app: &mut App, hover: Option<(u16, u16)>) {
    let c = app.chrome;
    let label = |i: usize, name: &str| -> (String, Style) {
        if form.field == i {
            (format!("▶ {name:<14}"), c.prompt().fg(c.prompt_button_accent_fg).add_modifier(Modifier::BOLD))
        } else {
            (format!("  {name:<14}"), c.prompt().fg(c.status_dim_fg))
        }
    };
    let agent = form.agents.get(form.agent).cloned().unwrap_or_else(|| "(none configured)".into());
    let agent_line = if form.agents.len() > 1 { format!("◀ {agent} ▶   {} available, Enter lists them", form.agents.len()) } else { agent };
    let policy_hint = match POLICIES[form.policy] {
        "ask" => "you approve each tool call",
        "approve-reads" => "reads auto, writes ask",
        "approve-all" => "nothing asks",
        _ => "everything denied",
    };
    let val = |i: usize, v: &str, hint: &str| -> Vec<(String, Style)> {
        let mut out = vec![label(i, ""), (v.to_owned(), if matches!(i, 1 | 2 | 4) && form.field == i { c.prompt_input() } else { c.prompt() })];
        out[0].0 = out[0].0.trim_end().to_owned();
        if !hint.is_empty() {
            out.push((format!("  {hint}"), c.prompt().fg(c.status_dim_fg)));
        }
        out
    };
    let names = ["agent", "name", "directory", "permissions", "first message"];
    let values: [(String, &str); 5] = [
        (agent_line, ""),
        (form.name.clone(), if form.name.is_empty() { "blank = automatic" } else { "" }),
        (form.cwd.clone(), ""),
        (format!("◀ {} ▶", POLICIES[form.policy]), policy_hint),
        (form.prompt.clone(), if form.prompt.is_empty() { "optional" } else { "" }),
    ];
    let mut header = vec![vec![]];
    for (i, (v, hint)) in values.iter().enumerate() {
        let (l, ls) = label(i, names[i]);
        let mut line = vec![(l, ls)];
        line.extend(val(i, v, hint).into_iter().skip(1));
        header.push(line);
    }
    let spec = DialogSpec {
        title: "New session",
        header,
        rows: vec![],
        selected: None,
        reveal: false,
        hint: "Tab next · ◀ ▶ change",
        buttons: vec![("[ Cancel esc ]", false, ButtonAction::CloseOverlay), ("[ Create ⏎ ]", true, ButtonAction::CreateFromForm)],
        close_button: false,
        min_width: 72,
        max_width: 96,
    };
    let mut state = std::mem::take(&mut app.dialog);
    let mut btns = Vec::new();
    let out = dialog::draw(f.buffer_mut(), area, &c, hover, spec, &mut state, &mut btns);
    app.dialog_rect = state.rect;
    app.buttons.extend(btns);
    app.dialog = state;
    // Cursor at the end of the focused text field.
    if matches!(form.field, 1 | 2 | 4) {
        let v = match form.field { 1 => &form.name, 2 => &form.cwd, _ => &form.prompt };
        let (hx, hy) = out.header_origin;
        f.set_cursor_position((hx + 16 + (v.width() as u16).min(out.inner_width.saturating_sub(18)), hy + 1 + form.field as u16));
    }
}

fn draw_picker(f: &mut ratatui::Frame, area: Rect, p: &mut Picker, app: &mut App) {
    let c = app.chrome;
    let hover = app.hover;
    let rows: Vec<DialogRow> = p
        .visible
        .iter()
        .map(|&ri| {
            let row = &p.rows[ri];
            if row.header {
                DialogRow { spans: vec![(format!(" {}", row.label), c.prompt_title())], selectable: false, note: if row.note.is_empty() { None } else { Some(row.note.clone()) } }
            } else {
                DialogRow { spans: vec![(row.label.clone(), c.prompt())], selectable: true, note: None }
            }
        })
        .collect();
    let filter_shown = if p.filter.is_empty() { String::new() } else { p.filter.clone() };
    let spec = DialogSpec {
        title: &p.title,
        header: vec![vec![("".into(), c.prompt())], vec![]],
        rows,
        selected: Some(p.cursor),
        reveal: std::mem::take(&mut p.reveal),
        hint: &p.hint,
        buttons: vec![],
        close_button: true,
        min_width: 40,
        max_width: 90,
    };
    let mut state = std::mem::take(&mut app.dialog);
    let mut btns = Vec::new();
    let out = dialog::draw(f.buffer_mut(), area, &c, hover, spec, &mut state, &mut btns);
    // Filter field on the first header line.
    let (hx, hy) = out.header_origin;
    let cursor = dialog::text_field(f.buffer_mut(), hx, hy, out.inner_width, &filter_shown, p.filter.chars().count(), "filter…", &c);
    p.row_rects = state.row_rects.clone();
    app.dialog_rect = state.rect;
    app.buttons.extend(btns);
    app.dialog = state;
    f.set_cursor_position(cursor);
}

fn draw_text_dialog(f: &mut ratatui::Frame, area: Rect, app: &mut App, hover: Option<(u16, u16)>, title: &str, above: &str, text: &super::editor::Editor, placeholder: &str, below: &str, ok_label: &str) {
    let c = app.chrome;
    let spec = DialogSpec {
        title,
        header: vec![spans(&[(above, c.prompt().fg(c.status_dim_fg))]), vec![], vec![], spans(&[(below, c.prompt().fg(c.status_dim_fg))])],
        rows: vec![],
        selected: None,
        reveal: false,
        hint: "",
        buttons: vec![("[ Cancel esc ]", false, ButtonAction::CloseOverlay), (ok_label, true, ButtonAction::CreateFromForm)],
        close_button: false,
        min_width: 60,
        max_width: 80,
    };
    let mut state = std::mem::take(&mut app.dialog);
    let mut btns = Vec::new();
    let out = dialog::draw(f.buffer_mut(), area, &c, hover, spec, &mut state, &mut btns);
    let (hx, hy) = out.header_origin;
    let cursor = dialog::text_field(f.buffer_mut(), hx, hy + 1, out.inner_width, &text.text(), text.cursor(), placeholder, &c);
    app.dialog_rect = state.rect;
    app.buttons.extend(btns);
    app.dialog = state;
    f.set_cursor_position(cursor);
}

fn draw_add_host(f: &mut ratatui::Frame, area: Rect, text: &super::editor::Editor, app: &mut App, hover: Option<(u16, u16)>) {
    draw_text_dialog(f, area, app, hover, "Add host", "ssh host, as you would type after `ssh`", text, "user@host  or  hostname", "acpmux opens the tunnel and reads the remote token over ssh", "[ Add ⏎ ]");
}

fn draw_directory(f: &mut ratatui::Frame, area: Rect, text: &super::editor::Editor, app: &mut App, hover: Option<(u16, u16)>) {
    let live = !app.on_draft();
    let note = if live { "a running agent cannot move: this opens a new session tab in the new directory" } else { "the new session starts here" };
    draw_text_dialog(f, area, app, hover, "Working directory", "absolute path, or ~/…", text, "/path/to/project", note, if live { "[ New session here ⏎ ]" } else { "[ Set ⏎ ]" });
}

fn draw_confirm(f: &mut ratatui::Frame, area: Rect, title: &str, app: &mut App, hover: Option<(u16, u16)>) {
    let c = app.chrome;
    let spec = DialogSpec {
        title: "Confirm",
        header: vec![spans(&[(title, c.prompt())])],
        rows: vec![],
        selected: None,
        reveal: false,
        hint: "",
        buttons: vec![("[ No n ]", false, ButtonAction::ConfirmNo), ("[ Yes y ]", true, ButtonAction::ConfirmYes)],
        close_button: false,
        min_width: 40,
        max_width: 80,
    };
    let mut state = std::mem::take(&mut app.dialog);
    let mut btns = Vec::new();
    dialog::draw(f.buffer_mut(), area, &c, hover, spec, &mut state, &mut btns);
    app.dialog_rect = state.rect;
    app.buttons.extend(btns);
    app.dialog = state;
}

fn draw_help(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let hover = app.hover;
    let rows: Vec<DialogRow> = HELP_ROWS
        .iter()
        .map(|(key, what)| {
            if key.is_empty() && !what.is_empty() {
                DialogRow { spans: vec![(what.to_string(), c.prompt_title())], selectable: false, note: None }
            } else if key.is_empty() {
                DialogRow { spans: vec![], selectable: false, note: None }
            } else {
                DialogRow { spans: vec![(format!("{key:<22}"), c.prompt().fg(c.prompt_title_fg)), (what.to_string(), c.prompt())], selectable: false, note: None }
            }
        })
        .collect();
    let spec = DialogSpec { title: "Keys", header: vec![], rows, selected: None, reveal: false, hint: "wheel or PgUp/PgDn to scroll", buttons: vec![], close_button: true, min_width: 60, max_width: 80 };
    let mut state = std::mem::take(&mut app.dialog);
    let mut btns = Vec::new();
    dialog::draw(f.buffer_mut(), area, &c, hover, spec, &mut state, &mut btns);
    app.dialog_rect = state.rect;
    app.buttons.extend(btns);
    app.dialog = state;
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
