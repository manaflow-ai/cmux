//! Search All Windows (`GlobalSearchCorpus.swift`): the query's words, a
//! source's lines, the order sources are read in, which tabs match and in what
//! order, and the snippet and highlighted word a row shows. Character counts
//! are grapheme clusters, as Swift's `String` counts them.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// Rows shown in all.
pub const LIMIT: usize = 200;
/// Characters a snippet keeps ahead of its first word.
pub const BEFORE: usize = 48;
/// Characters a snippet keeps from its first word.
pub const AFTER: usize = 110;

/// The query's words: lowercased, split on whitespace.
pub fn words(query: &str) -> Vec<String> {
    query.to_lowercase().split_whitespace().map(String::from).collect()
}

/// Foundation's `.whitespaces`: tab and the space separators (no line breaks).
fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// A source's text as searched: lines trimmed of spaces and tabs, empty ones dropped.
pub fn content_lines(raw: &[String]) -> Vec<String> {
    raw.iter()
        .map(|line| line.trim_matches(is_space))
        .filter(|line| !line.is_empty())
        .map(String::from)
        .collect()
}

/// One source to read: whether it has a terminal or an agent transcript, and whether it is on this Mac.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadSource {
    #[serde(default)]
    pub readable: bool,
    #[serde(default = "yes")]
    pub local: bool,
}

fn yes() -> bool {
    true
}

/// The sources to read, by index: those with text to read, this Mac's first, then in source order.
pub fn read_order(sources: &[ReadSource]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..sources.len()).filter(|&i| sources[i].readable).collect();
    order.sort_by_key(|&i| (usize::from(!sources[i].local), i));
    order
}

/// The grapheme range of `word`'s first case-insensitive match in `graphemes`, nil for an empty word.
fn find(graphemes: &[&str], word: &str) -> Option<(usize, usize)> {
    let wanted: Vec<String> = word.graphemes(true).map(str::to_lowercase).collect();
    if wanted.is_empty() || wanted.len() > graphemes.len() {
        return None;
    }
    (0..=graphemes.len() - wanted.len())
        .find(|&start| {
            wanted.iter().enumerate().all(|(k, w)| graphemes[start + k].to_lowercase() == *w)
        })
        .map(|start| (start, start + wanted.len()))
}

/// `line` cut to about `before` characters ahead of the first word and
/// `after` from it, with an ellipsis where it was cut.
pub fn snippet(line: &str, words: &[String], before: usize, after: usize) -> String {
    let graphemes: Vec<&str> = line.graphemes(true).collect();
    let Some((start, _)) = words.iter().find_map(|word| find(&graphemes, word)) else {
        return if graphemes.len() > before + after {
            graphemes[..before + after].concat() + "…"
        } else {
            line.to_string()
        };
    };
    let from = start.saturating_sub(before);
    let to = (start + after).min(graphemes.len());
    let mut out = String::new();
    if from > 0 {
        out.push('…');
    }
    out.push_str(&graphemes[from..to].concat());
    if to < graphemes.len() {
        out.push('…');
    }
    out
}

/// The word Find highlights: the first query word in the line, as typed there;
/// else the first word; "" without words.
pub fn needle(line: &str, words: &[String]) -> String {
    let graphemes: Vec<&str> = line.graphemes(true).collect();
    words
        .iter()
        .find_map(|word| find(&graphemes, word).map(|(from, to)| graphemes[from..to].concat()))
        .or_else(|| words.first().cloned())
        .unwrap_or_default()
}

/// Where a content match was found.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Origin {
    Terminal,
    /// The agent session's transcript (`claude`, `codex`).
    Transcript(String),
}

/// One text of a tab: its lines oldest first (``content_lines``) and their lowercased copies.
#[derive(Debug, Clone, Deserialize)]
pub struct Content {
    pub origin: Origin,
    pub lines: Vec<String>,
    #[serde(default)]
    pub lowered: Vec<String>,
}

