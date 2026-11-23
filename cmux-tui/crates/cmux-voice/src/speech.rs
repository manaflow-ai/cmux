//! What voice mode says: an agent's Markdown turned into the words read aloud, and the
//! transcription noise that is never sent as a prompt.
//!
//! A port of the iPhone's `AgentVoiceSpeech` and `AgentVoiceSession.isNoise`
//! (`cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileRealtime/`), so desktop and phone share one
//! set of rules. The Swift regular expressions are hand-written matchers here (the crate has no
//! regex dependency); each matcher names the pattern it reproduces.
//!
//! Character counts: Swift's `String.count` counts grapheme clusters; this port counts `char`s
//! (Unicode scalars). They differ only for text with combining marks or emoji sequences.

/// Turns an agent's Markdown into what voice mode reads aloud: the agent's own words, near
/// verbatim, without what is useless to the ear. Code blocks, diffs, tables, images, long
/// inline code and raw URLs are left out; links keep their text; Markdown markers go. A message
/// that is only code says nothing (`None`), so the voice stays quiet rather than reading it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Speech {
    /// Longest text read for one message; longer text stops at a sentence end.
    pub max_characters: usize,
    /// Inline code longer than this is dropped (a path or a name is kept).
    pub max_inline_code: usize,
}

impl Default for Speech {
    fn default() -> Self {
        Self { max_characters: 1200, max_inline_code: 40 }
    }
}

impl Speech {
    /// What to say for `markdown`, or `None` when nothing in it is worth saying.
    #[must_use]
    pub fn speakable(&self, markdown: &str) -> Option<String> {
        let mut kept: Vec<&str> = Vec::new();
        let mut fence: Option<&str> = None;
        let mut diff_run: Vec<&str> = Vec::new();

        for raw_line in markdown.split(is_newline) {
            let line = raw_line.trim_matches(is_space);
            if let Some(open) = fence {
                if line.starts_with(open) {
                    fence = None;
                }
                continue;
            }
            if line.starts_with("```") || line.starts_with("~~~") {
                flush_diff_run(&mut diff_run, &mut kept);
                fence = line.get(..3);
                continue;
            }
            // A horizontal rule (`---`, `***`) is layout, not a diff line.
            if !line.is_empty() && line.chars().all(|c| "-*_= ".contains(c)) {
                flush_diff_run(&mut diff_run, &mut kept);
                continue;
            }
            if is_diff_line(line) {
                diff_run.push(line);
                continue;
            }
            flush_diff_run(&mut diff_run, &mut kept);
            // Tables, rules and HTML are layout, not speech.
            if line.starts_with('|') || line.starts_with('<') {
                continue;
            }
            // Indented code (a tab or four spaces) that is not a nested list item.
            if (raw_line.starts_with('\t') || raw_line.starts_with("    ")) && !is_list_item(line) {
                continue;
            }
            kept.push(line);
        }
        flush_diff_run(&mut diff_run, &mut kept);

        // Wrapped lines join into their paragraph; a blank line, a heading or a list item starts
        // a new block.
        let mut blocks: Vec<String> = Vec::new();
        let mut current = String::new();
        for line in kept {
            let starts_block = line.is_empty()
                || line.starts_with('#')
                || line.starts_with('>')
                || is_list_item(line)
                || current.starts_with('#'); // a heading is a block of its own
            if starts_block && !current.is_empty() {
                blocks.push(std::mem::take(&mut current));
            }
            if line.is_empty() {
                continue;
            }
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(line);
        }
        if !current.is_empty() {
            blocks.push(current);
        }

        let sentences: Vec<String> = blocks
            .iter()
            .map(|block| self.spoken_line(block))
            .filter(|line| !line.is_empty())
            .map(|mut line| {
                // A line read as its own sentence: a list item, a heading.
                if !line.chars().last().is_some_and(|last| ".!?:;,…".contains(last)) {
                    line.push('.');
                }
                line
            })
            .collect();
        // `\s+` -> " ", then trimmed.
        let text = collapse_whitespace(&sentences.join(" "), 1);
        let text = text.trim_matches(char::is_whitespace);
        if !text.chars().any(char::is_alphabetic) {
            return None;
        }
        Some(self.truncated(text))
    }

    /// One line without Markdown: markers, links, images, inline code.
    fn spoken_line(&self, line: &str) -> String {
        // Headings, quotes, list markers and task boxes.
        let text = strip_list_marker(strip_block_markers(line));
        // Images say nothing; links say their text.
        let text = replace_links(text);
        // Inline code: short names are read, long snippets are not.
        let text = self.replace_inline_code(&text);
        // Raw URLs are unreadable aloud.
        let text = replace_urls(&text);
        // Emphasis markers.
        let text = strip_emphasis(&text);
        let text = strip_underscore_emphasis(&text);
        text.trim_matches(is_space).to_owned()
    }

