use super::*;

impl OscCollector {
    /// The byte-at-a-time scan [`OscCollector::observe`] replaced.
    fn observe_reference(&mut self, bytes: &[u8], mut receive: impl FnMut(&[u8])) {
        for &byte in bytes {
            self.observe_byte(byte, &mut receive);
        }
    }

    /// The state a later byte can see: the UTF-8 bounds matter only
    /// inside a sequence.
    fn observable(&self) -> Observable {
        let (min, max) =
            if self.utf8_continuations > 0 { (self.utf8_min, self.utf8_max) } else { (0, 0) };
        (self.state, self.body.clone(), self.utf8_continuations, min, max)
    }
}

/// Output that reaches every state of the collector: plain and colored
/// text, OSC 9/777/99/133 with BEL, ST and C1 ST, a C1 OSC, string
/// controls that hide an OSC, cancels, valid UTF-8 whose continuation
/// bytes are C1 values, invalid and overlong UTF-8, and an oversized body.
pub(super) fn adversarial_output() -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"plain text\r\n\x1b[1;31mred\x1b[0m \x1b]9;4;1;42\x07");
    out.extend_from_slice(b"\x1b]777;notify;Title;Body text\x1b\\\x1b]99;i=1:d=0;Hi\x1b\\");
    out.extend_from_slice(b"\x1b]133;A\x07$ \x1b]133;C\x07\x1b]133;D;0\x07");
    out.extend_from_slice(b"\x9d9;c1 osc\x9c\x1bPq\x1b]9;hidden\x07\x1b\\\x90x\x9c");
    out.extend_from_slice("caf\u{e9} \u{dd} \u{2500}\u{2502} \u{1f600}".as_bytes());
    out.extend_from_slice(b"\xc3\x9d9;lead then c1\x9c\xe0\x80\x9d9;overlong\x07");
    out.extend_from_slice(b"\xed\xa0\x9d\xf4\x90\x9d\x1b]9;can\x18\x1b]9;sub\x1a");
    out.extend_from_slice(b"\x1b\x1b]9;esc esc\x1b\x1b\\\x1b]9;\x1bx\x07\x1b_apc\x1b\x1b\\");
    out.extend_from_slice(b"\x1b]9;");
    out.extend(std::iter::repeat_n(b'z', MAX_OSC_BODY_BYTES + 3));
    out.extend_from_slice(b"\x07\x1b]9;\xe2\x94\x80 after\x07tail");
    out
}

/// What [`OscCollector::observable`] returns.
type Observable = (OscState, Vec<u8>, u8, u8, u8);

fn collect(
    chunks: &[&[u8]],
    observe: impl Fn(&mut OscCollector, &[u8], &mut dyn FnMut(&[u8])),
) -> (Vec<Vec<u8>>, Vec<Observable>) {
    let mut collector = OscCollector::default();
    let mut bodies = Vec::new();
    let mut states = Vec::new();
    for chunk in chunks {
        observe(&mut collector, chunk, &mut |body| bodies.push(body.to_vec()));
        states.push(collector.observable());
    }
    (bodies, states)
}