impl Content {
    pub fn new(origin: Origin, raw: &[String]) -> Self {
        let lines = content_lines(raw);
        let lowered = lines.iter().map(|line| line.to_lowercase()).collect();
        Self { origin, lines, lowered }
    }
}

/// One tab to search.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub tab_id: String,
    pub lowered_title: String,
    /// The transcript first: its text is what was said, a TUI's history is redraws.
    #[serde(default)]
    pub texts: Vec<Content>,
}

/// One tab's match.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    pub tab_id: String,
    /// The newest line with the query's words, nil when the title alone matched.
    pub line: Option<String>,
    pub origin: Option<Origin>,
    /// Matching lines in all of the tab's text.
    pub count: usize,
    pub title_matched: bool,
}

/// The tabs matching every word, at most `limit`, and whether more matched: a
/// word may match the title and the rest one line of the tab's text. Tabs whose
/// title holds every word come first, then the others in source order.
pub fn hits(documents: &[Document], words: &[String], limit: usize) -> (Vec<Hit>, bool) {
    if words.is_empty() {
        return (Vec::new(), false);
    }
    let mut titled = Vec::new();
    let mut others = Vec::new();
    for document in documents {
        let remaining: Vec<&String> =
            words.iter().filter(|word| !document.lowered_title.contains(word.as_str())).collect();
        let needs: Vec<&String> =
            if remaining.is_empty() { words.iter().collect() } else { remaining.clone() };
        let mut best: Option<(String, Origin)> = None;
        let mut count = 0;
        for text in &document.texts {
            for index in (0..text.lowered.len()).rev() {
                if needs.iter().all(|word| text.lowered[index].contains(word.as_str())) {
                    if best.is_none() {
                        let line = text.lines.get(index).cloned().unwrap_or_default();
                        best = Some((line, text.origin.clone()));
                    }
                    count += 1;
                }
            }
        }
        let (line, origin) = best.map_or((None, None), |(line, origin)| (Some(line), Some(origin)));
        if remaining.is_empty() {
            titled.push(Hit {
                tab_id: document.tab_id.clone(),
                line,
                origin,
                count,
                title_matched: true,
            });
        } else if line.is_some() {
            others.push(Hit {
                tab_id: document.tab_id.clone(),
                line,
                origin,
                count,
                title_matched: false,
            });
        }
    }
    titled.extend(others);
    let limited = titled.len() > limit;
    titled.truncate(limit);
    (titled, limited)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(query: &str) -> Vec<String> {
        words(query)
    }

    fn lines(raw: &[&str]) -> Vec<String> {
        raw.iter().map(|line| line.to_string()).collect()
    }

    fn doc(tab: &str, title: &str, texts: Vec<Content>) -> Document {
        Document { tab_id: tab.into(), lowered_title: title.to_lowercase(), texts }
    }

    #[test]
    fn words_lowercase_and_split_on_whitespace() {
        assert_eq!(w("  Deploy   FAILED\tnow\n"), vec!["deploy", "failed", "now"]);
        assert!(w("   ").is_empty());
    }

    #[test]
    fn content_trims_spaces_and_drops_empty_lines() {
        let content =
            Content::new(Origin::Terminal, &lines(&["  a b ", "", "\t ", "\u{00A0}C\u{3000}"]));
        assert_eq!(content.lines, vec!["a b", "C"]);
        assert_eq!(content.lowered, vec!["a b", "c"]);
        // Line breaks are not `.whitespaces`: kept.
        assert_eq!(content_lines(&lines(&["\nx\n"])), vec!["\nx\n"]);
    }

    #[test]
    fn read_order_is_local_first_then_source_order() {
        let source = |readable, local| ReadSource { readable, local };
        let order = read_order(&[
            source(true, false),
            source(false, true),
            source(true, true),
            source(true, false),
            source(true, true),
        ]);
        assert_eq!(order, vec![2, 4, 0, 3]);
    }

    #[test]
    fn snippet_without_a_word_cuts_the_head() {
        let short = "no match here";
        assert_eq!(snippet(short, &w("zzz"), BEFORE, AFTER), short);
        let long = "x".repeat(200);
        assert_eq!(snippet(&long, &w("zzz"), BEFORE, AFTER), "x".repeat(158) + "…");
        let exact = "x".repeat(158);
        assert_eq!(snippet(&exact, &[], BEFORE, AFTER), exact);
    }

    #[test]
    fn snippet_windows_around_the_first_found_word() {
        let line = format!("{}NEEDLE{}", "a".repeat(100), "b".repeat(200));
        let out = snippet(&line, &w("missing needle"), BEFORE, AFTER);
        assert_eq!(out, format!("…{}NEEDLE{}…", "a".repeat(48), "b".repeat(104)));
        // Near the start: no leading ellipsis; near the end: no trailing one.
        assert_eq!(snippet("the needle", &w("needle"), BEFORE, AFTER), "the needle");
        let tail = format!("{}end", "c".repeat(60));
        assert_eq!(snippet(&tail, &w("end"), BEFORE, AFTER), format!("…{}end", "c".repeat(48)));
    }

    #[test]
    fn snippet_counts_graphemes() {
        let line = format!("{}hit", "é".repeat(50));
        assert_eq!(snippet(&line, &w("hit"), 2, 3), "…ééhit");
        let flags = "🇫🇷🇩🇪🇯🇵";
        assert_eq!(snippet(flags, &[], 1, 1), "🇫🇷🇩🇪…");
    }

    #[test]
    fn needle_is_the_word_as_typed_in_the_line() {
        assert_eq!(needle("Deploy FAILED at 3", &w("failed deploy")), "FAILED");
        assert_eq!(needle("nothing", &w("other word")), "other");
        assert_eq!(needle("nothing", &[]), "");
    }

    #[test]
    fn hits_match_every_word_across_title_and_lines() {
        let docs = vec![
            doc(
                "a",
                "Build",
                vec![Content::new(
                    Origin::Terminal,
                    &lines(&["deploy ok", "deploy failed", "other"]),
                )],
            ),
            doc("b", "Deploy failed", vec![]),
            doc("c", "Shell", vec![Content::new(Origin::Terminal, &lines(&["nothing"]))]),
            doc(
                "d",
                "Deploy",
                vec![
                    Content::new(
                        Origin::Transcript("claude".into()),
                        &lines(&["it failed", "failed again"]),
                    ),
                    Content::new(Origin::Terminal, &lines(&["failed tty"])),
                ],
            ),
        ];
        let (found, limited) = hits(&docs, &w("deploy failed"), LIMIT);
        assert!(!limited);
        assert_eq!(
            found,
            vec![
                Hit { tab_id: "b".into(), line: None, origin: None, count: 0, title_matched: true },
                Hit {
                    tab_id: "a".into(),
                    line: Some("deploy failed".into()),
                    origin: Some(Origin::Terminal),
                    count: 1,
                    title_matched: false
                },
                Hit {
                    tab_id: "d".into(),
                    line: Some("failed again".into()),
                    origin: Some(Origin::Transcript("claude".into())),
                    count: 3,
                    title_matched: false
                },
            ]
        );
    }

    #[test]
    fn a_titled_hit_counts_lines_with_every_word() {
        let docs = vec![doc(
            "a",
            "deploy",
            vec![Content::new(Origin::Terminal, &lines(&["deploy one", "two", "deploy three"]))],
        )];
        let (found, _) = hits(&docs, &w("deploy"), LIMIT);
        assert_eq!(found[0].line.as_deref(), Some("deploy three"));
        assert_eq!(found[0].count, 2);
        assert!(found[0].title_matched);
    }

    #[test]
    fn hits_are_limited() {
        let docs: Vec<Document> = (0..5).map(|i| doc(&i.to_string(), "x", vec![])).collect();
        let (found, limited) = hits(&docs, &w("x"), 3);
        assert_eq!(found.len(), 3);
        assert!(limited);
        let (found, limited) = hits(&docs, &w("x"), 5);
        assert_eq!(found.len(), 5);
        assert!(!limited);
        assert_eq!(hits(&docs, &[], 5), (vec![], false));
    }
}