    fn replace_inline_code(&self, text: &str) -> String {
        if !text.contains('`') {
            return text.to_owned();
        }
        let mut out = String::with_capacity(text.len());
        let mut code: Option<String> = None;
        for character in text.chars() {
            if character == '`' {
                if let Some(span) = code.take() {
                    if span.chars().count() <= self.max_inline_code && !span.contains('\n') {
                        out.push_str(&span);
                    }
                } else {
                    code = Some(String::new());
                }
            } else if let Some(span) = code.as_mut() {
                span.push(character);
            } else {
                out.push(character);
            }
        }
        // An unclosed tick is just a tick (as in Swift, the text after it is kept, the tick not).
        if let Some(open) = code {
            out.push_str(&open);
        }
        // `\s{2,}` -> " "
        collapse_whitespace(&out, 2)
    }

    fn truncated(&self, text: &str) -> String {
        if text.chars().count() <= self.max_characters {
            return text.to_owned();
        }
        let head: String = text.chars().take(self.max_characters).collect();
        let end = head.chars().enumerate().filter(|&(_, c)| ".!?".contains(c)).last();
        if let Some((index, _)) = end
            && index > self.max_characters / 3
        {
            return head.chars().take(index + 1).collect();
        }
        head + "…"
    }
}

/// What transcription makes of noise, never sent as a prompt: nothing, a lone filler, or the
/// phrases speech models invent from silence.
#[must_use]
pub fn is_noise(text: &str) -> bool {
    const INVENTED: [&str; 14] = [
        "thank you",
        "thanks",
        "thanks for watching",
        "thank you for watching",
        "bye",
        "you",
        "uh",
        "um",
        "hmm",
        "mm",
        "ah",
        "oh",
        "okay bye",
        "subtitles by the amaraorg community",
    ];
    let lowered = text.to_lowercase();
    let folded = lowered.trim_matches(|c: char| c.is_whitespace() || is_punctuation(c));
    if !folded.chars().any(char::is_alphabetic) {
        return true;
    }
    INVENTED.contains(&folded.replace('.', "").as_str())
}

/// One `-`/`+` line is a list item; two or more in a row are a diff.
fn flush_diff_run<'a>(diff_run: &mut Vec<&'a str>, kept: &mut Vec<&'a str>) {
    if let [only] = diff_run.as_slice() {
        kept.push(only);
    }
    diff_run.clear();
}

fn is_diff_line(line: &str) -> bool {
    line.starts_with("@@")
        || line.starts_with("diff --git")
        || line.starts_with("+++ ")
        || line.starts_with("--- ")
        || (line.starts_with("index ") && line.contains(".."))
        || ((line.starts_with('+') || line.starts_with('-'))
            && !line.starts_with("- ")
            && !line.starts_with("+ ")
            && line.chars().count() > 1)
        || line == "+"
        || line == "-"
}

/// `^([-*+]|\d+[.)])\s+`: the text after the marker and its spaces, when `line` is a list item.
fn after_list_marker(line: &str) -> Option<&str> {
    let rest = if let Some(rest) = line.strip_prefix(|c| matches!(c, '-' | '*' | '+')) {
        rest
    } else {
        let rest = line.trim_start_matches(|c: char| c.is_ascii_digit());
        if rest.len() == line.len() {
            return None;
        }
        rest.strip_prefix(|c| matches!(c, '.' | ')'))?
    };
    let after = rest.trim_start_matches(char::is_whitespace);
    (after.len() < rest.len()).then_some(after)
}

fn is_list_item(line: &str) -> bool {
    after_list_marker(line).is_some()
}

/// `^(#{1,6}\s+|>\s*)+` -> "": leading heading and quote markers.
fn strip_block_markers(mut text: &str) -> &str {
    loop {
        let after_hashes = text.trim_start_matches('#');
        let hashes = text.len() - after_hashes.len();
        if (1..=6).contains(&hashes) {
            let after = after_hashes.trim_start_matches(char::is_whitespace);
            if after.len() < after_hashes.len() {
                text = after;
                continue;
            }
        }
        if let Some(rest) = text.strip_prefix('>') {
            text = rest.trim_start_matches(char::is_whitespace);
            continue;
        }
        return text;
    }
}