/// The jumping scan finds the bodies the byte-at-a-time scan found and
/// leaves the same state, for every split of adversarial output into two
/// chunks, for empty chunks, and for deterministic random byte soup.
#[test]
fn osc_scan_matches_the_byte_at_a_time_reference() {
    let fast = |collector: &mut OscCollector, bytes: &[u8], receive: &mut dyn FnMut(&[u8])| {
        collector.observe(bytes, receive);
    };
    let reference = |collector: &mut OscCollector, bytes: &[u8], receive: &mut dyn FnMut(&[u8])| {
        collector.observe_reference(bytes, receive);
    };
    let stream = adversarial_output();
    for at in 0..=stream.len() {
        let chunks: [&[u8]; 3] = [&stream[..at], b"", &stream[at..]];
        assert_eq!(collect(&chunks, fast), collect(&chunks, reference), "split at {at}");
    }
    let alphabet = b"\x1b\x07\x18\x1a\x9c\x9d\x90\x80\xbf\xc3\xe0\xed\xf0\xf4]P\\9;1A ";
    let mut seed = 0x2545_f491_4f6c_dd1du64;
    for _ in 0..2_000 {
        let mut soup = Vec::new();
        for _ in 0..64 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            soup.push(alphabet[(seed % alphabet.len() as u64) as usize]);
            if seed.is_multiple_of(5) {
                soup.extend_from_slice(b"plain ascii run ");
            }
        }
        let at = (seed as usize) % (soup.len() + 1);
        let chunks: [&[u8]; 2] = [&soup[..at], &soup[at..]];
        assert_eq!(collect(&chunks, fast), collect(&chunks, reference), "soup {soup:?}");
    }
}

/// The three output scanners over 64 KiB of colored log output and of
/// box-drawing TUI output: ns per byte, jumping scan against the
/// byte-at-a-time reference. Run on the fleet:
/// `cargo test -p cmux-tui-core --release --lib terminal_output_scan_bench -- --ignored --nocapture`
#[test]
#[ignore = "bench"]
fn terminal_output_scan_bench() {
    let mut colored = Vec::new();
    let mut boxes = Vec::new();
    for line in 0.. {
        if colored.len() >= 64 * 1024 {
            break;
        }
        colored.extend_from_slice(
                format!("\x1b[32m2026-11-10T12:00:{line:02}Z\x1b[0m INFO request served in 3ms id={line}\r\n")
                    .as_bytes(),
            );
        boxes.extend_from_slice(
            format!(
                "\x1b[{};1H\u{2502} cell {line:5} \u{2502}\x1b[7m sel \x1b[27m\u{2502}",
                line % 40
            )
            .as_bytes(),
        );
    }
    for (name, stream) in [("colored-log", &colored), ("box-tui", &boxes)] {
        let rounds = 400;
        let time = |reference: bool| {
            let start = Instant::now();
            for _ in 0..rounds {
                let mut collector = OscCollector::default();
                let mut titles = crate::terminal_title::TitleTracker::default();
                if reference {
                    collector.observe_reference(stream, |_| {});
                    std::hint::black_box(titles.rewrite_reference_for_bench(stream));
                } else {
                    collector.observe(stream, |_| {});
                    std::hint::black_box(titles.rewrite(stream));
                }
                std::hint::black_box(collector.state);
            }
            start.elapsed().as_nanos() as f64 / (rounds as f64 * stream.len() as f64)
        };
        let (reference, fast) = (time(true), time(false));
        println!(
            "SCAN-BENCH {name} reference_ns_per_byte={reference:.3} fast_ns_per_byte={fast:.3}"
        );
    }
}

#[test]
fn find_esc_or_high_stops_at_the_first_esc_or_high_byte() {
    for len in 0..40 {
        for stop in [None, Some(0x1b), Some(0x80), Some(0xff)] {
            for at in 0..len.max(1) {
                let mut bytes = vec![b'a'; len];
                let expected = match stop {
                    Some(byte) if at < len => {
                        bytes[at] = byte;
                        at
                    }
                    _ => len,
                };
                assert_eq!(find_esc_or_high(&bytes), expected, "{bytes:?}");
            }
        }
    }
}

