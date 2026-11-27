//! Search All Windows' corpus: every tab's title and text, searched once per keystroke.
//!
//! The macOS window (`GlobalSearchCorpus.hits`) used to walk every line of every tab on each key:
//! 50 agent tabs hold up to 1.2M lines (4,000 terminal rows plus 20,000 transcript lines each),
//! so each key cost a full pass whatever was typed before. Here each text is stored once as packed
//! lowercased UTF-8 (one buffer, one end offset per line) and searched with `memchr::memmem`. The
//! corpus keeps, per tab, the lines the previous query could still reach. A query that extends it
//! (every previous word is part of a new word) tests only those lines, so the work of a key
//! follows the matches left, not the corpus. A read landing (`apply`) drops only its own tab's
//! lines. RFD 0199 section 9.
//!
//! The answer is the one the Swift scan gave: a tab matches when every word is in its title or
//! in one line of its text (the words its title lacks, or every word when its title has them
//! all). Tabs whose title holds every word come first, then the others in source order, at most
//! `limit`. `tests/global_search.rs` checks every narrowed answer against that scan.

use memchr::memmem;

/// One text of a tab (a transcript, a terminal's history), lowercased, one line after another.
#[derive(Debug, Default, Clone)]
pub struct Text {
    /// Every line, lowercased, each followed by `\n` (a query word never holds whitespace, so no
    /// match spans two lines).
    bytes: Vec<u8>,
    /// Where each line ends in `bytes` (its `\n`).
    ends: Vec<usize>,
}

impl Text {
    pub fn new<S: AsRef<str>>(lines: &[S]) -> Self {
        let mut bytes = Vec::new();
        let mut ends = Vec::with_capacity(lines.len());
        for line in lines {
            bytes.extend_from_slice(line.as_ref().to_lowercase().as_bytes());
            ends.push(bytes.len());
            bytes.push(b'\n');
        }
        Self { bytes, ends }
    }

    pub fn len(&self) -> usize {
        self.ends.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ends.is_empty()
    }

    fn line(&self, index: usize) -> &[u8] {
        let start = index
            .checked_sub(1)
            .and_then(|previous| self.ends.get(previous))
            .map_or(0, |end| end.saturating_add(1));
        let end = self.ends.get(index).copied().unwrap_or(start);
        self.bytes.get(start..end).unwrap_or_default()
    }

    /// The lines holding `first` and every one of `rest`, oldest first: one pass over the
    /// buffer for `first`, then the other words in the lines it found.
    fn lines_with(&self, first: &memmem::Finder<'_>, rest: &[memmem::Finder<'_>]) -> Vec<usize> {
        let mut found: Vec<usize> = Vec::new();
        for at in first.find_iter(&self.bytes) {
            let index = self.ends.partition_point(|&end| end < at);
            if found.last() == Some(&index) {
                continue;
            }
            let line = self.line(index);
            if rest.iter().all(|word| word.find(line).is_some()) {
                found.push(index);
            }
        }
        found
    }
}

/// One tab.
#[derive(Debug, Default, Clone)]
struct Document {
    title: Vec<u8>,
    texts: Vec<Text>,
}

/// One tab's match.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    /// The tab's place in the corpus.
    pub document: usize,
    /// The text and line of the newest line with the query's words (texts in order, newest
    /// line first), none when the title alone matched.
    pub text: Option<usize>,
    pub line: Option<usize>,
    /// Matching lines in all of the tab's text.
    pub count: usize,
    pub title_matched: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    pub hits: Vec<Hit>,
    /// More tabs matched than `limit`.
    pub limited: bool,
    /// Lines this query tested (the narrowing's work).
    pub lines_scanned: u64,
}

/// The lines the previous query could still reach: per tab, per text, the lines that hold
/// every word of it the tab's title lacks. A line that matches a query extending it is one of
/// them.
#[derive(Debug, Default)]
struct Narrowing {
    words: Vec<String>,
    /// `None` for a tab to scan whole (a read landed since).
    reach: Vec<Option<Vec<Vec<usize>>>>,
}

/// What Search All Windows looks through, with the previous query's reach.
#[derive(Debug, Default)]
pub struct Corpus {
    documents: Vec<Document>,
    narrowing: Narrowing,
}

/// The query's words: lowercased, split at whitespace.
pub fn words(query: &str) -> Vec<String> {
    query.to_lowercase().split_whitespace().map(str::to_owned).collect()
}

