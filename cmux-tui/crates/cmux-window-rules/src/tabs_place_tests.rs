use super::*;

fn prompts(texts: &[&str]) -> Vec<String> {
    texts.iter().map(|text| text.to_string()).collect()
}

/// A resumed Claude Code session's screen: each prompt echoed after `> `, its reply below.
fn claude_screen() -> String {
    [
        "╭───────────────────────────╮",   // 0
        "│ ✻ Welcome to Claude Code! │",   // 1
        "╰───────────────────────────╯",   // 2
        "",                                // 3
        "> fix the login bug",             // 4
        "",                                // 5
        "⏺ The login bug is in auth.rs.",  // 6
        "  fix the login bug by checking", // 7
        "",                                // 8
        "> now add a test",                // 9
        "",                                // 10
        "⏺ Added tests/login.rs.",         // 11
        "",                                // 12
        "> fix the login bug",             // 13: the same words again, a later turn
        "",                                // 14
        "⏺ Done.",                         // 15
        "",                                // 16
        "> ",                              // 17: the input box
    ]
    .join("\n")
}

const CHAT: &[&str] = &["fix the login bug", "now add a test", "fix the login bug"];

#[test]
fn each_prompt_finds_its_own_row_newest_first() {
    // The repeated prompt's two turns land on their own rows, and the reply line that starts with
    // the first prompt's words (row 7) is not a prompt: it carries no mark.
    assert_eq!(prompt_rows(&prompts(CHAT), &claude_screen(), 80), vec![Some(4), Some(9), Some(13)]);
}

#[test]
fn the_terminal_lands_on_the_chats_turn() {
    let facts = |at| ToTerminal {
        prompts: prompts(CHAT),
        at,
        screen: claude_screen(),
        base: 0,
        columns: 80,
    };
    assert_eq!(terminal_place(&facts(Some(0))), TerminalPlace::Row { row: 4 });
    assert_eq!(terminal_place(&facts(Some(1))), TerminalPlace::Row { row: 9 });
    assert_eq!(terminal_place(&facts(Some(2))), TerminalPlace::Row { row: 13 });
    // A chat at its latest message: the terminal at its newest rows.
    assert_eq!(terminal_place(&facts(None)), TerminalPlace::Latest);
}

#[test]
fn the_chat_lands_on_the_terminals_turn() {
    let facts = |top, at_bottom| ToChat {
        prompts: prompts(CHAT),
        screen: claude_screen(),
        base: 0,
        columns: 80,
        top,
        at_bottom,
    };
    // The newest prompt at or above the viewport's top row.
    assert_eq!(chat_place(&facts(4, false)), ChatPlace::Turn { index: 0 });
    assert_eq!(chat_place(&facts(7, false)), ChatPlace::Turn { index: 0 });
    assert_eq!(chat_place(&facts(9, false)), ChatPlace::Turn { index: 1 });
    assert_eq!(chat_place(&facts(14, false)), ChatPlace::Turn { index: 2 });
    // Above the first prompt (the welcome box): the oldest turn the screen has.
    assert_eq!(chat_place(&facts(0, false)), ChatPlace::Turn { index: 0 });
    // The newest rows: the chat at its latest message.
    assert_eq!(chat_place(&facts(4, true)), ChatPlace::Latest);
}

#[test]
fn ten_swaps_keep_the_same_turn() {
    // Chat at turn 1 -> terminal at its row -> chat at the turn at that row, and so on.
    let mut at = 1;
    for _ in 0..10 {
        let row = match terminal_place(&ToTerminal {
            prompts: prompts(CHAT),
            at: Some(at),
            screen: claude_screen(),
            base: 0,
            columns: 80,
        }) {
            TerminalPlace::Row { row } => row,
            other => panic!("{other:?}"),
        };
        at = match chat_place(&ToChat {
            prompts: prompts(CHAT),
            screen: claude_screen(),
            base: 0,
            columns: 80,
            top: row,
            at_bottom: false,
        }) {
            ChatPlace::Turn { index } => index,
            other => panic!("{other:?}"),
        };
        assert_eq!(at, 1);
    }
}

#[test]
fn a_prompt_the_screen_lost_falls_back_to_an_older_one() {
    // The terminal's history no longer holds the oldest turn: the chat's prompts are a longer list.
    let chat = prompts(&[
        "an old prompt long gone",
        "fix the login bug",
        "now add a test",
        "fix the login bug",
    ]);
    let rows = prompt_rows(&chat, &claude_screen(), 80);
    assert_eq!(rows, vec![None, Some(4), Some(9), Some(13)]);
    let facts =
        ToTerminal { prompts: chat, at: Some(0), screen: claude_screen(), base: 0, columns: 80 };
    // Nothing older on the screen: the terminal stays where it is.
    assert_eq!(terminal_place(&facts), TerminalPlace::Stay);
    // A prompt not drawn (a turn the terminal never printed) lands on the one before it.
    let mut chat = prompts(CHAT);
    chat.insert(2, "a prompt the terminal never drew".into());
    let facts =
        ToTerminal { prompts: chat, at: Some(2), screen: claude_screen(), base: 0, columns: 80 };
    assert_eq!(terminal_place(&facts), TerminalPlace::Row { row: 9 });
}