#[test]
fn osc_9_4_progress_parses_states_and_reports_each_change_once() {
    assert_eq!(
        parse_progress("4;1;42"),
        Some(TerminalProgress { state: ProgressState::Normal, value: Some(42) })
    );
    assert_eq!(
        parse_progress("4;2;250"),
        Some(TerminalProgress { state: ProgressState::Error, value: Some(100) })
    );
    assert_eq!(
        parse_progress("4;3"),
        Some(TerminalProgress { state: ProgressState::Indeterminate, value: None })
    );
    assert_eq!(parse_progress("4;0;0"), None);
    assert_eq!(parse_progress("hello from a notification"), None);

    let mut metadata = TerminalMetadata::default();
    assert_eq!(metadata.take_progress_change(), None);
    metadata.observe_output(b"\x1b]9;4;1;10\x07");
    assert_eq!(
        metadata.take_progress_change(),
        Some(Some(TerminalProgress { state: ProgressState::Normal, value: Some(10) }))
    );
    assert_eq!(metadata.take_progress_change(), None);
    metadata.observe_output(b"\x1b]9;4;0\x1b\\");
    assert_eq!(metadata.take_progress_change(), Some(None));
}

#[test]
fn shell_history_osc_133_marks_cross_chunks_and_stay_bounded() {
    use crate::shell_history::{MAX_PENDING_MARKS, ShellMark};
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"prompt \x1b]133;B\x07ls\r\n\x1b]13");
    metadata.observe_output(b"3;C\x1b\\output\x1b]133;D;1\x07");
    assert_eq!(
        metadata.take_shell_marks(),
        vec![
            ShellMark::InputStart,
            ShellMark::CommandStart,
            ShellMark::CommandEnd { exit_code: Some(1) }
        ]
    );
    assert!(metadata.take_shell_marks().is_empty());
    for _ in 0..(MAX_PENDING_MARKS + 5) {
        metadata.observe_output(b"\x1b]133;A\x07");
    }
    assert_eq!(metadata.take_shell_marks().len(), MAX_PENDING_MARKS);
}

#[test]
fn read_run_osc_133_exit_code_is_the_last_commands_status_and_plain_output_has_none() {
    let mut metadata = TerminalMetadata::default();
    // A shell without integration: output, no marks, no status.
    metadata.observe_output(b"$ sh -c 'exit 7'\r\n$ ");
    assert_eq!(metadata.activity.last_command(), None);

    // Ghostty's shell integration: C at Enter, D;<status> before the next A,
    // split across output chunks.
    metadata.observe_output(b"\x1b]133;A\x07$ \x1b]133;B\x07sh -c 'exit 7'\r\n\x1b]133;C\x07");
    metadata.observe_output(b"\x1b]133;D");
    metadata.observe_output(b";7;aid=12\x07\x1b]133;A\x07$ ");
    let last = metadata.activity.last_command().expect("a finished command");
    assert_eq!(last.exit_code, Some(7));
    assert!(last.started_at_ms.is_some());

    metadata.observe_output(b"\x1b]133;C\x07ok\r\n\x1b]133;D;0\x07\x1b]133;A\x07");
    assert_eq!(metadata.activity.last_command().unwrap().exit_code, Some(0));
}

#[test]
fn captures_bel_st_and_c1_osc_progress() {
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"\x1b]9;4;3;\x07");
    assert_eq!(metadata.osc_progress(), "4;3;");
    metadata.observe_output(b"\x1b]9;4;1;50\x1b\\");
    assert_eq!(metadata.osc_progress(), "4;1;50");
    metadata.observe_output(b"\x9d9;4;2;\x9c");
    assert_eq!(metadata.osc_progress(), "4;2;");
}

#[test]
fn preserves_chunk_boundaries_and_ignores_other_strings() {
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"\x1b]9;4");
    metadata.observe_output(b";2;");
    metadata.observe_output(b"\x07");
    assert_eq!(metadata.osc_progress(), "4;2;");
    metadata.observe_output(b"\x1b]0;title\x07\x1bP+q9;bad\x1b\\");
    assert_eq!(metadata.osc_progress(), "4;2;");
}

#[test]
fn preserves_non_st_escape_bytes_inside_an_osc_payload() {
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"\x1b]9;before\x1bXafter\x07");
    // The ESC is a control character and is removed from the exposed
    // text, but the following byte and the remainder of the payload must
    // survive the framing state transition.
    assert_eq!(metadata.osc_progress(), "beforeXafter");
}

