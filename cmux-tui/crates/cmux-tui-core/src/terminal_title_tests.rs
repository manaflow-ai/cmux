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
            let out = out.get_or_insert_with(|| Vec::with_capacity(data.len() + title.len() + 6));
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
    out.extend_from_slice(b"\x1b]2;one\x1b\\\x1b[22t\x1b]0;two\x07\x1b[23;2t\x1b[23t\x1b[23;1t");
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
    let titles =
        titles_after(&[b"\x1b]2;kept\x07", b"\x1b[22;1t\x1b]2;next\x07\x1b[23;1t", b"\x1b[23;0t"]);
    assert_eq!(titles, ["kept", "next", "next"]);
}

#[test]
fn a_pop_split_across_chunks_still_restores() {
    let titles = titles_after(&[b"\x1b]2;shell\x07\x1b[2", b"2;0t\x1b]2;tool\x07\x1b[23", b";0t"]);
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
