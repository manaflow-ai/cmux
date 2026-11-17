//! When a phone that projects a terminal claims its own grid after all.
//!
//! A projecting phone never sizes the Mac's PTY: the primary screen is
//! re-wrapped on the phone and the alternate screen is shown at the Mac's
//! exact grid, zoomed and panned ([`crate::zoom`]). A real resize (the phone
//! claims its grid, "fit to phone") is the exception, and it happens on its
//! own, never as a chore (Leo, 2026-11-17: "Surely we can just calculate a
//! f***ing terminal and resize whatever needs exceptions when it comes / Fall
//! back if need be"):
//!
//! - **Typing into a TUI fits it.** A TUI is the alternate screen, or an
//!   inline TUI on the primary screen (a program that is not a shell, drawing
//!   with its cursor hidden: Claude Code's and Codex's prompt boxes). The
//!   phone fits once the person has *typed text* into it: [`TYPED_TO_FIT`]
//!   printable characters since the program came to the foreground. A quit
//!   key (`q`), a few navigation keys, arrows, Escape, control keys, mouse
//!   reports and terminal replies never fit: reading htop or paging through
//!   `less` at the Mac's grid stays free of resizes, and pressing `q` to
//!   leave never costs the Mac pane a SIGWINCH on the way out.
//! - **It is remembered per program.** The program's key (its name, from the
//!   terminal title or the tab, see [`program_key`]) is kept, so the next
//!   time it comes to the foreground the phone fits at once, before the first
//!   frame at the Mac's grid (no scaled-then-fit flicker).
//! - **It releases** when the program leaves the foreground (the alternate
//!   screen ends, the inline TUI is gone, the title names another program) or
//!   when the phone leaves (the page stops claiming: [`FitPolicy::set_page_present`]).
//! - **The person can override it** (the title menu or the key bar's overflow):
//!   [`FitPolicy::toggle`] fits now and remembers, or unfits now, forgets the
//!   program and stops typing from fitting it again until it next starts.
//!
//! Pure state, no clock and no I/O: the phone persists [`FitPolicy::remembered`].
/// Printable characters typed into one foreground TUI that make the phone
/// fit it. Three: one or two keys (`q`, `jj`, `y`) are a viewer's commands,
/// a word is text being written.
pub const TYPED_TO_FIT: u32 = 3;

/// Programs remembered at most (oldest dropped first).
pub const MAX_REMEMBERED: usize = 64;

/// Names that are a shell (or a terminal with no program named).
const SHELLS: &[&str] = &[
    "sh",
    "bash",
    "zsh",
    "fish",
    "dash",
    "ksh",
    "mksh",
    "tcsh",
    "csh",
    "nu",
    "nushell",
    "xonsh",
    "elvish",
    "pwsh",
    "powershell",
    "cmd",
    "login",
    "terminal",
    "tmux",
    "screen",
    "ssh",
    "mosh",
];

/// What is in the terminal's foreground, as the phone sees it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Foreground {
    /// The alternate screen is up.
    pub alternate: bool,
    /// The primary screen's cursor is hidden (an inline TUI draws its own).
    pub cursor_hidden: bool,
    /// The program's key ([`program_key`]); `None`: a shell or unknown.
    pub program: Option<String>,
}

impl Foreground {
    /// A TUI: the alternate screen (never a shell's), or a named program that
    /// is not a shell drawing on the primary screen with its cursor hidden.
    pub fn is_tui(&self) -> bool {
        self.alternate || (self.cursor_hidden && self.program.is_some())
    }
}

/// Why the phone claims (or does not).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FitReason {
    /// Projected: the Mac keeps its grid.
    Projected,
    /// The person typed text into this TUI.
    Typed,
    /// This program was fitted before.
    Remembered,
    /// The person chose Fit to Phone.
    Forced,
}

/// The policy's answer after an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FitDecision {
    /// The phone claims its grid now (only while the page is present).
    pub claims: bool,
    /// `claims` changed with this event.
    pub changed: bool,
    pub reason: FitReason,
    /// The remembered set changed (persist [`FitPolicy::remembered`]).
    pub remembered_changed: bool,
}

