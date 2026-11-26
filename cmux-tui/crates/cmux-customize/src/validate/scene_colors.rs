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
                &source[item.span.start..item.span.end],
                "color"
                    | "foregroundColor"
                    | "background"
                    | "hoverBackground"
                    | "borderColor"
                    | "fill"
                    | "stroke"
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
        let color = &source[literal.span.start + 1..literal.span.end - 1];
        if color.starts_with('#') && is_hex_color(color) {
            let method = &source[method.span.start..method.span.end];
            let position = literal.location.start;
            warnings.push(Problem::at(
                path, Some(position.line as u32), Some(position.column as u32),
                format!("literal color {color} in .{method}(). Use a scene color token such as \"secondary\" or \"accent\" to follow the theme"),
            ));
        }
    }
}
