use std::borrow::Cow;
use std::sync::LazyLock;

use pulldown_cmark::{Event as MdEvent, Options, Parser, Tag, TagEnd};
use ratatui::text::{Line, Span};
use syntect::easy::HighlightLines;
use syntect::highlighting::{Theme, ThemeSet};
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

// Use two-face's extended syntax set which includes TypeScript, Kotlin, Swift, etc.
static SYNTAX_SET: LazyLock<SyntaxSet> = LazyLock::new(two_face::syntax::extra_newlines);
static THEME_SET: LazyLock<ThemeSet> = LazyLock::new(ThemeSet::load_defaults);
static HIGHLIGHT_THEME: LazyLock<Theme> = LazyLock::new(|| {
    let preferred = [
        "base16-eighties.dark",
        "Solarized (dark)",
        "base16-ocean.dark",
    ];
    for name in preferred {
        if let Some(theme) = THEME_SET.themes.get(name) {
            return theme.clone();
        }
    }
    THEME_SET
        .themes
        .values()
        .next()
        .cloned()
        .unwrap_or_default()
});

/// Convert markdown text to ratatui Lines with syntax highlighting for code blocks
pub(crate) fn markdown_to_lines(source: &str) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut current_spans: Vec<Span<'static>> = Vec::new();

    let parser = Parser::new_ext(source, Options::all());

    let mut in_code_block = false;
    let mut code_lang: Option<String> = None;
    let mut code_content = String::new();

    for event in parser {
        match event {
            MdEvent::Start(Tag::CodeBlock(kind)) => {
                if !current_spans.is_empty() {
                    lines.push(Line::from(std::mem::take(&mut current_spans)));
                }
                lines.push(Line::from(""));
                in_code_block = true;
                code_lang = match kind {
                    pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                        let lang_str = lang.to_string();
                        if lang_str.is_empty() {
                            None
                        } else {
                            Some(canonical_language_token(&lang_str).into_owned())
                        }
                    }
                    pulldown_cmark::CodeBlockKind::Indented => None,
                };
                code_content.clear();
            }
            MdEvent::End(TagEnd::CodeBlock) => {
                let highlighted_lines = highlight_code(&code_content, code_lang.as_deref());
                lines.extend(highlighted_lines);
                lines.push(Line::from(""));
                in_code_block = false;
                code_lang = None;
                code_content.clear();
            }
            MdEvent::Text(text) => {
                if in_code_block {
                    code_content.push_str(&text);
                } else {
                    let text_str = text.to_string();
                    let mut parts = text_str.split('\n').peekable();
                    while let Some(part) = parts.next() {
                        if !part.is_empty() {
                            current_spans.push(Span::raw(part.to_owned()));
                        }
                        if parts.peek().is_some() {
                            lines.push(Line::from(std::mem::take(&mut current_spans)));
                        }
                    }
                }
            }
            MdEvent::Code(code) => {
                let code_style = ratatui::style::Style::default()
                    .fg(ratatui::style::Color::Yellow)
                    .add_modifier(ratatui::style::Modifier::BOLD);
                current_spans.push(Span::styled(format!("`{}`", code), code_style));
            }
            MdEvent::Start(Tag::Paragraph) => {}
            MdEvent::End(TagEnd::Paragraph) => {
                if !current_spans.is_empty() {
                    lines.push(Line::from(std::mem::take(&mut current_spans)));
                }
            }
            MdEvent::SoftBreak | MdEvent::HardBreak => {
                if !current_spans.is_empty() {
                    lines.push(Line::from(std::mem::take(&mut current_spans)));
                }
            }
            MdEvent::Start(Tag::Heading { level, .. }) => {
                let prefix = "#".repeat(level as usize);
                let header_style = ratatui::style::Style::default()
                    .fg(ratatui::style::Color::Cyan)
                    .add_modifier(ratatui::style::Modifier::BOLD);
                current_spans.push(Span::styled(format!("{} ", prefix), header_style));
            }
            MdEvent::End(TagEnd::Heading(_)) => {
                if !current_spans.is_empty() {
                    lines.push(Line::from(std::mem::take(&mut current_spans)));
                }
            }
            MdEvent::Start(Tag::Item) => {
                current_spans.push(Span::raw("• ".to_owned()));
            }
            MdEvent::End(TagEnd::Item) => {
                if !current_spans.is_empty() {
                    lines.push(Line::from(std::mem::take(&mut current_spans)));
                }
            }
            _ => {}
        }
    }

    if !current_spans.is_empty() {
        lines.push(Line::from(current_spans));
    }

    lines
}

/// Normalize code fence language tokens to syntect-compatible format.
/// Uses two-face's extended syntax set which includes TypeScript, Kotlin, Swift, etc.
pub(crate) fn normalize_code_fences(content: &str) -> String {
    let mut normalized = String::with_capacity(content.len());
    for line in content.split_inclusive('\n') {
        let (body, newline) = match line.strip_suffix('\n') {
            Some(stripped) => (stripped, "\n"),
            None => (line, ""),
        };

        if let Some(lang) = body.strip_prefix("```") {
            let lang = lang.trim();
            normalized.push_str("```");
            if !lang.is_empty() {
                let canonical = canonical_language_token(lang);
                normalized.push_str(canonical.as_ref());
            }
        } else {
            normalized.push_str(body);
        }

        normalized.push_str(newline);
    }
    normalized
}

