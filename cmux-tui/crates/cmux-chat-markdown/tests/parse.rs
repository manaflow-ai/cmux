//! The parser's behaviour, as the Home transcript's Swift parser had it (MessagesLab catalyst
//! MarkdownParser.swift): blocks, inlines, the link policy and the stream tail.

use cmux_chat_markdown::{
    Align, Block, DefaultPolicy, Document, Kind, LinkPolicy, Span, Text, might_contain, parse,
    parse_inline, parse_tail, placeholder_from_templates, sanitize, style,
};

fn doc(s: &str) -> Document {
    parse(s, &DefaultPolicy)
}

fn kinds(s: &str) -> Vec<Kind> {
    doc(s).blocks.into_iter().map(|b| b.kind).collect()
}

fn one(s: &str) -> Kind {
    let mut k = kinds(s);
    assert_eq!(k.len(), 1, "{s:?} gave {k:?}");
    k.remove(0)
}

fn para(s: &str) -> Text {
    match one(s) {
        Kind::Paragraph(t) => t,
        k => panic!("{s:?} is not a paragraph: {k:?}"),
    }
}

fn span(location: usize, length: usize, style: u16) -> Span {
    Span { location, length, style, link: None, image: None }
}

fn link(location: usize, length: usize, url: &str) -> Span {
    Span { location, length, style: style::LINK, link: Some(url.to_owned()), image: None }
}

fn plain(s: &str) -> Text {
    Text { string: s.to_owned(), spans: Vec::new() }
}

#[test]
fn plain_text_is_one_plain_paragraph() {
    let d = doc("hello world");
    assert!(!d.is_rich);
    assert_eq!(d.blocks.len(), 1);
    assert_eq!(para("hello world"), plain("hello world"));
}

#[test]
fn empty_text_has_no_blocks() {
    assert!(doc("").blocks.is_empty());
    assert!(doc("\n\n  \n").blocks.is_empty());
}

#[test]
fn newline_in_a_paragraph_is_a_line_break() {
    assert_eq!(para("one\ntwo").string, "one\ntwo");
    assert!(!doc("one\ntwo").is_rich);
    assert_eq!(para("one  \ntwo\\\nthree").string, "one\ntwo\nthree");
}

#[test]
fn blank_lines_separate_paragraphs() {
    let d = doc("a\n\nb");
    assert_eq!(d.blocks.len(), 2);
    let first = d.blocks.first().cloned();
    let second = d.blocks.get(1).cloned();
    assert!(!first.as_ref().is_some_and(|b| b.blank_before));
    assert!(second.as_ref().is_some_and(|b| b.blank_before));
    assert_eq!(first.map(|b| b.lines), Some((0, 1)));
    assert_eq!(second.map(|b| b.lines), Some((2, 3)));
}

#[test]
fn emphasis_strong_strike_code() {
    assert_eq!(para("*a* b").spans, vec![span(0, 1, style::EMPHASIS)]);
    assert_eq!(para("**a** b").spans, vec![span(0, 1, style::STRONG)]);
    assert_eq!(para("~~a~~").spans, vec![span(0, 1, style::STRIKE)]);
    assert_eq!(para("`a`").spans, vec![span(0, 1, style::CODE)]);
    assert_eq!(para("***a***").spans, vec![span(0, 1, style::EMPHASIS | style::STRONG)]);
    assert_eq!(para("x _a_ y").string, "x a y");
    assert!(doc("*a*").is_rich);
}

#[test]
fn intraword_underscore_is_literal() {
    let t = para("snake_case_name");
    assert_eq!(t.string, "snake_case_name");
    assert!(t.spans.is_empty());
    let t = para("in*tra*word");
    assert_eq!(t.string, "intraword");
    assert_eq!(t.spans, vec![span(2, 3, style::EMPHASIS)]);
}

#[test]
fn unmatched_delimiters_stay_literal() {
    assert_eq!(para("a * b").string, "a * b");
    assert_eq!(para("**a").string, "**a");
    assert_eq!(para("~a~").spans, vec![span(0, 1, style::STRIKE)]);
}