fn extends(previous: &[String], words: &[String]) -> bool {
    !previous.is_empty()
        && previous.iter().all(|old| words.iter().any(|new| new.contains(old.as_str())))
}

impl Corpus {
    /// Every tab with its title and no text yet.
    pub fn new<S: AsRef<str>>(titles: &[S]) -> Self {
        let documents = titles
            .iter()
            .map(|title| Document {
                title: title.as_ref().to_lowercase().into_bytes(),
                texts: Vec::new(),
            })
            .collect();
        Self { documents, narrowing: Narrowing::default() }
    }

    pub fn len(&self) -> usize {
        self.documents.len()
    }

    pub fn is_empty(&self) -> bool {
        self.documents.is_empty()
    }

    /// Puts tab `document`'s texts in place (transcript first, as the Swift read orders them).
    /// False when there is no such tab.
    pub fn apply(&mut self, document: usize, texts: Vec<Text>) -> bool {
        let Some(slot) = self.documents.get_mut(document) else { return false };
        slot.texts = texts;
        if let Some(reach) = self.narrowing.reach.get_mut(document) {
            *reach = None;
        }
        true
    }

    /// The tabs matching every word, at most `limit`.
    pub fn hits(&mut self, words: &[String], limit: usize) -> Answer {
        if words.is_empty() {
            self.narrowing = Narrowing::default();
            return Answer { hits: Vec::new(), limited: false, lines_scanned: 0 };
        }
        let narrows = extends(&self.narrowing.words, words);
        let finders: Vec<memmem::Finder<'_>> =
            words.iter().map(|word| memmem::Finder::new(word.as_bytes())).collect();
        let mut scanned: u64 = 0;
        let mut titled = Vec::new();
        let mut others = Vec::new();
        let mut reach = Vec::with_capacity(self.documents.len());
        for (index, document) in self.documents.iter().enumerate() {
            let in_title: Vec<bool> =
                finders.iter().map(|word| word.find(&document.title).is_some()).collect();
            let lacking: Vec<memmem::Finder<'_>> = finders
                .iter()
                .zip(&in_title)
                .filter(|(_, titled)| !**titled)
                .map(|(word, _)| word.clone())
                .collect();
            let title_matched = lacking.is_empty();
            let previous = if narrows {
                self.narrowing.reach.get(index).and_then(Option::as_ref)
            } else {
                None
            };
            let mut doc_reach = Vec::with_capacity(document.texts.len());
            for (text_index, text) in document.texts.iter().enumerate() {
                let lines =
                    match (previous.and_then(|texts| texts.get(text_index)), lacking.split_first())
                    {
                        (Some(lines), _) => {
                            scanned = scanned.saturating_add(lines.len() as u64);
                            lines
                                .iter()
                                .copied()
                                .filter(|&line| {
                                    let line = text.line(line);
                                    lacking.iter().all(|word| word.find(line).is_some())
                                })
                                .collect()
                        }
                        (None, Some((first, rest))) => {
                            scanned = scanned.saturating_add(text.len() as u64);
                            text.lines_with(first, rest)
                        }
                        (None, None) => (0..text.len()).collect(),
                    };
                doc_reach.push(lines);
            }
            // The title holds every word: the lines that count hold every word too.
            let matches: Vec<Vec<usize>> = if title_matched {
                doc_reach
                    .iter()
                    .zip(&document.texts)
                    .map(|(lines, text)| {
                        scanned = scanned.saturating_add(lines.len() as u64);
                        lines
                            .iter()
                            .copied()
                            .filter(|&line| {
                                let line = text.line(line);
                                finders.iter().all(|word| word.find(line).is_some())
                            })
                            .collect()
                    })
                    .collect()
            } else {
                doc_reach.clone()
            };
            let count = matches.iter().map(Vec::len).fold(0usize, usize::saturating_add);
            let best = matches
                .iter()
                .enumerate()
                .find_map(|(text_index, lines)| lines.last().map(|&line| (text_index, line)));
            let hit = Hit {
                document: index,
                text: best.map(|b| b.0),
                line: best.map(|b| b.1),
                count,
                title_matched,
            };
            if title_matched {
                titled.push(hit);
            } else if best.is_some() {
                others.push(hit);
            }
            reach.push(Some(doc_reach));
        }
        drop(finders);
        self.narrowing = Narrowing { words: words.to_vec(), reach };
        titled.extend(others);
        let limited = titled.len() > limit;
        titled.truncate(limit);
        Answer { hits: titled, limited, lines_scanned: scanned }
    }
}