/// `^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?` -> "": a list marker and its task box.
fn strip_list_marker(text: &str) -> &str {
    let Some(rest) = after_list_marker(text) else {
        return text;
    };
    let task_box = ["[ ]", "[x]", "[X]"].iter().find_map(|mark| rest.strip_prefix(mark));
    if let Some(after_box) = task_box {
        let after = after_box.trim_start_matches(char::is_whitespace);
        if after.len() < after_box.len() {
            return after;
        }
    }
    rest
}

/// `[label](target)` at the start of `text` (`[^\]]*` or, unless `allow_empty`, `[^\]]+` for
/// the label; `[^)]*` for the target): the label and the text after the `)`.
fn bracket_link(text: &str, allow_empty: bool) -> Option<(&str, &str)> {
    let inner = text.strip_prefix('[')?;
    let close = inner.find(']')?;
    let label = inner.get(..close)?;
    if label.is_empty() && !allow_empty {
        return None;
    }
    let target = inner.get(close + 1..)?.strip_prefix('(')?;
    let end = target.find(')')?;
    Some((label, target.get(end + 1..)?))
}

/// `!\[[^\]]*\]\([^)]*\)` -> "" over the whole line, then `\[([^\]]+)\]\([^)]*\)` -> "$1".
fn replace_links(text: &str) -> String {
    let without_images = replace_each(text, |rest| {
        let (_, after) = bracket_link(rest.strip_prefix('!')?, true)?;
        Some((String::new(), after))
    });
    replace_each(&without_images, |rest| {
        let (label, after) = bracket_link(rest, false)?;
        Some((label.to_owned(), after))
    })
}

/// `https?://\S+` -> "a link".
fn replace_urls(text: &str) -> String {
    replace_each(text, |rest| {
        let after = rest.strip_prefix("https://").or_else(|| rest.strip_prefix("http://"))?;
        let tail = after.trim_start_matches(|c: char| !c.is_whitespace());
        (tail.len() < after.len()).then(|| ("a link".to_owned(), tail))
    })
}

/// `(\*\*|__|\*|~~)` -> "".
fn strip_emphasis(text: &str) -> String {
    replace_each(text, |rest| {
        let after = rest
            .strip_prefix("**")
            .or_else(|| rest.strip_prefix("__"))
            .or_else(|| rest.strip_prefix('*'))
            .or_else(|| rest.strip_prefix("~~"))?;
        Some((String::new(), after))
    })
}

/// `(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])` -> "$1". The lookbehind sees the original text,
/// as a regex replace does.
fn strip_underscore_emphasis(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while let Some(&character) = chars.get(index) {
        let after_word = index
            .checked_sub(1)
            .and_then(|previous| chars.get(previous))
            .is_some_and(char::is_ascii_alphanumeric);
        if character == '_'
            && !after_word
            && let Some(length) =
                chars.get(index + 1..).and_then(|rest| rest.iter().position(|&c| c == '_'))
        {
            let close = index + 1 + length;
            if length > 0 && !chars.get(close + 1).is_some_and(char::is_ascii_alphanumeric) {
                out.extend(chars.get(index + 1..close).into_iter().flatten());
                index = close + 1;
                continue;
            }
        }
        out.push(character);
        index += 1;
    }
    out
}

/// A global regex replace: at each position `matcher` either matches (the replacement and the
/// text after the match) or the character there is kept and the scan moves on.
fn replace_each<'a>(
    text: &'a str,
    matcher: impl Fn(&'a str) -> Option<(String, &'a str)>,
) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        if let Some((replacement, after)) = matcher(rest) {
            out.push_str(&replacement);
            rest = after;
            continue;
        }
        let mut chars = rest.chars();
        let Some(character) = chars.next() else {
            return out;
        };
        out.push(character);
        rest = chars.as_str();
    }
}

/// `\s+` (`min_run` 1) or `\s{2,}` (`min_run` 2) -> " "; shorter runs are kept as they are.
fn collapse_whitespace(text: &str, min_run: usize) -> String {
    let mut out = String::with_capacity(text.len());
    let mut run = String::new();
    let flush = |out: &mut String, run: &mut String| {
        if run.chars().count() >= min_run {
            out.push(' ');
        } else {
            out.push_str(run);
        }
        run.clear();
    };
    for character in text.chars() {
        if character.is_whitespace() {
            run.push(character);
        } else {
            flush(&mut out, &mut run);
            out.push(character);
        }
    }
    flush(&mut out, &mut run);
    out
}

