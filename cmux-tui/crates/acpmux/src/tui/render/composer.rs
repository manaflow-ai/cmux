//! Part of the TUI renderer; see `render/mod.rs`.
//!
//! The composer is a rounded box like the Codex app's: the text inside,
//! and one controls row along the bottom edge of the box. Left: the
//! permission chip (warm when it grants full access) and the harness mode.
//! Right: model and effort, and the send glyph. Every chip is clickable.

use super::*;

pub(super) fn draw_composer(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let focused =
        matches!(app.focus, Focus::Input | Focus::Command) && matches!(app.overlay, Overlay::None);
    let hover = app.hover;
    let buf = f.buffer_mut();
    if area.height < 3 || area.width < 8 {
        return;
    }
    // The box sits one column in from the transcript edge so its corners
    // do not touch the sidebar rule.
    let bx =
        Rect { x: area.x + 1, y: area.y, width: area.width.saturating_sub(2), height: area.height };
    let border = Style::default().fg(if focused {
        c.composer_border_focus_fg
    } else {
        c.composer_border_fg
    });
    rounded_border(buf, bx, border);
    let attachment_rows = u16::from(!app.prompt_images().is_empty());
    if attachment_rows > 0 {
        let label = app
            .prompt_images()
            .iter()
            .map(|i| format!("📎 {}", i.name))
            .collect::<Vec<_>>()
            .join("  ");
        buf.set_stringn(bx.x + 2, bx.y + 1, &label, bx.width.saturating_sub(4) as usize, c.muted());
    }
    let text_area = Rect {
        x: bx.x + 2,
        y: bx.y + 1 + attachment_rows,
        width: bx.width.saturating_sub(4),
        height: bx.height.saturating_sub(3 + attachment_rows),
    };
    if app.focus == Focus::Command {
        let content = format!("{}{}", app.palette_prefix, app.command.text());
        buf.set_stringn(
            text_area.x,
            text_area.y,
            &content,
            text_area.width as usize,
            Style::default().fg(c.warn_fg),
        );
        if focused {
            let col = app.palette_prefix.width() as u16
                + app.command.text().chars().take(app.command.cursor()).collect::<String>().width()
                    as u16;
            let p: (u16, u16) = (text_area.x + col.min(text_area.width), text_area.y);
            app.cursor_pos = Some(p);
            f.set_cursor_position(p);
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
            let hint = if app.on_draft() {
                "Ask anything. Enter starts the session"
            } else if app.selected_supports_steer() {
                "Ask anything. Ctrl-s steers a running turn"
            } else {
                "Ask anything"
            };
            buf.set_stringn(text_area.x, text_area.y, hint, width, c.dim());
        }
        let sel = app.composer_sel.map(|(a, b)| (a.min(b), a.max(b))).filter(|(a, b)| a != b);
        for (i, row) in rows.iter().enumerate().skip(scroll).take(visible) {
            let y = text_area.y + (i - scroll) as u16;
            buf.set_stringn(text_area.x, y, app.editor().row_text(*row), width, Style::default());
            if let Some((a, b)) = sel {
                let (rs, re) = *row;
                let from = a.max(rs);
                let to = b.min(re);
                if from < to {
                    let text = app.editor().row_text(*row);
                    let col_of =
                        |n: usize| text.chars().take(n - rs).collect::<String>().width() as u16;
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
            let track =
                Rect { x: bx.x + bx.width - 2, y: text_area.y, width: 1, height: text_area.height };
            let thumb =
                crate::tui::scroll::thumb_geometry(rows.len(), visible, scroll, track.height);
            draw_thumb(
                buf,
                track,
                thumb,
                c.scrollbar_thumb_fg,
                c.scrollbar_thumb_active_fg,
                crate::tui::scroll::ThumbState::Idle,
            );
        }
        if focused {
            let p: (u16, u16) = (
                text_area.x + (cur_col as u16).min(text_area.width),
                text_area.y + (cur_row - scroll) as u16,
            );
            app.cursor_pos = Some(p);
            f.set_cursor_position(p);
        }
    }
    draw_controls(
        f,
        Rect { x: bx.x + 2, y: bx.y + bx.height - 2, width: bx.width.saturating_sub(4), height: 1 },
        app,
        hover,
    );
}

/// A box with rounded corners.
pub fn rounded_border(buf: &mut Buffer, r: Rect, style: Style) {
    if r.width < 2 || r.height < 2 {
        return;
    }
    let (x0, y0, x1, y1) = (r.x, r.y, r.x + r.width - 1, r.y + r.height - 1);
    for x in x0 + 1..x1 {
        for y in [y0, y1] {
            if let Some(cell) = buf.cell_mut((x, y)) {
                cell.set_symbol("─").set_style(style);
            }
        }
    }
    for y in y0 + 1..y1 {
        for x in [x0, x1] {
            if let Some(cell) = buf.cell_mut((x, y)) {
                cell.set_symbol("│").set_style(style);
            }
        }
    }
    for (x, y, sym) in [(x0, y0, "╭"), (x1, y0, "╮"), (x0, y1, "╰"), (x1, y1, "╯")] {
        if let Some(cell) = buf.cell_mut((x, y)) {
            cell.set_symbol(sym).set_style(style);
        }
    }
}

/// The controls row inside the box: permission and mode on the left,
/// model and effort and the send glyph on the right.
fn draw_controls(f: &mut ratatui::Frame, area: Rect, app: &mut App, hover: Option<(u16, u16)>) {
    let c = app.chrome;
    let on_draft = app.on_draft();
    let (mode, model) = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .map(|t| (t.mode.clone().unwrap_or_default(), t.model.clone().unwrap_or_default()))
        .unwrap_or_default();
    let (agent, policy, model_shown, thinking) = if let Some(d) = app.draft() {
        let a = match &d.peer {
            Some(p) => format!("{p}/{}", d.harness),
            None => d.harness.clone(),
        };
        (
            a,
            d.policy.clone(),
            d.model.clone().unwrap_or_default(),
            d.effort.clone().unwrap_or_default(),
        )
    } else {
        let s = app.selected_session();
        let a = s.and_then(|s| s.get("harness").and_then(Value::as_str)).unwrap_or("").to_owned();
        let policy = s
            .and_then(|s| s.get("policy").and_then(Value::as_str))
            .unwrap_or("approve-all")
            .to_owned();
        let thinking = app
            .selected_id()
            .and_then(|id| app.details.get(&id))
            .and_then(|d| d.get("configOptions").and_then(Value::as_array).cloned())
            .and_then(|opts| {
                ["effort", "reasoning_effort", "thought_level", "thinking", "reasoning"]
                    .iter()
                    .find_map(|k| {
                        opts.iter()
                            .find(|o| o.get("id").and_then(Value::as_str) == Some(k))
                            .and_then(|o| {
                                o.get("currentValue").and_then(Value::as_str).map(str::to_owned)
                            })
                    })
            })
            .unwrap_or_default();
        (a, policy, model, thinking)
    };
    let buf = f.buffer_mut();
    let mut chips: Vec<(Rect, ButtonAction)> = Vec::new();
    let hovered_at = |r: Rect| {
        hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false)
    };
    // Left side.
    let mut x = area.x;
    let put = |buf: &mut Buffer,
               x: &mut u16,
               text: &str,
               style: Style,
               action: Option<ButtonAction>,
               chips: &mut Vec<(Rect, ButtonAction)>| {
        let w = (text.width() as u16).min((area.x + area.width).saturating_sub(*x));
        if w == 0 {
            return;
        }
        let r = Rect { x: *x, y: area.y, width: w, height: 1 };
        let style = if action.is_some() && hovered_at(r) {
            Style::default().bg(c.status_active_bg).fg(c.status_active_fg)
        } else {
            style
        };
        buf.set_stringn(*x, area.y, text, w as usize, style);
        if let Some(a) = action {
            chips.push((r, a));
        }
        *x += w;
    };
    let (policy_text, policy_style) = policy_visual(&policy, c);
    put(buf, &mut x, &policy_text, policy_style, Some(ButtonAction::PickPolicy), &mut chips);
    // Harness modes that are the plain default carry no information.
    if !on_draft
        && !mode.is_empty()
        && !matches!(mode.as_str(), "default" | "normal" | "agent" | "build")
    {
        put(buf, &mut x, "   ", Style::default(), None, &mut chips);
        put(buf, &mut x, &mode_label(&mode), c.muted(), Some(ButtonAction::PickMode), &mut chips);
    }
    // Right side, laid out from the edge: send glyph, then model · effort.
    let send = "↑";
    let send_style = if app.editor().is_empty() {
        c.dim()
    } else {
        Style::default().fg(c.status_active_fg).add_modifier(Modifier::BOLD)
    };
    let right_edge = area.x + area.width;
    let mut rx = right_edge.saturating_sub(1);
    {
        let r = Rect { x: rx, y: area.y, width: 1, height: 1 };
        let style = if hovered_at(r) {
            Style::default().bg(c.status_active_bg).fg(c.status_active_fg)
        } else {
            send_style
        };
        buf.set_stringn(rx, area.y, send, 1, style);
        chips.push((r, ButtonAction::Send));
    }
    let model_text = if on_draft {
        format!(
            "{agent}{}",
            if model_shown.is_empty() {
                String::new()
            } else {
                format!(" · {}", model_label(&model_shown))
            }
        )
    } else if model_shown.is_empty() || model_shown == "default" {
        format!("{agent} · default")
    } else {
        model_label(&model_shown)
    };
    let effort_text = if thinking.is_empty() || thinking == "default" {
        String::new()
    } else {
        effort_label(&thinking)
    };
    let mut pieces: Vec<(String, ButtonAction)> = vec![(model_text, ButtonAction::PickModel)];
    if !effort_text.is_empty() {
        pieces.push((effort_text, ButtonAction::PickThinking));
    }
    let total: u16 = pieces.iter().map(|(t, _)| t.width() as u16).sum::<u16>()
        + (pieces.len() as u16 - 1) * 3
        + 3;
    if rx > x + total {
        rx = rx.saturating_sub(total);
        let mut cx = rx;
        for (i, (text, action)) in pieces.iter().enumerate() {
            if i > 0 {
                put(buf, &mut cx, " · ", c.dim(), None, &mut chips);
            }
            put(buf, &mut cx, text, c.muted(), Some(action.clone()), &mut chips);
        }
    }
    app.buttons.extend(chips);
}

/// Codex's wording for the permission policy, and whether it is the warm
/// "full access" chip.
pub(crate) fn policy_label(policy: &str) -> (String, bool) {
    match policy {
        "approve-all" => ("Full access".into(), true),
        "approve-edits" => ("Edits allowed".into(), false),
        "approve-reads" => ("Reads allowed".into(), false),
        "deny-all" => ("Read-only".into(), false),
        _ => ("Ask before acting".into(), false),
    }
}

fn policy_visual(policy: &str, c: Chrome) -> (String, Style) {
    match policy {
        "approve-all" => (
            "✓ Full access".into(),
            Style::default().fg(c.accent_warm_fg).add_modifier(Modifier::BOLD),
        ),
        "approve-edits" => ("✎ Edits allowed".into(), Style::default().fg(c.ok_fg)),
        "approve-reads" => {
            ("◉ Reads allowed".into(), Style::default().fg(c.prompt_button_accent_fg))
        }
        "deny-all" => ("⊘ Read-only".into(), Style::default().fg(c.error_fg)),
        _ => ("? Ask before acting".into(), Style::default().fg(c.attention_fg)),
    }
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
