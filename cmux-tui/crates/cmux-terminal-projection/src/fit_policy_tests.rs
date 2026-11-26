use super::*;

fn alt(program: &str) -> Foreground {
    Foreground { alternate: true, cursor_hidden: false, program: program_key(program) }
}

fn inline(program: &str) -> Foreground {
    Foreground { alternate: false, cursor_hidden: true, program: program_key(program) }
}

fn shell() -> Foreground {
    Foreground { alternate: false, cursor_hidden: false, program: None }
}

#[test]
fn viewing_a_tui_never_claims() {
    let mut policy = FitPolicy::new([]);
    let entered = policy.observe(alt("htop"));
    assert!(!entered.claims && !entered.changed);
    assert_eq!(entered.reason, FitReason::Projected);
    // Arrows, a mouse click, Escape, Ctrl-L, F10 and q: commands, not text.
    for keys in [
        &b"\x1b[A\x1b[B\x1b[C"[..],
        b"\x1b[<0;10;5M\x1b[<0;10;5m",
        b"\x1b",
        b"\x0c",
        b"\x1b[21~",
        b"\x1bOP",
    ] {
        assert!(!policy.typed(keys).claims, "{keys:?}");
    }
    assert!(!policy.typed(b"q").claims);
    assert!(!policy.claims());
    assert!(policy.remembered().is_empty());
}

#[test]
fn typing_text_into_a_tui_claims_once_and_remembers() {
    let mut policy = FitPolicy::new([]);
    policy.observe(alt("vim notes.md"));
    assert!(!policy.typed(b"i").claims);
    assert!(!policy.typed(b"h").claims);
    let fit = policy.typed(b"e");
    assert!(fit.claims && fit.changed && fit.remembered_changed);
    assert_eq!(fit.reason, FitReason::Typed);
    assert_eq!(policy.remembered(), ["vim"]);
    // More typing: still one claim.
    let more = policy.typed(b"llo world");
    assert!(more.claims && !more.changed && !more.remembered_changed);
}

#[test]
fn a_paste_or_a_word_at_once_claims() {
    let mut policy = FitPolicy::new([]);
    policy.observe(alt("codex"));
    assert!(policy.typed("héllo".as_bytes()).claims);
}

#[test]
fn exiting_releases_and_the_next_start_fits_at_once() {
    let mut policy = FitPolicy::new([]);
    policy.observe(alt("htop"));
    policy.typed(b"/claude");
    assert!(policy.claims());
    let exited = policy.observe(shell());
    assert!(!exited.claims && exited.changed);
    assert_eq!(exited.reason, FitReason::Projected);
    // Next time: fitted on entry, before a frame at the Mac's grid.
    assert!(policy.fits_on_entry(&alt("htop")));
    let again = policy.observe(alt("htop"));
    assert!(again.claims && again.changed);
    assert_eq!(again.reason, FitReason::Remembered);
    // Another program is its own.
    policy.observe(shell());
    assert!(!policy.observe(alt("less README")).claims);
}

#[test]
fn the_phone_leaving_releases_and_coming_back_claims_again() {
    let mut policy = FitPolicy::new(["htop".to_owned()]);
    assert!(policy.observe(alt("htop")).claims);
    let away = policy.set_page_present(false);
    assert!(!away.claims && away.changed);
    let back = policy.set_page_present(true);
    assert!(back.claims && back.changed);
    // Entered while away: nothing claimed until the page is back.
    policy.observe(shell());
    policy.set_page_present(false);
    assert!(!policy.observe(alt("htop")).claims);
    assert!(policy.set_page_present(true).claims);
}

#[test]
fn an_inline_tui_fits_when_typed_into_a_shell_never_does() {
    let mut policy = FitPolicy::new([]);
    policy.observe(inline("claude"));
    assert!(policy.typed(b"fix the bug").claims);
    assert_eq!(policy.remembered(), ["claude"]);
    policy.observe(shell());
    assert!(!policy.claims());
    // A shell, cursor shown or hidden, typed into: never.
    let mut fresh = FitPolicy::new([]);
    fresh.observe(Foreground { alternate: false, cursor_hidden: true, program: None });
    assert!(!fresh.typed(b"ls -la\r").claims);
    fresh.observe(shell());
    assert!(!fresh.typed(b"git status\r").claims);
}

#[test]
fn the_alternate_screen_of_an_unnamed_program_fits_but_is_not_remembered() {
    let mut policy = FitPolicy::new([]);
    policy.observe(Foreground { alternate: true, cursor_hidden: false, program: None });
    let fit = policy.typed(b"abc");
    assert!(fit.claims && !fit.remembered_changed);
    assert!(policy.remembered().is_empty());
}

#[test]
fn toggling_off_forgets_and_typing_does_not_refit_until_the_next_start() {
    let mut policy = FitPolicy::new([]);
    policy.observe(alt("vim"));
    policy.typed(b"iabc");
    assert!(policy.claims());
    let off = policy.toggle();
    assert!(!off.claims && off.changed && off.remembered_changed);
    assert!(policy.remembered().is_empty());
    assert!(!policy.typed(b"more text").claims, "declined: typing does not fit it again");
    // The next start of vim is projected, and typing fits it again.
    policy.observe(shell());
    policy.observe(alt("vim"));
    assert!(!policy.claims());
    assert!(policy.typed(b"abc").claims);
}

