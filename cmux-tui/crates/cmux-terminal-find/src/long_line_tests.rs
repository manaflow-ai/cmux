//! A long line (a minified file `cat` into a terminal soft-wraps into thousands of rows, one
//! logical line) with many matches costs its length once, not once per match: each snippet
//! walks back from its match at most its own room, and `find_in_lines` counts UTF-16 offsets on
//! from the previous match. The per-match prefix scans they replaced are the oracle here.

use std::time::Instant;

use crate::lines::snippet;
use crate::{FindOptions, LineMatch, MATCH_CAP, Matcher, SNIPPET_CHARS, find_in_lines};

/// The snippet as it was: the whole prefix collected per match.
fn snippet_oracle(line: &str, start: usize, end: usize) -> (String, u32, u32) {
    let utf16 = |text: &str| u32::try_from(text.encode_utf16().count()).unwrap_or(u32::MAX);
    let matched = &line[start..end];
    let room = SNIPPET_CHARS.saturating_sub(matched.chars().count());
    let before_room = room / 3;
    let before: Vec<char> = line[..start].chars().collect();
    let take_before = before.len().min(before_room);
    let after_room = room - take_before;
    let lead: String = before[before.len() - take_before..].iter().collect();
    let lead = lead.trim_start();
    let tail: String = line[end..].chars().take(after_room).collect();
    let tail = tail.trim_end();
    (format!("{lead}{matched}{tail}"), utf16(lead), utf16(matched))
}

/// `find_in_lines` as it was: each match's offset counted from the line's start.
fn find_in_lines_oracle(matcher: &Matcher, lines: &[String], max: usize) -> (Vec<LineMatch>, bool) {
    let utf16 = |text: &str| u32::try_from(text.encode_utf16().count()).unwrap_or(u32::MAX);
    let mut out = Vec::new();
    for (index, line) in lines.iter().enumerate().rev() {
        let found: Vec<(usize, usize)> = matcher.ranges(line).collect();
        for &(start, end) in found.iter().rev() {
            if out.len() == max {
                return (out, true);
            }
            let (snippet, snippet_start, snippet_len) = snippet_oracle(line, start, end);
            out.push(LineMatch {
                line: index,
                start: utf16(&line[..start]),
                len: utf16(&line[start..end]),
                snippet,
                snippet_start,
                snippet_len,
            });
        }
    }
    (out, false)
}

struct Rng(u64);

impl Rng {
    fn below(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D) % n
    }
}

const PIECES: &[&str] = &["a", "b", "ab", " ", "   ", "\t", "橋", "😀", "e\u{301}", "A", "-", "ß"];

fn random_line(rng: &mut Rng, max: u64) -> String {
    (0..rng.below(max)).map(|_| PIECES[rng.below(PIECES.len() as u64) as usize]).collect()
}

#[test]
fn snippets_and_offsets_match_the_prefix_scan_on_random_lines() {
    let mut rng = Rng(0xD1B5_4A32_D192_ED03);
    let queries = ["a", "ab", "橋", "😀", " ", "b a", "é", "ß", "[ab]+", r"\s+"];
    for case in 0..400 {
        let lines: Vec<String> =
            (0..1 + rng.below(6)).map(|_| random_line(&mut rng, 400)).collect();
        let query = queries[rng.below(queries.len() as u64) as usize];
        let options = FindOptions {
            regex: query.contains(['[', '\\']),
            case_sensitive: rng.below(2) == 0,
            whole_word: rng.below(4) == 0,
        };
        let Some(matcher) = Matcher::new(query, options).unwrap() else { continue };
        let max = 1 + rng.below(200) as usize;
        assert_eq!(
            find_in_lines(&matcher, &lines, max),
            find_in_lines_oracle(&matcher, &lines, max),
            "case {case}: {query:?} {options:?}"
        );
        for line in &lines {
            for (start, end) in matcher.ranges(line) {
                assert_eq!(
                    snippet(line, start, end),
                    snippet_oracle(line, start, end),
                    "case {case}"
                );
            }
        }
    }
}

/// Before -> after in one harness: "e" in one long line (a minified bundle), capped at
/// [`MATCH_CAP`] matches, at 200 KB and 2 MB (measured: 29 596 ms -> 15 ms at 200 KB; 315 s ->
/// 80 ms at 2 MB; linear in the line, which every match's position must be read from). Run:
/// `cargo test -p cmux-terminal-find --release long_line_bench -- --ignored --nocapture`
#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn long_line_bench() {
    let matcher = Matcher::new("e", FindOptions::default()).unwrap().unwrap();
    let mut new_ms = Vec::new();
    for bytes in [200_000usize, 2_000_000] {
        let word = "function(e){return e.default||e}var ";
        let line: String = word.repeat(bytes / word.len());
        let lines = vec![line];
        let time = |run: &dyn Fn() -> (Vec<LineMatch>, bool)| {
            let started = Instant::now();
            let (found, truncated) = run();
            assert_eq!(found.len(), MATCH_CAP);
            assert!(truncated);
            started.elapsed().as_secs_f64() * 1_000.0
        };
        let new = time(&|| find_in_lines(&matcher, &lines, MATCH_CAP));
        // The prefix scan is quadratic: 30 s at 200 KB, 5 min at 2 MB; time it at the small size.
        if bytes <= 200_000 {
            let old = time(&|| find_in_lines_oracle(&matcher, &lines, MATCH_CAP));
            println!("long line {bytes} B, {MATCH_CAP} matches: {old:.1} ms -> {new:.1} ms");
        } else {
            println!("long line {bytes} B, {MATCH_CAP} matches: {new:.1} ms");
        }
        new_ms.push(new);
        if !cfg!(debug_assertions) {
            assert!(new < 100.0, "{new:.1} ms for a {bytes} B line");
        }
    }
    println!("10x the line: {:.2}x the time", new_ms[1] / new_ms[0]);
}
