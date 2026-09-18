//! Part of the TUI renderer; see `render/mod.rs`.

use super::*;

pub(super) fn draw_composer(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let focused = matches!(app.focus, Focus::Input | Focus::Command) && matches!(app.overlay, Overlay::None);
    let hover = app.hover;
    let buf = f.buffer_mut();
    // Codex's shape: a blank row, `› text`, then the controls row. No rules.
    let text_area = Rect { x: area.x + COMPOSER_INDENT, y: area.y + 1, width: area.width.saturating_sub(COMPOSER_INDENT + 1), height: area.height.saturating_sub(2) };
    let prompt_style = if focused { Style::default().add_modifier(Modifier::BOLD) } else { c.dim() };
    buf.set_stringn(area.x, text_area.y, "›", 1, prompt_style);
    if app.focus == Focus::Command {
        let content = format!("/{}", app.command.text());
        buf.set_stringn(text_area.x, text_area.y, &content, text_area.width as usize, Style::default().fg(c.warn_fg));
        if focused {
            let col = 1 + app.command.text().chars().take(app.command.cursor()).collect::<String>().width() as u16;
            { let p: (u16, u16) = (text_area.x + col.min(text_area.width), text_area.y); app.cursor_pos = Some(p); f.set_cursor_position(p); }
        }
    } else {
        let width = text_area.width.max(1) as usize;
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
        if app.editor().is_empty() {
            let hint = if app.on_draft() { "Ask anything… Enter starts the session" } else if app.selected_supports_steer() { "Ask anything… Ctrl-s steers a running turn" } else { "Ask anything…" };
            buf.set_stringn(text_area.x, text_area.y, hint, width, c.dim());
        }
        let sel = app.composer_sel.map(|(a, b)| (a.min(b), a.max(b))).filter(|(a, b)| a != b);
        for (i, row) in rows.iter().enumerate().skip(scroll).take(visible) {
            let y = text_area.y + (i - scroll) as u16;
            buf.set_stringn(text_area.x, y, &app.editor().row_text(*row), width, Style::default());
            if let Some((a, b)) = sel {
                // Paint the selected chars of this row.
                let (rs, re) = *row;
                let from = a.max(rs);
                let to = b.min(re);
                if from < to {
                    let text = app.editor().row_text(*row);
                    let col_of = |n: usize| text.chars().take(n - rs).collect::<String>().width() as u16;
                    let (x0, x1) = (col_of(from), col_of(to));
                    for x in x0..x1.min(text_area.width) {
                        if let Some(cell) = buf.cell_mut((text_area.x + x, y)) {
                            cell.set_bg(c.selection_bg);
                        }
                    }
                }
            }
        }
        if rows.len() > visible {
            let track = Rect { x: area.x + area.width - 1, y: text_area.y, width: 1, height: text_area.height };
            let thumb = crate::tui::scroll::thumb_geometry(rows.len(), visible, scroll, track.height);
            draw_thumb(buf, track, thumb, c.scrollbar_thumb_fg, c.scrollbar_thumb_active_fg, crate::tui::scroll::ThumbState::Idle);
        }
        if focused {
            { let p: (u16, u16) = (text_area.x + (cur_col as u16).min(text_area.width), text_area.y + (cur_row - scroll) as u16); app.cursor_pos = Some(p); f.set_cursor_position(p); }
        }
    }
    draw_controls(f, Rect { x: area.x, y: area.y + area.height - 1, width: area.width, height: 1 }, app, hover);
}