#[test]
fn code_span_strips_one_space_and_keeps_backslashes() {
    assert_eq!(para("`` `a` ``").string, "`a`");
    assert_eq!(para("`a\\*b`").string, "a\\*b");
    assert_eq!(para("``a").string, "``a");
}

#[test]
fn escapes_and_entities() {
    assert_eq!(para("\\*a\\*").string, "*a*");
    assert_eq!(para("a &amp; b &lt; &#65; &#x42; &bogus;").string, "a & b < A B &bogus;");
    assert_eq!(para("&#0;").string, "\u{FFFD}");
}

#[test]
fn raw_html_stays_literal() {
    assert_eq!(para("<b>hi</b>").string, "<b>hi</b>");
    assert!(para("<b>hi</b>").spans.is_empty());
}

#[test]
fn inline_links_follow_the_policy() {
    let t = para("[cmux](https://cmux.com) x");
    assert_eq!(t.string, "cmux x");
    assert_eq!(t.spans, vec![link(0, 4, "https://cmux.com")]);
    let t = para("[bad](javascript:alert(1))");
    assert_eq!(t.string, "bad");
    assert!(t.spans.is_empty());
    let t = para("[a](<https://x.com/a> \"title\")");
    assert_eq!(t.spans, vec![link(0, 1, "https://x.com/a")]);
}

#[test]
fn reference_links_resolve() {
    let d = doc("see [x][Ref] and [ref]\n\n[ref]: https://a.com \"t\"");
    assert_eq!(d.blocks.len(), 1);
    let Some(Kind::Paragraph(t)) = d.blocks.first().map(|b| b.kind.clone()) else {
        panic!("{d:?}")
    };
    assert_eq!(t.string, "see x and ref");
    assert_eq!(t.spans, vec![link(4, 1, "https://a.com"), link(10, 3, "https://a.com")]);
}

#[test]
fn unknown_reference_is_literal() {
    assert_eq!(para("[x][nope]").string, "[x][nope]");
}

#[test]
fn autolinks() {
    let t = para("go to https://cmux.com/a.");
    assert_eq!(t.string, "go to https://cmux.com/a.");
    assert_eq!(t.spans, vec![link(6, 18, "https://cmux.com/a")]);
    assert!(!doc("go to https://cmux.com/a.").is_rich);
    let t = para("www.example.com");
    assert_eq!(t.spans, vec![link(0, 15, "http://www.example.com")]);
    let t = para("<https://a.com>");
    assert_eq!(t.string, "https://a.com");
    assert_eq!(t.spans, vec![link(0, 13, "https://a.com")]);
    let t = para("mail a@b.co now");
    assert_eq!(t.spans, vec![link(5, 6, "mailto:a@b.co")]);
}

#[test]
fn images_are_placeholders() {
    let t = para("![cat](https://a.com/c.png)");
    assert_eq!(t.string, "[Image: cat]");
    assert_eq!(t.spans.len(), 1);
    let s = t.spans.first().cloned().unwrap_or_else(|| span(0, 0, 0));
    assert_eq!(s.image.as_deref(), Some("https://a.com/c.png"));
    assert_eq!(s.style & style::IMAGE, style::IMAGE);
    assert_eq!(para("![](x)").string, "[Image]");
}

#[test]
fn headings() {
    assert!(matches!(one("# Title"), Kind::Heading(1, t) if t.string == "Title"));
    assert!(matches!(one("### T ###"), Kind::Heading(3, t) if t.string == "T"));
    assert!(matches!(one("#hashtag"), Kind::Paragraph(_)));
    assert!(matches!(one("####### seven"), Kind::Paragraph(_)));
    assert!(matches!(one("Title\n==="), Kind::Heading(1, t) if t.string == "Title"));
    assert!(matches!(one("Title\n---"), Kind::Heading(2, _)));
}