fn highlight_code(code: &str, lang: Option<&str>) -> Vec<Line<'static>> {
    let mut lines = Vec::new();

    let syntax = lang
        .and_then(|l| SYNTAX_SET.find_syntax_by_token(l))
        .unwrap_or_else(|| SYNTAX_SET.find_syntax_plain_text());

    let mut highlighter = HighlightLines::new(syntax, &HIGHLIGHT_THEME);

    for line in LinesWithEndings::from(code) {
        match highlighter.highlight_line(line, &SYNTAX_SET) {
            Ok(ranges) => {
                let spans: Vec<Span<'static>> = ranges
                    .into_iter()
                    .map(|(style, text)| {
                        let fg = ratatui::style::Color::Rgb(
                            style.foreground.r,
                            style.foreground.g,
                            style.foreground.b,
                        );
                        let mut ratatui_style = ratatui::style::Style::default().fg(fg);
                        if style
                            .font_style
                            .contains(syntect::highlighting::FontStyle::BOLD)
                        {
                            ratatui_style =
                                ratatui_style.add_modifier(ratatui::style::Modifier::BOLD);
                        }
                        if style
                            .font_style
                            .contains(syntect::highlighting::FontStyle::ITALIC)
                        {
                            ratatui_style =
                                ratatui_style.add_modifier(ratatui::style::Modifier::ITALIC);
                        }
                        Span::styled(text.trim_end_matches('\n').to_owned(), ratatui_style)
                    })
                    .collect();
                lines.push(Line::from(spans));
            }
            Err(_) => {
                lines.push(Line::from(line.trim_end_matches('\n').to_owned()));
            }
        }
    }

    lines
}

fn canonical_language_token(lang: &str) -> Cow<'static, str> {
    let trimmed = lang.trim_start_matches('.');
    let lower = trimmed.to_ascii_lowercase();
    match lower.as_str() {
        // JavaScript variants
        "js" | "javascript" | "node" => Cow::Borrowed("javascript"),
        "jsx" => Cow::Borrowed("jsx"),
        // TypeScript variants (two-face includes TypeScript support)
        "ts" | "typescript" => Cow::Borrowed("typescript"),
        "tsx" => Cow::Borrowed("tsx"),
        // Python
        "py" | "python" => Cow::Borrowed("python"),
        // Ruby
        "rb" | "ruby" => Cow::Borrowed("ruby"),
        // Rust
        "rs" | "rust" => Cow::Borrowed("rust"),
        // Go
        "go" | "golang" => Cow::Borrowed("go"),
        // Java
        "java" => Cow::Borrowed("java"),
        // Kotlin
        "kt" | "kotlin" => Cow::Borrowed("kotlin"),
        // Swift
        "swift" => Cow::Borrowed("swift"),
        // PHP
        "php" => Cow::Borrowed("php"),
        // Shell variants
        "sh" | "bash" | "shell" => Cow::Borrowed("bash"),
        "zsh" => Cow::Borrowed("zsh"),
        "ps" | "ps1" | "powershell" => Cow::Borrowed("powershell"),
        // C family
        "c" => Cow::Borrowed("c"),
        "cpp" | "c++" | "cxx" => Cow::Borrowed("cpp"),
        "cs" | "csharp" | "c#" => Cow::Borrowed("cs"),
        // Objective-C
        "objc" | "objective-c" | "objectivec" => Cow::Borrowed("objective-c"),
        // Data formats
        "json" => Cow::Borrowed("json"),
        "yaml" | "yml" => Cow::Borrowed("yaml"),
        "toml" => Cow::Borrowed("toml"),
        "xml" => Cow::Borrowed("xml"),
        // SQL
        "sql" => Cow::Borrowed("sql"),
        // Web
        "html" | "htm" => Cow::Borrowed("html"),
        "css" => Cow::Borrowed("css"),
        "scss" => Cow::Borrowed("scss"),
        "less" => Cow::Borrowed("less"),
        // Other languages
        "elixir" | "ex" | "exs" => Cow::Borrowed("elixir"),
        "dart" => Cow::Borrowed("dart"),
        "scala" => Cow::Borrowed("scala"),
        "clojure" | "clj" => Cow::Borrowed("clojure"),
        "haskell" | "hs" => Cow::Borrowed("haskell"),
        "lua" => Cow::Borrowed("lua"),
        "perl" | "pl" => Cow::Borrowed("perl"),
        "r" => Cow::Borrowed("r"),
        "julia" | "jl" => Cow::Borrowed("julia"),
        "erlang" | "erl" => Cow::Borrowed("erlang"),
        "groovy" => Cow::Borrowed("groovy"),
        // Markup
        "markdown" | "md" => Cow::Borrowed("markdown"),
        "tex" | "latex" => Cow::Borrowed("latex"),
        "rst" | "restructuredtext" => Cow::Borrowed("restructuredtext"),
        // Config files
        "ini" | "cfg" => Cow::Borrowed("ini"),
        "dockerfile" | "docker" => Cow::Borrowed("dockerfile"),
        "makefile" | "make" => Cow::Borrowed("makefile"),
        // Default: pass through as-is (lowercase)
        _ => Cow::Owned(lower),
    }
}