/// The row under the composer: every session setting as a clickable chip,
/// like Claude Code's `⏵⏵ accept edits on` line. Each chip opens its picker.
fn draw_controls(f: &mut ratatui::Frame, area: Rect, app: &mut App, hover: Option<(u16, u16)>) {
    let c = app.chrome;
    let on_draft = app.on_draft();
    let (mode, model) = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .map(|t| (t.mode.clone().unwrap_or_default(), t.model.clone().unwrap_or_default()))
        .unwrap_or_default();
    let (agent, cwd, policy, model_shown, thinking) = if let Some(d) = app.draft() {
        let a = match &d.peer { Some(p) => format!("{p}/{}", d.agent), None => d.agent.clone() };
        (a, d.cwd.clone(), d.policy.clone(), d.model.clone().unwrap_or_else(|| "default".into()), d.effort.clone().unwrap_or_else(|| "default".into()))
    } else {
        let s = app.selected_session();
        let a = s.and_then(|s| s.get("agent").and_then(Value::as_str)).unwrap_or("").to_owned();
        let cwd = s.and_then(|s| s.get("cwd").and_then(Value::as_str)).unwrap_or("").to_owned();
        let policy = s.and_then(|s| s.get("policy").and_then(Value::as_str)).unwrap_or("ask").to_owned();
        let thinking = app
            .selected_id()
            .and_then(|id| app.details.get(&id))
            .and_then(|d| d.get("configOptions").and_then(Value::as_array).cloned())
            .and_then(|opts| {
                ["effort", "reasoning_effort", "thought_level", "thinking", "reasoning"].iter().find_map(|k| {
                    opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some(k)).and_then(|o| o.get("currentValue").and_then(Value::as_str).map(str::to_owned))
                })
            })
            .unwrap_or_default();
        (a, cwd, policy, model, thinking)
    };
    let buf = f.buffer_mut();
    let mut x = area.x + COMPOSER_INDENT;
    let mut first = true;
    let mut chips: Vec<(Rect, ButtonAction)> = Vec::new();
    let mut chip = |buf: &mut Buffer, text: String, action: Option<ButtonAction>, accent: bool| {
        if text.is_empty() {
            return;
        }
        if !first {
            let sep = " · ";
            let w = (sep.width() as u16).min((area.x + area.width).saturating_sub(x));
            buf.set_stringn(x, area.y, sep, w as usize, c.dim());
            x += w;
        }
        first = false;
        let w = (text.width() as u16).min((area.x + area.width).saturating_sub(x));
        if w == 0 {
            return;
        }
        let r = Rect { x, y: area.y, width: w, height: 1 };
        let hovered = action.is_some() && hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
        let style = if hovered {
            Style::default().bg(c.status_active_bg).fg(c.status_active_fg)
        } else if accent {
            Style::default().fg(c.prompt_button_accent_fg)
        } else {
            c.dim()
        };
        buf.set_stringn(x, area.y, &text, w as usize, style);
        if let Some(a) = action {
            chips.push((r, a));
        }
        x += w;
    };
    if !on_draft && !mode.is_empty() {
        chip(buf, format!("⏵⏵ {}", mode_label(&mode)), Some(ButtonAction::PickMode), true);
    }
    let model_value = if on_draft { format!("{agent} · {}", if model_shown.is_empty() { "default" } else { &model_shown }) } else if model_shown.is_empty() { "default model".into() } else { model_shown.clone() };
    chip(buf, model_value, Some(ButtonAction::PickModel), false);
    if !thinking.is_empty() {
        chip(buf, format!("◉ {thinking}"), Some(ButtonAction::PickThinking), false);
    }
    chip(buf, format!("perms {policy}"), Some(ButtonAction::PickPolicy), false);
    chip(buf, shorten_path(&cwd), Some(ButtonAction::EditDirectory), false);
    // Right side: the help hint.
    let help = "? keys · / commands";
    let hw = help.width() as u16;
    if x + hw + 2 < area.x + area.width {
        let r = Rect { x: area.x + area.width - hw - 1, y: area.y, width: hw, height: 1 };
        let hovered = hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
        buf.set_stringn(r.x, r.y, help, hw as usize, if hovered { Style::default().bg(c.status_active_bg).fg(c.status_active_fg) } else { c.dim() });
        chips.push((r, ButtonAction::Help));
    }
    app.buttons.extend(chips);
}

/// Claude Code's wording for its permission modes; other harnesses show
/// their mode id as is.
fn mode_label(mode: &str) -> String {
    match mode {
        "default" => "normal".into(),
        "acceptEdits" => "accept edits".into(),
        "plan" => "plan mode".into(),
        "bypassPermissions" => "bypass".into(),
        "auto" => "auto mode".into(),
        other => other.to_owned(),
    }
}

