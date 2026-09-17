//! Part of the TUI renderer; see `render/mod.rs`.

use super::*;

pub(super) fn draw_transcript(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let buf = f.buffer_mut();
    fill(buf, area, Style::default());
    // Title row: name, status, and token usage. Settings live under the
    // composer.
    let title_y = area.y;
    let name = app.selected_name();
    let (status, mode, model) = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .map(|t| (t.status.clone(), t.mode.clone().unwrap_or_default(), t.model.clone().unwrap_or_default()))
        .unwrap_or_default();
    let usage = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .and_then(|t| t.usage)
        .map(|(u, s)| if s > 0 { format!("ctx {}k/{}k", u / 1000, s / 1000) } else { format!("{}k tokens", u / 1000) })
        .unwrap_or_default();
    {
        let buf = f.buffer_mut();
        let mut x = area.x + 1;
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
        let uw = usage.width() as u16;
        if !usage.is_empty() && x + uw + 2 < area.x + area.width {
            buf.set_stringn(area.x + area.width - uw - 1, title_y, &usage, uw as usize, c.dim());
        }
        let _ = (&mode, &model);
    }
    let hover = app.hover;
    let buf = f.buffer_mut();
    let inner = Rect { x: area.x + 1, y: area.y + 1, width: area.width.saturating_sub(3), height: area.height.saturating_sub(1) };
    if let Some(d) = app.draft() {
        let lines = [
            String::new(),
            format!("  {}{}  ·  {}  ·  {}  ·  {}", d.peer.as_deref().map(|p| format!("{p}/")).unwrap_or_default(), d.agent, d.model.as_deref().unwrap_or("default model"), shorten_path(&d.cwd), d.policy),
            String::new(),
            "  Type below and press Enter to start. The settings under the box are clickable. Esc discards.".into(),
        ];
        for (i, l) in lines.iter().enumerate() {
            if (i as u16) < inner.height {
                buf.set_stringn(inner.x, inner.y + i as u16, l, inner.width as usize, if i == 1 { Style::default() } else { c.dim() });
            }
        }
        let mut y = inner.y + 6;
        if d.creating {
            let mut spans = vec![Span::raw("  ")];
            spans.extend(crate::tui::shimmer::spans(&format!("Starting {}…", d.agent), c.shimmer_base, c.shimmer_bright));
            f_render(buf, Paragraph::new(Line::from(spans)), Rect { x: inner.x, y, width: inner.width, height: 1 });
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
            if let Some((c0, c1)) = s.cols_on_row(i, row.text.width()) {
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

