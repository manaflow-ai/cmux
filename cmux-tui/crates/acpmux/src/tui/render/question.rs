//! The answer flow's card (tui/answering.rs), docked above the composer in
//! place of the permission card: the active item's header, prompt and
//! numbered options (checkboxes for a multi select), then the keys.

use super::*;
use crate::tui::Answering;

/// Rows the card needs: borders, head, prompt, one per option, keys.
pub(super) fn card_height(flow: &Answering) -> u16 {
    let options = flow.active().and_then(|i| i["options"].as_array()).map_or(0, Vec::len);
    5 + options.min(9) as u16
}

pub(super) fn draw_question_card(
    f: &mut ratatui::Frame,
    area: Rect,
    flow: &Answering,
    app: &mut App,
) {
    let c = app.chrome;
    let hover = app.hover;
    let buf = f.buffer_mut();
    app.perm_rows.clear();
    let Some(item) = flow.active() else { return };
    if area.height < 4 || area.width < 12 {
        return;
    }
    fill(buf, area, Style::default());
    super::composer::rounded_border(buf, area, Style::default().fg(c.attention_fg));
    let inner_w = area.width.saturating_sub(4) as usize;
    let x = area.x + 2;
    let total = crate::question_answer::items(&flow.question).len();
    let agent = flow.question["agent"].as_str().unwrap_or("The agent");
    let header = item["header"].as_str().unwrap_or("");
    let mut head = format!("{agent} asks");
    if total > 1 {
        head.push_str(&format!("  ·  {}/{total}", flow.item + 1));
    }
    if !header.is_empty() {
        head.push_str(&format!("  ·  {header}"));
    }
    let bold = Style::default().fg(c.attention_fg).add_modifier(Modifier::BOLD);
    buf.set_stringn(x, area.y + 1, truncate(&head, inner_w), inner_w, bold);
    let prompt = item["prompt"].as_str().unwrap_or("").trim();
    buf.set_stringn(x, area.y + 2, truncate(prompt, inner_w), inner_w, Style::default());
    let multi = item["multiSelect"].as_bool().unwrap_or(false);
    let last = area.y + area.height.saturating_sub(2);
    let options = item["options"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    for (i, option) in options.iter().enumerate().take(9) {
        let y = area.y + 3 + i as u16;
        if y >= last {
            break;
        }
        let mark = if i == flow.highlight { "›" } else { " " };
        let check = match (multi, flow.picked.contains(&i)) {
            (false, _) => "",
            (true, true) => "[x] ",
            (true, false) => "[ ] ",
        };
        let label = option["label"].as_str().unwrap_or("");
        let detail = option["detail"].as_str().unwrap_or("");
        let detail = if detail.is_empty() { String::new() } else { format!("  {detail}") };
        let line = format!("{mark} {}. {check}{label}", i + 1);
        let r = Rect { x, y, width: area.width.saturating_sub(4), height: 1 };
        let hovered =
            hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
        let style = if hovered {
            Style::default().bg(c.status_active_bg).fg(c.status_active_fg)
        } else if i == flow.highlight {
            Style::default().fg(c.prompt_button_accent_fg)
        } else {
            Style::default()
        };
        buf.set_stringn(x, y, &line, inner_w, style);
        let used = line.width();
        if used + 2 < inner_w {
            buf.set_stringn(x + used as u16, y, &detail, inner_w - used, c.dim());
        }
        app.perm_rows.push((r, ButtonAction::PermissionOption(i)));
    }
    let other = item["allowsOther"].as_bool().unwrap_or(false);
    let keys = match (multi, other) {
        (true, true) => "digits/Space toggle · type for Other · Enter confirms · Esc leaves",
        (true, false) => "digits/Space toggle · Enter confirms · Esc leaves",
        (false, true) => "digit picks · type for Other · Enter confirms · Esc leaves",
        (false, false) => "digit picks · Enter confirms · Esc leaves",
    };
    buf.set_stringn(x, last, truncate(keys, inner_w), inner_w, c.dim());
    app.dialog_rect = area;
}
