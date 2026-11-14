//! A terminal's title as the program in it sets it (plans/cmux-next/osc-titles.md).
//!
//! libghostty-vt stores the OSC 0/2 title, but it treats xterm's title stack
//! (`CSI 22 ; Ps t` push, `CSI 23 ; Ps t` pop) as a no-op and drops OSC 1
//! (the icon name). [`TitleTracker`] follows the title in the output stream
//! and turns each pop into the `OSC 2` that restores the pushed title, and
//! an OSC 1 that comes before any OSC 0/2 into the `OSC 2` it stands for. The
//! rewrite only inserts bytes after a whole sequence, so the terminal, every
//! mirror fed the normalized stream and every attach client see one title.
//!
//! [`sanitize`] is the one way the daemon reads a title out of a terminal:
//! no control characters, no bidi overrides, at most [`MAX_TITLE_CHARS`].
//! [`TabTitle::terminal`] is the one rule for what a tab shows of it: the
//! text without the leading status glyphs, and their [`TitleActivity`].

use std::borrow::Cow;
use std::sync::Arc;

/// The longest title the daemon stores or sends, in characters.
pub(crate) const MAX_TITLE_CHARS: usize = 256;

/// The title read from `term`, sanitized; empty when the program set none.
pub(crate) fn read(term: &ghostty_vt::Terminal) -> String {
    sanitize(&term.title().unwrap_or_default())
}

/// `raw` without control characters, bidi controls or invisible separators,
/// trimmed and cut to [`MAX_TITLE_CHARS`]. A tab, newline or carriage return
/// reads as a space; a zero width joiner stays, it holds emoji together.
pub(crate) fn sanitize(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len().min(MAX_TITLE_CHARS * 4));
    let mut count = 0;
    for ch in raw.trim().chars() {
        let ch = match ch {
            '\t' | '\n' | '\r' => ' ',
            c if c.is_control() || is_hidden_format(c) => continue,
            c => c,
        };
        if count == MAX_TITLE_CHARS {
            break;
        }
        out.push(ch);
        count += 1;
    }
    out.truncate(out.trim_end().len());
    out
}

/// Bidi embeddings, overrides, isolates and marks (a title could otherwise
/// show `exe.gpj` as `jpg.exe`), and invisible separators.
fn is_hidden_format(c: char) -> bool {
    matches!(
        c,
        '\u{061C}'
            | '\u{200B}'
            | '\u{200E}'
            | '\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{2069}'
            | '\u{FEFF}'
    )
}

/// What a leading status glyph of a terminal title says about the program.
///
/// Agents animate their title: Claude Code writes `⠂ Fix the login bug`,
/// `⠐ Fix the login bug`, … while it works and `✳ Fix the login bug` when it
/// waits. [`TabTitle::terminal`] moves those glyphs into an activity, so a
/// spinner frame changes nothing a tab shows and the daemon announces nothing
/// for it (plans/cmux-next/main-thread-scheduling.md, D2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TitleActivity {
    /// A spinner frame (Braille dots, a turning circle): the program works.
    Working,
    /// A resting marker (`✳`, `●`, `⏺`): the program waits.
    Idle,
    /// A check mark: the program finished.
    Done,
    /// A cross: the program failed.
    Failed,
}

impl TitleActivity {
    /// The wire name (`title-changed`'s and a tab snapshot's `title_activity`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Idle => "idle",
            Self::Done => "done",
            Self::Failed => "failed",
        }
    }

    /// The activity a wire name names; `None` for an unknown name.
    pub fn from_wire(name: &str) -> Option<Self> {
        match name {
            "working" => Some(Self::Working),
            "idle" => Some(Self::Idle),
            "done" => Some(Self::Done),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }

    fn of(c: char) -> Option<Self> {
        match u32::from(c) {
            // Braille patterns: every terminal spinner frame (`⠋⠙⠹`, Claude's `⠂⠐`).
            0x2801..=0x28FF => Some(Self::Working),
            // Turning circles and half blocks used as spinners.
            0x25D0..=0x25D3 | 0x25F4..=0x25F7 | 0x2596..=0x259F => Some(Self::Working),
            // Claude Code's resting asterisks, a filled or empty dot, a record mark.
            0x2733 | 0x2736 | 0x273B | 0x273D | 0x2722 | 0x00B7 | 0x25CF | 0x25CB | 0x25C9
            | 0x23FA => Some(Self::Idle),
            0x2713 | 0x2714 | 0x2705 => Some(Self::Done),
            0x2717 | 0x2718 | 0x274C => Some(Self::Failed),
            _ => None,
        }
    }
}

