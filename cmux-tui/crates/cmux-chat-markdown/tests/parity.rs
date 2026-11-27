//! Parity with the app's Swift parser (MessagesLab catalyst MarkdownParser.swift), which this
//! crate replaces: tests/parity/expected.txt is that parser's output for tests/parity/corpus.json
//! (the CommonMark spec examples, GFM's, regressions and chat messages), in this crate's byte
//! format, one line per text: the document, then the stream tail from its last top-level block
//! ("-" without one). tests/parity/swift/run.sh printed it.
//!
//! `PARITY_EXPECTED=PATH` compares against another file; `PARITY_WRITE=PATH` writes this
//! crate's output there.

use std::fmt::Write as _;
use std::path::Path;

use cmux_chat_markdown::{DefaultPolicy, encode, parse, parse_tail};

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len().saturating_mul(2));
    for x in b {
        let _ = write!(s, "{x:02x}");
    }
    s
}

fn line(text: &str) -> String {
    let doc = parse(text, &DefaultPolicy);
    let tail = match doc.blocks.last() {
        Some(last) if last.lines.0 < last.lines.1 => {
            hex(&encode::blocks(&parse_tail(text, last.lines.0, &DefaultPolicy)))
        }
        _ => "-".to_owned(),
    };
    format!("{} {tail}", hex(&encode::document(&doc)))
}

#[test]
fn matches_the_swift_parser() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/parity");
    let corpus: Vec<String> =
        serde_json::from_str(&std::fs::read_to_string(dir.join("corpus.json")).unwrap_or_default())
            .unwrap_or_default();
    assert!(corpus.len() > 1000, "tests/parity/corpus.json did not load");
    let ours: Vec<String> = corpus.iter().map(|t| line(t)).collect();
    if let Some(path) = std::env::var_os("PARITY_WRITE") {
        let mut all = ours.join("\n");
        all.push('\n');
        assert!(std::fs::write(path, all).is_ok());
    }
    let expected_path =
        std::env::var_os("PARITY_EXPECTED").map_or(dir.join("expected.txt"), Into::into);
    let expected = std::fs::read_to_string(&expected_path).unwrap_or_default();
    let expected: Vec<&str> = expected.lines().collect();
    assert_eq!(
        expected.len(),
        corpus.len(),
        "{} has a line per corpus text",
        expected_path.display()
    );
    let mut misses = Vec::new();
    for (i, ((text, want), got)) in corpus.iter().zip(&expected).zip(&ours).enumerate() {
        if want != got {
            misses.push(format!("#{i} {text:?}\n  swift: {want}\n  rust:  {got}"));
        }
    }
    assert!(
        misses.is_empty(),
        "{} of {} texts differ:\n{}",
        misses.len(),
        corpus.len(),
        misses.join("\n")
    );
}

/// The parse time over the corpus (the Swift side: tests/parity/swift/run.sh OUT ROUNDS).
/// `PARITY_ROUNDS=N cargo test --release --test parity -- --ignored --nocapture time_the_corpus`
#[test]
#[ignore = "timing, run by hand"]
fn time_the_corpus() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/parity");
    let corpus: Vec<String> =
        serde_json::from_str(&std::fs::read_to_string(dir.join("corpus.json")).unwrap_or_default())
            .unwrap_or_default();
    let rounds: usize =
        std::env::var("PARITY_ROUNDS").ok().and_then(|r| r.parse().ok()).unwrap_or(20);
    let mut best = f64::INFINITY;
    let mut sink = 0usize;
    for _ in 0..rounds {
        let t0 = std::time::Instant::now();
        for text in &corpus {
            sink = sink.wrapping_add(parse(text, &DefaultPolicy).blocks.len());
        }
        best = best.min(t0.elapsed().as_secs_f64() * 1e3);
    }
    println!("rust best round ms {best} texts {} sink {sink}", corpus.len());
}
