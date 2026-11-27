use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

/// Readable chunks, not a transport send limit. Splitting retains all text and
/// happens at Unicode character boundaries; URLs stay intact on separate lines.
const PARAGRAPH_CHARS: usize = 512;

/// Render CommonMark text without markup. Link destinations are listed after
/// their paragraph, one per line. No HTML is executed, fetched, or displayed.
pub fn plain_messages(markdown: &str) -> String {
    let mut output = Vec::new();
    let mut paragraph = String::new();
    let mut links = Vec::new();
    for event in Parser::new_ext(markdown, Options::ENABLE_STRIKETHROUGH) {
        match event {
            Event::Text(text) | Event::Code(text) => paragraph.push_str(&text),
            Event::SoftBreak | Event::HardBreak => paragraph.push(' '),
            Event::Start(Tag::Link { dest_url, .. } | Tag::Image { dest_url, .. }) => {
                let url = dest_url.trim();
                if (url.starts_with("https://")
                    || url.starts_with("http://")
                    || url.starts_with("mailto:"))
                    && !url.chars().any(char::is_whitespace)
                    && !links.iter().any(|link| link == url)
                {
                    links.push(url.to_owned());
                }
            }
            Event::End(
                TagEnd::Paragraph | TagEnd::Heading(_) | TagEnd::CodeBlock | TagEnd::Item,
            )
            | Event::Rule => flush(&mut paragraph, &mut links, &mut output),
            _ => {}
        }
    }
    flush(&mut paragraph, &mut links, &mut output);
    output.join("\n\n")
}

fn flush(paragraph: &mut String, links: &mut Vec<String>, output: &mut Vec<String>) {
    let text = super::one_line(paragraph);
    paragraph.clear();
    // Keep whole URLs intact. Their own line is a deliberate exception to the
    // prose chunk size: wrapping one changes the link a person can open.
    if !text.is_empty() {
        let chars: Vec<_> = text.chars().collect();
        let mut remaining = chars.as_slice();
        while let Some((window, _)) =
            remaining.split_at_checked(PARAGRAPH_CHARS).filter(|(_, rest)| !rest.is_empty())
        {
            let end = window
                .iter()
                .rposition(|ch| ch.is_whitespace())
                .map_or(PARAGRAPH_CHARS, |index| index.saturating_add(1));
            let Some((chunk, rest)) = remaining.split_at_checked(end) else {
                break;
            };
            output.push(chunk.iter().collect());
            remaining = rest;
        }
        output.push(remaining.iter().collect());
    }
    if !links.is_empty() {
        output.push(links.join("\n"));
        links.clear();
    }
}

#[cfg(test)]
mod tests {
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
}