#[test]
fn code_blocks() {
    match one("```swift\nlet a = 1\n```") {
        Kind::Code { lang, text, fenced, closed } => {
            assert_eq!(lang, "swift");
            assert_eq!(text, "let a = 1");
            assert!(fenced && closed);
        }
        k => panic!("{k:?}"),
    }
    match one("```\nstreaming") {
        Kind::Code { closed, text, .. } => {
            assert!(!closed);
            assert_eq!(text, "streaming");
        }
        k => panic!("{k:?}"),
    }
    match one("    indented\n    code") {
        Kind::Code { fenced, text, .. } => {
            assert!(!fenced);
            assert_eq!(text, "indented\ncode");
        }
        k => panic!("{k:?}"),
    }
    match one("~~~\n```\n~~~") {
        Kind::Code { text, .. } => assert_eq!(text, "```"),
        k => panic!("{k:?}"),
    }
}

#[test]
fn rules_and_quotes() {
    assert_eq!(one("---"), Kind::Rule);
    assert_eq!(one("* * *"), Kind::Rule);
    match one("> a\n> b") {
        Kind::Quote(b) => {
            assert_eq!(b.len(), 1);
            assert!(
                matches!(b.first().map(|b| &b.kind), Some(Kind::Paragraph(t)) if t.string == "a\nb")
            );
        }
        k => panic!("{k:?}"),
    }
    match one("> a\nlazy") {
        Kind::Quote(b) => assert!(
            matches!(b.first().map(|b| &b.kind), Some(Kind::Paragraph(t)) if t.string == "a\nlazy")
        ),
        k => panic!("{k:?}"),
    }
}

#[test]
fn lists() {
    match one("- a\n- b") {
        Kind::List(l) => {
            assert!(!l.ordered && !l.loose);
            assert_eq!(l.items.len(), 2);
            assert_eq!(l.items.first().map(|i| i.marker.as_str()), Some("-"));
        }
        k => panic!("{k:?}"),
    }
    match one("3. a\n4. b") {
        Kind::List(l) => {
            assert!(l.ordered);
            assert_eq!(l.start, 3);
            assert_eq!(l.items.get(1).map(|i| i.marker.as_str()), Some("4."));
        }
        k => panic!("{k:?}"),
    }
    match one("- a\n\n- b") {
        Kind::List(l) => assert!(l.loose),
        k => panic!("{k:?}"),
    }
    match one("- a\n  - nested") {
        Kind::List(l) => {
            let inner = l.items.first().map(|i| i.blocks.clone()).unwrap_or_default();
            assert!(inner.iter().any(|b| matches!(b.kind, Kind::List(_))), "{inner:?}");
        }
        k => panic!("{k:?}"),
    }
    assert_eq!(kinds("- a\n* b").len(), 2);
}

#[test]
fn task_lists() {
    match one("- [ ] open\n- [x] done\n- plain") {
        Kind::List(l) => {
            let tasks: Vec<_> = l.items.iter().map(|i| i.task).collect();
            assert_eq!(tasks, vec![Some(false), Some(true), None]);
            assert!(matches!(
                l.items.first().and_then(|i| i.blocks.first()).map(|b| &b.kind),
                Some(Kind::Paragraph(t)) if t.string == "open"
            ));
        }
        k => panic!("{k:?}"),
    }
}

#[test]
fn tables() {
    match one("| a | b |\n|:-|-:|\n| 1 | `x|y` |\n| 2 | 3 | 4 |") {
        Kind::Table(t) => {
            // A row wider than the header widens the table; its extra column has no alignment.
            assert_eq!(t.aligns, vec![Align::Left, Align::Right, Align::None]);
            assert_eq!(t.header, vec![plain("a"), plain("b"), plain("")]);
            assert_eq!(t.rows.len(), 2);
            assert_eq!(
                t.rows.first().and_then(|r| r.get(1)).map(|c| c.string.as_str()),
                Some("x|y")
            );
            assert_eq!(t.rows.iter().map(Vec::len).collect::<Vec<_>>(), vec![3, 3]);
        }
        k => panic!("{k:?}"),
    }
    assert!(matches!(one("a | b\n--|--"), Kind::Table(_)));
    assert!(matches!(one("a | b\n--|--|--"), Kind::Paragraph(_)));
    let k = kinds("intro\n| a |\n|---|\n| 1 |");
    assert_eq!(k.len(), 2, "{k:?}");
    assert!(matches!(k.get(1), Some(Kind::Table(_))));
}

