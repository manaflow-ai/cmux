use super::*;

fn known(text: &str) -> Typed {
    Typed::Known(text.to_string())
}

fn typed(bytes: &[u8]) -> Typed {
    typed_draft(bytes, false)
}

#[test]
fn printable_text_after_the_last_enter_is_the_draft() {
    assert_eq!(typed(b""), known(""));
    assert_eq!(typed(b"hello"), known("hello"));
    assert_eq!(typed(b"first prompt\rsecond"), known("second"));
    assert_eq!(typed(b"sent\r"), known(""));
    // UTF-8 split across two writes of the terminal arrives joined.
    assert_eq!(typed("caf\u{e9} \u{1f600}".as_bytes()), known("caf\u{e9} \u{1f600}"));
    // The kitty keyboard protocol's Enter.
    assert_eq!(typed(b"sent\x1b[13usecond"), known("second"));
    assert_eq!(typed(b"sent\x1b[13;1:1usecond"), known("second"));
}

#[test]
fn backspace_takes_the_last_character() {
    assert_eq!(typed(b"helloo\x7f"), known("hello"));
    assert_eq!(typed(b"hello\x08\x08"), known("hel"));
    assert_eq!(typed("ab\u{e9}\x7f".as_bytes()), known("ab"));
    assert_eq!(typed(b"hi\x1b[127u"), known("h"));
    // More than there is deletes nothing more.
    assert_eq!(typed(b"a\x7f\x7f\x7f"), known(""));
}

#[test]
fn ctrl_u_and_ctrl_c_clear_and_ctrl_w_takes_a_word() {
    assert_eq!(typed(b"one two\x15three"), known("three"));
    assert_eq!(typed(b"one two\x03"), known(""));
    assert_eq!(typed(b"one two  \x17"), known("one "));
    assert_eq!(typed(b"one\x17"), known(""));
    assert_eq!(typed("one\u{3000}two\x17".as_bytes()), known("one\u{3000}"));
    // The kitty protocol's Ctrl+U, Ctrl+C and Ctrl+W.
    assert_eq!(typed(b"one two\x1b[117;5u"), known(""));
    assert_eq!(typed(b"one two\x1b[99;5u"), known(""));
    assert_eq!(typed(b"one two\x1b[119;5u"), known("one "));
}

#[test]
fn a_bracketed_paste_appends_newlines_and_all() {
    assert_eq!(
        typed(b"see \x1b[200~line one\rline two\x1b[201~ ok"),
        known("see line one\nline two ok")
    );
    assert_eq!(typed(b"\x1b[200~a\r\nb\nc\x1b[201~"), known("a\nb\nc"));
    // An Enter inside a paste sends nothing; one after it does.
    assert_eq!(typed(b"\x1b[200~a\rb\x1b[201~\r"), known(""));
    // A paste whose end has not arrived yet.
    assert_eq!(typed(b"\x1b[200~still coming"), Typed::Unknown);
    // The end of a paste whose start is not in the bytes.
    assert_eq!(typed(b"tail\x1b[201~"), Typed::Unknown);
}

#[test]
fn reports_and_answers_the_terminal_sends_on_its_own_are_ignored() {
    // Focus in and out.
    assert_eq!(typed(b"he\x1b[Ill\x1b[Oo"), known("hello"));
    // SGR mouse presses and releases.
    assert_eq!(typed(b"hi\x1b[<0;10;5M\x1b[<0;10;5m"), known("hi"));
    // Answers to queries: DA1, the kitty keyboard flags, a color (OSC, BEL and ST), XTGETTCAP.
    assert_eq!(typed(b"a\x1b[?62;22cb\x1b[?1uc"), known("abc"));
    assert_eq!(
        typed(b"a\x1b]11;rgb:0000/0000/0000\x07b\x1b]10;rgb:ffff/ffff/ffff\x1b\\c"),
        known("abc")
    );
    assert_eq!(typed(b"a\x1bP1+r544e=787465726d\x1b\\b"), known("ab"));
}

