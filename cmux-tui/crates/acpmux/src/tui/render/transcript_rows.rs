//! A transcript rendered into rows (`transcript_rows`).

use super::*;

/// Render a transcript into rows at `width`. Every row starts after a
/// two-column gutter that holds the role or state marker, so text lines
/// up down the page. The transcript is a hierarchy of collapsibles: the
/// work of a turn (everything between your message and the turn's final
/// reply; the message and the reply themselves never hide), runs of
/// consecutive tool calls, and single tool calls or thoughts. `toggled`
/// holds the ones flipped from their default (work and groups open,
/// details closed); the thought being streamed is always open.
pub fn transcript_rows(
    t: &Transcript,
    width: usize,
    show_thoughts: bool,
    show_system: bool,
    toggled: &std::collections::HashSet<Toggle>,
    c: &Chrome,
) -> Vec<Row> {
    transcript_rows_range(
        t,
        width,
        show_thoughts,
        show_system,
        toggled,
        c,
        0..t.items.len(),
        true,
        None,
    )
}

pub(super) fn transcript_rows_range(
    t: &Transcript,
    width: usize,
    show_thoughts: bool,
    show_system: bool,
    toggled: &std::collections::HashSet<Toggle>,
    c: &Chrome,
    range: std::ops::Range<usize>,
    footer: bool,
    mut markdown: Option<&mut std::collections::HashMap<usize, Vec<Row>>>,
) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    let w = width;
    let running = t.status == "running";
    let last = t.items.len().saturating_sub(1);
    let is_open = |tg: Toggle, default_open: bool| default_open ^ toggled.contains(&tg);
    let group = |it: &Item| matches!(it, Item::Tool { .. } | Item::Permission { .. });
    // Visible items: lifecycle noise and silent turn ends never draw.
    let vis: Vec<usize> = range
        .filter(|&i| {
            let it = &t.items[i];
            if let Item::Permission { title, decided: Some(d), .. } = it {
                // "✓ Allowed  Write x" right under "✎ Write x" repeats the row.
                let echoes_tool =
                    i > 0 && matches!(&t.items[i - 1], Item::Tool { title: tt, .. } if tt == title);
                if d.starts_with("allow") && echoes_tool {
                    return false;
                }
            }
            (show_system || !is_system_noise(it))
                && !matches!(it, Item::TurnEnd { stop } if stop == "end_turn")
        })
        .collect();
    // Codex spacing: one plain blank row before every block. The user block
    // also carries a tinted blank row inside its band above and below.
    let after_user_block = false;
    let spacer = |rows: &mut Vec<Row>, i: usize, _after_user_block: bool| {
        if !rows.is_empty() {
            plain("", Style::default(), i, rows);
        }
    };
    // One tool or permission row (plus open details) at `indent`.
    let tool_rows = |rows: &mut Vec<Row>, i: usize, indent: &str| {
        let iw = width.saturating_sub(indent.len());
        match &t.items[i] {
            Item::Tool { title, kind, status, detail, .. } => {
                // Codex app: one muted line per activity, an icon for the
                // kind, paths shortened, red only when it failed. Details
                // open on click.
                let glyph = match kind.as_str() {
                    "read" => "≡",
                    "edit" => "✎",
                    "execute" => "$",
                    "search" => "⌕",
                    "fetch" => "↓",
                    "think" => "…",
                    "delete" | "move" => "⇄",
                    _ => "•",
                };
                let (gstyle, tstyle) = match status.as_str() {
                    "failed" => (Style::default().fg(c.error_fg), Style::default().fg(c.error_fg)),
                    "in_progress" | "pending" => (c.muted(), c.muted()),
                    _ => (c.dim(), c.muted()),
                };
                let open = !detail.is_empty() && is_open(Toggle::Item(i), false);
                // A diff names its files better than the harness's generic
                // "Editing files": "Edited calc.py".
                let files: Vec<String> = detail
                    .lines()
                    .filter_map(|l| l.strip_prefix("@@ "))
                    .map(|p| p.rsplit('/').next().unwrap_or(p).to_owned())
                    .collect();
                let shown = if !files.is_empty()
                    && (kind == "edit" || title.to_lowercase().contains("edit"))
                {
                    format!(
                        "{} {}",
                        if status == "completed" { "Edited" } else { "Editing" },
                        files.join(", ")
                    )
                } else {
                    shorten_tool_title(title)
                };
                let title_shown = truncate(&shown, iw.saturating_sub(4));
                let text = format!("{indent}{glyph} {title_shown}");
                let mut spans = vec![
                    Span::raw(indent.to_owned()),
                    Span::styled(format!("{glyph} "), gstyle),
                    Span::styled(title_shown, tstyle),
                ];
                let counts = crate::transcript::diff_counts(detail);
                if let Some((plus, minus)) = counts {
                    spans.push(Span::styled(
                        format!("  +{plus}"),
                        Style::default().fg(c.diff_add_fg),
                    ));
                    spans.push(Span::styled(
                        format!(" -{minus}"),
                        Style::default().fg(c.diff_del_fg),
                    ));
                }
                if !detail.is_empty() {
                    spans.push(Span::styled(if open { "  ▾" } else { "  ›" }, c.dim()));
                }
                rows.push(Row {
                    line: Line::from(spans),
                    text,
                    item: i,
                    toggle: if detail.is_empty() { None } else { Some(Toggle::Item(i)) },
                });
                if open && counts.is_some() {
                    // Diff lines keep their prefix colors and are not wrapped.
                    for l in detail.lines() {
                        let style = match l.chars().next() {
                            Some('+') => Style::default().fg(c.diff_add_fg),
                            Some('-') => Style::default().fg(c.diff_del_fg),
                            Some('@') => c.muted(),
                            _ => c.dim(),
                        };
                        let text = format!("{indent}  {}", truncate(l, iw.saturating_sub(3)));
                        rows.push(Row {
                            line: Line::from(Span::styled(text.clone(), style)),
                            text,
                            item: i,
                            toggle: None,
                        });
                    }
                } else if open {
                    wrap(detail, iw.saturating_sub(2), c.dim(), &format!("{indent}  "), i, rows);
                }
            }
            Item::Permission { title, decided, .. } => {
                // Codex app wording: the request while it waits, the answer after.
                let shown = shorten_tool_title(title);
                let (text, style) = match decided.as_deref() {
                    Some(d) if d.starts_with("allow") => {
                        (format!("{indent}✓ Allowed  {shown}"), c.dim())
                    }
                    Some(d) if d.starts_with("reject") => {
                        (format!("{indent}✗ Rejected  {shown}"), c.dim())
                    }
                    Some(_) => (format!("{indent}– Cancelled  {shown}"), c.dim()),
                    None => (
                        format!("{indent}? Needs permission  {shown}"),
                        Style::default().fg(c.attention_fg),
                    ),
                };
                plain(&text, style, i, rows);
            }
            _ => {}
        }
    };

    // Queued messages wait at the bottom, under the running turn, until
    // their own turn starts (Codex app).
    let queued: Vec<usize> = vis
        .iter()
        .copied()
        .filter(|&i| matches!(t.items[i], Item::User { queued: true, .. }))
        .collect();
    let mut k = 0usize;
    let mut turn_open = true;
    // When a turn's work is collapsed, rendering resumes at this item (the
    // turn's final reply, or the next user message).
    let mut reopen_at: Option<usize> = None;
    while k < vis.len() {
        let i = vis[k];
        if reopen_at == Some(i) {
            turn_open = true;
            reopen_at = None;
        }
        let item = &t.items[i];
        if matches!(item, Item::User { queued: true, .. }) {
            k += 1;
            continue;
        }
        match item {
            Item::User { text, steer, queued } => {
                k += 1;
                turn_open = true;
                reopen_at = None;
                spacer(&mut rows, i, false);
                // Timestamps share the transcript content margin.
                if let Some(at) = t.user_at.get(&i) {
                    let label = when_label(*at);
                    let text = format!("{GUTTER}{label}");
                    rows.push(Row {
                        line: Line::from(Span::styled(text.clone(), c.dim())),
                        text,
                        item: i,
                        toggle: None,
                    });
                    plain("", Style::default(), i, &mut rows);
                }
                // Keep user text on the same left margin as assistant text,
                // with its role marker in the gutter and a tinted background.
                let bg = Style::default().bg(c.user_bg);
                let style = if *queued { c.dim().bg(c.user_bg) } else { bg.fg(c.status_fg) };
                let marker = if *steer {
                    "» "
                } else if *queued {
                    "⋯ "
                } else {
                    "❯ "
                };
                let marker_style = bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD);
                let bubble_w = if width < 50 { width } else { (width * 7 / 10).max(40).min(width) };
                let inner_w = bubble_w.saturating_sub(4);
                let mut body: Vec<Row> = Vec::new();
                wrap(text, inner_w, style, "", i, &mut body);
                if *queued {
                    plain(
                        "queued · sends when the running turn ends · Ctrl-x cancels it",
                        c.dim().bg(c.user_bg),
                        i,
                        &mut body,
                    );
                }
                let bubble_row = |content: Vec<Span<'static>>, used: usize, text: String| -> Row {
                    let mut spans = Vec::new();
                    spans.extend(content);
                    spans.push(Span::styled(" ".repeat(bubble_w.saturating_sub(used)), bg));
                    Row { line: Line::from(spans), text, item: i, toggle: None }
                };
                rows.push(bubble_row(vec![], 0, String::new()));
                for (n, r) in body.into_iter().enumerate() {
                    let m = if n == 0 { marker } else { "  " };
                    let content = r.text.clone();
                    let used = 2 + content.width();
                    let spans = vec![
                        Span::styled(m.to_owned(), if n == 0 { marker_style } else { bg }),
                        Span::styled(
                            content.clone(),
                            if r.line.spans.len() > 1 {
                                r.line.spans[1].style.bg(c.user_bg)
                            } else {
                                style
                            },
                        ),
                    ];
                    rows.push(bubble_row(spans, used, format!("{m}{content}")));
                }
                rows.push(bubble_row(vec![], 0, String::new()));
                let _ = after_user_block;
                // The turn's work: everything visible between this message
                // and the final reply. Two or more blocks get a handle row
                // that collapses them all; one block collapses on its own.
                let next_user = t.items[i + 1..]
                    .iter()
                    .position(|x| matches!(x, Item::User { queued: false, .. }))
                    .map(|p| i + 1 + p)
                    .unwrap_or(t.items.len());
                let turn_live = running && next_user == t.items.len();
                // While the turn runs there is no final reply yet: every block
                // is work and the handle reads "Working for …".
                let final_reply = if turn_live {
                    None
                } else {
                    (i + 1..next_user).rev().find(|&j| matches!(t.items[j], Item::Assistant { .. }))
                };
                let work_end = final_reply.unwrap_or(next_user);
                let work: Vec<usize> =
                    vis[k..].iter().copied().take_while(|&j| j < work_end).collect();
                let mut blocks = 0usize;
                let mut tools = 0usize;
                let mut commands = 0usize;
                let mut failed_tools = 0usize;
                let mut thoughts = 0usize;
                let mut prev_group = false;
                for &j in &work {
                    match &t.items[j] {
                        Item::Tool { title, kind, status, .. } => {
                            tools += 1;
                            if matches!(kind.as_str(), "execute" | "terminal" | "shell")
                                || title.to_ascii_lowercase().contains("command")
                                || title.to_ascii_lowercase().contains("bash")
                                || title.to_ascii_lowercase().contains("shell")
                            {
                                commands += 1;
                            }
                            if status == "failed" {
                                failed_tools += 1;
                            }
                            if !prev_group {
                                blocks += 1;
                            }
                            prev_group = true;
                        }
                        Item::Permission { .. } => {
                            if !prev_group {
                                blocks += 1;
                            }
                            prev_group = true;
                        }
                        Item::Thought { .. } => {
                            thoughts += 1;
                            blocks += 1;
                            prev_group = false;
                        }
                        Item::Assistant { .. } => {
                            blocks += 1;
                            prev_group = false;
                        }
                        // Keep a failed turn's notice visible after the work
                        // summary folds; the error is the useful result.
                        Item::Error { .. } => {}
                        _ => {
                            blocks += 1;
                            prev_group = false;
                        }
                    }
                }
                if blocks >= 1 {
                    // Finished work starts folded; a live turn stays open so
                    // its activity is visible while the agent is working.
                    let open = is_open(Toggle::Turn(i), turn_live);
                    // Codex app: "Worked for 1m 7s ›" (collapsed) or "Worked for 1m 7s ▾".
                    let span = t.turn_span(i);
                    let edited_files = work
                        .iter()
                        .filter_map(|&j| match &t.items[j] {
                            Item::Tool { detail, .. } => Some(detail),
                            _ => None,
                        })
                        .flat_map(|detail| {
                            detail
                                .lines()
                                .filter_map(|line| line.strip_prefix("@@ "))
                                .map(|path| path.to_owned())
                        })
                        .collect::<std::collections::HashSet<_>>()
                        .len();
                    let mut label = match span {
                        Some((start, Some(end))) => {
                            format!("Worked for {}", duration_label(end.saturating_sub(start)))
                        }
                        Some((start, None))
                            if t.turn_times.last().map(|x| x.0 == i).unwrap_or(false)
                                && t.status != "ready"
                                && t.status != "idle" =>
                        {
                            format!(
                                "Working for {}",
                                duration_label(now_ms().saturating_sub(start))
                            )
                        }
                        _ => "Worked".to_owned(),
                    };
                    if tools > 0 {
                        label.push_str(&format!(
                            " · {tools} step{}",
                            if tools == 1 { "" } else { "s" }
                        ));
                    }
                    if commands > 0 {
                        label.push_str(&format!(
                            " · {commands} command{}",
                            if commands == 1 { "" } else { "s" }
                        ));
                    }
                    if thoughts > 0 {
                        label.push_str(&format!(
                            " · {thoughts} thought{}",
                            if thoughts == 1 { "" } else { "s" }
                        ));
                    }
                    if edited_files > 0 {
                        label.push_str(&format!(
                            " · {edited_files} file{} edited",
                            if edited_files == 1 { "" } else { "s" }
                        ));
                    }
                    if failed_tools > 0 {
                        label.push_str(&format!(" · {failed_tools} failed"));
                    }
                    spacer(&mut rows, i, false);
                    let text = format!("{label}  {}", if open { "▾" } else { "›" });
                    rows.push(Row {
                        line: Line::from(vec![
                            Span::styled(label.to_string(), c.muted()),
                            Span::styled(format!("  {}", if open { "▾" } else { "›" }), c.dim()),
                        ]),
                        text,
                        item: i,
                        toggle: Some(Toggle::Turn(i)),
                    });
                    // Codex app: a hairline under the handle.
                    rows.push(Row {
                        line: Line::from(Span::styled(
                            "─".repeat(w).to_string(),
                            Style::default().fg(c.composer_border_fg),
                        )),
                        text: String::new(),
                        item: i,
                        toggle: None,
                    });
                    // "Edited 2 files  +21 -2": the turn's file edits, summed, visible even when folded.
                    let mut files: Vec<String> = Vec::new();
                    let (mut plus, mut minus) = (0usize, 0usize);
                    for &j in &work {
                        if let Item::Tool { detail, .. } = &t.items[j]
                            && let Some((p, m)) = crate::transcript::diff_counts(detail)
                        {
                            plus += p;
                            minus += m;
                            for f in detail
                                .lines()
                                .filter_map(|l| l.strip_prefix("@@ "))
                                .map(|p| p.rsplit('/').next().unwrap_or(p).to_owned())
                            {
                                if !files.contains(&f) {
                                    files.push(f);
                                }
                            }
                        }
                    }
                    if !files.is_empty() {
                        let label = format!(
                            "✎ Edited {} file{}  ",
                            files.len(),
                            if files.len() == 1 { "" } else { "s" }
                        );
                        let names =
                            truncate(&files.join(", "), w.saturating_sub(label.width() + 14));
                        let text = format!("{label}{names}  +{plus} -{minus}");
                        rows.push(Row {
                            line: Line::from(vec![
                                Span::styled(label, c.muted()),
                                Span::styled(names, c.dim()),
                                Span::styled(
                                    format!("  +{plus}"),
                                    Style::default().fg(c.diff_add_fg),
                                ),
                                Span::styled(
                                    format!(" -{minus}"),
                                    Style::default().fg(c.diff_del_fg),
                                ),
                            ]),
                            text,
                            item: i,
                            toggle: None,
                        });
                    }
                    if !open {
                        turn_open = false;
                        reopen_at = Some(work_end);
                    }
                }
                continue;
            }
            it if group(it) => {
                let start_k = k;
                while k < vis.len() && group(&t.items[vis[k]]) {
                    k += 1;
                }
                if !turn_open {
                    continue;
                }
                let members = &vis[start_k..k];
                spacer(&mut rows, i, after_user_block);
                let tools: Vec<usize> = members
                    .iter()
                    .copied()
                    .filter(|&m| matches!(t.items[m], Item::Tool { .. }))
                    .collect();
                if tools.len() >= 2 {
                    let g = Toggle::Group(tools[0]);
                    let open = is_open(g, true);
                    let names: Vec<String> = tools
                        .iter()
                        .take(6)
                        .map(|&m| match &t.items[m] {
                            Item::Tool { title, .. } => {
                                title.split_whitespace().next().unwrap_or("tool").to_owned()
                            }
                            _ => String::new(),
                        })
                        .collect();
                    let done = tools.iter().filter(|&&m| matches!(&t.items[m], Item::Tool { status, .. } if status == "completed")).count();
                    let failed = tools.iter().filter(|&&m| matches!(&t.items[m], Item::Tool { status, .. } if status == "failed")).count();
                    let state = if failed > 0 {
                        format!(" · {failed} failed")
                    } else if done < tools.len() {
                        format!(" · {done}/{} done", tools.len())
                    } else {
                        String::new()
                    };
                    let text = format!(
                        "{} steps · {}{state}  {}",
                        tools.len(),
                        names.join(", "),
                        if open { "▾" } else { "›" }
                    );
                    rows.push(Row {
                        line: Line::from(vec![
                            Span::styled(format!("{} steps", tools.len()), c.muted()),
                            Span::styled(format!(" · {}{state}", names.join(", ")), c.dim()),
                            Span::styled(format!("  {}", if open { "▾" } else { "›" }), c.dim()),
                        ]),
                        text,
                        item: tools[0],
                        toggle: Some(g),
                    });
                    if open {
                        for &m in members {
                            tool_rows(&mut rows, m, "    ");
                        }
                    }
                } else {
                    for &m in members {
                        tool_rows(&mut rows, m, "");
                    }
                }
            }
            _ => {
                k += 1;
                if !turn_open {
                    continue;
                }
                spacer(&mut rows, i, after_user_block);
                match item {
                    Item::Assistant { text } => {
                        if let Some(cache) = markdown.as_deref_mut() {
                            let rendered = cache.entry(i).or_insert_with(|| {
                                let mut rows = Vec::new();
                                super::super::markdown::render(
                                    text,
                                    width,
                                    "",
                                    Style::default(),
                                    c,
                                    i,
                                    &mut rows,
                                );
                                rows
                            });
                            rows.extend(rendered.iter().cloned());
                        } else {
                            super::super::markdown::render(
                                text,
                                width,
                                "",
                                Style::default(),
                                c,
                                i,
                                &mut rows,
                            );
                        }
                    }
                    Item::Thought { text } => {
                        let live = running && i == last;
                        let open = live || is_open(Toggle::Item(i), show_thoughts);
                        let n = text.chars().count();
                        let first_line =
                            text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
                        let _ = n;
                        let summary = first_line.trim_matches('*').trim();
                        if live {
                            // Codex app: one shimmering line with the latest
                            // sentence while it streams; a click opens the rest.
                            let latest = text
                                .lines()
                                .rev()
                                .find(|l| !l.trim().is_empty())
                                .unwrap_or("")
                                .trim()
                                .trim_matches('*')
                                .trim();
                            let mut spans = vec![Span::raw("")];
                            spans.extend(super::super::shimmer::spans(
                                "Thinking",
                                c.shimmer_base,
                                c.shimmer_bright,
                            ));
                            if !latest.is_empty() {
                                spans.push(Span::styled(
                                    format!("  {}", truncate(latest, w.saturating_sub(12))),
                                    c.dim().add_modifier(Modifier::ITALIC),
                                ));
                            }
                            rows.push(Row {
                                line: Line::from(spans),
                                text: format!("Thinking  {latest}"),
                                item: i,
                                toggle: Some(Toggle::Item(i)),
                            });
                            if is_open(Toggle::Item(i), false) {
                                wrap(
                                    text,
                                    w,
                                    c.dim().add_modifier(Modifier::ITALIC),
                                    "",
                                    i,
                                    &mut rows,
                                );
                            }
                        } else if open {
                            header_row("Thought  ▾", c.muted_fg, i, Toggle::Item(i), &mut rows);
                            wrap(text, w, c.dim().add_modifier(Modifier::ITALIC), "", i, &mut rows);
                        } else {
                            let shown = truncate(summary, w.saturating_sub(14));
                            let text_row = format!("Thought  {shown}  ›");
                            rows.push(Row {
                                line: Line::from(vec![
                                    Span::raw(""),
                                    Span::styled("Thought  ", c.muted()),
                                    Span::styled(shown, c.dim().add_modifier(Modifier::ITALIC)),
                                    Span::styled("  ›", c.dim()),
                                ]),
                                text: text_row,
                                item: i,
                                toggle: Some(Toggle::Item(i)),
                            });
                        }
                    }
                    Item::Plan { entries } => {
                        plain("plan", Style::default().fg(c.attention_fg), i, &mut rows);
                        for (s, content) in entries {
                            let glyph = match s.as_str() {
                                "completed" => "✓",
                                "in_progress" => "▶",
                                _ => "○",
                            };
                            wrap(
                                content,
                                w.saturating_sub(2),
                                Style::default().fg(c.attention_fg),
                                &format!("{glyph} "),
                                i,
                                &mut rows,
                            );
                        }
                    }
                    Item::Status { text } => plain(&format!("-- {text}"), c.dim(), i, &mut rows),
                    Item::TurnEnd { stop } => plain(&format!("-- {stop}"), c.dim(), i, &mut rows),
                    Item::Error { text } => {
                        // Codex app: a rounded notice card with an icon.
                        let border = Style::default().fg(c.composer_border_fg);
                        let cw = width.max(12);
                        let inner = cw.saturating_sub(6);
                        let mut body: Vec<Row> = Vec::new();
                        wrap(text, inner, Style::default().fg(c.status_fg), "", i, &mut body);
                        rows.push(Row {
                            line: Line::from(Span::styled(
                                format!("╭{}╮", "─".repeat(cw - 2)),
                                border,
                            )),
                            text: String::new(),
                            item: i,
                            toggle: None,
                        });
                        for (n, r) in body.into_iter().enumerate() {
                            let content = r.text.clone();
                            let icon = if n == 0 { "✗ " } else { "  " };
                            let pad = inner.saturating_sub(content.width());
                            rows.push(Row {
                                line: Line::from(vec![
                                    Span::styled("│ ".to_owned(), border),
                                    Span::styled(
                                        icon.to_owned(),
                                        Style::default()
                                            .fg(c.error_fg)
                                            .add_modifier(Modifier::BOLD),
                                    ),
                                    Span::styled(content.clone(), Style::default().fg(c.status_fg)),
                                    Span::raw(" ".repeat(pad)),
                                    Span::styled(" │".to_owned(), border),
                                ]),
                                text: format!("  {icon}{content}"),
                                item: i,
                                toggle: None,
                            });
                        }
                        rows.push(Row {
                            line: Line::from(Span::styled(
                                format!("╰{}╯", "─".repeat(cw - 2)),
                                border,
                            )),
                            text: String::new(),
                            item: i,
                            toggle: None,
                        });
                    }
                    Item::Stderr { text } => plain(
                        &format!("stderr: {}", truncate(text, w.saturating_sub(8))),
                        c.dim(),
                        i,
                        &mut rows,
                    ),
                    _ => {}
                }
            }
        }
    }
    for &i in &queued {
        if let Item::User { text, .. } = &t.items[i] {
            spacer(&mut rows, i, false);
            let bg = Style::default().bg(c.user_bg);
            let style = c.dim().bg(c.user_bg);
            let bubble_w = if width < 50 { width } else { (width * 7 / 10).max(40).min(width) };
            let inner_w = bubble_w.saturating_sub(4);
            let mut body: Vec<Row> = Vec::new();
            wrap(text, inner_w, style, "", i, &mut body);
            plain(
                "queued · sends when the running turn ends · Ctrl-x cancels it",
                c.dim().bg(c.user_bg),
                i,
                &mut body,
            );
            let bubble_row = |content: Vec<Span<'static>>, used: usize, text: String| -> Row {
                let mut spans = Vec::new();
                spans.extend(content);
                spans.push(Span::styled(" ".repeat(bubble_w.saturating_sub(used)), bg));
                Row { line: Line::from(spans), text, item: i, toggle: None }
            };
            rows.push(bubble_row(vec![], 0, String::new()));
            for (n, r) in body.into_iter().enumerate() {
                let m = if n == 0 { "⋯ " } else { "  " };
                let content = r.text.clone();
                let used = 2 + content.width();
                rows.push(bubble_row(
                    vec![
                        Span::styled(
                            m.to_owned(),
                            bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(content.clone(), style),
                    ],
                    used,
                    format!("{m}{content}"),
                ));
            }
            rows.push(bubble_row(vec![], 0, String::new()));
        }
    }
    if running && footer {
        plain("", Style::default(), usize::MAX, &mut rows);
        rows.push(working_row(t, c));
    }
    rows
}

