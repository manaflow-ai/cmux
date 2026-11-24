//! The query, compiled once per find with the bar's toggles.

use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};

/// The find bar's toggles. All off by default: a literal, case-insensitive substring, which is
/// what Cmd-F did before the toggles existed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct FindOptions {
    /// Match letter case exactly.
    pub case_sensitive: bool,
    /// Only matches with a word boundary on both sides (`\b`).
    pub whole_word: bool,
    /// The query is a regular expression (Rust `regex` syntax), not a literal.
    pub regex: bool,
}

/// Why a query cannot be searched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FindError {
    /// The regular expression does not compile; the message says where.
    InvalidPattern(String),
}

impl std::fmt::Display for FindError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidPattern(message) => write!(f, "invalid pattern: {message}"),
        }
    }
}

impl std::error::Error for FindError {}

/// A compiled query.
#[derive(Debug, Clone)]
pub struct Matcher {
    regex: Regex,
}

/// Bounds a pathological pattern's compiled size, so a pasted regex cannot take the daemon's
/// memory (the `regex` crate's default is 10 MiB; a find needs far less).
const REGEX_SIZE_LIMIT: usize = 2 << 20;

impl Matcher {
    /// Compiles `query`. `Ok(None)` for an empty query, which matches nothing.
    pub fn new(query: &str, options: FindOptions) -> Result<Option<Self>, FindError> {
        if query.is_empty() {
            return Ok(None);
        }
        let body = if options.regex { query.to_owned() } else { regex::escape(query) };
        let pattern = if options.whole_word { format!(r"\b(?:{body})\b") } else { body };
        let regex = RegexBuilder::new(&pattern)
            .case_insensitive(!options.case_sensitive)
            .size_limit(REGEX_SIZE_LIMIT)
            .build()
            .map_err(|err| FindError::InvalidPattern(err.to_string()))?;
        Ok(Some(Self { regex }))
    }

    /// The byte ranges of every non-empty match in `text`, left to right. A pattern that can
    /// match the empty string (`a*`) reports only its non-empty matches, so a find never counts
    /// a highlight with nothing in it.
    pub fn ranges<'t>(&'t self, text: &'t str) -> impl Iterator<Item = (usize, usize)> + 't {
        self.regex
            .find_iter(text)
            .filter(|found| !found.is_empty())
            .map(|found| (found.start(), found.end()))
    }
}
