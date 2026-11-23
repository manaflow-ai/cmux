//! A slide deck written as Markdown: slides split by a `---` line, compiled into the
//! cmux deck page (the `cmux-rich-output` skill's `templates/deck.html`: slide strip,
//! arrow keys, Present, Export PDF, Export .pptx).
//!
//! The format is the common Markdown slide format, so a deck an agent already knows how to
//! write works: optional front matter (`title:`), a `---` line between slides (never inside
//! a code fence), `<!-- _class: title -->` (or `center`) on a slide for its layout,
//! `<!-- skip -->` on a slide to keep it out of Present and the exports, and any
//! other HTML comment as the slide's speaker notes. A `Notes:` line also starts the notes.
//! A slide with nothing but headings is a title slide. Raw HTML (an inline `<svg>` chart, a
//! `<div class="cols">`) passes through.
//!
//! The deck viewer (`pptx_view`) compiles the file on every load, so a deck the agent
//! keeps editing shows its newest text when `open {live}` reloads the tab.

use std::path::Path;

use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

const TEMPLATE: &str =
    include_str!("../../../../acpmux/skills/cmux-rich-output/templates/deck.html");
const MAIN_OPEN: &str = "<main class=\"deck\">";
const MAIN_CLOSE: &str = "</main>";
const TITLE_TAG: &str = "<title>Deck title</title>";

/// The most front matter read to tell a deck from a document, in bytes.
const SNIFF_BYTES: usize = 4096;

/// Whether `open` shows `path` as a deck: a `.slides.md` or `.deck.md` name, or a
/// Markdown file whose front matter says `slides: true` (or `deck: true`, or the key other
/// slide tools write).
pub(super) fn is_deck(path: &str) -> bool {
    let name = Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    if [".slides.md", ".deck.md"].iter().any(|suffix| name.ends_with(suffix)) {
        return true;
    }
    if !(name.ends_with(".md") || name.ends_with(".markdown")) {
        return false;
    }
    let Ok(file) = std::fs::File::open(path) else { return false };
    let mut head = Vec::with_capacity(SNIFF_BYTES);
    if std::io::Read::read_to_end(&mut std::io::Read::take(file, SNIFF_BYTES as u64), &mut head)
        .is_err()
    {
        return false;
    }
    let head = String::from_utf8_lossy(&head);
    front_matter(&head).0.iter().any(|(key, value)| {
        matches!(key.as_str(), "marp" | "slides" | "deck") && value.eq_ignore_ascii_case("true")
    })
}

/// The deck page for `source`; `fallback_title` (the file's name) when the front matter
/// names none.
pub(super) fn compile(source: &str, fallback_title: &str) -> String {
    let (meta, body) = front_matter(source);
    let title = meta
        .iter()
        .find(|(key, _)| key == "title")
        .map(|(_, value)| value.as_str())
        .filter(|title| !title.is_empty())
        .unwrap_or(fallback_title);
    let mut sections = String::new();
    for slide in split_slides(body) {
        sections.push_str(&render_slide(&slide));
    }
    let (head, rest) = TEMPLATE.split_once(MAIN_OPEN).unwrap_or((TEMPLATE, ""));
    let tail = rest.split_once(MAIN_CLOSE).map(|(_, tail)| tail).unwrap_or_default();
    let head = head.replace(TITLE_TAG, &format!("<title>{}</title>", escape(title)));
    format!("{head}{MAIN_OPEN}\n{sections}{MAIN_CLOSE}{tail}")
}

/// How many slides `source` makes.
pub(super) fn slide_count(source: &str) -> usize {
    split_slides(front_matter(source).1).len()
}

/// The template's runtime script, the one script the page's policy lets run.
pub(super) fn runtime_script() -> &'static str {
    TEMPLATE
        .rsplit_once("<script>")
        .and_then(|(_, rest)| rest.split_once("</script>"))
        .map(|(script, _)| script)
        .unwrap_or_default()
}