#[test]
fn utf8_continuation_bytes_are_not_c1_framing() {
    let mut metadata = TerminalMetadata::default();
    // U+00DD is encoded as C3 9D. The continuation byte is numerically
    // equal to C1 OSC, but it is ordinary text in this stream.
    metadata.observe_output("Ý".as_bytes());
    let mut first = b"\x1b]9;before".to_vec();
    first.extend_from_slice("Ýafter\x07".as_bytes());
    metadata.observe_output(&first);
    assert_eq!(metadata.osc_progress(), "beforeÝafter");

    // U+00DC is encoded as C3 9C. It must not terminate an OSC payload.
    let mut second = b"\x1b]9;left".to_vec();
    second.extend_from_slice("Üright\x07".as_bytes());
    metadata.observe_output(&second);
    assert_eq!(metadata.osc_progress(), "leftÜright");
}

#[test]
fn invalid_utf8_does_not_swallow_a_c1_string_terminator() {
    let mut metadata = TerminalMetadata::default();
    // E0 must be followed by A0..BF as its first UTF-8 continuation.
    // 9C is therefore a raw C1 ST here and must close the OSC body.
    let mut bytes = vec![0x9d, b'9', b';'];
    bytes.extend_from_slice(b"old");
    bytes.extend_from_slice(&[0xe0, 0x9c]);
    metadata.observe_output(&bytes);
    metadata.observe_output(b"\x1b]9;new\x07");
    assert_eq!(metadata.osc_progress(), "new");
}

#[test]
fn c1_string_openers_are_isolated_from_osc() {
    let mut metadata = TerminalMetadata::default();
    for opener in [0x90, 0x98, 0x9e, 0x9f] {
        let mut bytes = vec![opener];
        bytes.extend_from_slice(b"payload \x9d9;leaked\x9c");
        metadata.observe_output(&bytes);
    }
    assert_eq!(metadata.osc_progress(), "");
    metadata.observe_output(b"\x1b]9;valid\x07");
    assert_eq!(metadata.osc_progress(), "valid");
}

#[test]
fn can_and_sub_cancel_all_string_states() {
    let mut metadata = TerminalMetadata::default();
    for cancel in [0x18, 0x1a] {
        metadata.observe_output(&[0x1b, b']', b'9', b';', b'b', b'a', cancel]);
        metadata.observe_output(b"\x1b]9;valid\x07");
        assert_eq!(metadata.osc_progress(), "valid");

        metadata.observe_output(&[0x90, b'\x9d', cancel]);
        metadata.observe_output(b"\x1b]9;valid-again\x07");
        assert_eq!(metadata.osc_progress(), "valid-again");
    }
}

#[test]
fn discards_oversized_bodies_and_bounds_text() {
    let mut metadata = TerminalMetadata::default();
    let mut body = b"\x1b]9;".to_vec();
    body.extend(std::iter::repeat_n(b'x', MAX_OSC_BODY_BYTES + 1));
    body.push(0x07);
    metadata.observe_output(&body);
    assert_eq!(metadata.osc_progress(), "");

    let mut bounded = b"\x1b]9;".to_vec();
    bounded.extend(std::iter::repeat_n(b'x', MAX_PROGRESS_CHARS + 32));
    bounded.push(0x07);
    metadata.observe_output(&bounded);
    assert_eq!(metadata.osc_progress().chars().count(), MAX_PROGRESS_CHARS);
}

fn notes(metadata: &mut TerminalMetadata) -> Vec<(String, String)> {
    metadata.take_notifications().into_iter().map(|note| (note.title, note.body)).collect()
}

