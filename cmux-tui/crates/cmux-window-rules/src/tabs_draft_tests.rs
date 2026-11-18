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
    assert_eq!(typed("caf\u{e9} \u{1f600}".as_bytes()), known("caf\u{e9} \u{1f600}"));
    // The kitty keyboard protocol's Enter, with and without its event type.
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
    // The kitty protocol's Ctrl+U, Ctrl+C and Ctrl+W, Caps Lock on or off.
    assert_eq!(typed(b"one two\x1b[117;5u"), known(""));
    assert_eq!(typed(b"one two\x1b[99;5u"), known(""));
    assert_eq!(typed(b"one two\x1b[119;5u"), known("one "));
    assert_eq!(typed(b"one two\x1b[119;69u"), known("one "));
}

#[test]
fn kitty_keys_type_text_and_their_releases_change_nothing() {
    // Releases (event type 3) and modifier keys alone are no input; a repeat is one more press.
    assert_eq!(typed(b"ab\x1b[13;1:3u\x1b[127;1:3u\x1b[1;1:3D"), known("ab"));
    assert_eq!(typed(b"a\x1b[57441;2uB"), known("aB"));
    assert_eq!(typed(b"abc\x1b[127;1:2u"), known("ab"));
    // Keys reported as codes (report all keys): the code, Shift's shifted key, or the report's text.
    assert_eq!(typed(b"\x1b[104u\x1b[105;1:1u"), known("hi"));
    assert_eq!(typed(b"\x1b[104:72;2u\x1b[105;1:3u"), known("H"));
    assert_eq!(typed(b"\x1b[97;1;233u"), known("\u{e9}"));
    // Shift with no shifted key, Ctrl or Alt with a letter, a functional key: not followed.
    assert_eq!(typed(b"a\x1b[104;2u"), Typed::Unknown);
    assert_eq!(typed(b"a\x1b[97;5u"), Typed::Unknown);
    assert_eq!(typed(b"a\x1b[98;3u"), Typed::Unknown);
    assert_eq!(typed(b"a\x1b[57399u"), Typed::Unknown);
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
        "> fix the login bug".to_string(),
        String::new(),
        "⏺ Added tests/login.rs.".to_string(),
        String::new(),
        "╭──────────────────────────────────────╮".to_string(),
        format!("│ > {draft:<36} │"),
        "╰──────────────────────────────────────╯".to_string(),
        "  ? for shortcuts".to_string(),
    ]
    .join("\n")
}

/// A Codex screen's bottom rows with `draft` in its composer.
fn codex_rows(draft: &str) -> String {
    [
        "› fix the login bug",
        "",
        "• Added tests/login.rs.",
        "",
        &format!("› {draft}"),
        "",
        "  ⏎ send",
    ]
    .join("\n")
}

#[test]
fn the_input_box_is_the_last_marked_row_and_the_rows_under_it() {
    assert_eq!(shown_input(&claude_rows("ship it")).as_deref(), Some("shipit"));
    assert_eq!(shown_input(&claude_rows("")).as_deref(), Some(""));
    assert_eq!(shown_input(&codex_rows("ship it")).as_deref(), Some("shipit"));
    assert_eq!(shown_input(&codex_rows("")).as_deref(), Some(""));
    // A long draft the box wraps, up to the box's rule.
    let wrapped = "│ > please refactor the login handler so │\n│   it checks the token     │\n╰──╯";
    assert_eq!(
        shown_input(wrapped).as_deref(),
        Some("pleaserefactortheloginhandlersoitchecksthetoken")
    );
    // No marked row in the bottom rows: a shell, or output still drawing.
    assert_eq!(shown_input("$ ls\nREADME.md\n$ "), None);
    let above = format!("{}{}", claude_rows("ship it"), "\nmore output".repeat(SCREEN_ROWS));
    assert_eq!(shown_input(&above), None);
}

fn to_chat_facts(typed: &[u8], screen: String) -> ToChat {
    ToChat { typed: typed.to_vec(), truncated: false, screen, composer_empty: true }
}

#[test]
fn a_typed_draft_the_input_box_shows_goes_to_an_empty_composer() {
    let facts = to_chat_facts(b"done\rnow add a test", claude_rows("now add a test"));
    assert_eq!(to_chat(&facts), ChatDraft::Carry { text: "now add a test".to_string(), erase: 14 });
    let codex = to_chat_facts(b"now add a test", codex_rows("now add a test"));
    assert_eq!(to_chat(&codex), ChatDraft::Carry { text: "now add a test".to_string(), erase: 14 });
    // A long draft the box wraps across two rows.
    let long = "please refactor the login handler so it checks the token";
    let rows = "│ > please refactor the login handler so │\n│   it checks the token                │\n╰───╯"
        .to_string();
    assert_eq!(
        to_chat(&to_chat_facts(long.as_bytes(), rows)),
        ChatDraft::Carry { text: long.to_string(), erase: long.chars().count() }
    );
    // A pasted draft of two lines: each new line is one more DEL.
    let pasted = to_chat_facts(b"\x1b[200~one\rtwo\x1b[201~", "│ > one\n│   two\n".to_string());
    assert_eq!(to_chat(&pasted), ChatDraft::Carry { text: "one\ntwo".to_string(), erase: 7 });
}