#[test]
fn no_shared_prompt_leaves_both_views_where_they_are() {
    let screen = "$ ls\nREADME.md\n$ ".to_string();
    let to_terminal = ToTerminal {
        prompts: prompts(CHAT),
        at: Some(1),
        screen: screen.clone(),
        base: 0,
        columns: 80,
    };
    assert_eq!(terminal_place(&to_terminal), TerminalPlace::Stay);
    let to_chat =
        ToChat { prompts: prompts(CHAT), screen, base: 0, columns: 80, top: 0, at_bottom: false };
    assert_eq!(chat_place(&to_chat), ChatPlace::Stay);
    let empty =
        ToTerminal { prompts: vec![], at: Some(0), screen: claude_screen(), base: 0, columns: 80 };
    assert_eq!(terminal_place(&empty), TerminalPlace::Stay);
}

#[test]
fn a_long_prompt_matches_the_words_that_fit_its_first_row() {
    let prompt = "please refactor the session store so that every reader goes through one cache and nothing \
                  reads the disk twice";
    // A 40 column terminal wrapped the prompt at a word.
    let screen =
        "> please refactor the session store so\n  that every reader goes through one\n\n⏺ Sure.";
    assert_eq!(prompt_rows(&prompts(&[prompt]), screen, 40), vec![Some(0)]);
    // Only the first line of a prompt of several lines.
    let screen = "› first line of it\n  second line\n";
    assert_eq!(
        prompt_rows(&prompts(&["first line of it\nsecond line"]), screen, 80),
        vec![Some(0)]
    );
}

#[test]
fn a_harness_that_marks_no_prompt_still_matches_them() {
    let screen = "fix the login bug\nsome reply\nnow add a test\nanother reply";
    assert_eq!(
        prompt_rows(&prompts(&["fix the login bug", "now add a test"]), screen, 80),
        vec![Some(0), Some(2)]
    );
}

#[test]
fn a_long_chat_matches_in_one_pass() {
    // 2,000 turns and 20,000 rows: the row index keeps it to a lookup per prompt.
    let chat: Vec<String> =
        (0..2_000).map(|n| format!("prompt number {n} about the store")).collect();
    let mut screen = String::new();
    for prompt in &chat {
        screen.push_str(&format!("> {prompt}\n"));
        for line in 0..9 {
            screen.push_str(&format!("⏺ reply line {line}\n"));
        }
    }
    let started = std::time::Instant::now();
    let rows = prompt_rows(&chat, &screen, 120);
    assert_eq!(rows[0], Some(0));
    assert_eq!(rows[1_999], Some(19_990));
    assert!(started.elapsed() < std::time::Duration::from_millis(250), "{:?}", started.elapsed());
}

#[test]
fn a_window_of_the_newest_rows_answers_in_screen_rows() {
    // The app read only rows 9 on (a long history): rows come back as the screen's, not the window's.
    let window: String = claude_screen().lines().skip(9).collect::<Vec<_>>().join("\n");
    let facts = ToTerminal {
        prompts: prompts(CHAT),
        at: Some(1),
        screen: window.clone(),
        base: 9,
        columns: 80,
    };
    assert_eq!(terminal_place(&facts), TerminalPlace::Row { row: 9 });
    let facts = ToTerminal {
        prompts: prompts(CHAT),
        at: Some(2),
        screen: window.clone(),
        base: 9,
        columns: 80,
    };
    assert_eq!(terminal_place(&facts), TerminalPlace::Row { row: 13 });
    // Turn 0's prompt is above the window: nothing older in it either, so the terminal stays.
    let facts =
        ToTerminal { prompts: prompts(CHAT), at: Some(0), screen: window, base: 9, columns: 80 };
    assert_eq!(terminal_place(&facts), TerminalPlace::Stay);
}

#[test]
fn a_window_from_the_viewports_top_names_the_turn_above_it() {
    // The viewport's top is row 11, inside turn 1's reply; the window starts there, so turn 1's
    // prompt (row 9) is above it: the turn is the one before the first prompt below the top.
    let window: String = claude_screen().lines().skip(11).collect::<Vec<_>>().join("\n");
    let facts = |screen: String| ToChat {
        prompts: prompts(CHAT),
        screen,
        base: 11,
        columns: 80,
        top: 11,
        at_bottom: false,
    };
    assert_eq!(chat_place(&facts(window)), ChatPlace::Turn { index: 1 });
    // A window from the top that is a prompt row names that prompt.
    let window: String = claude_screen().lines().skip(13).collect::<Vec<_>>().join("\n");
    let facts = ToChat { base: 13, top: 13, ..facts(window) };
    assert_eq!(chat_place(&facts), ChatPlace::Turn { index: 2 });
}
