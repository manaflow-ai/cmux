//! Part of the TUI renderer; see `render/mod.rs`.
//!
//! The sidebar follows the Codex app's rail: a shaded column with "New
//! session" at the top, sessions grouped under their project (the session
//! directory's last segment, prefixed by the host for remote ones), one
//! line per session with a status mark at the right edge, and "Add host"
//! pinned to the bottom. No vertical rule: the shade is the edge.

use super::*;

enum Entry {
    Header(String, Option<String>),
    Row(usize),
    Blank,
    /// "Show more (N)" under a group that is cut at its first rows.
    More(String, usize),
}

/// Rows a project shows before "Show more", as in the Codex app.
const GROUP_ROWS: usize = 6;

pub(super) fn draw_sidebar(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let buf = f.buffer_mut();
    let ground = Style::default().bg(c.sidebar_bg);
    fill(buf, area, ground);
    let focused = app.focus == Focus::Sidebar;
    let content_w = area.width.saturating_sub(1) as usize;
    let hovered_row = |hover: Option<(u16, u16)>, y: u16| {
        hover
            .map(|(hx, hy)| hy == y && hx >= area.x && hx < area.x + area.width - 1)
            .unwrap_or(false)
    };
    let paint_row = |buf: &mut Buffer, y: u16, style: Style| {
        for x in area.x..area.x + area.width - 1 {
            if let Some(cell) = buf.cell_mut((x, y)) {
                cell.set_style(style);
            }
        }
    };
    // Top action.
    {
        let label = match app.host_filter.as_deref() {
            Some("local") => "New session on mac".to_owned(),
            Some(h) => format!("New session on {h}"),
            None => "New session".to_owned(),
        };
        let rect = Rect { x: area.x, y: area.y, width: area.width - 1, height: 1 };
        let hot = hovered_row(app.hover, rect.y) || (focused && app.selected == usize::MAX);
        let style = if hot {
            ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
        } else {
            ground.fg(c.status_fg)
        };
        if hot {
            paint_row(buf, rect.y, style);
        }
        buf.set_stringn(area.x + 1, area.y, "✎", 1, style.fg(c.muted_fg));
        buf.set_stringn(area.x + 3, area.y, &label, content_w.saturating_sub(3), style);
        app.buttons.push((rect, ButtonAction::NewDraft));
    }
    // Footer.
    let footer_h: u16 = if area.height > 6 { 2 } else { 0 };
    if footer_h > 0 {
        let y = area.y + area.height - 1;
        let rect = Rect { x: area.x, y, width: area.width - 1, height: 1 };
        let hot = hovered_row(app.hover, y);
        let style = if hot {
            ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
        } else {
            ground.fg(c.muted_fg)
        };
        if hot {
            paint_row(buf, y, style);
        }
        buf.set_stringn(area.x + 1, y, "+", 1, style);
        buf.set_stringn(area.x + 3, y, "Add host", content_w.saturating_sub(3), style);
        app.buttons.push((rect, ButtonAction::AddHost));
    }
    // Rows: drafts first, then sessions grouped by host and project.
    let mut rows: Vec<Value> = Vec::with_capacity(app.sessions.len() + app.drafts.len());
    for d in &app.drafts {
        let preview = d.text.text();
        let title = if preview.trim().is_empty() {
            "Draft".to_owned()
        } else {
            preview.lines().next().unwrap_or("").to_owned()
        };
        rows.push(serde_json::json!({"name": title, "status": if d.creating { "running" } else { "draft" }, "draft": true, "cwd": d.cwd, "peer": d.peer}));
    }
    rows.extend(app.sessions.iter().cloned());
    let filtered: Vec<usize> = (0..rows.len()).filter(|i| app.row_visible(*i)).collect();
    // Every session of a project sits under one header; groups are ordered
    // by their most recent session (the list is already recency-sorted).
    let group_of = |s: &Value| -> String {
        if s.get("draft").and_then(Value::as_bool).unwrap_or(false) {
            return String::new();
        }
        let cwd = s.get("cwd").and_then(Value::as_str).unwrap_or("");
        let project = project_label(cwd);
        match s.get("peer").and_then(Value::as_str) {
            Some(p) => format!("{p} · {project}"),
            None => project,
        }
    };
    let mut order: Vec<String> = Vec::new();
    let mut members: std::collections::HashMap<String, Vec<usize>> =
        std::collections::HashMap::new();
    for &i in &filtered {
        let g = group_of(&rows[i]);
        if !members.contains_key(&g) {
            order.push(g.clone());
        }
        members.entry(g).or_default().push(i);
    }
    let mut entries: Vec<Entry> = Vec::new();
    let selected = app.selected;
    for g in order {
        let idxs = members.remove(&g).unwrap_or_default();
        if !g.is_empty() {
            if !entries.is_empty() {
                entries.push(Entry::Blank);
            }
            let cwd = idxs.iter().find_map(|&i| {
                let s = &rows[i];
                (s.get("peer").is_none())
                    .then(|| s.get("cwd").and_then(Value::as_str).map(str::to_owned))
                    .flatten()
            });
            entries.push(Entry::Header(g.clone(), cwd));
        }
        // A long group shows its first rows and a "Show more"; the group
        // holding the selection is always open so the keys can reach it.
        let open = g.is_empty()
            || app.expanded_groups.contains(&g)
            || idxs.len() <= GROUP_ROWS + 1
            || idxs.iter().skip(GROUP_ROWS).any(|&i| i == selected);
        if open {
            entries.extend(idxs.into_iter().map(Entry::Row));
        } else {
            let hidden = idxs.len() - GROUP_ROWS;
            entries.extend(idxs.into_iter().take(GROUP_ROWS).map(Entry::Row));
            entries.push(Entry::More(g, hidden));
        }
    }
    let body_y = area.y + 2;
    let body_h = area.height.saturating_sub(2 + footer_h) as usize;
    let sel_pos =
        entries.iter().position(|e| matches!(e, Entry::Row(i) if *i == selected)).unwrap_or(0);
    let offset = if body_h == 0 {
        0
    } else {
        sel_pos.saturating_sub(body_h.saturating_sub(1)).min(entries.len().saturating_sub(body_h))
    };
    app.sidebar_offset = offset;
    app.sidebar_rows.clear();
    app.sidebar_order = entries
        .iter()
        .filter_map(|e| match e {
            Entry::Row(i) => Some(*i),
            _ => None,
        })
        .collect();
    for (line, entry) in entries.iter().skip(offset).take(body_h).enumerate() {
        let y = body_y + line as u16;
        match entry {
            Entry::Blank => {}
            Entry::More(group, hidden) => {
                let label = format!("Show more ({hidden})");
                let rect = Rect { x: area.x, y, width: area.width - 1, height: 1 };
                let hot = hovered_row(app.hover, y);
                let style = if hot {
                    ground.bg(c.sidebar_selected_bg).fg(c.status_fg)
                } else {
                    ground.fg(c.sidebar_dim_fg)
                };
                if hot {
                    paint_row(buf, y, style);
                }
                buf.set_stringn(area.x + 3, y, &label, content_w.saturating_sub(4), style);
                app.buttons.push((rect, ButtonAction::ShowGroup(group.clone())));
            }
            Entry::Header(name, cwd) => {
                buf.set_stringn(area.x + 1, y, "▢", 1, ground.fg(c.sidebar_dim_fg));
                let plus_w = if cwd.is_some() { 3 } else { 0 };
                let name_w = content_w.saturating_sub(4 + plus_w);
                buf.set_stringn(
                    area.x + 3,
                    y,
                    truncate(name, name_w),
                    name_w,
                    ground.fg(c.sidebar_dim_fg),
                );
                if let Some(path) = cwd {
                    let x = area.x + area.width.saturating_sub(4);
                    let hot =
                        app.hover.map(|(hx, hy)| hy == y && hx >= x && hx < x + 3).unwrap_or(false);
                    let style = if hot {
                        ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
                    } else {
                        ground.fg(c.sidebar_dim_fg)
                    };
                    buf.set_stringn(x, y, "+", 1, style);
                    app.buttons.push((
                        Rect { x, y, width: 3, height: 1 },
                        ButtonAction::NewProject(path.clone()),
                    ));
                }
            }
            Entry::Row(idx) => {
                let idx = *idx;
                let s = &rows[idx];
                let is_sel = idx == selected;
                let is_draft = s.get("draft").and_then(Value::as_bool).unwrap_or(false);
                let name_owned = if is_draft {
                    s.get("name").and_then(Value::as_str).unwrap_or("Draft").to_owned()
                } else {
                    let t = session_title(s);
                    match s.get("peer").and_then(Value::as_str) {
                        Some(p) => t.strip_prefix(&format!("{p}/")).map(str::to_owned).unwrap_or(t),
                        None => t,
                    }
                };
                let name = name_owned.as_str();
                let status = s.get("status").and_then(Value::as_str).unwrap_or("");
                let pending = s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
                let sid = s.get("sessionId").and_then(Value::as_str).unwrap_or("");
                let dot = app.attention.get(sid).copied().unwrap_or(0);
                let hot = hovered_row(app.hover, y);
                let row_style = if is_sel {
                    ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
                } else if hot {
                    ground.bg(c.sidebar_selected_bg).fg(c.status_fg)
                } else if status == "closed" {
                    ground.fg(c.sidebar_dim_fg)
                } else {
                    ground.fg(c.status_fg)
                };
                if is_sel || hot {
                    paint_row(buf, y, row_style);
                }
                // Mark at the right edge: a question for a pending permission,
                // a dot for work that ended unseen, a spinner glyph while running.
                let (mark, mark_style): (&str, Style) = if is_draft {
                    ("", row_style)
                } else if pending {
                    ("?", row_style.fg(c.attention_fg).add_modifier(Modifier::BOLD))
                } else if status == "running" {
                    ("●", row_style.fg(c.warn_fg))
                } else if status == "waiting" {
                    ("?", row_style.fg(c.attention_fg))
                } else if matches!(status, "disconnected" | "unreachable") {
                    ("!", row_style.fg(c.error_fg))
                } else if dot > 0 && !is_sel {
                    (
                        "•",
                        row_style.fg(match dot {
                            3 => c.error_fg,
                            2 => c.attention_fg,
                            _ => c.ok_fg,
                        }),
                    )
                } else {
                    ("", row_style)
                };
                let indent: u16 = if is_draft { 1 } else { 3 };
                let name_w =
                    content_w.saturating_sub(indent as usize + if mark.is_empty() { 1 } else { 3 });
                let shown = if is_draft { format!("✎ {name}") } else { name.to_owned() };
                buf.set_stringn(
                    area.x + indent,
                    y,
                    truncate(&shown, name_w),
                    name_w,
                    if is_sel { row_style.add_modifier(Modifier::BOLD) } else { row_style },
                );
                if !mark.is_empty() {
                    buf.set_stringn(area.x + area.width - 3, y, mark, 1, mark_style);
                }
                app.sidebar_rows
                    .push((Rect { x: area.x, y, width: area.width - 1, height: 1 }, idx));
            }
        }
    }
    if filtered.is_empty() && body_h > 1 {
        let what = match app.host_filter.as_deref() {
            Some("local") => "No sessions on this Mac".to_owned(),
            Some(h) => format!("No sessions on {h}"),
            None => "No sessions yet".to_owned(),
        };
        buf.set_stringn(area.x + 1, body_y, &what, content_w, ground.fg(c.sidebar_dim_fg));
        buf.set_stringn(
            area.x + 1,
            body_y + 1,
            "Ctrl-t starts one",
            content_w,
            ground.fg(c.sidebar_dim_fg),
        );
    }
    // Scrollbar at the inner edge when the list overflows.
    if entries.len() > body_h && body_h > 0 {
        let track = Rect { x: area.x + area.width - 2, y: body_y, width: 1, height: body_h as u16 };
        let thumb = crate::tui::scroll::thumb_geometry(entries.len(), body_h, offset, track.height);
        draw_thumb(
            buf,
            track,
            thumb,
            c.scrollbar_thumb_fg,
            c.scrollbar_thumb_active_fg,
            crate::tui::scroll::ThumbState::Idle,
        );
    }
    // The resize handle column stays the sidebar shade; a hover or drag
    // shows a thin mark so the affordance is discoverable.
    let rule_x = area.x + area.width - 1;
    let rule_hot =
        app.sidebar_drag.is_some() || app.hover.map(|(hx, _)| hx == rule_x).unwrap_or(false);
    if rule_hot {
        for y in area.y..area.y + area.height {
            if let Some(cell) = buf.cell_mut((rule_x, y)) {
                cell.set_symbol("▏").set_style(ground.fg(c.border_active_fg));
            }
        }
    }
}
