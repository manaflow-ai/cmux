//! Part of the TUI renderer; see `render/mod.rs`.

use super::*;

/// Help rows come from the action table plus the editing keys, so the
/// dialog can never drift from what the keys do.
pub fn help_rows(app: &App) -> Vec<(String, String)> {
    let mut rows: Vec<(String, String)> = Vec::new();
    let mut group = "";
    for d in crate::tui::actions::ACTIONS {
        if d.group != group {
            if !group.is_empty() {
                rows.push((String::new(), String::new()));
            }
            group = d.group;
            rows.push((String::new(), group.to_owned()));
        }
        let shortcuts = app.keymap.hints(d.name);
        let key = if shortcuts.is_empty() { format!("{}{}", app.palette_prefix, d.name) } else { shortcuts };
        let what = format!("{}   ({}{})", d.label, app.palette_prefix, d.name);
        rows.push((key, what));
    }
    rows.push((String::new(), String::new()));
    rows.push((String::new(), "editing and mouse".to_owned()));
    for (k, w) in crate::tui::actions::EDITING_KEYS {
        rows.push(((*k).to_owned(), (*w).to_owned()));
    }
    rows
}

fn spans(parts: &[(&str, Style)]) -> Vec<(String, Style)> {
    parts.iter().map(|(s, st)| (s.to_string(), *st)).collect()
}