#[test]
fn cmux_next_terminal_notification_osc9_text_is_a_notification() {
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"\x1b]9;Build finished\x07");
    assert_eq!(notes(&mut metadata), vec![("Build finished".into(), String::new())]);
    // The ST terminator, a chunk boundary and C1 OSC frame the same text.
    metadata.observe_output(b"\x1b]9;two");
    metadata.observe_output(b" parts\x1b\\");
    metadata.observe_output(b"\x9d9;c1\x9c");
    assert_eq!(
        notes(&mut metadata),
        vec![("two parts".into(), String::new()), ("c1".into(), String::new())]
    );
    // Taking drains the queue.
    assert!(notes(&mut metadata).is_empty());
}

#[test]
fn cmux_next_terminal_notification_osc9_conemu_forms_are_not_notifications() {
    // Ghostty's osc9.zig treats these as ConEmu commands, not iTerm2
    // desktop notifications.
    let mut metadata = TerminalMetadata::default();
    for body in [
        "9;1;100",
        "9;10",
        "9;10;1",
        "9;11;comment",
        "9;12",
        "9;2;box",
        "9;3;",
        "9;3;tab",
        "9;4;0",
        "9;4;1;50",
        "9;4;2",
        "9;4;3",
        "9;4;4;10",
        "9;5",
        "9;5 minutes",
        "9;6;macro",
        "9;7;run",
        "9;8;VAR",
        "9;9;/tmp",
    ] {
        metadata.observe_output(format!("\x1b]{body}\x07").as_bytes());
        assert!(notes(&mut metadata).is_empty(), "{body} must not notify");
    }
    // Near misses fall through to a notification, as in Ghostty.
    for (body, text) in [
        ("9;1", "1"),
        ("9;10;7", "10;7"),
        ("9;11", "11"),
        ("9;2", "2"),
        ("9;4", "4"),
        ("9;4;9", "4;9"),
        ("9;6", "6"),
        ("9;done", "done"),
    ] {
        metadata.observe_output(format!("\x1b]{body}\x07").as_bytes());
        assert_eq!(notes(&mut metadata), vec![(text.to_string(), String::new())], "{body}");
    }
    // An empty OSC 9 has nothing to show.
    metadata.observe_output(b"\x1b]9;\x07");
    assert!(notes(&mut metadata).is_empty());
}

#[test]
fn cmux_next_terminal_notification_osc777_notify_has_title_and_body() {
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"\x1b]777;notify;Title;Body; with semicolon\x07");
    assert_eq!(notes(&mut metadata), vec![("Title".into(), "Body; with semicolon".into())]);
    // Missing title separator, other extensions and empty text are ignored.
    metadata.observe_output(b"\x1b]777;notify;only\x07");
    metadata.observe_output(b"\x1b]777;other;a;b\x07");
    metadata.observe_output(b"\x1b]777;notify;;\x07");
    assert!(notes(&mut metadata).is_empty());
    // An empty title shows the body as the title.
    metadata.observe_output(b"\x1b]777;notify;;body only\x07");
    assert_eq!(notes(&mut metadata), vec![("body only".into(), String::new())]);
}