/// One terminal's fit state.
#[derive(Debug, Clone)]
pub struct FitPolicy {
    remembered: Vec<String>,
    foreground: Foreground,
    /// Printable characters typed into the current TUI.
    typed: u32,
    /// The current foreground is fitted, and why.
    fitted: Option<FitReason>,
    /// The person unfitted the current foreground: typing does not fit it again.
    declined: bool,
    page_present: bool,
    /// In an escape sequence of typed bytes (`ESC`, CSI, SS3, OSC).
    escape: Escape,
    claims: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Escape {
    None,
    Esc,
    Csi,
    Ss3,
    String,
    StringEsc,
}

impl FitPolicy {
    /// A terminal's policy with the programs fitted before (most recent last).
    pub fn new(remembered: impl IntoIterator<Item = String>) -> FitPolicy {
        let mut kept: Vec<String> = Vec::new();
        for name in remembered {
            if let Some(key) = program_key(&name) {
                kept.retain(|k| *k != key);
                kept.push(key);
            }
        }
        let excess = kept.len().saturating_sub(MAX_REMEMBERED);
        kept.drain(..excess);
        FitPolicy {
            remembered: kept,
            foreground: Foreground::default(),
            typed: 0,
            fitted: None,
            declined: false,
            page_present: true,
            escape: Escape::None,
            claims: false,
        }
    }

    /// The programs that fit at once, most recent last (to persist).
    pub fn remembered(&self) -> &[String] {
        &self.remembered
    }

    pub fn is_remembered(&self, program: &str) -> bool {
        program_key(program).is_some_and(|key| self.remembered.contains(&key))
    }

    pub fn foreground(&self) -> &Foreground {
        &self.foreground
    }

    /// Whether the phone claims its grid now.
    pub fn claims(&self) -> bool {
        self.claims
    }

    /// Whether the current foreground is fitted (claimed while the page is present).
    pub fn is_fitted(&self) -> bool {
        self.fitted.is_some()
    }

    /// Whether the current foreground would fit the moment it is entered:
    /// the caller holds frames at the Mac's grid instead of flashing them.
    pub fn fits_on_entry(&self, foreground: &Foreground) -> bool {
        foreground.is_tui()
            && foreground.program.as_ref().is_some_and(|p| self.remembered.contains(p))
    }

    /// What is in the foreground now (after each feed). A new program starts
    /// over: unfitted unless remembered, nothing typed.
    ///
    /// A TUI's run lasts while the same screen keeps a TUI on it: its key is
    /// the first one named in the run, and later titles (Claude Code's `✳
    /// <task>`, vim's `file - VIM`) do not make it another program. Call it
    /// once per feed, so a cursor hidden and shown inside one redraw is not
    /// the inline TUI ending.
    pub fn observe(&mut self, foreground: Foreground) -> FitDecision {
        if foreground == self.foreground {
            return self.decision(false);
        }
        let was = std::mem::take(&mut self.foreground);
        let continues =
            was.is_tui() && foreground.is_tui() && was.alternate == foreground.alternate;
        if continues {
            let named_now = was.program.is_none() && foreground.program.is_some();
            self.foreground =
                Foreground { program: was.program.or(foreground.program), ..foreground };
            let mut remembered_changed = false;
            if named_now {
                // Named only now: a fit typed before is remembered, a program
                // fitted before fits.
                if self.fitted == Some(FitReason::Typed) || self.fitted == Some(FitReason::Forced) {
                    remembered_changed = self.remember();
                } else if self.fitted.is_none()
                    && !self.declined
                    && self.fits_on_entry(&self.foreground)
                {
                    self.fitted = Some(FitReason::Remembered);
                }
            }
            return self.decision(remembered_changed);
        }
        let starts_tui = foreground.is_tui();
        self.foreground = foreground;
        if !was.is_tui() && !starts_tui {
            // A shell's title or cursor changed: a forced fit of the shell stays.
            return self.decision(false);
        }
        // A TUI started or ended: a new run, unfitted unless remembered.
        self.typed = 0;
        self.declined = false;
        self.fitted = None;
        if self.fits_on_entry(&self.foreground) {
            self.fitted = Some(FitReason::Remembered);
        }
        self.decision(false)
    }

    /// Bytes the person sent (keys, the key bar, the composer, a paste).
    /// Escape sequences (arrows, function keys, mouse reports) and control
    /// characters are not text and never count.
    pub fn typed(&mut self, bytes: &[u8]) -> FitDecision {
        let printable = self.count_printable(bytes);
        if !self.foreground.is_tui() || self.fitted.is_some() || self.declined || printable == 0 {
            return self.decision(false);
        }
        self.typed = self.typed.saturating_add(printable);
        if self.typed < TYPED_TO_FIT {
            return self.decision(false);
        }
        self.fitted = Some(FitReason::Typed);
        let remembered_changed = self.remember();
        self.decision(remembered_changed)
    }