#[test]
fn nothing_goes_to_the_chat_unless_the_bytes_and_the_input_box_agree() {
    let draft = b"now add a test";
    // The composer holds something: never merged.
    let mut full = to_chat_facts(draft, claude_rows("now add a test"));
    full.composer_empty = false;
    assert_eq!(to_chat(&full), ChatDraft::None);
    // Nothing typed, or only spaces.
    assert_eq!(to_chat(&to_chat_facts(b"sent\r", claude_rows(""))), ChatDraft::None);
    assert_eq!(to_chat(&to_chat_facts(b"   ", claude_rows("   "))), ChatDraft::None);
    // A dialog took the keys: "1" chose an option, and its rows say so, not the draft.
    let dialog = "Do you want to proceed?\n❯ 1. Yes\n  2. No".to_string();
    assert_eq!(to_chat(&to_chat_facts(b"1", dialog)), ChatDraft::None);
    // The input held words the bytes never saw (typed before this app attached, or by another
    // client): the box shows more than the draft, so nothing moves and nothing is erased.
    assert_eq!(to_chat(&to_chat_facts(b" now", claude_rows("refactor auth now"))), ChatDraft::None);
    // An Enter that answered a dialog sent nothing: the box still holds the earlier words.
    let kept = to_chat_facts(b"next, fix X\rabc", claude_rows("next, fix Xabc"));
    assert_eq!(to_chat(&kept), ChatDraft::None);
    // The harness's Ctrl+W took a different word than the rules did.
    let word = to_chat_facts(b"see foo.bar\x17", claude_rows("see foo."));
    assert_eq!(to_chat(&word), ChatDraft::None);
    // A key the rules cannot follow, or bytes that start mid-draft.
    let arrow = to_chat_facts(b"now add\x1b[Da test", claude_rows("now ada testd"));
    assert_eq!(to_chat(&arrow), ChatDraft::None);
    let mut cut = to_chat_facts(draft, claude_rows("now add a test"));
    cut.truncated = true;
    assert_eq!(to_chat(&cut), ChatDraft::None);
}

fn to_terminal_facts(chat: Option<&str>, typed: &[u8], screen: String) -> ToTerminal {
    ToTerminal { chat: chat.map(str::to_string), typed: typed.to_vec(), truncated: false, screen }
}

#[test]
fn the_composers_draft_goes_to_a_terminal_whose_input_is_empty() {
    let paste = |text: &str| TerminalDraft::Paste { text: text.to_string() };
    let facts = |chat, typed: &[u8]| to_terminal_facts(Some(chat), typed, claude_rows(""));
    assert_eq!(to_terminal(&facts("add a test", b"")), paste("add a test"));
    assert_eq!(to_terminal(&facts("add a test", b"fix it\r")), paste("add a test"));
    assert_eq!(
        to_terminal(&to_terminal_facts(Some("add a test"), b"", codex_rows(""))),
        paste("add a test")
    );
    // A carried draft erased by its DELs is an empty input again.
    assert_eq!(to_terminal(&facts("again", b"fix\x7f\x7f\x7f")), paste("again"));
    // Trailing new lines stay behind.
    assert_eq!(to_terminal(&facts("add a test\n\n", b"")), paste("add a test"));
}

#[test]
fn nothing_goes_to_the_terminal_unless_its_input_is_surely_empty() {
    let none = TerminalDraft::None;
    // The terminal holds a draft of its own: never merged.
    let mine = to_terminal_facts(Some("add a test"), b"mine", claude_rows("mine"));
    assert_eq!(to_terminal(&mine), none);
    // The bytes say empty, but the box holds words they never saw (a relaunch, another client,
    // an Enter that answered a dialog): never merged.
    let unseen = to_terminal_facts(Some("add a test"), b"", claude_rows("refactor auth"));
    assert_eq!(to_terminal(&unseen), none);
    let answered =
        to_terminal_facts(Some("add a test"), b"next, fix X\r", claude_rows("next, fix X"));
    assert_eq!(to_terminal(&answered), none);
    // No input box on screen (a dialog, a shell).
    let shell = to_terminal_facts(Some("add a test"), b"", "$ ".to_string());
    assert_eq!(to_terminal(&shell), none);
    // The terminal's input is not known to be empty.
    let arrow = to_terminal_facts(Some("add a test"), b"x\x1b[A", claude_rows(""));
    assert_eq!(to_terminal(&arrow), none);
    let mut cut = to_terminal_facts(Some("add a test"), b"mid draft", claude_rows(""));
    cut.truncated = true;
    assert_eq!(to_terminal(&cut), none);
    // Several lines: a program without bracketed paste would send the first.
    let lines = to_terminal_facts(Some("rm -rf build\nnext step"), b"", claude_rows(""));
    assert_eq!(to_terminal(&lines), none);
    // Nothing to carry: an empty composer, or one whose draft cannot leave as text.
    assert_eq!(to_terminal(&to_terminal_facts(Some("  \n"), b"", claude_rows(""))), none);
    assert_eq!(to_terminal(&to_terminal_facts(None, b"", claude_rows(""))), none);
}

#[test]
fn a_draft_carried_both_ways_comes_back_whole() {
    // To the terminal: pasted (bracketed) into an empty input.
    let TerminalDraft::Paste { text } =
        to_terminal(&to_terminal_facts(Some("ship it"), b"x\r", claude_rows("")))
    else {
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