/// What a tab shows of a title: its text and what its leading glyphs said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabTitle {
    /// The title without its leading status glyphs; empty for none.
    pub text: Arc<str>,
    /// What the stripped glyphs said; `None` when the title had none.
    pub activity: Option<TitleActivity>,
}

impl TabTitle {
    /// A page's title: shown as is (a remote terminal tab uses the terminal rule).
    pub fn page(raw: &str) -> Self {
        Self { text: Arc::from(raw), activity: None }
    }

    /// A terminal's title (already [`sanitize`]d) split into its text and the
    /// activity its leading glyphs name. `✳ ⠂ Task` reads as working (the last
    /// glyph wins); a title of glyphs only keeps them as its text, so the tab
    /// is not blank.
    pub fn terminal(raw: &str) -> Self {
        let mut rest = raw;
        let mut activity = None;
        loop {
            let mut chars = rest.chars();
            let Some(found) = chars.next().and_then(TitleActivity::of) else { break };
            activity = Some(found);
            rest = chars
                .as_str()
                // A variation selector (`✔︎`) belongs to the glyph before it.
                .trim_start_matches(is_variation_selector)
                .trim_start_matches(char::is_whitespace);
        }
        let words = rest.trim();
        let text = if words.is_empty() { raw.trim() } else { words };
        Self { text: Arc::from(text), activity }
    }
}

impl TabTitle {
    /// What a tab of `kind` (a tree tab's `kind`) shows of `raw`: a local or a
    /// remote terminal's title loses its status glyphs, any other shows as is.
    pub(crate) fn of_kind(kind: Option<&str>, raw: &str) -> Self {
        match kind {
            Some("pty" | crate::state::remote_terminal_tabs_store::REMOTE_TERMINAL_KIND) => {
                Self::terminal(raw)
            }
            _ => Self::page(raw),
        }
    }

    /// What a `list-workspaces` tab shows: its `title_text` and
    /// `title_activity`, or, from a daemon before them, the rule of its kind
    /// over its raw `title`. Clients show this and never the raw title, which
    /// keeps a spinner frame the daemon does not announce.
    pub fn of_tree_tab(tab: &serde_json::Value) -> Self {
        let field = |name| tab.get(name).and_then(serde_json::Value::as_str);
        let Some(text) = field("title_text") else {
            return Self::of_kind(field("kind"), field("title").unwrap_or_default());
        };
        let activity = field("title_activity").and_then(TitleActivity::from_wire);
        Self { text: Arc::from(text), activity }
    }
}

/// Unicode's `Variation_Selector` property.
fn is_variation_selector(c: char) -> bool {
    matches!(c, '\u{180B}'..='\u{180D}' | '\u{180F}' | '\u{FE00}'..='\u{FE0F}' | '\u{E0100}'..='\u{E01EF}')
}

/// Stores `title` as the terminal's raw title. Returns it when what a tab
/// shows of it ([`TabTitle::terminal`]) moved: a spinner frame, or a program
/// that writes the same title again, announces nothing.
pub(crate) fn store(stored: &mut String, title: String) -> Option<String> {
    if *stored == title {
        return None;
    }
    let moved = TabTitle::terminal(stored) != TabTitle::terminal(&title);
    *stored = title;
    moved.then(|| stored.clone())
}

/// How many pushed titles the stack keeps, as xterm does.
const MAX_STACK: usize = 10;
/// The most title bytes kept: libghostty-vt cuts a title to 1024 bytes too.
const MAX_TITLE_BYTES: usize = 1024;
/// The most CSI parameter bytes followed; a longer CSI is no title op.
const MAX_CSI_BYTES: usize = 16;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum ScanState {
    #[default]
    Ground,
    Escape,
    Csi,
    /// A CSI too long or too odd to be a title op: skipped to its final byte.
    CsiIgnore,
    Osc,
    /// An ESC inside an OSC: `\` ends it (ST), anything else aborts it.
    OscEscape,
}

