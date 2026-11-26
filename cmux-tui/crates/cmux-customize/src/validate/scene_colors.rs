//! Advisory for direct scene color modifiers. Tokenize the authored JS/TS without running it.
//! A color in display text, a comment or a regex is not a scene style.

use std::collections::BTreeMap;

use cmux_config::schema::is_hex_color;
use ress::Scanner;
use ress::tokens::{Punct, Token};

use super::Problem;
use crate::{Change, Part};

pub(crate) fn scene_color_warnings(
    changes: &[Change],
    files: &BTreeMap<String, Vec<u8>>,
) -> Vec<Problem> {
    let mut warnings = Vec::new();
    for change in changes {
        let path = &change.path;
        if change.part != Part::Views
            || ![".js", ".ts", ".mjs"].iter().any(|ext| path.ends_with(ext))
        {
            continue;
        }
        let Some(source) = files.get(path).and_then(|bytes| std::str::from_utf8(bytes).ok()) else {
            continue;
        };
        if source.contains('#') {
            check_modifiers(path, source, &mut warnings);
        }
    }
    warnings
}

fn check_modifiers(path: &str, source: &str, warnings: &mut Vec<Problem>) {
    let mut tokens = Scanner::new(source)
        .map_while(Result::ok)
        .filter(|item| !item.token.is_comment())
        .peekable();
    while let Some(item) = tokens.next() {
        if !item.token.matches_punct(Punct::Period) {
            continue;
        }
        let Some(method) = tokens.next_if(|item| {
            matches!(
                source.get(item.span.start..item.span.end),
                Some(
                    "color"
                        | "foregroundColor"
                        | "background"
                        | "hoverBackground"
                        | "borderColor"
                        | "fill"
                        | "stroke"
                )
            )
        }) else {
            continue;
        };
        if tokens.next_if(|item| item.token.matches_punct(Punct::OpenParen)).is_none() {
            continue;
        }
        let Some(literal) = tokens.next_if(|item| {
            item.is_string() || matches!(&item.token, Token::Template(t) if t.is_no_sub())
        }) else {
            continue;
        };
        // Require a single literal argument. Expressions and interpolated strings are dynamic.
        tokens.next_if(|item| item.token.matches_punct(Punct::Comma));
        if tokens.next_if(|item| item.token.matches_punct(Punct::CloseParen)).is_none() {
            continue;
        }
        let Some(quoted) = source.get(literal.span.start..literal.span.end) else {
            continue;
        };
        let Some(color) = quoted.get(1..quoted.len().saturating_sub(1)) else {
            continue;
        };
        if color.starts_with('#') && is_hex_color(color) {
            let Some(method) = source.get(method.span.start..method.span.end) else {
                continue;
            };
            let position = literal.location.start;
            warnings.push(Problem::at(
                path, Some(position.line as u32), Some(position.column as u32),
                format!("literal color {color} in .{method}(). Use a scene color token such as \"secondary\" or \"accent\" to follow the theme"),
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::check_modifiers;

    #[test]
    fn scene_color_warnings_handle_unicode_and_incomplete_source() {
        for method in [
            "color",
            "foregroundColor",
            "background",
            "hoverBackground",
            "borderColor",
            "fill",
            "stroke",
        ] {
            let source = format!("Text('日本語 🦀').{method}('#112233')");
            let mut warnings = Vec::new();
            check_modifiers("main.js", &source, &mut warnings);
            assert_eq!(warnings.len(), 1, "{source}");
            assert!(
                warnings
                    .iter()
                    .any(|warning| warning.message.contains(&format!("#112233 in .{method}()")))
            );
        }
        for source in [
            "Text('🦀').color('é#112233')",
            "Text('🦀').色('#112233')",
            "Text('🦀').color('')",
            "Text('🦀').color('#112233",
            "Text('🦀').color(`#${色}`)",
        ] {
            let mut warnings = Vec::new();
            check_modifiers("main.js", source, &mut warnings);
            assert!(warnings.is_empty(), "{source}");
        }
    }
}