/// The front matter's top-level `key: value` lines (quotes dropped) and the text after it.
fn front_matter(source: &str) -> (Vec<(String, String)>, &str) {
    let source = source.strip_prefix('\u{feff}').unwrap_or(source);
    let Some(rest) = source.strip_prefix("---").filter(|rest| rest.starts_with(['\n', '\r']))
    else {
        return (Vec::new(), source);
    };
    let mut meta = Vec::new();
    let mut offset = 0;
    for line in rest.split_inclusive('\n') {
        offset += line.len();
        let trimmed = line.trim_end();
        if offset > line.len() && (trimmed == "---" || trimmed == "...") {
            return (meta, rest.get(offset..).unwrap_or_default());
        }
        if line.starts_with([' ', '\t']) {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once(':') {
            let value = value.trim().trim_matches(['"', '\'']).to_owned();
            meta.push((key.trim().to_ascii_lowercase(), value));
        }
    }
    // An unclosed block is not front matter.
    (Vec::new(), source)
}

/// The slides' Markdown, split at `---` lines outside fenced code.
fn split_slides(body: &str) -> Vec<String> {
    let mut slides = vec![String::new()];
    let mut fence: Option<String> = None;
    for line in body.split_inclusive('\n') {
        let trimmed = line.trim();
        match &fence {
            Some(open) if trimmed.starts_with(open.as_str()) => fence = None,
            Some(_) => {}
            None if trimmed.starts_with("```") || trimmed.starts_with("~~~") => {
                fence = Some(trimmed.get(..3).unwrap_or(trimmed).to_owned());
            }
            None if trimmed == "---" => {
                slides.push(String::new());
                continue;
            }
            None => {}
        }
        if let Some(slide) = slides.last_mut() {
            slide.push_str(line);
        }
    }
    slides.retain(|slide| !slide.trim().is_empty());
    slides
}

/// One `<section>`: its class and skip directives, its notes, and its Markdown as HTML.
fn render_slide(markdown: &str) -> String {
    let mut class = None;
    let mut skip = false;
    let mut notes = Vec::new();
    let mut body = String::with_capacity(markdown.len());
    let mut rest = markdown;
    // HTML comments: a class or skip directive or speaker notes, never shown.
    while let Some((before, after)) = rest.split_once("<!--") {
        body.push_str(before);
        let Some((comment, tail)) = after.split_once("-->") else {
            body.push_str("<!--");
            body.push_str(after);
            rest = "";
            break;
        };
        let comment = comment.trim();
        let directive = comment.strip_prefix("_class:").or_else(|| comment.strip_prefix("class:"));
        match directive {
            Some(value) => class = Some(value.trim().to_owned()),
            None if comment == "skip" || comment == "_skip: true" => skip = true,
            None if !comment.is_empty() => notes.push(comment.to_owned()),
            None => {}
        }
        rest = tail;
    }
    body.push_str(rest);
    // `Notes:` on its own line: the rest of the slide is notes.
    let mut shown = String::with_capacity(body.len());
    let mut in_notes = false;
    for line in body.split_inclusive('\n') {
        let trimmed = line.trim_start();
        if !in_notes {
            if let Some(said) = ["Notes:", "Note:"].iter().find_map(|tag| trimmed.strip_prefix(tag))
            {
                in_notes = true;
                if !said.trim().is_empty() {
                    notes.push(said.trim().to_owned());
                }
                continue;
            }
            shown.push_str(line);
        } else if !line.trim().is_empty() {
            notes.push(line.trim().to_owned());
        }
    }
    let (html, only_headings) = markdown_html(&shown);
    let class = class.or_else(|| only_headings.then(|| "title".to_owned()));
    let mut section = match class.as_deref().map(class_attr).filter(|class| !class.is_empty()) {
        Some(class) => format!("<section class=\"{class}\""),
        None => "<section".to_owned(),
    };
    section.push_str(if skip { " data-skip>\n" } else { ">\n" });
    section.push_str(&html);
    if !notes.is_empty() {
        section.push_str("<aside class=\"notes\">");
        section.push_str(&escape(&notes.join("\n")));
        section.push_str("</aside>\n");
    }
    section.push_str("</section>\n\n");
    section
}

/// Only the class names a deck has: letters, digits, `-` and `_`, space separated.
fn class_attr(value: &str) -> String {
    value
        .split_whitespace()
        .filter(|name| name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The slide's Markdown as HTML, and whether it held only headings (with an h1 among them).
fn markdown_html(markdown: &str) -> (String, bool) {
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_FOOTNOTES;
    let mut out = String::with_capacity(markdown.len() * 2);
    let mut table: Vec<Alignment> = Vec::new();
    let mut cell = 0;
    let mut in_head = false;
    // Inside an image the text is its alt, written once the image ends.
    let mut image: Option<(String, String, String)> = None;
    let mut blocks = 0;
    let mut heading_blocks = 0;
    // Lists and quotes open: a block inside one is not one of the slide's own.
    let mut nested = 0usize;
    let mut has_h1 = false;
    for event in Parser::new_ext(markdown, options) {
        if let Some((_, _, alt)) = image.as_mut() {
            match event {
                Event::End(TagEnd::Image) => {
                    let (src, title, alt) = image.take().unwrap_or_default();
                    out.push_str(&format!(
                        "<img src=\"{}\" alt=\"{}\"",
                        escape(&src),
                        escape(&alt)
                    ));
                    if !title.is_empty() {
                        out.push_str(&format!(" title=\"{}\"", escape(&title)));
                    }
                    out.push('>');
                }
                Event::Text(text) | Event::Code(text) => alt.push_str(&text),
                _ => {}
            }
            continue;
        }
        match event {
            Event::Start(tag) => {
                if is_block(&tag) && nested == 0 {
                    blocks += 1;
                    if matches!(tag, Tag::Heading { .. }) {
                        heading_blocks += 1;
                    }
                }
                if matches!(tag, Tag::List(_) | Tag::BlockQuote(_)) {
                    nested += 1;
                }
                match tag {
                    Tag::Paragraph => out.push_str("<p>"),
                    Tag::Heading { level, .. } => {
                        has_h1 |= level == HeadingLevel::H1;
                        out.push_str(&format!("<{}>", heading(level)));
                    }
                    Tag::BlockQuote(_) => out.push_str("<blockquote>\n"),
                    Tag::CodeBlock(kind) => match kind {
                        CodeBlockKind::Fenced(lang) if !lang.is_empty() => {
                            let lang = lang.split_whitespace().next().unwrap_or_default();
                            out.push_str(&format!(
                                "<pre><code class=\"language-{}\">",
                                escape(lang)
                            ));
                        }
                        _ => out.push_str("<pre><code>"),
                    },
                    Tag::List(Some(1)) => out.push_str("<ol>\n"),
                    Tag::List(Some(start)) => out.push_str(&format!("<ol start=\"{start}\">\n")),
                    Tag::List(None) => out.push_str("<ul>\n"),
                    Tag::Item => out.push_str("<li>"),
                    Tag::Table(alignments) => {
                        table = alignments;
                        out.push_str("<table>");
                    }
                    Tag::TableHead => {
                        in_head = true;
                        cell = 0;
                        out.push_str("<thead><tr>");
                    }
                    Tag::TableRow => {
                        cell = 0;
                        out.push_str("<tr>");
                    }
                    Tag::TableCell => {
                        let name = if in_head { "th" } else { "td" };
                        match table.get(cell) {
                            Some(Alignment::Left) => {
                                out.push_str(&format!("<{name} style=\"text-align:left\">"));
                            }
                            Some(Alignment::Center) => {
                                out.push_str(&format!("<{name} style=\"text-align:center\">"));
                            }
                            Some(Alignment::Right) => {
                                out.push_str(&format!("<{name} style=\"text-align:right\">"));
                            }
                            _ => out.push_str(&format!("<{name}>")),
                        }
                    }
                    Tag::Emphasis => out.push_str("<em>"),
                    Tag::Strong => out.push_str("<strong>"),
                    Tag::Strikethrough => out.push_str("<del>"),
                    Tag::Link { dest_url, title, .. } => {
                        out.push_str(&format!("<a href=\"{}\"", escape(&dest_url)));
                        if !title.is_empty() {
                            out.push_str(&format!(" title=\"{}\"", escape(&title)));
                        }
                        out.push('>');
                    }
                    Tag::Image { dest_url, title, .. } => {
                        image = Some((dest_url.into_string(), title.into_string(), String::new()));
                    }
                    Tag::FootnoteDefinition(name) => {
                        out.push_str(&format!(
                            "<div class=\"footnote\"><sup>{}</sup> ",
                            escape(&name)
                        ));
                    }
                    _ => {}
                }
            }
            Event::End(tag) => match tag {
                TagEnd::List(_) | TagEnd::BlockQuote(_) => {
                    nested = nested.saturating_sub(1);
                    out.push_str(match tag {
                        TagEnd::List(true) => "</ol>\n",
                        TagEnd::List(false) => "</ul>\n",
                        _ => "</blockquote>\n",
                    });
                }
                TagEnd::Paragraph => out.push_str("</p>\n"),
                TagEnd::Heading(level) => out.push_str(&format!("</{}>\n", heading(level))),
                TagEnd::CodeBlock => out.push_str("</code></pre>\n"),
                TagEnd::Item => out.push_str("</li>\n"),
                TagEnd::Table => out.push_str("</tbody></table>\n"),
                TagEnd::TableHead => {
                    in_head = false;
                    out.push_str("</tr></thead><tbody>");
                }
                TagEnd::TableRow => out.push_str("</tr>"),
                TagEnd::TableCell => {
                    out.push_str(if in_head { "</th>" } else { "</td>" });
                    cell += 1;
                }
                TagEnd::Emphasis => out.push_str("</em>"),
                TagEnd::Strong => out.push_str("</strong>"),
                TagEnd::Strikethrough => out.push_str("</del>"),
                TagEnd::Link => out.push_str("</a>"),
                TagEnd::FootnoteDefinition => out.push_str("</div>\n"),
                _ => {}
            },
            Event::Text(text) => out.push_str(&escape(&text)),
            Event::Code(text) => out.push_str(&format!("<code>{}</code>", escape(&text))),
            Event::Html(html) => out.push_str(&html),
            Event::InlineHtml(html) => out.push_str(&html),
            Event::FootnoteReference(name) => {
                out.push_str(&format!("<sup>{}</sup>", escape(&name)));
            }
            Event::SoftBreak => out.push('\n'),
            Event::HardBreak => out.push_str("<br>\n"),
            Event::Rule => out.push_str("<hr>\n"),
            Event::TaskListMarker(done) => out.push_str(if done {
                "<input type=\"checkbox\" checked disabled> "
            } else {
                "<input type=\"checkbox\" disabled> "
            }),
            _ => {}
        }
    }
    (out, has_h1 && blocks > 0 && blocks == heading_blocks)
}

fn is_block(tag: &Tag) -> bool {
    matches!(
        tag,
        Tag::Paragraph
            | Tag::Heading { .. }
            | Tag::BlockQuote(_)
            | Tag::CodeBlock(_)
            | Tag::List(_)
            | Tag::Table(_)
            | Tag::HtmlBlock
    )
}

fn heading(level: HeadingLevel) -> &'static str {
    match level {
        HeadingLevel::H1 => "h1",
        HeadingLevel::H2 => "h2",
        HeadingLevel::H3 => "h3",
        HeadingLevel::H4 => "h4",
        HeadingLevel::H5 => "h5",
        HeadingLevel::H6 => "h6",
    }
}

pub(super) fn escape(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            other => escaped.push(other),
        }
    }
    escaped
}
