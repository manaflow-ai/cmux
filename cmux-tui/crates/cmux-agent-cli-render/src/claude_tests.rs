use super::*;
use serde_json::json;

fn chrome() -> Chrome {
    Chrome { mode: "manual mode on".into(), cwd: Some("/w".into()), ..Chrome::default() }
}

#[test]
fn a_turn_draws_prompt_tool_and_answer_above_the_input_box() {
    let update = |u: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}});
    let records = vec![
        json!({"kind": "turn_started", "msg": {}, "at": 1000}),
        json!({"kind": "user_message", "msg": {"text": "hi"}}),
        json!({"kind": "tool_call", "msg": update(json!({"sessionUpdate": "tool_call", "toolCallId": "t", "title": "x", "rawInput": {"command": "ls"}, "_meta": {"claude": {"tool": "Bash"}}}))}),
        json!({"kind": "tool_call_update", "msg": update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "a.txt"}}]}))}),
        json!({"kind": "agent_message_chunk", "msg": update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done `a.txt`."}}))}),
        json!({"kind": "turn_end", "msg": {}, "at": 3000}),
    ];
    let grid = render(&records, &chrome(), 40, 16);
    let text: Vec<String> = (0..16).map(|y| grid.row_text(y)).collect();
    assert_eq!(text.get(1).map(String::as_str), Some("❯ hi"));
    assert_eq!(text.get(3).map(String::as_str), Some("● Bash(ls)"));
    assert_eq!(text.get(4).map(String::as_str), Some("  ⎿ \u{a0}a.txt"));
    assert_eq!(text.get(6).map(String::as_str), Some("● Done a.txt."));
    assert!(text.get(8).is_some_and(|t| t.starts_with("✻ Worked for 2s")));
    assert!(text.iter().any(|t| t == "❯"));
    let code = grid.cells.get(6).and_then(|r| r.get(7)).map(|c| c.style.fg);
    assert_eq!(code, Some(crate::Color::Palette(CODE)));
}

#[test]
fn an_edit_marks_the_changed_word_not_its_common_letters() {
    assert_eq!(common_ends("print(\"hi\")", "print(\"hello\")"), (7, 2));
}

#[test]
fn a_tall_transcript_shows_its_bottom_rows() {
    let records: Vec<Value> = (0..20)
        .map(|i| json!({"kind": "user_message", "msg": {"text": format!("p{i}")}}))
        .collect();
    let grid = render(&records, &chrome(), 30, 10);
    assert_eq!(grid.row_text(4), "❯ p19");
}

fn fullscreen_chrome() -> Chrome {
    Chrome { version: Some("2.1.332".into()), ..chrome() }
}

#[test]
fn a_fullscreen_empty_draft_shows_the_placeholder() {
    let chrome = Chrome { placeholder: Some("Try \"fix lint\"".into()), ..fullscreen_chrome() };
    let grid = render(&[], &chrome, 40, 12);
    let text: Vec<String> = (0..12).map(|y| grid.row_text(y)).collect();
    assert!(text.iter().any(|t| t.contains("Try \"fix lint\"")), "{text:?}");
}

#[test]
fn a_fullscreen_box_taller_than_the_screen_keeps_its_footer() {
    let draft = (0..20).map(|i| format!("line{i}")).collect::<Vec<_>>().join("\n");
    let chrome = Chrome { draft, ..fullscreen_chrome() };
    let grid = render(&[], &chrome, 40, 8);
    let text: Vec<String> = (0..8).map(|y| grid.row_text(y)).collect();
    assert!(text.last().is_some_and(|t| t.contains("manual mode on")), "{text:?}");
    assert!(text.iter().any(|t| t.contains("line19")), "{text:?}");
}

#[test]
fn a_fullscreen_dot_in_the_text_is_not_a_gutter_dot() {
    let update = |u: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}});
    let records = vec![
        json!({"kind": "user_message", "msg": {"text": "hi"}}),
        json!({"kind": "agent_message_chunk", "msg": update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "a ● b"}}))}),
    ];
    let grid = render(&records, &fullscreen_chrome(), 40, 12);
    let text: Vec<String> = (0..12).map(|y| grid.row_text(y)).collect();
    assert!(text.iter().any(|t| t == "⏺ a ● b"), "{text:?}");
}

