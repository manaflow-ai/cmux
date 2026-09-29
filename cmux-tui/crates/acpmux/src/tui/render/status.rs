//! Part of the TUI renderer; see `render/mod.rs`.

use super::*;

pub(super) fn draw_status(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
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
    // Right side: a click opens the web dashboard (the URL carries a token,
    // so it is not printed).
    let mut right_x = area.x + area.width;
    if app.web_url.is_some() {
        let right = " web dashboard ↗ ";
        let rw = right.width() as u16;
        if x + rw < right_x {
            let r = Rect { x: right_x - rw, y: area.y, width: rw, height: 1 };
            let hovered = app.hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
            buf.set_stringn(r.x, r.y, right, rw as usize, if hovered { c.status().bg(c.status_active_bg).fg(c.prompt_button_accent_fg) } else { c.status_dim() });
            app.buttons.push((r, ButtonAction::Web));
            right_x = r.x;
        }
    }
    {
        let keys = format!(" ? keys · {} commands ", app.palette_prefix);
        let kw = keys.width() as u16;
        if x + kw < right_x {
            let r = Rect { x: right_x - kw, y: area.y, width: kw, height: 1 };
            let hovered = app.hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
            buf.set_stringn(r.x, r.y, &keys, kw as usize, if hovered { c.status().bg(c.status_active_bg).fg(c.prompt_button_accent_fg) } else { c.status_dim() });
            app.buttons.push((r, ButtonAction::Help));
        }
    }
    app.host_chips = chips;
}

