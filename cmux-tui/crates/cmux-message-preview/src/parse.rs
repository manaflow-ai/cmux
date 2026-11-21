//! Red: the Markdown is not read yet; a preview is the text as written.

use crate::{Image, Piece, folded};

pub(crate) fn parse(markdown: &str) -> (Vec<Piece>, Vec<Image>) {
    let words = folded(markdown);
    (if words.is_empty() { Vec::new() } else { vec![Piece::Words(words)] }, Vec::new())
}
