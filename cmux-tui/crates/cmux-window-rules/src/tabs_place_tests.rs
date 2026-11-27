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

/// The swap's driver as `TerminalChatPlacing` runs it over these rules, on a fake terminal and
/// chat (the app's TerminalChatPlaceTests' cases, held here on Linux).
mod swap {
    use super::*;

    const SCREEN: &[&str] = &[
        "> fix the login bug",
        "",
        "⏺ In auth.rs.",
        "",
        "> now add a test",
        "",
        "⏺ Added.",
        "",
        "> ",
    ];
    const PROMPTS: &[&str] = &["fix the login bug", "now add a test"];

    struct Terminal {
        rows: Vec<String>,
        visible: usize,
        top: usize,
        scrolls: Vec<Option<usize>>,
        reads: Vec<(usize, usize)>,
    }

    impl Terminal {
        fn new(rows: Vec<String>, top: Option<usize>) -> Self {
            let visible = 5;
            let top = top.unwrap_or(rows.len().saturating_sub(visible));
            Terminal { rows, visible, top, scrolls: vec![], reads: vec![] }
        }
        fn bottom(&self) -> usize {
            self.rows.len().saturating_sub(self.visible)
        }
        fn at_bottom(&self) -> bool {
            self.top >= self.bottom()
        }
        fn read(&mut self, from_top: bool, through_bottom: bool) -> String {
            let first = if from_top { self.top } else { 0 };
            let last = if through_bottom {
                self.rows.len().min(self.top + self.visible) - 1
            } else {
                self.rows.len() - 1
            };
            self.reads.push((first, last));
            self.rows[first..=last].join("\n")
        }
        fn scroll(&mut self, row: Option<usize>) {
            self.scrolls.push(row);
            self.top = row.unwrap_or(self.bottom()).min(self.bottom());
        }
    }

    struct Chat {
        at: Option<usize>,
        shows: Vec<Option<usize>>,
        reads: usize,
    }

    fn chat(at: Option<usize>) -> Chat {
        Chat { at, shows: vec![], reads: 0 }
    }

    fn screen() -> Vec<String> {
        prompts(SCREEN)
    }

    fn long_screen() -> Vec<String> {
        let mut rows = vec!["older output".to_string(); 40];
        rows.extend(screen());
        rows.push(String::new());
        rows
    }

    fn place_terminal(chat: &mut Chat, terminal: &mut Terminal, rows: usize) {
        let (top, at_bottom) = (terminal.top, terminal.at_bottom());
        chat.reads += 1;
        let read =
            terminal_read(&TerminalReadFacts { at: chat.at, total: terminal.rows.len(), rows });
        let TerminalRead::Screen { base, from_viewport_top } = read else {
            return terminal.scroll(None);
        };
        if base > 0 {
            terminal.scroll(Some(base));
        }
        let screen = terminal.read(from_viewport_top, false);
        let place =
            ToTerminal { prompts: prompts(PROMPTS), at: chat.at, screen, base, columns: 80 };
        match terminal_scroll(&ToTerminalScroll { place, top, at_bottom }) {
            TerminalScroll::Row { row } => terminal.scroll(Some(row)),
            TerminalScroll::Latest => terminal.scroll(None),
            TerminalScroll::Keep => {}
        }
    }

    fn place_chat(chat: &mut Chat, terminal: &mut Terminal, rows: usize) {
        let facts = ChatReadFacts {
            top: terminal.top,
            visible: terminal.visible,
            total: terminal.rows.len(),
            at_bottom: terminal.at_bottom(),
            at_latest: chat.at.is_none(),
            rows,
        };
        let (base, from_top, through) = match chat_read(&facts) {
            ChatRead::Latest { show } => {
                if show {
                    chat.shows.push(None);
                    chat.at = None;
                }
                return;
            }
            ChatRead::Stay => return,
            ChatRead::Screen { base, from_viewport_top, through_viewport_bottom } => {
                (base, from_viewport_top, through_viewport_bottom)
            }
        };
        chat.reads += 1;
        let screen = terminal.read(from_top, through);
        let place = ToChat {
            prompts: prompts(PROMPTS),
            screen,
            base,
            columns: 80,
            top: terminal.top,
            at_bottom: false,
        };
        let show = match chat_show(&ToChatShow { place, at: chat.at }) {
            ChatShow::Latest => None,
            ChatShow::Turn { index } => Some(index),
            ChatShow::Stay => return,
        };
        chat.shows.push(show);
        chat.at = show;
    }

