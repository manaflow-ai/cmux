use super::*;

fn terminal() -> Terminal {
    Terminal::new(40, 4, 100, ghostty_vt::Callbacks::default()).unwrap()
}

/// Feeds `stream` split at `at` and returns the terminal and the bytes it parsed.
fn feed_split(stream: &[u8], at: usize) -> (Terminal, Vec<u8>) {
    let mut term = terminal();
    let mut marks = ShellMarks::default();
    let mut parsed = Vec::new();
    for chunk in [&stream[..at], &stream[at..]] {
        parsed.extend_from_slice(&write_output(&mut term, chunk, &mut marks));
    }
    (term, parsed)
}

/// A dead program's mouse mode is reset at the next prompt mark wherever
/// the output stream splits, also inside the mark itself: a reader chunk
/// ends anywhere, and a mark split across two chunks used to be missed.
#[test]
fn a_prompt_mark_split_across_chunks_still_resets_modes() {
    let stream = b"\x1b[?1000h\x1b[?25lkilled\r\n\x1b]133;A\x07$ ";
    let (_, whole) = feed_split(stream, stream.len());
    for at in 0..=stream.len() {
        let (term, parsed) = feed_split(stream, at);
        assert!(!term.mouse_tracking(), "mouse mode survived a mark split at {at}");
        assert!(term.mode(CURSOR_VISIBLE, false), "cursor stayed hidden, split at {at}");
        assert_eq!(parsed, whole, "parsed bytes differ for a split at {at}");
    }
}

/// The keyboard modes a command left are reset at its end mark, wherever
/// the stream splits.
#[test]
fn a_command_end_mark_split_across_chunks_still_resets_keyboard_modes() {
    let stream = b"\x1b]133;C\x07\x1b[?2004h\x1b[?1004hran\r\n\x1b]133;D;0\x07";
    let (_, whole) = feed_split(stream, stream.len());
    for at in 0..=stream.len() {
        let (term, parsed) = feed_split(stream, at);
        assert!(!term.mode(2004, false), "bracketed paste survived a split at {at}");
        assert!(!term.mode(1004, false), "focus reports survived a split at {at}");
        assert_eq!(parsed, whole, "parsed bytes differ for a split at {at}");
    }
}

/// A shell session in one stream: a killed full-screen program's modes, a
/// prompt, a command that sets keyboard modes and finishes, colors, a title
/// pop, UTF-8 and a C1 control, so every rewrite of the parsed bytes shows.
const SESSION: &[u8] = b"\x1b[?1049h\x1b[?1000h\x1b[?25l\x1b[38;5;196mkilled\x1b[0m\r\n\
\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07\x1b[?2004h\x1b[?1004h\x1b]2;t\x07\x1b[22t\
caf\xc3\xa9 \xe2\x86\x92 \xc2\x9b31mred\x1b[23t\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ done";

/// The cuts of `stream` into chunks at `cuts`, in order.
fn chunks<'a>(stream: &'a [u8], cuts: &[usize]) -> Vec<&'a [u8]> {
    let mut out = Vec::new();
    let mut from = 0;
    for &cut in cuts.iter().chain([stream.len()].iter()) {
        out.push(&stream[from..cut]);
        from = cut;
    }
    out
}

/// What a viewer can see of a terminal: its screen text and the modes a
/// prompt mark resets.
fn screen_state(term: &mut Terminal) -> (String, bool, bool, bool, bool, bool) {
    (
        term.viewport_text().unwrap(),
        term.mouse_tracking(),
        matches!(term.active_screen(), Screen::Alternate),
        term.mode(CURSOR_VISIBLE, false),
        term.mode(2004, false),
        term.mode(1004, false),
    )
}

/// The early forward (goal terminal-throughput, G3): the runs a mirror
/// forwards to its viewers before it parses them join to exactly the bytes
/// [`write_rewritten_output`] returns, for every way two cuts split a session
/// with prompt marks (marks split inside themselves included), and a viewer
/// fed the forwarded runs ends on the mirror's screen and modes.
#[test]
fn forwarded_runs_join_to_the_returned_bytes_and_viewers_match_the_mirror_at_every_split() {
    let (_, whole) = feed_split(SESSION, SESSION.len());
    for first in 0..=SESSION.len() {
        for second in first..=SESSION.len() {
            let mut mirror = terminal();
            let mut viewer = terminal();
            let mut marks = ShellMarks::default();
            let mut returned = Vec::new();
            let mut forwarded = Vec::new();
            for chunk in chunks(SESSION, &[first, second]) {
                let data = marks.titles.rewrite(chunk);
                let parsed =
                    write_rewritten_output_forwarding(&mut mirror, data, &mut marks, |run| {
                        assert!(!run.is_empty(), "an empty run was forwarded");
                        forwarded.extend_from_slice(run);
                        viewer.vt_write(run);
                    });
                returned.extend_from_slice(&parsed);
            }
            assert_eq!(forwarded, returned, "forwarded runs differ, cuts {first}/{second}");
            assert_eq!(returned, whole, "parsed bytes differ, cuts {first}/{second}");
            assert_eq!(
                screen_state(&mut viewer),
                screen_state(&mut mirror),
                "viewer and mirror differ, cuts {first}/{second}"
            );
        }
    }
}

/// A reset is its own run, computed from the modes as of the mark: the run
/// before the mark has parsed when the reset is built, and the reset goes
/// out before the mark that follows it.
#[test]
fn a_prompt_mark_reset_is_forwarded_as_its_own_run_between_the_mark_and_what_precedes_it() {
    let mut term = terminal();
    let mut marks = ShellMarks::default();
    let mut runs: Vec<Vec<u8>> = Vec::new();
    let stream: &[u8] = b"\x1b[?1000hkilled\r\n\x1b]133;A\x07$ ";
    let parsed =
        write_rewritten_output_forwarding(&mut term, Cow::Borrowed(stream), &mut marks, |run| {
            runs.push(run.to_vec())
        })
        .into_owned();
    assert_eq!(
        runs,
        vec![b"\x1b[?1000hkilled\r\n".to_vec(), MOUSE_RESET.to_vec(), b"\x1b]133;A\x07$ ".to_vec()]
    );
    assert_eq!(parsed, runs.concat());
}

/// A chunk that ends inside a prompt mark forwards nothing of the mark: the
/// held tail goes out with the chunk that completes it, after its reset.
#[test]
fn a_held_partial_mark_is_not_forwarded_until_the_next_chunk_completes_it() {
    let mut term = terminal();
    let mut marks = ShellMarks::default();
    let mut runs: Vec<Vec<u8>> = Vec::new();
    let _ = write_rewritten_output_forwarding(
        &mut term,
        Cow::Borrowed(b"\x1b[?25lkilled\x1b]13"),
        &mut marks,
        |run| runs.push(run.to_vec()),
    );
    assert_eq!(runs, vec![b"\x1b[?25lkilled".to_vec()]);
    runs.clear();
    let _ = write_rewritten_output_forwarding(
        &mut term,
        Cow::Borrowed(b"3;A\x07$ "),
        &mut marks,
        |run| runs.push(run.to_vec()),
    );
    assert_eq!(runs, vec![CURSOR_SHOW.to_vec(), b"\x1b]133;A\x07$ ".to_vec()]);
}