    /// Fit to Phone from the title menu or the key bar: unfit a fitted
    /// foreground (forget its program, and typing does not fit it again until
    /// it next starts), or fit it now (and remember it).
    pub fn toggle(&mut self) -> FitDecision {
        if self.fitted.is_some() {
            self.fitted = None;
            self.declined = true;
            let before = self.remembered.len();
            if let Some(program) = &self.foreground.program {
                self.remembered.retain(|p| p != program);
            }
            let changed = before != self.remembered.len();
            self.decision(changed)
        } else {
            self.fitted = Some(FitReason::Forced);
            self.declined = false;
            let changed = self.foreground.is_tui() && self.remember();
            self.decision(changed)
        }
    }

    /// The page is on screen and interactive (or not: another tab, the
    /// background). Away, the phone claims nothing; the fit comes back with it.
    pub fn set_page_present(&mut self, present: bool) -> FitDecision {
        self.page_present = present;
        self.decision(false)
    }

    fn remember(&mut self) -> bool {
        let Some(program) = self.foreground.program.clone() else { return false };
        if self.remembered.last() == Some(&program) {
            return false;
        }
        self.remembered.retain(|p| *p != program);
        self.remembered.push(program);
        let excess = self.remembered.len().saturating_sub(MAX_REMEMBERED);
        self.remembered.drain(..excess);
        true
    }

    fn decision(&mut self, remembered_changed: bool) -> FitDecision {
        let claims = self.page_present && self.fitted.is_some();
        let changed = claims != self.claims;
        self.claims = claims;
        FitDecision {
            claims,
            changed,
            reason: self.fitted.unwrap_or(FitReason::Projected),
            remembered_changed,
        }
    }

    fn count_printable(&mut self, bytes: &[u8]) -> u32 {
        let mut count = 0u32;
        for &byte in bytes {
            self.escape = match (self.escape, byte) {
                (Escape::None, 0x1b) => Escape::Esc,
                (Escape::None, b) => {
                    // UTF-8 lead bytes and ASCII printables count once per character.
                    if (0x20..0x7f).contains(&b) || b >= 0xc0 {
                        count += 1;
                    }
                    Escape::None
                }
                (Escape::Esc, b'[') => Escape::Csi,
                (Escape::Esc, b'O') => Escape::Ss3,
                (Escape::Esc, b']' | b'P' | b'_' | b'^') => Escape::String,
                // Alt+key (ESC then the key) is a command, not text.
                (Escape::Esc, _) => Escape::None,
                (Escape::Csi, 0x40..=0x7e) => Escape::None,
                (Escape::Csi, _) => Escape::Csi,
                (Escape::Ss3, _) => Escape::None,
                (Escape::String, 0x07) => Escape::None,
                (Escape::String, 0x1b) => Escape::StringEsc,
                (Escape::String, _) => Escape::String,
                (Escape::StringEsc, b'\\') => Escape::None,
                (Escape::StringEsc, _) => Escape::String,
            };
        }
        count
    }
}

/// A program's key from a terminal title or a tab title: its command's
/// name, lowercased (`vim README.md` → `vim`, `/usr/bin/htop` → `htop`,
/// `✳ Claude Code` → `claude`). `None` for a shell, a folder (`~/src`,
/// `user@host: ~/src`) or nothing.
pub fn program_key(title: &str) -> Option<String> {
    let title = title.trim();
    // `user@host: dir` and `user@host:dir` are a shell's prompt titles.
    if let Some((before, _)) = title.split_once(':')
        && before.contains('@')
        && !before.contains(' ')
    {
        return None;
    }
    // Leading symbols (Claude Code's `✳`, a spinner, `-` of a login shell).
    let start = title
        .find(|c: char| c.is_alphanumeric() || c == '/' || c == '~' || c == '.')
        .unwrap_or(title.len());
    let rest = title.get(start..).unwrap_or_default();
    let first =
        rest.split(|c: char| c.is_whitespace() || c == '—' || c == '–').next().unwrap_or_default();
    if first.is_empty()
        || first.starts_with('~')
        || (first.starts_with('/') && first.ends_with('/'))
    {
        return None;
    }
    let name = first.rsplit('/').next().unwrap_or(first).trim_end_matches(':').to_lowercase();
    if name.is_empty() || name.starts_with('.') || SHELLS.contains(&name.as_str()) {
        return None;
    }
    // A path title (`/Users/x/src`): its last part is a folder, not a command.
    if first.starts_with('/') && first.matches('/').count() > 1 && !first.contains("/bin/") {
        return None;
    }
    Some(name)
}

#[cfg(test)]
mod tests {
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
            policy
                .observe(Foreground { alternate: false, cursor_hidden: true, program: None })
                .claims
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
            !vim.observe(Foreground { alternate: true, cursor_hidden: false, program: None })
                .claims
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
}