#[test]
fn cmux_next_terminal_notification_osc99_kitty_chunks_and_base64() {
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"\x1b]99;;Hello\x1b\\");
    assert_eq!(notes(&mut metadata), vec![("Hello".into(), String::new())]);

    // Chunks with one id accumulate until d=1 (the default).
    metadata.observe_output(b"\x1b]99;i=job:d=0;Deploy\x1b\\");
    assert!(notes(&mut metadata).is_empty());
    metadata.observe_output(b"\x1b]99;i=job:d=0:p=body;done in \x1b\\");
    metadata.observe_output(b"\x1b]99;i=job:p=body;3s\x1b\\");
    assert_eq!(notes(&mut metadata), vec![("Deploy".into(), "done in 3s".into())]);

    // Base64 payloads (e=1) decode; "SGk=" is "Hi".
    metadata.observe_output(b"\x1b]99;e=1;SGk=\x1b\\");
    assert_eq!(notes(&mut metadata), vec![("Hi".into(), String::new())]);

    // Body only becomes the title; close/alive/unknown payloads are ignored.
    metadata.observe_output(b"\x1b]99;p=body;just body\x1b\\");
    assert_eq!(notes(&mut metadata), vec![("just body".into(), String::new())]);
    metadata.observe_output(b"\x1b]99;p=close;x\x1b\\\x1b]99;p=alive;x\x1b\\");
    metadata.observe_output(b"\x1b]99;p=?;x\x1b\\\x1b]99;no-separator\x1b\\");
    assert!(notes(&mut metadata).is_empty());

    // A new id drops an unfinished notification with another id.
    metadata.observe_output(b"\x1b]99;i=a:d=0;lost\x1b\\");
    metadata.observe_output(b"\x1b]99;i=b;kept\x1b\\");
    assert_eq!(notes(&mut metadata), vec![("kept".into(), String::new())]);

    // Invalid base64 is dropped.
    metadata.observe_output(b"\x1b]99;e=1;***\x1b\\");
    assert!(notes(&mut metadata).is_empty());
}

#[test]
fn cmux_next_terminal_notification_text_is_bounded_and_queue_is_capped() {
    let mut metadata = TerminalMetadata::default();
    let mut long = b"\x1b]777;notify;".to_vec();
    long.extend(std::iter::repeat_n(b't', MAX_NOTIFICATION_TITLE_CHARS + 10));
    long.push(b';');
    long.extend(std::iter::repeat_n(b'b', MAX_NOTIFICATION_BODY_CHARS + 10));
    long.push(0x07);
    metadata.observe_output(&long);
    let taken = notes(&mut metadata);
    assert_eq!(taken[0].0.chars().count(), MAX_NOTIFICATION_TITLE_CHARS);
    assert_eq!(taken[0].1.chars().count(), MAX_NOTIFICATION_BODY_CHARS);

    // Control characters are removed from the shown text.
    metadata.observe_output(b"\x1b]777;notify;a\tb;c\x1bXd\x07");
    assert_eq!(notes(&mut metadata), vec![("ab".into(), "cXd".into())]);

    // A reader that never drains (a terminal host) keeps a bounded queue.
    for index in 0..(MAX_PENDING_NOTIFICATIONS + 5) {
        metadata.observe_output(format!("\x1b]9;n{index}\x07").as_bytes());
    }
    let taken = notes(&mut metadata);
    assert_eq!(taken.len(), MAX_PENDING_NOTIFICATIONS);
    assert_eq!(taken.last().unwrap().0, format!("n{}", MAX_PENDING_NOTIFICATIONS + 4));
}

#[test]
fn cmux_next_terminal_notification_invisible_formatting_is_removed() {
    let hidden = "\u{202e}\u{2066}\u{200b}\u{00ad}\u{feff}\u{1bca0}\u{e0020}";
    let mut metadata = TerminalMetadata::default();

    metadata.observe_output(format!("\x1b]9;Build{hidden} finished\x07").as_bytes());
    assert_eq!(notes(&mut metadata), vec![("Build finished".into(), String::new())]);

    metadata.observe_output(format!("\x1b]777;notify;Deploy{hidden};Done{hidden}\x07").as_bytes());
    assert_eq!(notes(&mut metadata), vec![("Deploy".into(), "Done".into())]);

    metadata.observe_output(format!("\x1b]99;;Kitty{hidden}\x1b\\").as_bytes());
    assert_eq!(notes(&mut metadata), vec![("Kitty".into(), String::new())]);
}

#[test]
fn cmux_next_terminal_notification_osc9_progress_text_is_still_retained() {
    let mut metadata = TerminalMetadata::default();
    metadata.observe_output(b"\x1b]9;4;1;50\x07");
    assert_eq!(metadata.osc_progress(), "4;1;50");
    assert!(notes(&mut metadata).is_empty());
}
