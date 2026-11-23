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
#[path = "question_reply_render_tests.rs"]
mod tests;
