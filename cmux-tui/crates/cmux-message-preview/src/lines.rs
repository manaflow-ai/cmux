//! Red: the lines are as written.

use crate::{Words, folded};

pub(crate) fn lines(markdown: &str, _words: &Words) -> Vec<String> {
    markdown.lines().map(folded).filter(|l| !l.is_empty()).collect()
}