#[allow(dead_code)]
pub(super) fn draw_permission(f: &mut ratatui::Frame, area: Rect, title: &str, options: &[(String, String, String)], app: &mut App) {
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

/// The pending permission as a card docked above the composer: the tool
/// title, then the options as chips. Digits, y and n still answer it.
pub(super) fn draw_permission_card(f: &mut ratatui::Frame, area: Rect, title: &str, options: &[(String, String, String)], app: &mut App) {
    let c = app.chrome;
    let hover = app.hover;
    let buf = f.buffer_mut();
    if area.height < 4 || area.width < 12 {
        return;
    }
    fill(buf, area, Style::default());
    super::composer::rounded_border(buf, area, Style::default().fg(c.attention_fg));
    let inner_w = area.width.saturating_sub(4) as usize;
    let head = format!("Needs permission  ·  {}", truncate(title, inner_w.saturating_sub(20)));
    buf.set_stringn(area.x + 2, area.y + 1, &head, inner_w, Style::default().fg(c.attention_fg).add_modifier(Modifier::BOLD));
    let hint = "y allow · n reject";
    if (head.width() + hint.width() + 4) < inner_w {
        buf.set_stringn(area.x + area.width - 2 - hint.width() as u16, area.y + 1, hint, hint.width(), c.dim());
    }
    let mut x = area.x + 2;
    let y = area.y + 2;
    app.perm_rows.clear();
    for (i, (_, name, kind)) in options.iter().enumerate() {
        let label = format!(" {}  {} ", i + 1, name);
        let w = (label.width() as u16).min((area.x + area.width - 2).saturating_sub(x));
        if w == 0 {
            break;
        }
        let r = Rect { x, y, width: w, height: 1 };
        let hovered = hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
        let fg = if kind.starts_with("allow") { c.prompt_button_accent_fg } else { c.error_fg };
        let style = if hovered { Style::default().bg(c.status_active_bg).fg(c.status_active_fg) } else { Style::default().bg(c.prompt_bg).fg(fg) };
        buf.set_stringn(x, y, &label, w as usize, style);
        app.perm_rows.push((r, ButtonAction::PermissionOption(i)));
        x += w + 2;
    }
    app.dialog_rect = area;
}

pub(super) fn draw_new_session(f: &mut ratatui::Frame, area: Rect, form: &NewForm, app: &mut App, hover: Option<(u16, u16)>) {
    let c = app.chrome;
    let label = |i: usize, name: &str| -> (String, Style) {
        if form.field == i {
            (format!("▶ {name:<14}"), c.prompt().fg(c.prompt_button_accent_fg).add_modifier(Modifier::BOLD))
        } else {
            (format!("  {name:<14}"), c.prompt().fg(c.status_dim_fg))
        }
    };
    let agent = form.harnesses.get(form.agent).cloned().unwrap_or_else(|| "(none configured)".into());
    let agent_line = if form.harnesses.len() > 1 { format!("◀ {agent} ▶   {} available, Enter lists them", form.harnesses.len()) } else { agent };
    let policy_hint = match POLICIES[form.policy] {
        "ask" => "you approve each tool call",
        "approve-reads" => "reads auto, writes ask",
        "approve-edits" => "reads and edits auto, shell asks",
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
    let names = ["harness", "name", "directory", "permissions", "first message"];
    let values: [(String, &str); 5] = [
        (agent_line, ""),
        (form.name.text(), if form.name.is_empty() { "blank = automatic" } else { "" }),
        (form.cwd.text(), ""),
        (format!("◀ {} ▶", POLICIES[form.policy]), policy_hint),
        (form.prompt.text(), if form.prompt.is_empty() { "optional" } else { "" }),
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
        let col = v.text().chars().take(v.cursor()).collect::<String>().width() as u16;
        { let p: (u16, u16) = (hx + 16 + col.min(out.inner_width.saturating_sub(18)), hy + 1 + form.field as u16); app.cursor_pos = Some(p); f.set_cursor_position(p); }
    }
}

pub(super) fn draw_picker(f: &mut ratatui::Frame, area: Rect, p: &mut Picker, app: &mut App) {
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
    let filter_shown = p.filter.text();
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
    let cursor = dialog::text_field(f.buffer_mut(), hx, hy, out.inner_width, &filter_shown, p.filter.cursor(), "filter…", &c);
    p.row_rects = state.row_rects.clone();
    app.dialog_rect = state.rect;
    app.buttons.extend(btns);
    app.dialog = state;
    { let p: (u16, u16) = cursor; app.cursor_pos = Some(p); f.set_cursor_position(p); }
}

fn draw_text_dialog(f: &mut ratatui::Frame, area: Rect, app: &mut App, hover: Option<(u16, u16)>, title: &str, above: &str, text: &crate::tui::editor::Editor, placeholder: &str, below: &str, ok_label: &str) {
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
    { let p: (u16, u16) = cursor; app.cursor_pos = Some(p); f.set_cursor_position(p); }
}

pub(super) fn draw_add_host(f: &mut ratatui::Frame, area: Rect, text: &crate::tui::editor::Editor, app: &mut App, hover: Option<(u16, u16)>) {
    draw_text_dialog(f, area, app, hover, "Add host", "ssh host, as you would type after `ssh`", text, "user@host  or  hostname", "acpmux opens the tunnel and reads the remote token over ssh", "[ Add ⏎ ]");
}

pub(super) fn draw_directory(f: &mut ratatui::Frame, area: Rect, text: &crate::tui::editor::Editor, app: &mut App, hover: Option<(u16, u16)>) {
    let c = app.chrome;
    let mut paths = Vec::new();
    if !app.remote_directory()
        && let Ok(path) = app.resolve_directory(&text.text()) {
            if let Some(parent) = path.parent() { paths.push(("↑ Parent directory".to_owned(), parent.to_string_lossy().into_owned())); }
            for p in crate::tui::directory::children(&path) { paths.push((format!("▢ {}", p.file_name().unwrap_or_default().to_string_lossy()), p.to_string_lossy().into_owned())); }
        }
    let rows = paths.iter().map(|(name,_)| DialogRow { spans: vec![(name.clone(), c.prompt())], selectable: true, note: None }).collect();
    let spec = DialogSpec {
        title: "Working directory",
        header: vec![spans(&[("Path (absolute, ~/, or relative to this session)", c.dim())]), vec![], vec![], spans(&[(if app.on_draft() { "Choose where to start this session" } else { "Choose where to start a new session" }, c.dim())])],
        rows, selected: None, reveal: false,
        hint: "Click a folder to browse · Enter uses the path · Esc cancels",
        buttons: vec![("[ Cancel esc ]", false, ButtonAction::CloseOverlay), ("[ Use directory ⏎ ]", true, ButtonAction::CreateFromForm)],
        close_button: false, min_width: 52, max_width: 96,
    };
    let mut state = std::mem::take(&mut app.dialog);
    let mut buttons = Vec::new();
    let out = dialog::draw(f.buffer_mut(), area, &c, hover, spec, &mut state, &mut buttons);
    for (rect, i) in &state.row_rects { if let Some((_, path)) = paths.get(*i) { buttons.push((*rect, ButtonAction::BrowseDirectory(path.clone()))); } }
    let (x,y) = out.header_origin;
    let pos = dialog::text_field(f.buffer_mut(), x, y+1, out.inner_width, &text.text(), text.cursor(), "directory", &c);
    app.dialog_rect = state.rect; app.buttons.extend(buttons); app.dialog = state;
    app.cursor_pos = Some(pos); f.set_cursor_position(pos);

}

pub(super) fn draw_confirm(f: &mut ratatui::Frame, area: Rect, title: &str, app: &mut App, hover: Option<(u16, u16)>) {
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

pub(super) fn draw_help(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let hover = app.hover;
    let rows: Vec<DialogRow> = help_rows(app)
        .into_iter()
        .map(|(key, what)| {
            if key.is_empty() && !what.is_empty() {
                DialogRow { spans: vec![(what, c.prompt_title())], selectable: false, note: None }
            } else if key.is_empty() {
                DialogRow { spans: vec![], selectable: false, note: None }
            } else {
                DialogRow { spans: vec![(format!("{key:<26}"), c.prompt().fg(c.prompt_title_fg)), (what, c.prompt())], selectable: false, note: None }
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

