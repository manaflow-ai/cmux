use super::*;

#[test]
fn markdown_is_plain_and_links_get_their_own_lines() {
    assert_eq!(
        plain_messages(
            "# **Choose**\n\nUse `code` and [docs](https://example.com/docs), or [help](https://example.com/help).\n\n~~Old~~ text."
        ),
        "Choose\n\nUse code and docs, or help.\n\nhttps://example.com/docs\nhttps://example.com/help\n\nOld text."
    );
    assert_eq!(
        plain_messages("Click [here](javascript:alert) or <b>read</b>."),
        "Click here or read."
    );
}

#[test]
fn paragraphs_are_bounded_without_losing_unicode_text() {
    let text = "界".repeat(PARAGRAPH_CHARS * 2 + 7);
    let rendered = plain_messages(&text);
    let chunks: Vec<_> = rendered.split("\n\n").collect();
    assert_eq!(chunks.len(), 3);
    assert!(chunks.iter().all(|chunk| chunk.chars().count() <= PARAGRAPH_CHARS));
    assert_eq!(chunks.join(""), text);
}

#[test]
fn prose_splits_at_whitespace_without_breaking_words_or_losing_text() {
    let text = format!("{}final word", "word ".repeat(103));
    let rendered = plain_messages(&text);
    let chunks: Vec<_> = rendered.split("\n\n").collect();
    assert_eq!(chunks.len(), 2);
    assert!(chunks[0].ends_with(' '));
    assert!(chunks[1].starts_with("word "));
    assert!(chunks.iter().all(|chunk| chunk.chars().count() <= PARAGRAPH_CHARS));
    assert_eq!(chunks.join(""), text);
}