#[test]
fn toggling_on_fits_now_and_remembers() {
    let mut policy = FitPolicy::new([]);
    policy.observe(alt("htop"));
    let on = policy.toggle();
    assert!(on.claims && on.changed && on.remembered_changed);
    assert_eq!(on.reason, FitReason::Forced);
    assert_eq!(policy.remembered(), ["htop"]);
    policy.observe(shell());
    assert!(!policy.claims(), "it releases when the program exits");
    assert!(policy.observe(alt("htop")).claims);
}

#[test]
fn a_forced_fit_of_the_shell_lasts_until_toggled_off() {
    let mut policy = FitPolicy::new([]);
    policy.observe(shell());
    let on = policy.toggle();
    assert!(on.claims && !on.remembered_changed);
    // The shell's title changes (a directory): still fitted.
    assert!(
        policy.observe(Foreground { alternate: false, cursor_hidden: true, program: None }).claims
    );
    // A TUI starts: the shell's fit ends; the TUI is its own.
    assert!(!policy.observe(alt("htop")).claims);
    policy.observe(shell());
    assert!(policy.toggle().claims);
    assert!(!policy.toggle().claims);
}

#[test]
fn remembered_programs_are_bounded_and_most_recent_last() {
    let names: Vec<String> = (0..80).map(|i| format!("prog{i}")).collect();
    let mut policy = FitPolicy::new(names);
    assert_eq!(policy.remembered().len(), MAX_REMEMBERED);
    assert_eq!(policy.remembered().last().map(String::as_str), Some("prog79"));
    policy.observe(alt("prog20"));
    assert!(policy.claims());
    policy.observe(shell());
    policy.observe(alt("newone"));
    policy.typed(b"abc");
    assert_eq!(policy.remembered().len(), MAX_REMEMBERED);
    assert_eq!(policy.remembered().last().map(String::as_str), Some("newone"));
    assert!(!policy.is_remembered("prog16"), "the oldest went");
}

#[test]
fn a_text_typed_partly_in_one_program_does_not_carry_to_the_next() {
    let mut policy = FitPolicy::new([]);
    policy.observe(alt("htop"));
    policy.typed(b"ab");
    policy.observe(shell());
    policy.observe(alt("htop"));
    assert!(!policy.typed(b"c").claims);
}

#[test]
fn an_escape_sequence_split_across_sends_is_still_not_text() {
    let mut policy = FitPolicy::new([]);
    policy.observe(alt("htop"));
    for part in [&b"\x1b"[..], b"[", b"1;5", b"A", b"\x1b]52;c;aGVsbG8=", b"\x07"] {
        assert!(!policy.typed(part).claims, "{part:?}");
    }
    assert!(!policy.typed(b"q").claims);
}

#[test]
fn a_tui_retitling_itself_is_still_the_same_program() {
    let mut policy = FitPolicy::new([]);
    policy.observe(inline("claude"));
    policy.typed(b"hello");
    assert!(policy.claims());
    // Claude Code names its task in the title; the run is still claude's.
    let retitled = policy.observe(inline("✳ Fix the login bug"));
    assert!(retitled.claims && !retitled.changed);
    assert_eq!(policy.foreground().program.as_deref(), Some("claude"));
    assert_eq!(policy.remembered(), ["claude"]);
    // vim on the alternate screen, entered before its name reached the title.
    let mut vim = FitPolicy::new(["vim".to_owned()]);
    assert!(
        !vim.observe(Foreground { alternate: true, cursor_hidden: false, program: None }).claims
    );
    let named = vim.observe(alt("vim notes.md"));
    assert!(named.claims && named.changed, "named now: the remembered program fits");
    assert!(vim.observe(alt("notes.md (~/src) - VIM")).claims);
}

#[test]
fn a_fit_typed_before_the_program_was_named_is_remembered_once_it_is() {
    let mut policy = FitPolicy::new([]);
    policy.observe(Foreground { alternate: true, cursor_hidden: false, program: None });
    assert!(policy.typed(b"abc").claims);
    let named = policy.observe(alt("htop"));
    assert!(named.claims && named.remembered_changed);
    assert_eq!(policy.remembered(), ["htop"]);
}

#[test]
fn the_terminal_title_names_the_program() {
    let mut term = crate::Terminal::new(80, 24, 100);
    assert_eq!(term.title_text(), None);
    for (bytes, title) in [
        (&b"\x1b]2;htop\x07"[..], "htop"),
        (b"\x1b]0;vim README.md\x1b\\", "vim README.md"),
        ("\x1b]0;✳ Claude Code\x07".as_bytes(), "✳ Claude Code"),
    ] {
        for &byte in bytes {
            term.advance(byte);
        }
        assert_eq!(term.title_text().as_deref(), Some(title));
    }
    assert_eq!(program_key(&term.title_text().unwrap_or_default()).as_deref(), Some("claude"));
}

#[test]
fn program_keys() {
    for (title, key) in [
        ("htop", Some("htop")),
        ("vim README.md", Some("vim")),
        ("nvim — ~/src", Some("nvim")),
        ("/usr/bin/htop", Some("htop")),
        ("/opt/homebrew/bin/btop --utf-force", Some("btop")),
        ("✳ Claude Code", Some("claude")),
        ("Codex", Some("codex")),
        ("-zsh", None),
        ("zsh", None),
        ("bash", None),
        ("~/src/cmux", None),
        ("leo@mac: ~/src", None),
        ("leo@mac:~", None),
        ("/Users/leo/src/cmux", None),
        ("", None),
        ("   ", None),
        ("ssh build-box", None),
    ] {
        assert_eq!(program_key(title).as_deref(), key, "{title:?}");
    }
}