/// Follows OSC 0/1/2 and the xterm title stack across output chunks.
#[derive(Debug, Default)]
pub(crate) struct TitleTracker {
    state: ScanState,
    csi: Vec<u8>,
    osc: Vec<u8>,
    /// The title as the stream set it: what a push saves.
    title: Vec<u8>,
    /// An OSC 0 or 2 set the title; from then on OSC 1 names only the icon.
    titled: bool,
    stack: Vec<Vec<u8>>,
}

impl TitleTracker {
    /// `data` with the title sequences libghostty-vt cannot apply rewritten
    /// into the `OSC 2` that applies them; borrowed when nothing changed.
    // perf-hot: 0.1ns/byte terminal-output-scan (every output byte, host and daemon)
    pub(crate) fn rewrite<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        let mut out: Option<Vec<u8>> = None;
        let mut copied = 0;
        let mut index = 0;
        while let Some(rest) = data.get(index..) {
            // On the ground only an ESC starts a sequence: jump to the next one.
            if self.state == ScanState::Ground {
                let Some(offset) = memchr::memchr(0x1b, rest) else { break };
                index = index.saturating_add(offset);
            }
            let Some(&byte) = data.get(index) else { break };
            index = index.saturating_add(1);
            let Some(title) = self.step(byte) else { continue };
            let out = out.get_or_insert_with(|| {
                Vec::with_capacity(data.len().saturating_add(title.len()).saturating_add(6))
            });
            out.extend_from_slice(data.get(copied..index).unwrap_or_default());
            copied = index;
            out.extend_from_slice(b"\x1b]2;");
            out.extend_from_slice(&title);
            out.push(0x07);
        }
        match out {
            None => Cow::Borrowed(data),
            Some(mut out) => {
                out.extend_from_slice(data.get(copied..).unwrap_or_default());
                Cow::Owned(out)
            }
        }
    }

    /// Advances over one byte; `Some(title)` when the sequence it ends needs
    /// an `OSC 2 ; title` right after it.
    fn step(&mut self, byte: u8) -> Option<Vec<u8>> {
        match self.state {
            ScanState::Ground => {
                if byte == 0x1b {
                    self.state = ScanState::Escape;
                }
                None
            }
            ScanState::Escape => {
                self.state = match byte {
                    b'[' => {
                        self.csi.clear();
                        ScanState::Csi
                    }
                    b']' => {
                        self.osc.clear();
                        ScanState::Osc
                    }
                    0x1b => ScanState::Escape,
                    _ => ScanState::Ground,
                };
                None
            }
            ScanState::Csi | ScanState::CsiIgnore => match byte {
                0x40..=0x7e => {
                    let ignored = self.state == ScanState::CsiIgnore;
                    self.state = ScanState::Ground;
                    (!ignored && byte == b't').then(|| self.window_op()).flatten()
                }
                0x1b => {
                    self.state = ScanState::Escape;
                    None
                }
                0x18 | 0x1a => {
                    self.state = ScanState::Ground;
                    None
                }
                b'0'..=b'9' | b';'
                    if self.state == ScanState::Csi && self.csi.len() < MAX_CSI_BYTES =>
                {
                    self.csi.push(byte);
                    None
                }
                // C0 controls run inside a CSI without ending it.
                0x00..=0x1f => None,
                _ => {
                    self.state = ScanState::CsiIgnore;
                    None
                }
            },
            ScanState::Osc => match byte {
                0x07 => {
                    self.state = ScanState::Ground;
                    self.osc_end()
                }
                0x1b => {
                    self.state = ScanState::OscEscape;
                    None
                }
                0x18 | 0x1a => {
                    self.state = ScanState::Ground;
                    None
                }
                _ => {
                    if self.osc.len() < MAX_TITLE_BYTES + 8 {
                        self.osc.push(byte);
                    }
                    None
                }
            },
            ScanState::OscEscape => {
                if byte == b'\\' {
                    self.state = ScanState::Ground;
                    return self.osc_end();
                }
                // Another sequence aborted the OSC: the terminal applied it,
                // but nothing can go between this ESC and its sequence.
                let _ = self.osc_end();
                self.state = ScanState::Escape;
                self.step(byte)
            }
        }
    }

    /// `CSI Ps ; Ps t`: 22 pushes and 23 pops the title (second parameter 0,
    /// 2 or none; 1 is the icon name only).
    fn window_op(&mut self) -> Option<Vec<u8>> {
        let mut params = self.csi.split(|&b| b == b';');
        let op = params.next().filter(|p| !p.is_empty());
        let which = params.next().filter(|p| !p.is_empty());
        let which_title = matches!(which, None | Some(b"0") | Some(b"2"));
        match op {
            Some(b"22") if which_title => {
                if self.stack.len() == MAX_STACK {
                    self.stack.remove(0);
                }
                self.stack.push(self.title.clone());
                None
            }
            Some(b"23") if which_title => {
                let title = self.stack.pop()?;
                self.title = title.clone();
                Some(title)
            }
            _ => None,
        }
    }

    fn osc_end(&mut self) -> Option<Vec<u8>> {
        let split = self.osc.iter().position(|&b| b == b';')?;
        let (command, payload) = (&self.osc[..split], &self.osc[split + 1..]);
        let payload = clip_utf8(payload, MAX_TITLE_BYTES);
        match command {
            b"0" | b"2" => {
                self.title = payload.to_vec();
                self.titled = true;
                None
            }
            b"1" if !self.titled => {
                self.title = payload.to_vec();
                Some(self.title.clone())
            }
            _ => None,
        }
    }
}