#[test]
fn a_key_that_moves_the_cursor_or_the_contents_makes_it_unknown() {
    for key in [
        &b"\x1b[D"[..], // left
        b"\x1b[A",      // up: history
        b"\x1bOA",      // up in application mode
        b"\x1b",        // Esc
        b"\x1bb",       // Alt+B
        b"\t",          // Tab: a completion
        b"\x01",        // Ctrl+A
        b"\x05",        // Ctrl+E
        b"\n",          // Ctrl+J
        b"\x1b[27u",    // Esc in the kitty protocol
        b"\x1b[13;2u",  // Shift+Enter: a new line in some harnesses
        b"\x1b[3~",     // Delete
    ] {
        let mut bytes = b"draft".to_vec();
        bytes.extend_from_slice(key);
        bytes.extend_from_slice(b"more");
        assert_eq!(typed(&bytes), Typed::Unknown, "{key:?}");
        // An Enter after it starts a fresh line the rules can follow again.
        bytes.extend_from_slice(b"\rnext");
        assert_eq!(typed(&bytes), known("next"), "{key:?}");
    }
}

#[test]
fn a_backslash_enter_is_a_new_line_not_a_send() {
    assert_eq!(typed(b"line one\\\rline two"), Typed::Unknown);
}

#[test]
fn bytes_that_start_after_the_input_began_are_unknown_until_an_enter() {
    assert_eq!(typed_draft(b"the middle of a draft", true), Typed::Unknown);
    assert_eq!(typed_draft(b"old\rnew", true), known("new"));
    assert_eq!(typed_draft(b"old\r", true), known(""));
}

/// A Claude Code screen's bottom rows with `draft` in its input box.
fn claude_rows(draft: &str) -> String {
    [
        "⏺ Added tests/login.rs.".to_string(),
        String::new(),
        "╭──────────────────────────────────────╮".to_string(),
        format!("│ > {draft:<36} │"),
        "╰──────────────────────────────────────╯".to_string(),
        "  ? for shortcuts".to_string(),
    ]
    .join("\n")
}

fn to_chat_facts(typed: &[u8], screen: String) -> ToChat {
    ToChat { typed: typed.to_vec(), truncated: false, screen, composer_empty: true }
}

#[test]
fn a_typed_draft_the_screen_shows_goes_to_an_empty_composer() {
    let facts = to_chat_facts(b"done\rnow add a test", claude_rows("now add a test"));
    assert_eq!(
        to_chat(&facts),
        ChatDraft::Carry { text: "now add a test".to_string(), erase: 14 + ERASE_SLACK }
    );
    // A long draft the box wraps: its last characters span two rows.
    let long = "please refactor the login handler so it checks the token";
    let rows = "│ > please refactor the login handler so │\n│   it checks the token                │\n╰───╯"
        .to_string();
    assert_eq!(
        to_chat(&to_chat_facts(long.as_bytes(), rows)),
        ChatDraft::Carry { text: long.to_string(), erase: long.chars().count() + ERASE_SLACK }
    );
    // A pasted draft of two lines.
    let pasted = to_chat_facts(b"\x1b[200~one\rtwo\x1b[201~", "│ > one\n│   two\n".to_string());
    assert_eq!(
        to_chat(&pasted),
        ChatDraft::Carry { text: "one\ntwo".to_string(), erase: 7 + ERASE_SLACK }
    );
}