/// Live gap 1 and 2 (cmux#56889): a turn that ends in an API error draws its answer in
/// Claude Code's warning amber, and no done line after it, as the host's screen does.
#[test]
fn an_api_error_answer_is_amber_and_ends_with_no_done_line() {
    let update = |u: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}});
    let records = vec![
        json!({"kind": "turn_started", "msg": {}, "at": 1000}),
        json!({"kind": "user_message", "msg": {"text": "hi"}}),
        json!({"kind": "agent_message_chunk", "msg": update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "API Error: 502 upstream request failed."}}))}),
        json!({"kind": "turn_end", "msg": {}, "at": 3000}),
    ];
    let mut c = chrome();
    c.version = Some("2.1.332".into());
    let grid = render(&records, &c, 50, 20);
    let text: Vec<String> = (0..20).map(|y| grid.row_text(y)).collect();
    let y = text.iter().position(|t| t.starts_with("⏺ API Error: 502")).expect("the error row");
    let amber = crate::Color::Rgb(255, 193, 7);
    assert_eq!(grid.cells[y][0].style.fg, amber, "dot");
    assert_eq!(grid.cells[y][2].style.fg, amber, "text");
    assert!(!text.iter().any(|t| t.contains("Worked for")), "no done line: {text:#?}");
}

fn put(grid: &mut Grid, y: usize, text: &str, style: Style) {
    for (x, ch) in text.chars().enumerate() {
        if let Some(cell) = grid.cells.get_mut(y).and_then(|r| r.get_mut(x)) {
            *cell = Cell { text: ch.to_string(), style };
        }
    }
}

/// Live gap 3: the host's dim placeholder reaches the phone, also when the cursor sits on
/// its first letter (drawn plain).
#[test]
fn the_placeholder_under_the_cursor_is_read_and_drawn() {
    let mut mac = Grid::blank(80, 6);
    put(&mut mac, 2, &"─".repeat(80), Style::PLAIN);
    put(&mut mac, 3, "❯\u{a0}R", Style::PLAIN);
    let dim = Style::PLAIN.with(FAINT);
    for (x, ch) in "esend your message to try again".chars().enumerate() {
        mac.cells[3][3 + x] = Cell { text: ch.to_string(), style: dim };
    }
    put(&mut mac, 4, &"─".repeat(80), Style::PLAIN);
    let facts = crate::claude_facts::ScreenFacts::read(&mac);
    assert_eq!(facts.draft, "");
    assert_eq!(facts.placeholder.as_deref(), Some("Resend your message to try again"));
    let mut c = chrome();
    c.version = Some("2.1.332".into());
    facts.apply(&mut c);
    let grid = render(&[], &c, 50, 12);
    assert!(
        (0..12).any(|y| grid.row_text(y) == "❯\u{a0}Resend your message to try again"),
        "drawn on the phone: {:#?}",
        (0..12).map(|y| grid.row_text(y)).collect::<Vec<_>>()
    );
}

/// Live gap 4: the host's one-time notice under the banner is drawn on the phone, laid out
/// again at its width, bar and styles kept.
#[test]
fn the_hosts_notice_is_laid_out_at_the_phones_width() {
    let bar = Style::fg(CLAUDE);
    let bold = Style::PLAIN.with(BOLD);
    let mut mac = Grid::blank(110, 6);
    put(&mut mac, 0, "▎ ", bar);
    put(&mut mac, 0, "  Auto mode is now Claude Code's default permission mode.", bold);
    put(&mut mac, 0, "▎", bar);
    put(&mut mac, 1, "▎", bar);
    put(
        &mut mac,
        1,
        "  Auto mode lets Claude handle permission prompts automatically.",
        Style::PLAIN,
    );
    put(&mut mac, 1, "▎", bar);
    put(&mut mac, 2, "▎", bar);
    put(&mut mac, 2, "  https://code.claude.com/docs/en/permission-modes", Style::PLAIN);
    put(&mut mac, 2, "▎", bar);
    let facts = crate::claude_facts::ScreenFacts::read(&mac);
    assert_eq!(facts.notice.len(), 3);
    let mut c = chrome();
    c.version = Some("2.1.332".into());
    facts.apply(&mut c);
    let grid = render(&[], &c, 40, 24);
    let text: Vec<String> = (0..24).map(|y| grid.row_text(y)).collect();
    let y = text.iter().position(|t| t.starts_with("▎ Auto mode is now")).expect("notice title");
    assert!(text.iter().all(|t| crate::str_width(t) <= 40), "fits: {text:#?}");
    assert_eq!(grid.cells[y][2].style.attrs & BOLD, BOLD, "the title stays bold");
    assert!(
        text.iter().any(|t| t == "▎ https://code.claude.com/docs/en/permission-modes"
            || t.starts_with("▎ https://")),
        "the link starts its own row: {text:#?}"
    );
    assert!(text.iter().filter(|t| t.starts_with('▎')).count() >= 4, "wrapped: {text:#?}");
}