/// At most `max` bytes of `bytes`, never ending inside a UTF-8 sequence.
fn clip_utf8(bytes: &[u8], max: usize) -> &[u8] {
    if bytes.len() <= max {
        return bytes;
    }
    let mut end = max;
    while end > 0 && (bytes[end] & 0xC0) == 0x80 {
        end -= 1;
    }
    &bytes[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    impl TitleTracker {
        /// For the scan bench in `terminal_metadata`.
        pub(crate) fn rewrite_reference_for_bench<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
            self.rewrite_reference(data)
        }

        /// The byte-at-a-time scan [`TitleTracker::rewrite`] replaced.
        fn rewrite_reference<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
            let mut out: Option<Vec<u8>> = None;
            let mut copied = 0;
            for (index, &byte) in data.iter().enumerate() {
                let Some(title) = self.step(byte) else { continue };
                let out =
                    out.get_or_insert_with(|| Vec::with_capacity(data.len() + title.len() + 6));
                out.extend_from_slice(&data[copied..=index]);
                copied = index + 1;
                out.extend_from_slice(b"\x1b]2;");
                out.extend_from_slice(&title);
                out.push(0x07);
            }
            match out {
                None => Cow::Borrowed(data),
                Some(mut out) => {
                    out.extend_from_slice(&data[copied..]);
                    Cow::Owned(out)
                }
            }
        }
    }

    /// Output that reaches every state of the tracker: titles with BEL and
    /// ST, pushes and pops with every parameter form, OSC 1 before and after
    /// an OSC 0/2, cancels, ESC inside a CSI and an OSC, an over-long CSI,
    /// C0 controls inside a CSI, non-UTF-8 bytes and an over-long title.
    fn adversarial_output() -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"plain \x1b[1;31mred\x1b[0m\x1b]1;icon\x07\x1b[22;0t");
        out.extend_from_slice(
            b"\x1b]2;one\x1b\\\x1b[22t\x1b]0;two\x07\x1b[23;2t\x1b[23t\x1b[23;1t",
        );
        out.extend_from_slice(b"\x1b[2\x1b[22;0t\x1b]2;x\x18\x1b]2;y\x1a\x1b]2;z\x1b[23t");
        out.extend_from_slice(b"\x1b[11111111111111111111;0t\x1b[2\n2;0t\x1b[?22t\x1b[23;0t");
        out.extend_from_slice(b"\xff\xfe\x9d\x1b\x1b]1;late icon\x07\x1b]2;");
        out.extend(std::iter::repeat_n(b'w', MAX_TITLE_BYTES + 20));
        out.extend_from_slice("\u{e9}\x07\x1b[22;0t\x1b]2;\u{2500}\x07\x1b[23;0ttail".as_bytes());
        out
    }

    fn rewritten(chunks: &[&[u8]], reference: bool) -> (Vec<Vec<u8>>, String) {
        let mut tracker = TitleTracker::default();
        let out = chunks
            .iter()
            .map(|chunk| {
                if reference {
                    tracker.rewrite_reference(chunk).into_owned()
                } else {
                    tracker.rewrite(chunk).into_owned()
                }
            })
            .collect();
        (out, format!("{tracker:?}"))
    }

    /// The jumping scan rewrites exactly what the byte-at-a-time scan did
    /// and ends in the same state, for every split of adversarial output,
    /// for empty chunks and for deterministic random byte soup.
    #[test]
    fn title_scan_matches_the_byte_at_a_time_reference() {
        let stream = adversarial_output();
        for at in 0..=stream.len() {
            let chunks: [&[u8]; 3] = [&stream[..at], b"", &stream[at..]];
            assert_eq!(rewritten(&chunks, false), rewritten(&chunks, true), "split at {at}");
        }
        let alphabet = b"\x1b\x07\x18\x1a\\[]t;0123\n\xff";
        let mut seed = 0x9e37_79b9_7f4a_7c15u64;
        for _ in 0..2_000 {
            let mut soup = Vec::new();
            for _ in 0..64 {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                soup.push(alphabet[(seed % alphabet.len() as u64) as usize]);
                if seed.is_multiple_of(7) {
                    soup.extend_from_slice(b"plain text ");
                }
            }
            let at = (seed as usize) % (soup.len() + 1);
            let chunks: [&[u8]; 2] = [&soup[..at], &soup[at..]];
            assert_eq!(rewritten(&chunks, false), rewritten(&chunks, true), "soup {soup:?}");
        }
    }

    fn run(tracker: &mut TitleTracker, chunks: &[&[u8]]) -> Vec<u8> {
        chunks.iter().flat_map(|chunk| tracker.rewrite(chunk).into_owned()).collect()
    }

    fn terminal() -> ghostty_vt::Terminal {
        ghostty_vt::Terminal::new(40, 4, 100, ghostty_vt::Callbacks::default()).unwrap()
    }

    /// Feeds `chunks` through the daemon's output path and returns the title after each.
    fn titles_after(chunks: &[&[u8]]) -> Vec<String> {
        let mut term = terminal();
        let mut marks = crate::prompt_mode_reset::ShellMarks::default();
        chunks
            .iter()
            .map(|chunk| {
                let _ = crate::prompt_mode_reset::write_output(&mut term, chunk, &mut marks);
                read(&term)
            })
            .collect()
    }

    #[test]
    fn sanitize_drops_controls_and_bidi_and_caps_the_length() {
        assert_eq!(sanitize("  build\u{7}\u{1b}[31m ok\t "), "build[31m ok");
        assert_eq!(sanitize("evil\u{202e}gpj.exe"), "evilgpj.exe");
        assert_eq!(sanitize("a\u{2066}b\u{2069}c\u{200f}d\u{061c}e\u{feff}"), "abcde");
        assert_eq!(sanitize("line one\nline two"), "line one line two");
        assert_eq!(sanitize("\u{85}c1"), "c1");
        // A zero width joiner holds an emoji sequence together: it stays.
        assert_eq!(sanitize("👩\u{200d}💻 dev"), "👩\u{200d}💻 dev");
        let long = "é".repeat(MAX_TITLE_CHARS + 40);
        assert_eq!(sanitize(&long).chars().count(), MAX_TITLE_CHARS);
    }

    #[test]
    fn a_pop_restores_the_pushed_title() {
        let titles = titles_after(&[
            b"\x1b]2;zsh ~/src\x07",
            b"\x1b[22;0t\x1b]2;vim notes.md\x07",
            b"\x1b[23;0t",
        ]);
        assert_eq!(titles, ["zsh ~/src", "vim notes.md", "zsh ~/src"]);
    }

    #[test]
    fn push_and_pop_with_title_only_and_default_params() {
        let titles = titles_after(&[
            b"\x1b]0;one\x1b\\",
            b"\x1b[22t\x1b]2;two\x07\x1b[22;2t\x1b]2;three\x07",
            b"\x1b[23;2t",
            b"\x1b[23t",
        ]);
        assert_eq!(titles, ["one", "three", "two", "one"]);
    }

    #[test]
    fn an_icon_only_push_and_an_empty_stack_leave_the_title() {
        let titles = titles_after(&[
            b"\x1b]2;kept\x07",
            b"\x1b[22;1t\x1b]2;next\x07\x1b[23;1t",
            b"\x1b[23;0t",
        ]);
        assert_eq!(titles, ["kept", "next", "next"]);
    }

    #[test]
    fn a_pop_split_across_chunks_still_restores() {
        let titles =
            titles_after(&[b"\x1b]2;shell\x07\x1b[2", b"2;0t\x1b]2;tool\x07\x1b[23", b";0t"]);
        assert_eq!(titles, ["shell", "tool", "shell"]);
    }

    #[test]
    fn osc_1_names_the_terminal_only_until_an_osc_2() {
        assert_eq!(titles_after(&[b"\x1b]1;icon name\x07"]), ["icon name"]);
        assert_eq!(titles_after(&[b"\x1b]2;real\x07\x1b]1;icon\x07"]), ["real"]);
    }

    #[test]
    fn the_stack_holds_at_most_ten_titles() {
        let mut tracker = TitleTracker::default();
        let mut stream = Vec::new();
        for i in 0..12 {
            stream.extend_from_slice(format!("\x1b]2;t{i}\x07\x1b[22;0t").as_bytes());
        }
        for _ in 0..12 {
            stream.extend_from_slice(b"\x1b[23;0t");
        }
        let out = run(&mut tracker, &[&stream]);
        let pops = out.windows(4).filter(|w| *w == b"\x1b]2;").count() - 12;
        assert_eq!(pops, 10);
    }

    #[test]
    fn leading_status_glyphs_become_the_activity() {
        use TitleActivity::*;
        let cases: [(&str, &str, Option<TitleActivity>); 11] = [
            ("⠐ Fix the login bug", "Fix the login bug", Some(Working)),
            ("⠂ Fix the login bug", "Fix the login bug", Some(Working)),
            ("✳ Claude Code", "Claude Code", Some(Idle)),
            ("● build", "build", Some(Idle)),
            ("✔\u{fe0e} tests passed", "tests passed", Some(Done)),
            ("✘ deploy", "deploy", Some(Failed)),
            ("✳ ⠂ Task", "Task", Some(Working)),
            ("vim notes.md", "vim notes.md", None),
            ("~/src · main", "~/src · main", None),
            ("⠂", "⠂", Some(Working)),
            ("", "", None),
        ];
        for (raw, text, activity) in cases {
            let title = TabTitle::terminal(raw);
            assert_eq!((title.text.as_ref(), title.activity), (text, activity), "{raw:?}");
        }
        assert_eq!(TabTitle::page("● Slack | general").text.as_ref(), "● Slack | general");
        assert_eq!(TabTitle::page("● Slack | general").activity, None);
        for activity in [Working, Idle, Done, Failed] {
            assert_eq!(TitleActivity::from_wire(activity.as_str()), Some(activity));
        }
    }

    #[test]
    fn store_announces_a_title_only_when_what_a_tab_shows_moved() {
        let mut stored = String::new();
        assert_eq!(store(&mut stored, "⠂ Fix it".into()).as_deref(), Some("⠂ Fix it"));
        // A spinner frame: stored raw, not announced.
        assert_eq!(store(&mut stored, "⠐ Fix it".into()), None);
        assert_eq!(stored, "⠐ Fix it");
        // The same title again: not announced.
        assert_eq!(store(&mut stored, "⠐ Fix it".into()), None);
        // The program waits now: the activity moved.
        assert_eq!(store(&mut stored, "✳ Fix it".into()).as_deref(), Some("✳ Fix it"));
        // New words.
        assert_eq!(store(&mut stored, "✳ Run tests".into()).as_deref(), Some("✳ Run tests"));
    }

    #[test]
    fn plain_output_is_not_copied() {
        let mut tracker = TitleTracker::default();
        assert!(matches!(tracker.rewrite(b"hello \x1b]2;title\x07 world"), Cow::Borrowed(_)));
    }
}