#[test]
fn nothing_goes_to_the_chat_without_a_sure_shown_draft_and_an_empty_composer() {
    let draft = b"now add a test";
    // The composer holds something: never merged.
    let mut full = to_chat_facts(draft, claude_rows("now add a test"));
    full.composer_empty = false;
    assert_eq!(to_chat(&full), ChatDraft::None);
    // Nothing typed, or only spaces.
    assert_eq!(to_chat(&to_chat_facts(b"sent\r", claude_rows(""))), ChatDraft::None);
    assert_eq!(to_chat(&to_chat_facts(b"   ", claude_rows("   "))), ChatDraft::None);
    // The keys went somewhere the screen does not show (a dialog took them).
    let dialog = "Do you want to proceed?\n❯ 1. Yes\n  2. No".to_string();
    assert_eq!(to_chat(&to_chat_facts(draft, dialog)), ChatDraft::None);
    // The draft scrolled above the bottom rows the input lives in.
    let above = format!("{}\n{}", claude_rows("now add a test"), "\n".repeat(SCREEN_ROWS));
    assert_eq!(to_chat(&to_chat_facts(draft, above)), ChatDraft::None);
    // A key the rules cannot follow, or bytes that start mid-draft.
    assert_eq!(
        to_chat(&to_chat_facts(b"now add\x1b[Da test", claude_rows("now add a test"))),
        ChatDraft::None
    );
    let mut cut = to_chat_facts(draft, claude_rows("now add a test"));
    cut.truncated = true;
    assert_eq!(to_chat(&cut), ChatDraft::None);
}

#[test]
fn the_composers_draft_goes_to_a_terminal_with_an_empty_input() {
    let facts = |chat: Option<&str>, typed: &[u8], truncated| ToTerminal {
        chat: chat.map(str::to_string),
        typed: typed.to_vec(),
        truncated,
    };
    let paste = |text: &str| TerminalDraft::Paste { text: text.to_string() };
    assert_eq!(to_terminal(&facts(Some("add a test"), b"", false)), paste("add a test"));
    assert_eq!(to_terminal(&facts(Some("add a test"), b"fix it\r", false)), paste("add a test"));
    // A carried draft erased by its DELs is an empty input again.
    assert_eq!(
        to_terminal(&facts(Some("again"), b"fix\x7f\x7f\x7f\x7f\x7f", false)),
        paste("again")
    );
    // Trailing new lines stay behind: a pasted new line in a program without bracketed paste sends.
    assert_eq!(to_terminal(&facts(Some("one\ntwo\n\n"), b"", false)), paste("one\ntwo"));
    // The terminal holds a draft of its own: never merged.
    assert_eq!(to_terminal(&facts(Some("add a test"), b"mine", false)), TerminalDraft::None);
    // The terminal's input is not known to be empty.
    assert_eq!(to_terminal(&facts(Some("add a test"), b"x\x1b[A", false)), TerminalDraft::None);
    assert_eq!(to_terminal(&facts(Some("add a test"), b"mid draft", true)), TerminalDraft::None);
    // Nothing to carry: an empty composer, or one whose draft cannot leave as text.
    assert_eq!(to_terminal(&facts(Some("  \n"), b"", false)), TerminalDraft::None);
    assert_eq!(to_terminal(&facts(None, b"", false)), TerminalDraft::None);
}

#[test]
fn a_draft_carried_both_ways_comes_back_whole() {
    // To the terminal: pasted (bracketed) into an empty input.
    let TerminalDraft::Paste { text } = to_terminal(&ToTerminal {
        chat: Some("ship it".into()),
        typed: b"x\r".to_vec(),
        truncated: false,
    }) else {
        panic!("no paste")
    };
    let mut bytes = b"x\r\x1b[200~".to_vec();
    bytes.extend_from_slice(text.as_bytes());
    bytes.extend_from_slice(b"\x1b[201~");
    // Back to the chat: the same text, then the DELs that erase it leave the input empty.
    let ChatDraft::Carry { text, erase } = to_chat(&to_chat_facts(&bytes, claude_rows("ship it")))
    else {
        panic!("no carry")
    };
    assert_eq!(text, "ship it");
    bytes.extend(std::iter::repeat_n(0x7f, erase));
    assert_eq!(typed(&bytes), known(""));
}
