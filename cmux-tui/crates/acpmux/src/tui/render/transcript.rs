//! Part of the TUI renderer; see `render/mod.rs`.

use super::*;

pub(super) fn draw_transcript(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let buf = f.buffer_mut();
    fill(buf, area, Style::default());
    // Title row: name, status, and token usage. Settings live under the
    // composer.
    let title_y = area.y;
    let name = {
        let raw = app.selected_session().map(session_title).unwrap_or_else(|| app.selected_name());
        let peer = app.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str)).map(str::to_owned);
        let stripped = match peer { Some(p) => raw.strip_prefix(&format!("{p}/")).map(str::to_owned).unwrap_or(raw), None => raw };
        truncate(&stripped, 64)
    };
    let (status, mode, model) = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .map(|t| (t.status.clone(), t.mode.clone().unwrap_or_default(), t.model.clone().unwrap_or_default()))
        .unwrap_or_default();
    let usage = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .and_then(|t| t.usage)
        .map(|(u, s)| if s > 0 { format!("{}k / {}k", u / 1000, s / 1000) } else { format!("{}k tokens", u / 1000) })
        .unwrap_or_default();
    {
        // Codex app header: "▢ project  ›  title", status only when it
        // needs attention, token use at the right edge.
        let buf = f.buffer_mut();
        let project = app
            .selected_session()
            .and_then(|s| {
                let cwd = s.get("cwd").and_then(Value::as_str)?;
                let base = project_label(cwd);
                Some(match s.get("peer").and_then(Value::as_str) { Some(p) => format!("{p} · {base}"), None => base })
            })
            .or_else(|| app.draft().map(|d| project_label(&d.cwd)))
            .unwrap_or_default();
        let mut x = area.x + 2;
        let right = area.x + area.width;
        let put = |buf: &mut Buffer, x: &mut u16, text: &str, style: Style| {
            let w = (text.width() as u16).min(right.saturating_sub(*x));
            if w > 0 {
                buf.set_stringn(*x, title_y, text, w as usize, style);
                *x += w;
            }
        };
        if !project.is_empty() {
            put(buf, &mut x, "▢ ", c.dim());
            put(buf, &mut x, &project, c.muted());
            put(buf, &mut x, "  ›  ", c.dim());
        }
        let name_style = if app.focus == Focus::Transcript && matches!(app.overlay, Overlay::None) {
            Style::default().fg(c.border_active_fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().add_modifier(Modifier::BOLD)
        };
        put(buf, &mut x, &name, name_style);
        let attention = matches!(status.as_str(), "waiting" | "disconnected" | "unreachable" | "closed");
        if attention {
            let word = match status.as_str() { "waiting" => "needs permission", other => other };
            put(buf, &mut x, &format!("   {word}"), status_fg(&c, &status));
        }
        let uw = usage.width() as u16;
        if !usage.is_empty() && x + uw + 2 < right {
            buf.set_stringn(right - uw - 2, title_y, &usage, uw as usize, c.dim());
        }
        let _ = (&mode, &model);
    }
    let hover = app.hover;
    let buf = f.buffer_mut();
    let inner = app.transcript_inner();
    if let Some(d) = app.draft() {
        // Codex app: a centered headline naming the project, the settings
        // as one muted line under it. The composer below is where to type.
        let project = project_label(&d.cwd);
        let headline = format!("What should we build in {project}?");
        let effort = d.effort.as_deref().filter(|e| !e.is_empty() && *e != "default").map(|e| format!("  ·  {}", effort_label(e))).unwrap_or_default();
        let settings = format!(
            "{}{}  ·  {}{}  ·  {}",
            d.peer.as_deref().map(|p| format!("{p} / ")).unwrap_or_default(),
            d.harness,
            d.model.as_deref().map(model_label).unwrap_or_else(|| "default model".to_owned()),
            effort,
            crate::tui::render::composer::policy_label(&d.policy).0
        );
        let top = inner.y + inner.height / 3;
        let center = |buf: &mut Buffer, y: u16, text: &str, style: Style| {
            if y < inner.y + inner.height {
                let w = text.width().min(inner.width as usize);
                let x = inner.x + (inner.width as usize - w) as u16 / 2;
                buf.set_stringn(x, y, text, w, style);
            }
        };
        center(buf, top, &headline, Style::default().add_modifier(Modifier::BOLD));
        center(buf, top + 2, &settings, c.muted());
        center(buf, top + 4, "Type below and press Enter to start · Esc discards", c.dim());
        let mut y = top + 6;
        if d.creating {
            let label = format!("Starting {}…", d.harness);
            let w = label.width().min(inner.width as usize);
            let x = inner.x + (inner.width as usize - w) as u16 / 2;
            let spans = crate::tui::shimmer::spans(&label, c.shimmer_base, c.shimmer_bright);
            f_render(buf, Paragraph::new(Line::from(spans)), Rect { x, y, width: w as u16, height: 1 });
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
        let top = inner.y + inner.height / 3;
        let center = |buf: &mut Buffer, y: u16, text: &str, style: Style| {
            if y < inner.y + inner.height {
                let w = text.width().min(inner.width as usize);
                let x = inner.x + (inner.width as usize - w) as u16 / 2;
                buf.set_stringn(x, y, text, w, style);
            }
        };
        center(buf, top, "What should we build?", Style::default().add_modifier(Modifier::BOLD));
        center(buf, top + 2, "Ctrl-t starts a session: pick a harness, name it, choose a directory", c.muted());
        center(buf, top + 3, "?  every key        /  every command", c.dim());
        center(buf, top + 5, "From a shell:  acpmux new -m claude -n my-task", c.dim());
        return;
    };
    let Some(t) = app.transcripts.get(&id) else {
        buf.set_stringn(inner.x, inner.y, "loading…", inner.width as usize, c.dim());
        return;
    };
    if t.items.is_empty() && t.status != "running" {
        let project = app
            .selected_session()
            .and_then(|s| s.get("cwd").and_then(Value::as_str))
            .map(project_label)
            .unwrap_or_default();
        let headline = if project.is_empty() { "What should we build?".to_owned() } else { format!("What should we build in {project}?") };
        let top = inner.y + inner.height / 3;
        let w = headline.width().min(inner.width as usize);
        buf.set_stringn(inner.x + (inner.width as usize - w) as u16 / 2, top, &headline, w, Style::default().add_modifier(Modifier::BOLD));
        let sub = "Type below and press Enter";
        let sw = sub.width().min(inner.width as usize);
        buf.set_stringn(inner.x + (inner.width as usize - sw) as u16 / 2, top + 2, sub, sw, c.dim());
        return;
    }
    let empty = std::collections::HashSet::new();
    let toggled = app.toggled.get(&id).unwrap_or(&empty);
    let rows = transcript_rows(t, inner.width as usize, app.show_thoughts, app.show_system, toggled, &c);
    let track = Rect { x: area.x + area.width - 1, y: inner.y, width: 1, height: inner.height };
    let cwd = app.selected_session().and_then(|s| s.get("cwd").and_then(Value::as_str)).unwrap_or("").to_owned();
    let mut link_runs: Vec<crate::tui::links::LinkCell> = Vec::new();
    let vp = app.viewport.entry(id.clone()).or_default();
    vp.layout(rows.len(), inner.height as usize, track);
    vp.hover = hover.map(|(hx, hy)| vp.track_contains(hx, hy)).unwrap_or(false);
    let offset = vp.offset;
    let sel = app.selection.as_ref().filter(|s| s.session == id).cloned();
    for (i, row) in rows.iter().enumerate().skip(offset).take(inner.height as usize) {
        let y = inner.y + (i - offset) as u16;
        let p = Paragraph::new(row.line.clone());
        f_render(buf, p, Rect { x: inner.x, y, width: inner.width, height: 1 });
        // Codex app: a collapsible row lights up under the pointer.
        if row.toggle.is_some() && hover.map(|(_, hy)| hy == y).unwrap_or(false) {
            let (lo, hi) = content_bounds(&row.text);
            for x in lo..hi.min(inner.width as usize) {
                if let Some(cell) = buf.cell_mut((inner.x + x as u16, y)) {
                    cell.set_style(cell.style().bg(c.prompt_button_hover_bg));
                }
            }
        }
        // URLs and paths become OSC 8 hyperlinks the terminal can Cmd-click;
        // the run is re-printed after the frame (see `links::paint`).
        for link in crate::tui::links::find(&row.text) {
            let href = crate::tui::links::href(&link.target, &cwd);
            let end = link.end.min(inner.width as usize);
            if link.start >= end {
                continue;
            }
            let mut text = String::new();
            let mut style = None;
            for col in link.start..end {
                if let Some(cell) = buf.cell((inner.x + col as u16, y)) {
                    text.push_str(cell.symbol());
                    style.get_or_insert(cell.style());
                }
            }
            link_runs.push(crate::tui::links::LinkCell { x: inner.x + link.start as u16, y, text, href, style: style.unwrap_or_default() });
        }
        if let Some(s) = &sel {
            if let Some((c0, c1)) = s.cols_on_row(i, &row.text) {
                for x in c0..c1.min(inner.width as usize) {
                    if let Some(cell) = buf.cell_mut((inner.x + x as u16, y)) {
                        cell.set_style(cell.style().patch(c.selection()));
                    }
                }
            }
        }
    }
    app.link_cells.extend(link_runs);
    app.row_meta = rows.iter().map(|r| (r.item, r.toggle)).collect();
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

