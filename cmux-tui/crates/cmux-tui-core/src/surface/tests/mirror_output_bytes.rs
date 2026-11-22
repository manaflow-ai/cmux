//! The bytes a hosted terminal's mirror broadcasts to viewers, pinned byte for
//! byte on a mixed corpus: plain and colored lines, UTF-8, titles (OSC 0/1/2,
//! `CSI 22/23 t`), modes a killed program leaves, and OSC 133 marks split at
//! every byte across host frames. A change to the mirror's parse path (cut 3 of
//! goal terminal-throughput, CMUX-571) must leave this stream as it is: the
//! same bytes, the same resets spliced at the same marks.

use super::hosted::hosted_typing_surface;
use super::*;

/// FNV-1a 64 of the stream the mirror broadcast for [`corpus`] before cut 3.
const PINNED_DIGEST: u64 = 0;
const PINNED_LEN: usize = 0;

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

struct Lcg(u64);

impl Lcg {
    fn next(&mut self, n: usize) -> usize {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        usize::try_from(self.0 >> 33).unwrap_or(0) % n
    }
}

/// A shell session's worth of output: prompts with their marks, commands
/// that leave modes behind or clean up, titles, and long colored runs.
pub(super) fn corpus(bytes: usize) -> Vec<u8> {
    let words = ["cargo", "build", "warning:", "src/main.rs:42:7", "Compiling", "ok", "FAIL"];
    let utf8 = ["é", "→", "✓", "日本語", "│", "🙂"];
    let leftovers: [&[u8]; 6] = [
        b"\x1b[?1000h\x1b[?1006h",
        b"\x1b[?1049h\x1b[2Jfull screen",
        b"\x1b[?25l",
        b"\x1b[?2004h\x1b[?1004h\x1b[?1h\x1b=",
        b"\x1b[>1u\x1b[>4;2m",
        b"",
    ];
    let titles: [&[u8]; 5] = [
        b"\x1b]0;build\x07",
        b"\x1b]2;vim main.rs\x1b\\",
        b"\x1b]1;icon\x07",
        b"\x1b[22;0t\x1b]2;pushed\x07",
        b"\x1b[23;0t",
    ];
    let mut rng = Lcg(571);
    let mut out = Vec::with_capacity(bytes + 4096);
    while out.len() < bytes {
        // The prompt: D (the last command's end), A, the prompt, B.
        out.extend_from_slice(b"\x1b]133;D;0\x07\x1b]133;A\x07~/src $ \x1b]133;B\x07");
        out.extend_from_slice(b"make\r\n\x1b]133;C\x07");
        if rng.next(3) == 0 {
            out.extend_from_slice(titles[rng.next(titles.len())]);
        }
        for _ in 0..rng.next(40) {
            let kind = rng.next(100);
            for i in 0..4 + rng.next(20) {
                if i > 0 {
                    out.push(b' ');
                }
                if kind < 25 {
                    out.extend_from_slice(
                        format!(
                            "\x1b[38;5;{}m{}\x1b[0m",
                            rng.next(256),
                            words[rng.next(words.len())]
                        )
                        .as_bytes(),
                    );
                } else if kind < 35 {
                    out.extend_from_slice(utf8[rng.next(utf8.len())].as_bytes());
                } else {
                    out.extend_from_slice(words[rng.next(words.len())].as_bytes());
                }
            }
            out.extend_from_slice(b"\r\n");
        }
        // A program that dies with its modes on, or one that marks a prompt
        // of its own while it runs (its modes stay).
        out.extend_from_slice(leftovers[rng.next(leftovers.len())]);
        if rng.next(4) == 0 {
            out.extend_from_slice(b"\x1b]133;A\x07inner> ");
        }
    }
    out.extend_from_slice(b"\x1b]133;D;0\x07\x1b]133;A\x07~/src $ done\r\n");
    out
}

/// The corpus as host Output frames: random sizes, and frames that end inside
/// each prompt mark so every split of `ESC ] 1 3 3 ;` is held and joined.
fn frames(corpus: &[u8]) -> Vec<&[u8]> {
    let mut rng = Lcg(50222);
    let mut cuts = Vec::new();
    let mut at = 0;
    while at < corpus.len() {
        at += 1 + rng.next(24 * 1024);
        cuts.push(at.min(corpus.len()));
    }
    let mut split = 0;
    for (index, _) in corpus.windows(6).enumerate().filter(|(_, w)| **w == *b"\x1b]133;") {
        cuts.push(index + 1 + split % 6);
        split += 1;
    }
    cuts.sort_unstable();
    cuts.dedup();
    let mut out = Vec::new();
    let mut from = 0;
    for cut in cuts {
        if cut > from {
            out.push(&corpus[from..cut]);
            from = cut;
        }
    }
    out
}

#[cfg(unix)]
#[test]
fn the_mirror_broadcasts_the_same_bytes_for_a_mixed_corpus_split_at_every_mark() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-mirror-output-bytes", false);
    let attach = surface.attach_stream().unwrap();
    let corpus = corpus(384 * 1024);
    let mut reference = Terminal::new(80, 24, 1000, Callbacks::default()).unwrap();
    let expected = crate::prompt_mode_reset::write_output(
        &mut reference,
        &corpus,
        &mut crate::prompt_mode_reset::ShellMarks::default(),
    )
    .into_owned();
    let writer = std::thread::spawn({
        let frames: Vec<Vec<u8>> = frames(&corpus).into_iter().map(<[u8]>::to_vec).collect();
        move || {
            for (index, chunk) in frames.into_iter().enumerate() {
                let mut frame = Frame::new(MessageKind::Output, chunk);
                frame.sequence = index as u64 + 1;
                crate::terminal_host_protocol::write_frame(&mut host, &frame).unwrap();
            }
            host
        }
    });
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut received = Vec::new();
    while received.len() < expected.len() && Instant::now() < deadline {
        match attach.stream.try_recv() {
            Ok(AttachFrame::Output(bytes)) => received.extend(bytes),
            Ok(AttachFrame::OutputWithColors { output, .. }) => received.extend(output),
            Ok(_) => {}
            Err(_) => std::thread::sleep(Duration::from_millis(1)),
        }
    }
    let _host = writer.join().unwrap();
    let digest = fnv1a(&received);
    println!("MIRROR-BYTES len={} fnv1a={digest:#018x}", received.len());
    assert!(received == expected, "the mirror's bytes differ from one parse of the whole corpus");
    assert_eq!((received.len(), digest), (PINNED_LEN, PINNED_DIGEST));
}