    #[test]
    fn the_terminal_shows_at_the_chats_turn() {
        let mut terminal = Terminal::new(screen(), None);
        place_terminal(&mut chat(Some(0)), &mut terminal, READ_ROWS);
        assert_eq!(terminal.scrolls, vec![Some(0)]);
        let mut other = Terminal::new(screen(), Some(0));
        place_terminal(&mut chat(Some(1)), &mut other, READ_ROWS);
        assert_eq!(other.scrolls, vec![Some(4)]);
    }

    #[test]
    fn the_chat_shows_at_the_terminals_turn() {
        let (mut chat, mut terminal) = (chat(None), Terminal::new(screen(), Some(2)));
        place_chat(&mut chat, &mut terminal, READ_ROWS);
        assert_eq!(chat.shows, vec![Some(0)]);
        // The terminal back at its newest rows: the chat at its latest message.
        terminal.top = terminal.bottom();
        place_chat(&mut chat, &mut terminal, READ_ROWS);
        assert_eq!(chat.shows, vec![Some(0), None]);
    }

    #[test]
    fn a_chat_at_its_latest_brings_the_terminal_to_its_newest_rows() {
        let (mut chat, mut terminal) = (chat(None), Terminal::new(screen(), Some(0)));
        place_terminal(&mut chat, &mut terminal, READ_ROWS);
        assert_eq!(terminal.scrolls, vec![None]);
        assert!(terminal.reads.is_empty());
    }

    #[test]
    fn both_at_their_latest_move_nothing_going_to_the_chat() {
        let (mut chat, mut terminal) = (chat(None), Terminal::new(screen(), None));
        place_chat(&mut chat, &mut terminal, READ_ROWS);
        assert!(chat.reads == 0 && chat.shows.is_empty() && terminal.reads.is_empty());
    }

    #[test]
    fn ten_swaps_on_a_scrolled_up_turn_keep_it() {
        let (mut chat, mut terminal) = (chat(Some(0)), Terminal::new(screen(), None));
        for _ in 0..10 {
            place_terminal(&mut chat, &mut terminal, READ_ROWS);
            assert_eq!(terminal.top, 0);
            place_chat(&mut chat, &mut terminal, READ_ROWS);
            assert_eq!(chat.at, Some(0));
        }
        assert!(chat.shows.is_empty());
    }

    #[test]
    fn a_long_history_is_read_only_as_far_as_the_cap() {
        let mut terminal = Terminal::new(long_screen(), None);
        place_terminal(&mut chat(Some(1)), &mut terminal, 10);
        assert_eq!(terminal.reads, vec![(40, 49)]);
        assert_eq!(terminal.scrolls, vec![Some(40), Some(44)]);
        let (mut shown, mut chat_none) = (Terminal::new(long_screen(), Some(44)), chat(None));
        place_chat(&mut chat_none, &mut shown, 10);
        assert_eq!(shown.reads, vec![(44, 49)]);
        assert!(chat_none.shows == vec![Some(1)] && shown.scrolls.is_empty());
        let (mut far, mut stays) = (Terminal::new(long_screen(), Some(20)), chat(None));
        place_chat(&mut stays, &mut far, 10);
        assert!(far.reads.is_empty() && stays.shows.is_empty());
    }

    #[test]
    fn a_turn_the_window_lacks_puts_the_hidden_terminal_back() {
        let mut terminal = Terminal::new(long_screen(), None);
        place_terminal(&mut chat(Some(0)), &mut terminal, 5);
        assert_eq!(terminal.scrolls, vec![Some(45), None]);
        assert!(terminal.at_bottom());
    }

    #[test]
    fn rows_default_to_the_read_cap() {
        let facts: ChatReadFacts =
            serde_json::from_str(r#"{"top":1,"visible":5,"total":9}"#).unwrap();
        assert_eq!(facts.rows, READ_ROWS);
        let facts: TerminalReadFacts = serde_json::from_str(r#"{"at":0,"total":30000}"#).unwrap();
        assert_eq!(
            terminal_read(&facts),
            TerminalRead::Screen { base: 10_000, from_viewport_top: true }
        );
    }
}