#[test]
fn might_contain_is_a_superset() {
    assert!(!might_contain(b"hello world"));
    for s in
        ["*a*", "# h", "a\n- b", "`c`", "[a](b)", "https://x", "a | b", "&amp;", "1. x", "x@y.z"]
    {
        if doc(s).is_rich {
            assert!(might_contain(s.as_bytes()), "{s:?}");
        }
    }
}

#[test]
fn stream_tail_matches_the_whole_parse() {
    let text = "# T\n\npara one\nline\n\n- a\n- b\n\n```\ncode";
    let whole = doc(text).blocks;
    let last = whole.last().cloned();
    let Some(last) = last else { panic!("no blocks") };
    let tail = parse_tail(text, last.lines.0, &DefaultPolicy);
    assert_eq!(tail.len(), 1);
    let first: Option<&Block> = tail.first();
    assert_eq!(first.map(|b| &b.kind), Some(&last.kind));
    assert_eq!(first.map(|b| b.lines), Some(last.lines));
    assert!(parse_tail(text, 1000, &DefaultPolicy).is_empty());
}

#[test]
fn inline_alone() {
    let t = parse_inline("a *b*\nc", true, &DefaultPolicy);
    assert_eq!(t.string, "a b\nc");
    assert_eq!(t.spans, vec![span(2, 1, style::EMPHASIS)]);
}

#[test]
fn utf16_offsets() {
    let t = para("😀 *a*");
    assert_eq!(t.spans, vec![span(3, 1, style::EMPHASIS)]);
}

struct OnlyExample;

impl LinkPolicy for OnlyExample {
    fn allows(&self, url: &str) -> bool {
        url.starts_with("https://example.com")
    }

    fn image_placeholder(&self, alt: &str) -> String {
        format!("<{alt}>")
    }
}

#[test]
fn host_policy_decides_links_and_placeholders() {
    let d = parse("[a](https://example.com) [b](https://other.com) ![c](x)", &OnlyExample);
    let Some(Kind::Paragraph(t)) = d.blocks.first().map(|b| b.kind.clone()) else {
        panic!("{d:?}")
    };
    assert_eq!(t.string, "a b <c>");
    assert_eq!(t.spans.iter().filter(|s| s.link.is_some()).count(), 1);
}

#[test]
fn sanitize_trims_and_checks_the_scheme() {
    assert_eq!(
        sanitize(&DefaultPolicy, " https://a.com\u{200B}").as_deref(),
        Some("https://a.com")
    );
    assert_eq!(sanitize(&DefaultPolicy, "//a.com"), None);
    assert_eq!(sanitize(&DefaultPolicy, "1http://a.com"), None);
    assert_eq!(sanitize(&DefaultPolicy, "https://"), None);
    assert_eq!(sanitize(&DefaultPolicy, "mailto:a@b.c").as_deref(), Some("mailto:a@b.c"));
    assert_eq!(sanitize(&DefaultPolicy, "file:///etc"), None);
}

#[test]
fn placeholder_templates() {
    assert_eq!(placeholder_from_templates("[Image]", "[Image: %@]", ""), "[Image]");
    assert_eq!(placeholder_from_templates("[Image]", "[Image: %@]", "a%b"), "[Image: a%b]");
    assert_eq!(placeholder_from_templates("x", "%% %@ %@", "a"), "% a %@");
}

#[test]
fn hostile_inputs_finish() {
    let deep = "> ".repeat(500) + "x";
    let _ = doc(&deep);
    let nest = "- ".repeat(300) + "x";
    let _ = doc(&nest);
    let brackets = "[".repeat(5000) + &"]".repeat(5000);
    let _ = doc(&brackets);
    let stars = "*a ".repeat(5000);
    let _ = doc(&stars);
    let ticks = "`".repeat(3000) + "a";
    let _ = doc(&ticks);
    let _ = doc("\u{0}\u{FFFF}\r\n\t\u{2028}");
}
