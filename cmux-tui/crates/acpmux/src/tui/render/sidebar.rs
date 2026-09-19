//! Part of the TUI renderer; see `render/mod.rs`.

use super::*;

pub(super) fn draw_sidebar(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
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
    // Header row: the new-session action, like a cmux rail's top action.
    {
        let label = match app.host_filter.as_deref() {
            Some("local") => "+ new session on mac".to_owned(),
            Some(h) => format!("+ new session on {h}"),
            None => "+ new session".to_owned(),
        };
        let rect = Rect { x: area.x, y: area.y, width: area.width - 1, height: 1 };
        let hovered = app.hover.map(|(hx, hy)| hy == rect.y && hx >= rect.x && hx < rect.x + rect.width).unwrap_or(false);
        let style = if hovered {
            Style::default().bg(c.prompt_button_hover_bg).fg(c.prompt_button_accent_fg).add_modifier(Modifier::BOLD)
        } else if focused {
            Style::default().bg(c.status_active_bg).fg(c.prompt_button_accent_fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(c.prompt_button_accent_fg)
        };
        if hovered || focused {
            for x in rect.x..rect.x + rect.width {
                if let Some(cell) = buf.cell_mut((x, rect.y)) {
                    cell.set_style(style);
                }
            }
        }
        buf.set_stringn(area.x + 1, area.y, &label, content_w.saturating_sub(1), style);
        app.buttons.push((rect, ButtonAction::NewDraft));
    }
    // Footer actions pinned to the bottom, like a cmux rail: they keep
    // their rows even on a short terminal so they stay reachable.
    let footer: [(&str, ButtonAction); 1] = [("+ add host", ButtonAction::AddHost)];
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
        let agent_label = match &d.peer { Some(p) => format!("{p}/{}", d.harness), None => d.harness.clone() };
        rows.push(serde_json::json!({"name": "new session", "status": if d.creating { "running" } else { "draft" }, "harness": agent_label, "lastPrompt": sub, "draft": true}));
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
        let agent = s.get("harness").and_then(Value::as_str).unwrap_or("");
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
        let tags: Vec<String> = s.get("tags").and_then(Value::as_object).map(|m| m.iter().map(|(k, v)| format!("{k}={}", v.as_str().unwrap_or(""))).collect()).unwrap_or_default();
        let sub_text = s
            .get("lastPrompt")
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
            .map(|t| format!("{agent} · {t}"))
            .unwrap_or_else(|| format!("{agent} · {status}"));
        // Orchestrator tags lead the subtitle so a labelled session stands out.
        let sub_text = if tags.is_empty() { sub_text } else { format!("[{}] {sub_text}", tags.join(" ")) };

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
        let thumb = crate::tui::scroll::thumb_geometry(total, visible, offset * rows_per, track.height);
        draw_thumb(buf, track, thumb, c.scrollbar_thumb_fg, c.scrollbar_thumb_active_fg, crate::tui::scroll::ThumbState::Idle);
    }
}