/// Foundation's `CharacterSet.newlines`: U+000A–U+000D, U+0085, U+2028, U+2029.
fn is_newline(c: char) -> bool {
    matches!(c, '\n'..='\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Foundation's `CharacterSet.whitespaces`: spaces (Unicode `Zs`) and tab, not newlines.
fn is_space(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !is_newline(c))
}

/// Foundation's `CharacterSet.punctuationCharacters` (Unicode `P*`): ASCII punctuation (not the
/// symbols such as `$`, `+`, `^`, `|`, `~` and the backtick), Latin-1 punctuation, General Punctuation and CJK punctuation. Rare
/// `P*` code points outside these blocks are not covered.
fn is_punctuation(c: char) -> bool {
    matches!(
        c,
        '!' | '"' | '#' | '%' | '&' | '\'' | '(' | ')' | '*' | ',' | '-' | '.' | '/' | ':' | ';'
            | '?' | '@' | '[' | '\\' | ']' | '_' | '{' | '}'
            | '¡' | '§' | '«' | '¶' | '·' | '»' | '¿'
            | '\u{2010}'..='\u{2027}'
            | '\u{2030}'..='\u{2043}'
            | '\u{2045}'..='\u{2051}'
            | '\u{2053}'..='\u{205E}'
            | '\u{3001}'..='\u{3003}'
            | '\u{3008}'..='\u{3011}'
            | '\u{3014}'..='\u{301F}'
            | '\u{FF01}'..='\u{FF03}'
            | '\u{FF05}'..='\u{FF0A}'
            | '\u{FF0C}'..='\u{FF0F}'
            | '\u{FF1A}'
            | '\u{FF1B}'
            | '\u{FF1F}'
            | '\u{FF20}'
    )
}

#[cfg(test)]
mod tests {
    use super::{Speech, is_noise};

    fn speakable(markdown: &str) -> Option<String> {
        Speech::default().speakable(markdown)
    }

    #[test]
    fn code_blocks_and_diffs_are_not_read() {
        let markdown = "I fixed the race in the session store.\n\n```swift\nlet x = store.load()\nx.save()\n```\n\n```diff\n@@ -1,3 +1,3 @@\n-let a = 1\n+let a = 2\n```\n\nAll 43 tests pass now.";
        assert_eq!(
            speakable(markdown).as_deref(),
            Some("I fixed the race in the session store. All 43 tests pass now.")
        );
    }

    #[test]
    fn a_bare_diff_outside_a_fence_is_not_read() {
        let markdown = "Here is the change:\ndiff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -4 +4 @@\n-old()\n+new()\nDone.";
        assert_eq!(speakable(markdown).as_deref(), Some("Here is the change: Done."));
    }

    #[test]
    fn only_code_says_nothing() {
        assert_eq!(speakable("```\nmake test\n```"), None);
        assert_eq!(speakable(""), None);
        assert_eq!(speakable("| a | b |\n|---|---|\n| 1 | 2 |"), None);
    }

    #[test]
    fn markdown_markers_go_and_links_keep_their_text() {
        let markdown = "## Summary\n- **Fixed** the [login bug](https://github.com/x/y/pull/1)\n- Updated `README.md` and _docs_\n\n---\nSee https://example.com/very/long/url for more.\n![screenshot](shot.png)";
        assert_eq!(
            speakable(markdown).as_deref(),
            Some("Summary. Fixed the login bug. Updated README.md and docs. See a link for more.")
        );
    }

    #[test]
    fn long_inline_code_is_dropped() {
        let text = "Run `xcodebuild -scheme CmuxMobileKit-Package -destination generic/platform=iOS test` again.";
        assert_eq!(speakable(text).as_deref(), Some("Run again."));
    }

    #[test]
    fn wrapped_lines_join_into_one_sentence() {
        assert_eq!(
            speakable("The build failed because\nthe cache was stale.").as_deref(),
            Some("The build failed because the cache was stale.")
        );
    }

    #[test]
    fn a_single_dashed_list_item_is_kept() {
        assert_eq!(speakable("Next:\n- rerun CI").as_deref(), Some("Next: rerun CI."));
    }

    #[test]
    fn long_text_stops_at_a_sentence_end() {
        let speech = Speech { max_characters: 60, ..Speech::default() };
        let text = "First sentence is here. Second sentence is also here. Third sentence goes past the limit.";
        assert_eq!(
            speech.speakable(text).as_deref(),
            Some("First sentence is here. Second sentence is also here.")
        );
    }

    /// `AgentVoiceSessionRecoveryTests.noiseIsNeverSentAsAPrompt`: the transcripts it delivers,
    /// checked against the filter directly.
    #[test]
    fn noise_is_never_sent_as_a_prompt() {
        for noise in ["Thank you.", "  ", "Bye!", "Hmm…", "you"] {
            assert!(is_noise(noise), "{noise:?} is noise");
        }
        assert!(!is_noise("Yes, go ahead."));
    }
}