pub(super) fn working_row(t: &Transcript, c: &Chrome) -> Row {
    // Codex-style persistent footer: it remains visible while a tool or
    // thought streams, and carries the normalized activity plus the
    // interrupt affordance so the user never has to infer whether work
    // is still live from the last transcript row.
    let elapsed = match t.turn_times.last() {
        Some((_, start, None)) => duration_label(now_ms().saturating_sub(*start)).to_string(),
        _ => "…".to_owned(),
    };
    let mut label = format!("Working ({elapsed} · Esc to interrupt)");
    if let Some(activity) = t.activity.as_deref().filter(|s| !s.is_empty()) {
        label.push_str(" · ");
        label.push_str(activity);
    }
    if t.active_terminals > 0 {
        label.push_str(&format!(
            " · {} background terminal{}",
            t.active_terminals,
            if t.active_terminals == 1 { "" } else { "s" }
        ));
    } else if t.active_tools > 0 {
        label.push_str(&format!(
            " · {} active tool{}",
            t.active_tools,
            if t.active_tools == 1 { "" } else { "s" }
        ));
    }
    let queued =
        t.items.iter().filter(|item| matches!(item, Item::User { queued: true, .. })).count();
    if queued > 0 {
        label.push_str(&format!(" · {} queued", queued));
    }
    let mut spans = vec![Span::raw("")];
    spans.extend(super::super::shimmer::spans(&label, c.shimmer_base, c.shimmer_bright));
    let note = t.note.as_deref().map(|n| format!("  {n}")).unwrap_or_default();
    if !note.is_empty() {
        spans.push(Span::styled(note.clone(), c.dim()));
    }
    Row { line: Line::from(spans), text: format!("{label}{note}"), item: usize::MAX, toggle: None }
}
