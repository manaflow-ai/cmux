//! What the checks share: the Rust files of a tree, paths and line numbers.

use std::path::{Path, PathBuf};

use proc_macro2::{Span, TokenStream, TokenTree};

/// The `.rs` files under `dir` (or `dir` itself when it is one), sorted, leaving out `target`
/// directories.
pub fn rust_files(dir: &Path) -> Vec<PathBuf> {
    if dir.is_file() {
        return vec![dir.to_path_buf()];
    }
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(at) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&at) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if path.file_name().is_some_and(|n| n != "target") {
                    stack.push(path);
                }
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

/// `path` from `root`, with `/` between its parts (`path` as given when it is not under `root`).
pub fn rel_path(root: &Path, path: &Path) -> String {
    let rel = path.strip_prefix(root).unwrap_or(path);
    rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/")
}

/// The 1-based line a span starts on.
pub fn line_of(span: Span) -> usize {
    span.start().line
}

/// Whether `tokens` hold the identifier `name` at any depth.
pub fn has_ident(tokens: TokenStream, name: &str) -> bool {
    tokens.into_iter().any(|tree| match tree {
        TokenTree::Ident(ident) => ident == name,
        TokenTree::Group(group) => has_ident(group.stream(), name),
        _ => false,
    })
}

/// The source text of `span` in `lines` (the file's lines), its whitespace folded.
pub fn snippet(lines: &[&str], span: Span) -> String {
    let (start, end) = (span.start(), span.end());
    let mut text = String::new();
    for line in start.line..=end.line {
        let Some(row) = lines.get(line.wrapping_sub(1)) else {
            continue;
        };
        let from = if line == start.line { start.column } else { 0 };
        let to = if line == end.line { end.column } else { usize::MAX };
        text.extend(row.chars().skip(from).take(to.saturating_sub(from)));
        text.push(' ');
    }
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}
